///|
priv struct RowEvidence {
  estimated : Double?
  actual : Double?
  loops : Double?
}

///|
priv struct JoinInput {
  path : String
  fields : Map[String, Json]
  rows : RowEvidence
}

///|
fn bounded_rows(value : Json?, integral~ : Bool) -> Double? {
  match value {
    Some(Number(n, ..)) if n >= 0.0 &&
      n <= 281474976710656.0 &&
      (!integral || n.to_int64().to_double() == n) => Some(n)
    _ => None
  }
}

///|
fn row_evidence(fields : Map[String, Json]) -> RowEvidence {
  {
    estimated: bounded_rows(fields.get("Plan Rows"), integral=true),
    actual: bounded_rows(fields.get("Actual Rows"), integral=false),
    loops: bounded_rows(fields.get("Actual Loops"), integral=true),
  }
}

///|
/// Analyze observed row counts per execution and locate the deepest confirmed
/// discrepancies. InputError concerns capture decoding, not missing metrics.
pub fn analyze_cardinality(capture : Capture) -> Json raise InputError {
  let findings : Array[Json] = []
  let nested_loops : Array[Json] = []
  let mut incomplete = !capture.limitations.is_empty()
  if !incomplete {
    guard strict_json(capture.source) is Array([{ "Plan": plan, .. }]) else {
      raise invalid("MissingPlan", "/0/Plan", "capture requires a plan")
    }
    let (_, partial, _) = analyze_node(
      plan, "/0/Plan", false, findings, nested_loops,
    )
    incomplete = partial
  }
  Json::object({
    "schema": Json::number(1),
    "mode": Json::string("cardinality"),
    "exit_code": Json::number(if incomplete { 3 } else { 0 }),
    "query_id": Json::string(capture.context.query_id),
    "nodes": Json::array(findings),
    "nested_loops": Json::array(nested_loops),
    "limitations": Json::array(
      capture.limitations.map(diag => {
        Json::object({
          "code": Json::string(diag.code),
          "path": Json::string(diag.path),
          "message": Json::string(diag.message),
        })
      }),
    ),
  })
}

///|
fn number_or_null(value : Double?) -> Json {
  value.map(n => Json::number(n)).unwrap_or(Json::null())
}

///|
fn observed_row_bounds(rows : RowEvidence) -> (Double, Double)? {
  match (rows.actual, rows.loops) {
    (Some(actual), Some(1.0)) if actual.to_int64().to_double() == actual =>
      Some((actual, actual))
    (Some(actual), Some(loops)) if loops > 1.0 => {
      // PostgreSQL 18 prints the average with two fractional digits.
      // Leave extra room for floating-point conversion and arithmetic.
      let tolerance = 0.0051 + actual * 0.000000000000001
      Some(
        (
          if actual > tolerance {
            actual - tolerance
          } else {
            0.0
          },
          actual + tolerance,
        ),
      )
    }
    _ => None
  }
}

///|
fn analyze_node(
  plan : Json,
  path : String,
  demand_limited : Bool,
  findings : Array[Json],
  nested_loops : Array[Json],
) -> (Bool, Bool, RowEvidence) raise InputError {
  let fields = object(plan, path)
  let kind = text(fields, "Node Type", path)
  let rows = row_evidence(fields)
  let child_limit = demand_limited ||
    kind == "Limit" ||
    fields.get("Join Type") is Some(String("Semi" | "Anti"))
  let mut descendant_error = false
  let mut incomplete = false
  let outer : Array[JoinInput] = []
  let inner : Array[JoinInput] = []
  if fields.get("Plans") is Some(Array(children)) {
    for i, child in children {
      let child_path = path + "/Plans/" + i.to_string()
      let (error, partial, child_rows) = analyze_node(
        child, child_path, child_limit, findings, nested_loops,
      )
      if kind == "Nested Loop" {
        let child_fields = object(child, child_path)
        let input = JoinInput::{
          path: child_path,
          fields: child_fields,
          rows: child_rows,
        }
        match child_fields.get("Parent Relationship") {
          Some(String("Outer")) => outer.push(input)
          Some(String("Inner")) => inner.push(input)
          _ => ()
        }
      }
      descendant_error = descendant_error || error
      incomplete = incomplete || partial
    }
  }
  if kind == "Nested Loop" && rows.loops != Some(0.0) {
    let (loop_report, partial) = analyze_nested_loop(path, rows, outer, inner)
    nested_loops.push(loop_report)
    incomplete = incomplete || partial
  }
  let bounds = observed_row_bounds(rows)
  let (status, factor) = match (rows.estimated, bounds, rows.loops) {
    (_, _, Some(0.0)) => ("not_executed", None)
    _ if demand_limited => ("demand_limited", None)
    _ if kind == "Bitmap Index Scan" => ("bitmap_counters", None)
    (Some(est), Some((lower, upper)), _) =>
      if est < lower {
        ("underestimated", if est > 0.0 { Some(lower / est) } else { None })
      } else if est > upper {
        ("overestimated", if upper > 0.0 { Some(est / upper) } else { None })
      } else {
        ("consistent", None)
      }
    _ => ("missing_or_invalid_metrics", None)
  }
  let error = status == "underestimated" || status == "overestimated"
  findings.push(
    Json::object({
      "path": Json::string(path),
      "kind": Json::string(kind),
      "status": Json::string(status),
      "estimated_rows_per_loop": number_or_null(rows.estimated),
      "actual_rows_per_loop": number_or_null(rows.actual),
      "loops": number_or_null(rows.loops),
      "factor_lower_bound": number_or_null(factor),
      "deepest_confirmed": Json::boolean(error && !descendant_error),
    }),
  )
  (
    error || descendant_error,
    incomplete || status == "missing_or_invalid_metrics",
    rows,
  )
}

///|
fn analyze_nested_loop(
  path : String,
  join : RowEvidence,
  outer : Array[JoinInput],
  inner : Array[JoinInput],
) -> (Json, Bool) {
  guard outer is [outer_input] && inner is [inner_input] else {
    return (
      Json::object({
        "path": Json::string(path),
        "status": Json::string("ambiguous_join_roles"),
      }),
      true,
    )
  }
  let outer_rows = outer_input.rows
  let inner_rows = inner_input.rows
  let invocations = match (inner_rows.loops, join.loops) {
    (Some(child), Some(parent)) if parent > 0.0 => Some(child / parent)
    _ => None
  }
  let relative_to_estimate = match (invocations, outer_rows.estimated) {
    (Some(observed), Some(estimated)) if estimated > 0.0 =>
      Some(observed / estimated)
    _ => None
  }
  let inner_output = match (inner_rows.actual, inner_rows.loops) {
    (_, Some(0.0)) => Some(0.0)
    (Some(avg), Some(loops)) if observed_row_bounds(inner_rows) is Some(_) =>
      Some(avg * loops)
    _ => None
  }
  let output_bounds = match
    (observed_row_bounds(inner_rows), inner_rows.loops) {
    (_, Some(0.0)) => Json::array([Json::number(0), Json::number(0)])
    (Some((lower, upper)), Some(loops)) =>
      Json::array([Json::number(lower * loops), Json::number(upper * loops)])
    _ => Json::null()
  }
  let complete = invocations is Some(_) &&
    outer_rows.estimated is Some(_) &&
    outer_rows.actual is Some(_) &&
    outer_rows.loops is Some(_) &&
    inner_output is Some(_)
  (
    Json::object({
      "path": Json::string(path),
      "status": Json::string(
        if complete {
          "observed"
        } else {
          "missing_or_invalid_metrics"
        },
      ),
      "outer_path": Json::string(outer_input.path),
      "inner_path": Json::string(inner_input.path),
      "outer_estimated_rows_per_loop": number_or_null(outer_rows.estimated),
      "outer_actual_rows_per_loop": number_or_null(outer_rows.actual),
      "outer_loops": number_or_null(outer_rows.loops),
      "join_loops": number_or_null(join.loops),
      "inner_loops": number_or_null(inner_rows.loops),
      "inner_invocations_per_join_loop": number_or_null(invocations),
      "invocations_vs_outer_row_estimate": number_or_null(relative_to_estimate),
      "approx_inner_output_rows": number_or_null(inner_output),
      "inner_output_row_bounds": output_bounds,
      "inner_index_searches": number_or_null(
        bounded_rows(inner_input.fields.get("Index Searches"), integral=true),
      ),
    }),
    !complete,
  )
}
