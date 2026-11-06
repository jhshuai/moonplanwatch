///|
/// A diagnostic path is a JSON Pointer into the original plan or configuration.
#derive(Eq, Debug)
pub(all) struct Diagnostic {
  code : String
  path : String
  message : String
}

///|
#derive(Debug)
pub(all) suberror InputError {
  Invalid(Diagnostic)
}

///|
fn invalid(code : String, path : String, message : String) -> InputError {
  Invalid({ code, path, message, })
}

///|
/// Caller-declared capture identity, not proof of database origin or isolation.
#derive(Eq)
pub struct Context {
  priv query_id : String
  priv parameters_id : String
  priv dataset_id : String
  priv server_version : String
  priv settings_id : String
}

///|
pub fn Context::new(
  query_id~ : String,
  parameters_id~ : String,
  dataset_id~ : String,
  server_version~ : String,
  settings_id~ : String,
) -> Context raise InputError {
  for
    (name, value) in [
      ("query_id", query_id),
      ("parameters_id", parameters_id),
      ("dataset_id", dataset_id),
      ("server_version", server_version),
      ("settings_id", settings_id),
    ] {
    if value.trim().is_empty() || value.length() > 256 {
      raise invalid(
        "ContextValue",
        "/context/" + name,
        "use a nonblank identifier of at most 256 UTF-16 units",
      )
    }
  }
  if !server_version.has_prefix("18.") ||
    !server_version[3:].iter().all(char => char is ('0'..<='9')) ||
    server_version.length() == 3 {
    raise invalid(
      "ServerVersion", "/context/server_version", "this profile requires a PostgreSQL 18.x numeric version",
    )
  }
  { query_id, parameters_id, dataset_id, server_version, settings_id, }
}

///|
pub fn Context::query_id(self : Context) -> String {
  self.query_id
}

///|
#derive(Eq, Debug)
pub(all) struct Relation {
  schema : String
  name : String
  table_alias : String
}

///|
#derive(Eq, Debug)
pub(all) struct NodeInfo {
  path : String
  kind : String
  relation : Relation?
  index_name : String?
}

///|
priv struct PlanNode {
  info : NodeInfo
  shared_reads : UInt64?
  shared_writes : UInt64?
  temp_writes : UInt64?
  sort_space : String?
}

///|
/// Immutable evidence. Original JSON text, including unknown fields, is retained.
pub struct Capture {
  priv context : Context
  priv source : String
  priv nodes : Array[PlanNode]
  priv limitations : Array[Diagnostic]
}

///|
pub fn Capture::source(self : Capture) -> String {
  self.source
}

///|
pub fn Capture::context(self : Capture) -> Context {
  self.context
}

///|
pub fn Capture::nodes(self : Capture) -> Array[NodeInfo] {
  self.nodes.map(node => node.info)
}

///|
pub fn Capture::limitations(self : Capture) -> Array[Diagnostic] {
  self.limitations.copy()
}

///|
/// Access constraints apply only to exactly selected schema/relation/alias scans.
pub(all) struct AccessRule {
  relation : Relation
  allow_sequential : Bool
}

///|
pub struct Policy {
  priv access : Array[AccessRule]
  priv max_shared_reads : UInt64?
  priv max_shared_writes : UInt64?
  priv max_temp_writes : UInt64?
  priv forbid_disk_sort : Bool
}

///|
pub fn Policy::new(
  access~ : Array[AccessRule] = [],
  max_shared_reads? : UInt64,
  max_shared_writes? : UInt64,
  max_temp_writes? : UInt64,
  forbid_disk_sort~ : Bool = false,
) -> Policy raise InputError {
  if access.length() > 256 {
    raise invalid(
      "PolicyLimit", "/access", "at most 256 access rules are supported",
    )
  }
  let seen : Set[String] = Set([])
  for i, rule in access {
    let path = "/access/" + i.to_string()
    for
      value in [
        rule.relation.schema,
        rule.relation.name,
        rule.relation.table_alias,
      ] {
      if value.is_empty() || value.length() > 256 {
        raise invalid(
          "RelationIdentity", path, "schema, name and alias must be nonempty and bounded",
        )
      }
    }
    let key = relation_key(rule.relation)
    if seen.contains(key) {
      raise invalid(
        "DuplicateRule", path, "each relation identity can have only one access rule",
      )
    }
    seen.add(key)
  }
  {
    access: access.copy(),
    max_shared_reads,
    max_shared_writes,
    max_temp_writes,
    forbid_disk_sort,
  }
}

///|
fn relation_key(relation : Relation) -> String {
  Json::array([
    Json::string(relation.schema),
    Json::string(relation.name),
    Json::string(relation.table_alias),
  ]).stringify()
}

///|
#derive(Eq, Debug)
pub(all) enum FindingKind {
  Violation
  Incomplete
  Change
}

///|
#derive(Eq, Debug)
pub(all) struct Finding {
  kind : FindingKind
  code : String
  path : String
  message : String
}

///|
pub struct Report {
  priv findings : Array[Finding]
  priv mode : String
  priv query_id : String
}

///|
pub fn Report::findings(self : Report) -> Array[Finding] {
  self.findings.copy()
}

///|
/// Incompleteness takes precedence over violations. Invalid input raises instead.
pub fn Report::exit_code(self : Report) -> Int32 {
  if self.findings.any(finding => finding.kind == Incomplete) {
    3
  } else if self.findings.any(finding => finding.kind == Violation) {
    1
  } else {
    0
  }
}
