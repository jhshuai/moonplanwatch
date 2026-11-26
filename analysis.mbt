///|
priv struct RowEvidence {
  estimated : Double?
  actual : Double?
  loops : Double?
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
  let mut incomplete = !capture.limitations.is_empty()
  if !incomplete {
    guard strict_json(capture.source) is Array([{ "Plan": plan, .. }]) else {
      raise invalid("MissingPlan", "/0/Plan", "capture requires a plan")
    }
    let (_, partial, _) = analyze_node(plan, "/0/Plan", false, findings)
    incomplete = partial
  }
  Json::object({
    "schema": Json::number(1),
    "mode": Json::string("cardinality"),
    "exit_code": Json::number(if incomplete { 3 } else { 0 }),
    "query_id": Json::string(capture.context.query_id),
    "nodes": Json::array(findings),
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
fn analyze_node(
  plan : Json,
  path : String,
  demand_limited : Bool,
  findings : Array[Json],
) -> (Bool, Bool, RowEvidence) raise InputError {
  let fields = object(plan, path)
  let kind = text(fields, "Node Type", path)
  let rows = row_evidence(fields)
  let child_limit = demand_limited ||
    kind == "Limit" ||
    fields.get("Join Type") is Some(String("Semi" | "Anti"))
  let mut descendant_error = false
  let mut incomplete = false
  if fields.get("Plans") is Some(Array(children)) {
    for i, child in children {
      let (error, partial, _) = analyze_node(
        child,
        path + "/Plans/" + i.to_string(),
        child_limit,
        findings,
      )
      descendant_error = descendant_error || error
      incomplete = incomplete || partial
    }
  }
  let (status, factor) = match (rows.estimated, rows.actual, rows.loops) {
    (_, _, Some(0.0)) => ("not_executed", None)
    _ if demand_limited => ("demand_limited", None)
    _ if kind == "Bitmap Index Scan" => ("bitmap_counters", None)
    (Some(est), Some(actual), Some(loops)) if loops > 1.0 ||
      actual.to_int64().to_double() == actual => {
      // The displayed average is rounded. Only report differences that
      // survive that uncertainty, with guard room for floating-point error.
      let tolerance = if loops == 1.0 {
        0.0
      } else {
        0.0051 + actual * 0.000000000000001
      }
      let lower = if actual > tolerance { actual - tolerance } else { 0.0 }
      let upper = actual + tolerance
      if est < lower {
        ("underestimated", if est > 0.0 { Some(lower / est) } else { None })
      } else if est > upper {
        ("overestimated", if upper > 0.0 { Some(est / upper) } else { None })
      } else {
        ("consistent", None)
      }
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
