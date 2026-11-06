///|
// Current core supports decoded duplicate-key rejection and exact number lexemes.
fn strict_json(source : String) -> Json raise InputError {
  if source.length() > 4194304 {
    raise invalid("SourceLimit", "", "input exceeds 4,194,304 UTF-16 units")
  }
  @json.parse(
    source,
    max_nesting_depth=64,
    reject_duplicate_keys=true,
    preserve_number_repr=true,
  ) catch {
    @json.ParseError::DuplicateKey(_, key) =>
      raise invalid("DuplicateKey", "", "duplicate decoded key: " + key)
    _ =>
      raise invalid(
        "InvalidJson", "", "invalid JSON grammar or nesting exceeds 64",
      )
  }
}

///|
fn object(value : Json, path : String) -> Map[String, Json] raise InputError {
  guard value is Object(fields) else {
    raise invalid("ObjectExpected", path, "expected a JSON object")
  }
  fields
}

///|
fn text(
  fields : Map[String, Json],
  key : String,
  path : String,
) -> String raise InputError {
  guard fields.get(key) is Some(String(value)) && !value.is_empty() else {
    raise invalid(
      "StringExpected",
      path + "/" + key,
      "expected a nonempty string",
    )
  }
  value
}

///|
fn optional_text(
  fields : Map[String, Json],
  key : String,
  path : String,
) -> String? raise InputError {
  match fields.get(key) {
    None => None
    Some(String(value)) if !value.is_empty() => Some(value)
    _ =>
      raise invalid(
        "StringExpected",
        path + "/" + key,
        "expected a nonempty string when present",
      )
  }
}

///|
fn boolean(
  fields : Map[String, Json],
  key : String,
  path : String,
  default~ : Bool,
) -> Bool raise InputError {
  match fields.get(key) {
    None => default
    Some(True) => true
    Some(False) => false
    _ =>
      raise invalid("BooleanExpected", path + "/" + key, "expected a boolean")
  }
}

///|
fn count(value : Json, path : String) -> UInt64 raise InputError {
  let lexeme = match value {
    Number(number, repr~) => repr.unwrap_or(number.to_string())
    _ =>
      raise invalid(
        "CountExpected", path, "expected a nonnegative integer literal",
      )
  }
  if lexeme.is_empty() || !lexeme.iter().all(char => char is ('0'..<='9')) {
    raise invalid(
      "CountExpected", path, "counts require decimal integer literals, not fractions, signs or exponent notation",
    )
  }
  @string.parse_uint64(lexeme, base=10) catch {
    _ => raise invalid("CountRange", path, "count exceeds UInt64 range")
  }
}

///|
fn optional_count(
  fields : Map[String, Json],
  key : String,
  path : String,
) -> UInt64? raise InputError {
  fields.get(key).map(value => count(value, path + "/" + key))
}

///|
fn closed(
  fields : Map[String, Json],
  keys : Array[String],
  path : String,
) -> Unit raise InputError {
  for key in fields.keys() {
    if !keys.contains(key) {
      raise invalid(
        "UnknownField",
        path + "/" + key,
        "unknown configuration field",
      )
    }
  }
}

///|
fn context_json(context : Context) -> Json {
  Json::object({
    "query_id": Json::string(context.query_id),
    "parameters_id": Json::string(context.parameters_id),
    "dataset_id": Json::string(context.dataset_id),
    "server_version": Json::string(context.server_version),
    "settings_id": Json::string(context.settings_id),
  })
}

///|
pub fn decode_context(source : String) -> Context raise InputError {
  context_value(strict_json(source))
}

///|
fn context_value(value : Json) -> Context raise InputError {
  let fields = object(value, "/context")
  closed(
    fields,
    ["query_id", "parameters_id", "dataset_id", "server_version", "settings_id"],
    "/context",
  )
  Context::new(
    query_id=text(fields, "query_id", "/context"),
    parameters_id=text(fields, "parameters_id", "/context"),
    dataset_id=text(fields, "dataset_id", "/context"),
    server_version=text(fields, "server_version", "/context"),
    settings_id=text(fields, "settings_id", "/context"),
  )
}

///|
pub fn decode_policy(source : String) -> Policy raise InputError {
  let fields = object(strict_json(source), "")
  closed(
    fields,
    [
      "schema", "access", "max_shared_reads", "max_shared_writes", "max_temp_writes",
      "forbid_disk_sort",
    ],
    "",
  )
  guard fields.get("schema") is Some(Number(1, ..)) else {
    raise invalid("PolicySchema", "/schema", "expected schema 1")
  }
  if count(fields["schema"], "/schema") != 1UL {
    raise invalid("PolicySchema", "/schema", "expected schema 1")
  }
  let rules : Array[AccessRule] = []
  match fields.get("access") {
    None => ()
    Some(Array(entries)) => {
      if entries.length() > 256 {
        raise invalid("PolicyLimit", "/access", "at most 256 access rules")
      }
      for entry in entries {
        let rule = object(entry, "/access")
        closed(
          rule,
          ["schema", "relation", "alias", "allow_sequential"],
          "/access",
        )
        rules.push({
          relation: {
            schema: text(rule, "schema", "/access"),
            name: text(rule, "relation", "/access"),
            table_alias: text(rule, "alias", "/access"),
          },
          allow_sequential: boolean(
            rule,
            "allow_sequential",
            "/access",
            default=false,
          ),
        })
      }
    }
    _ => raise invalid("ArrayExpected", "/access", "expected an array")
  }
  Policy::new(
    access=rules,
    max_shared_reads?=optional_count(fields, "max_shared_reads", ""),
    max_shared_writes?=optional_count(fields, "max_shared_writes", ""),
    max_temp_writes?=optional_count(fields, "max_temp_writes", ""),
    forbid_disk_sort=boolean(fields, "forbid_disk_sort", "", default=false),
  )
}
