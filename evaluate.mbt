///|
/// Evaluate explicit policy. Missing/unsupported evidence never counts as pass.
pub fn evaluate(capture : Capture, policy : Policy) -> Report {
  let findings : Array[Finding] = capture.limitations.map(diag => {
    kind: Incomplete,
    code: diag.code,
    path: diag.path,
    message: diag.message,
  })
  for rule in policy.access {
    let matches = capture.nodes.filter(node => {
      node.info.relation == Some(rule.relation)
    })
    if matches.length() != 1 {
      findings.push({
        kind: Incomplete,
        code: "AmbiguousRelation",
        path: "/0/Plan",
        message: "expected exactly one scan for " +
        relation_key(rule.relation) +
        "; found " +
        matches.length().to_string(),
      })
    } else if !rule.allow_sequential && matches[0].info.kind == "Seq Scan" {
      findings.push({
        kind: Violation,
        code: "SequentialScan",
        path: matches[0].info.path,
        message: "policy forbids a sequential scan for " +
        relation_key(rule.relation),
      })
    }
  }
  // PostgreSQL node buffer counters include child work. Only the root is used.
  let root = capture.nodes[0]
  budget(
    root.shared_reads,
    policy.max_shared_reads,
    "Shared Read Blocks",
    root.info.path,
    findings,
  )
  budget(
    root.temp_writes,
    policy.max_temp_writes,
    "Temp Written Blocks",
    root.info.path,
    findings,
  )
  if policy.forbid_disk_sort {
    for node in capture.nodes {
      if node.info.kind == "Sort" {
        match node.sort_space {
          Some("Disk") =>
            findings.push({
              kind: Violation,
              code: "DiskSort",
              path: node.info.path,
              message: "policy forbids disk-backed sort",
            })
          Some(_) => ()
          None =>
            findings.push({
              kind: Incomplete,
              code: "MissingSortMetric",
              path: node.info.path,
              message: "Sort Space Type absent; capture EXPLAIN ANALYZE on a safe SELECT",
            })
        }
      }
    }
  }
  { findings, mode: "check", query_id: capture.context.query_id, }
}

///|
fn budget(
  actual : UInt64?,
  maximum : UInt64?,
  name : String,
  path : String,
  out : Array[Finding],
) -> Unit {
  if maximum is Some(limit) {
    match actual {
      None =>
        out.push({
          kind: Incomplete,
          code: "MissingMetric",
          path: path + "/" + name,
          message: name + " absent; capture ANALYZE, BUFFERS",
        })
      Some(value) if value > limit =>
        out.push({
          kind: Violation,
          code: "BudgetExceeded",
          path: path + "/" + name,
          message: name +
          "=" +
          value.to_string() +
          " exceeds " +
          limit.to_string(),
        })
      Some(_) => ()
    }
  }
}

///|
/// Compare declared equivalent captures. Structural changes are observations;
/// violations are determined exclusively by the current capture's policy.
pub fn compare(
  baseline : Capture,
  current : Capture,
  policy : Policy,
) -> Report {
  let report = evaluate(current, policy)
  let findings = report.findings.copy()
  for diag in baseline.limitations {
    findings.push({
      kind: Incomplete,
      code: diag.code,
      path: "/baseline" + diag.path,
      message: diag.message,
    })
  }
  if baseline.context != current.context {
    findings.push({
      kind: Incomplete,
      code: "ContextMismatch",
      path: "/context",
      message: "query, parameters, dataset, settings and server version declarations must all match",
    })
  } else {
    let before = baseline.nodes.map(node => node.info)
    let after = current.nodes.map(node => node.info)
    if before != after {
      findings.push({
        kind: Change,
        code: "StructureChanged",
        path: "/0/Plan",
        message: "node order, access method, relation identity or index name changed; this does not establish a timing regression",
      })
    }
  }
  { findings, mode: "compare", query_id: current.context.query_id, }
}

///|
fn kind_name(kind : FindingKind) -> String {
  match kind {
    Violation => "violation"
    Incomplete => "incomplete"
    Change => "change"
  }
}

///|
/// Stable machine-readable report; no timestamps or hash-map iteration order.
pub fn Report::to_json(self : Report) -> String {
  Json::object({
    "schema": Json::number(1),
    "mode": Json::string(self.mode),
    "query_id": Json::string(self.query_id),
    "exit_code": Json::number(self.exit_code().to_double()),
    "findings": Json::array(
      self.findings.map(finding => {
        Json::object({
          "kind": Json::string(kind_name(finding.kind)),
          "code": Json::string(finding.code),
          "path": Json::string(finding.path),
          "message": Json::string(finding.message),
        })
      }),
    ),
  }).stringify()
}

///|
/// Markdown uses JSON string literals so caller labels cannot inject new lines.
pub fn Report::to_markdown(self : Report) -> String {
  let out = StringBuilder()
  out.write_string(
    "# MoonPlanWatch\n\nQuery: " +
    markdown_text(self.query_id) +
    "\n\nExit: " +
    self.exit_code().to_string() +
    "\n",
  )
  for finding in self.findings {
    out.write_string(
      "\n- " +
      kind_name(finding.kind) +
      " **" +
      finding.code +
      "**: " +
      markdown_text(finding.message) +
      " (" +
      markdown_text(finding.path) +
      ")\n",
    )
  }
  out.to_string()
}

///|
fn markdown_text(value : String) -> String {
  let out = StringBuilder()
  for char in Json::string(value).stringify() {
    match char {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '\\' | '`' | '*' | '_' | '[' | ']' | '(' | ')' | '#' | '!' | '|' => {
        out.write_char('\\')
        out.write_char(char)
      }
      _ => out.write_char(char)
    }
  }
  out.to_string()
}
