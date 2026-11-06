///|
/// Read exactly one PostgreSQL 18 EXPLAIN JSON result. Unknown semantics are
/// retained in source() and make all policy checks inconclusive.
pub fn read_plan(
  source : String,
  context : Context,
) -> Capture raise InputError {
  if source.length() > 524288 {
    raise invalid("PlanSize", "", "plan exceeds 524,288 UTF-16 units")
  }
  guard strict_json(source) is Array([top]) else {
    raise invalid(
      "PlanEnvelope", "", "expected an array containing exactly one EXPLAIN result",
    )
  }
  let fields = object(top, "/0")
  guard fields.get("Plan") is Some(plan) else {
    raise invalid(
      "MissingPlan", "/0/Plan", "capture with EXPLAIN (VERBOSE, FORMAT JSON)",
    )
  }
  let limitations : Array[Diagnostic] = []
  unknown_fields(
    fields,
    [
      "Plan", "Planning", "Planning Time", "Execution Time", "Settings", "Triggers",
    ],
    "/0",
    limitations,
  )
  match fields.get("Triggers") {
    None | Some(Array([])) => ()
    Some(Array(_)) =>
      limitations.push({
        code: "Triggers",
        path: "/0/Triggers",
        message: "trigger execution is outside the SELECT profile",
      })
    _ =>
      raise invalid("TriggersArray", "/0/Triggers", "expected a trigger array")
  }
  let nodes : Array[PlanNode] = []
  walk_plan(plan, "/0/Plan", nodes, limitations)
  { context, source, nodes, limitations, }
}

///|
fn pointer(key : String) -> String {
  key.replace(old="~", new="~0").replace(old="/", new="~1")
}

///|
fn unknown_fields(
  fields : Map[String, Json],
  allowed : Array[String],
  path : String,
  out : Array[Diagnostic],
) -> Unit {
  let keys = fields.keys().collect()
  keys.sort()
  for key in keys {
    if !allowed.contains(key) {
      out.push({
        code: "UnsupportedField",
        path: path + "/" + pointer(key),
        message: "field is retained but outside this profile: " + key,
      })
    }
  }
}

///|
fn walk_plan(
  value : Json,
  path : String,
  nodes : Array[PlanNode],
  limitations : Array[Diagnostic],
) -> Unit raise InputError {
  if nodes.length() >= 10000 {
    raise invalid("NodeLimit", path, "at most 10,000 plan nodes are supported")
  }
  let fields = object(value, path)
  let kind = text(fields, "Node Type", path)
  let kinds = [
    "Seq Scan", "Index Scan", "Index Only Scan", "Bitmap Heap Scan", "Bitmap Index Scan",
    "Nested Loop", "Hash Join", "Merge Join", "Hash", "Sort", "Aggregate", "Limit",
    "Result", "Materialize", "Unique", "Subquery Scan", "Append",
  ]
  if !kinds.contains(kind) {
    limitations.push({
      code: "UnsupportedNode",
      path: path + "/Node Type",
      message: "node kind outside the nonparallel SELECT profile: " + kind,
    })
  }
  for key in ["Parallel Aware", "Async Capable", "Disabled"] {
    if boolean(fields, key, path, default=false) {
      limitations.push({
        code: "ParallelPlan",
        path: path + "/" + key,
        message: "capture a nonparallel, nonasync plan for this profile",
      })
    }
  }
  unknown_fields(
    fields,
    [
      "Node Type", "Parent Relationship", "Parallel Aware", "Async Capable", "Disabled",
      "Startup Cost", "Total Cost", "Plan Rows", "Plan Width", "Actual Startup Time",
      "Actual Total Time", "Actual Rows", "Actual Loops", "Output", "Filter", "Rows Removed by Filter",
      "Schema", "Relation Name", "Alias", "Scan Direction", "Index Name", "Index Cond",
      "Recheck Cond", "Rows Removed by Index Recheck", "Heap Fetches", "Exact Heap Blocks",
      "Lossy Heap Blocks", "Join Type", "Inner Unique", "Join Filter", "Rows Removed by Join Filter",
      "Hash Cond", "Merge Cond", "Hash Buckets", "Original Hash Buckets", "Hash Batches",
      "Original Hash Batches", "Peak Memory Usage", "Sort Key", "Sort Method", "Sort Space Used",
      "Sort Space Type", "Strategy", "Partial Mode", "Group Key", "HashAgg Batches",
      "Planned Partitions", "Disk Usage", "Subplan Name", "Shared Hit Blocks", "Shared Read Blocks",
      "Shared Dirtied Blocks", "Shared Written Blocks", "Local Hit Blocks", "Local Read Blocks",
      "Local Dirtied Blocks", "Local Written Blocks", "Temp Read Blocks", "Temp Written Blocks",
      "I/O Read Time", "I/O Write Time", "Temp I/O Read Time", "Temp I/O Write Time",
      "Shared I/O Read Time", "Shared I/O Write Time", "Local I/O Read Time", "Local I/O Write Time",
      "Plans",
    ],
    path,
    limitations,
  )
  let relation = match optional_text(fields, "Relation Name", path) {
    Some(name) =>
      Some(Relation::{
        schema: text(fields, "Schema", path),
        name,
        table_alias: text(fields, "Alias", path),
      })
    None => None
  }
  if ["Seq Scan", "Index Scan", "Index Only Scan", "Bitmap Heap Scan"].contains(
      kind,
    ) &&
    relation is None {
    raise invalid(
      "MissingRelation", path, "relation scans require Schema, Relation Name and Alias; capture VERBOSE",
    )
  }
  let index_name = optional_text(fields, "Index Name", path)
  if ["Index Scan", "Index Only Scan", "Bitmap Index Scan"].contains(kind) &&
    index_name is None {
    raise invalid("MissingIndex", path, "index scans require Index Name")
  }
  let sort_space = optional_text(fields, "Sort Space Type", path)
  if sort_space is Some(space) && space != "Memory" && space != "Disk" {
    raise invalid(
      "SortSpace",
      path + "/Sort Space Type",
      "expected Memory or Disk",
    )
  }
  nodes.push({
    info: { path, kind, relation, index_name, },
    shared_reads: optional_count(fields, "Shared Read Blocks", path),
    shared_writes: optional_count(fields, "Shared Written Blocks", path),
    temp_writes: optional_count(fields, "Temp Written Blocks", path),
    sort_space,
  })
  match fields.get("Plans") {
    None => ()
    Some(Array(children)) =>
      for i, child in children {
        walk_plan(child, path + "/Plans/" + i.to_string(), nodes, limitations)
      }
    _ =>
      raise invalid(
        "PlansArray",
        path + "/Plans",
        "expected an array of child plan objects",
      )
  }
}

///|
/// Versioned evidence envelope. The raw plan string is preserved verbatim.
pub fn Capture::encode(self : Capture) -> String {
  Json::object({
    "schema": Json::number(1),
    "kind": Json::string("moonplanwatch/capture"),
    "context": self.context.to_json(),
    "plan_source": Json::string(self.source),
  }).stringify()
}

///|
pub fn decode_capture(source : String) -> Capture raise InputError {
  let fields = object(strict_json(source), "")
  closed(fields, ["schema", "kind", "context", "plan_source"], "")
  guard fields.get("schema") is Some(schema) && count(schema, "/schema") == 1UL else {
    raise invalid("CaptureSchema", "/schema", "expected capture schema 1")
  }
  if text(fields, "kind", "") != "moonplanwatch/capture" {
    raise invalid("CaptureKind", "/kind", "wrong evidence kind")
  }
  guard fields.get("context") is Some(context) else {
    raise invalid("MissingContext", "/context", "capture identity is required")
  }
  read_plan(text(fields, "plan_source", ""), context_value(context))
}
