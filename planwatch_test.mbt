///|
fn context(query~ : String = "q") -> @moonplanwatch.Context raise {
  @moonplanwatch.Context::new(
    query_id=query,
    parameters_id="p",
    dataset_id="d",
    server_version="18.6",
    settings_id="s",
  )
}

///|
fn plan(node : String) -> @moonplanwatch.Capture raise {
  @moonplanwatch.read_plan("[{\"Plan\":" + node + "}]", context())
}

///|
fn rejects(node : String) -> Bool {
  try {
    ignore(plan(node))
    false
  } catch {
    @moonplanwatch.InputError::Invalid(_) => true
    _ => false
  }
}

///|
fn rule() -> @moonplanwatch.AccessRule {
  {
    relation: { schema: "public", name: "t", table_alias: "t", },
    allow_sequential: false,
  }
}

///|
test "explicit policy and unchanged comparison" {
  let capture = plan(
    "{\"Node Type\":\"Seq Scan\",\"Schema\":\"public\",\"Relation Name\":\"t\",\"Alias\":\"t\"}",
  )
  assert_eq(
    @moonplanwatch.evaluate(
      capture,
      @moonplanwatch.Policy::new(access=[rule()]),
    ).exit_code(),
    1,
  )
  assert_eq(
    @moonplanwatch.compare(capture, capture, @moonplanwatch.Policy::new()).exit_code(),
    0,
  )
  assert_eq(
    @moonplanwatch.compare(capture, capture, @moonplanwatch.Policy::new())
    .findings()
    .length(),
    0,
  )
}

///|
test "unknown data retained exactly and cannot pass" {
  let raw = "[ {\"Plan\":{\"Node Type\":\"Future Scan\",\"extension/a~b\":{\"x\":[1,true,null]}}} ]\n"
  let capture = @moonplanwatch.read_plan(raw, context())
  assert_eq(capture.source(), raw)
  let decoded = @moonplanwatch.decode_capture(capture.encode())
  assert_eq(decoded.source(), raw)
  assert_eq(decoded.encode(), capture.encode())
  assert_eq(
    @moonplanwatch.evaluate(decoded, @moonplanwatch.Policy::new()).exit_code(),
    3,
  )
  assert_true(
    decoded.limitations().any(diag => diag.path == "/0/Plan/extension~1a~0b"),
  )
}

///|
test "duplicate decoded keys and recovery" {
  assert_true(
    rejects("{\"Node Type\":\"Result\",\"Node \\u0054ype\":\"Seq Scan\"}"),
  )
  assert_true(
    rejects(
      "{\"Node Type\":\"Result\",\"Plans\":[{\"Node Type\":\"Result\",\"x\":1,\"x\":2}]}",
    ),
  )
  assert_true(rejects("{\"Node Type\":\"Result\",}"))
  assert_eq(
    @moonplanwatch.evaluate(
      plan("{\"Node Type\":\"Result\"}"),
      @moonplanwatch.Policy::new(),
    ).exit_code(),
    0,
  )
}

///|
test "exact UInt64 counters above double precision" {
  let capture = plan(
    "{\"Node Type\":\"Result\",\"Shared Read Blocks\":9007199254740993,\"Temp Written Blocks\":18446744073709551615}",
  )
  assert_eq(
    @moonplanwatch.evaluate(
      capture,
      @moonplanwatch.Policy::new(max_shared_reads=9007199254740992UL),
    ).exit_code(),
    1,
  )
  assert_eq(
    @moonplanwatch.evaluate(
      capture,
      @moonplanwatch.Policy::new(
        max_shared_reads=9007199254740993UL,
        max_temp_writes=18446744073709551615UL,
      ),
    ).exit_code(),
    0,
  )
  for
    invalid in [
      "-1", "1.5", "1e3", "18446744073709551616", "null", "\"1\"", "true",
    ] {
    if !rejects(
        "{\"Node Type\":\"Result\",\"Shared Read Blocks\":" + invalid + "}",
      ) {
      fail("accepted invalid count: " + invalid)
    }
  }
}

///|
test "missing is distinct from zero and incomplete wins" {
  let policy = @moonplanwatch.Policy::new(
    max_shared_reads=0UL,
    max_temp_writes=0UL,
  )
  assert_eq(
    @moonplanwatch.evaluate(
      plan(
        "{\"Node Type\":\"Result\",\"Shared Read Blocks\":0,\"Temp Written Blocks\":0}",
      ),
      policy,
    ).exit_code(),
    0,
  )
  assert_eq(
    @moonplanwatch.evaluate(
      plan("{\"Node Type\":\"Result\",\"Shared Read Blocks\":1}"),
      policy,
    ).exit_code(),
    3,
  )
}

///|
test "inclusive root buffers are never summed" {
  let capture = plan(
    "{\"Node Type\":\"Limit\",\"Shared Read Blocks\":7,\"Plans\":[{\"Node Type\":\"Result\",\"Shared Read Blocks\":7}]}",
  )
  assert_eq(
    @moonplanwatch.evaluate(
      capture,
      @moonplanwatch.Policy::new(max_shared_reads=7UL),
    ).exit_code(),
    0,
  )
}

///|
test "exact relation selector missing ambiguous and self join" {
  let scan = "{\"Node Type\":\"Seq Scan\",\"Schema\":\"public\",\"Relation Name\":\"t\",\"Alias\":\"t\"}"
  let policy = @moonplanwatch.Policy::new(access=[rule()])
  assert_eq(
    @moonplanwatch.evaluate(plan("{\"Node Type\":\"Result\"}"), policy).exit_code(),
    3,
  )
  assert_eq(
    @moonplanwatch.evaluate(
      plan("{\"Node Type\":\"Append\",\"Plans\":[" + scan + "," + scan + "]}"),
      policy,
    ).exit_code(),
    3,
  )
  let separate_alias = scan.replace(
    old="\"Alias\":\"t\"",
    new="\"Alias\":\"other\"",
  )
  assert_eq(
    @moonplanwatch.evaluate(
      plan(
        "{\"Node Type\":\"Nested Loop\",\"Plans\":[" +
        scan +
        "," +
        separate_alias +
        "]}",
      ),
      policy,
    ).exit_code(),
    1,
  )
}

///|
test "disk sort and absent analyze evidence" {
  let policy = @moonplanwatch.Policy::new(forbid_disk_sort=true)
  for (space, expected) in [("Memory", 0), ("Disk", 1)] {
    assert_eq(
      @moonplanwatch.evaluate(
        plan("{\"Node Type\":\"Sort\",\"Sort Space Type\":\"" + space + "\"}"),
        policy,
      ).exit_code(),
      expected,
    )
  }
  assert_eq(
    @moonplanwatch.evaluate(plan("{\"Node Type\":\"Sort\"}"), policy).exit_code(),
    3,
  )
  assert_true(rejects("{\"Node Type\":\"Sort\",\"Sort Space Type\":\"SSD\"}"))
}

///|
test "parallel and extensions are incomplete even when violating" {
  let policy = @moonplanwatch.Policy::new(max_shared_reads=0UL)
  for
    extension in [
      "\"Parallel Aware\":true", "\"Workers\":[]", "\"Custom Plans\":[]",
    ] {
    let capture = plan(
      "{\"Node Type\":\"Result\",\"Shared Read Blocks\":9," + extension + "}",
    )
    assert_eq(@moonplanwatch.evaluate(capture, policy).exit_code(), 3)
  }
  assert_true(
    rejects("{\"Node Type\":\"Result\",\"Parallel Aware\":\"false\"}"),
  )
}

///|
test "shared write budget uses exact inclusive root counts" {
  let exact = plan(
    "{\"Node Type\":\"Limit\",\"Shared Written Blocks\":9007199254740993,\"Plans\":[{\"Node Type\":\"Result\",\"Shared Written Blocks\":9007199254740993}]}",
  )
  assert_eq(exact.root_buffers().shared_writes, Some(9007199254740993UL))
  assert_eq(exact.root_buffers().shared_reads, None)
  let pass = @moonplanwatch.decode_policy(
    "{\"schema\":1,\"max_shared_writes\":9007199254740993}",
  )
  let fail_policy = @moonplanwatch.decode_policy(
    "{\"schema\":1,\"max_shared_writes\":9007199254740992}",
  )
  assert_eq(@moonplanwatch.evaluate(exact, pass).exit_code(), 0)
  let failed = @moonplanwatch.evaluate(exact, fail_policy)
  assert_eq(failed.exit_code(), 1)
  assert_eq(failed.findings()[0].path, "/0/Plan/Shared Written Blocks")
  let missing = plan("{\"Node Type\":\"Result\"}")
  assert_eq(@moonplanwatch.evaluate(missing, pass).exit_code(), 3)
}

///|
test "policy diagnostics point to the exact invalid access entry" {
  let valid = "{\"schema\":\"public\",\"relation\":\"orders\",\"alias\":\"o\"}"
  for
    (entry, expected) in [
      ("false", "/access/1"),
      ("{\"a/b~c\":true}", "/access/1/a~1b~0c"),
      (
        "{\"schema\":\"public\",\"relation\":\"orders\",\"alias\":\"p\",\"allow_sequential\":0}",
        "/access/1/allow_sequential",
      ),
      (valid, "/access/1"),
    ] {
    try {
      ignore(
        @moonplanwatch.decode_policy(
          "{\"schema\":1,\"access\":[" + valid + "," + entry + "]}",
        ),
      )
      fail("invalid rule accepted")
    } catch {
      @moonplanwatch.InputError::Invalid(diag) => assert_eq(diag.path, expected)
      error => raise error
    }
  }
}

///|
test "standalone context encoding preserves all identity fields" {
  let original = @moonplanwatch.Context::new(
    query_id="query",
    parameters_id="parameters",
    dataset_id="dataset",
    settings_id="settings",
    server_version="18.6",
  )
  let restored = @moonplanwatch.decode_context(original.to_json().stringify())
  assert_true(restored == original)
}

///|
test "context mismatch prevents comparison" {
  let base = plan("{\"Node Type\":\"Result\"}")
  let other = @moonplanwatch.read_plan(base.source(), context(query="another"))
  let report = @moonplanwatch.compare(base, other, @moonplanwatch.Policy::new())
  assert_eq(
    report.findings()[0].message,
    "capture declarations differ: query_id",
  )
  assert_eq(
    @moonplanwatch.compare(base, other, @moonplanwatch.Policy::new()).exit_code(),
    3,
  )
}

///|
test "structural comparison identifies a removed child" {
  let before = plan(
    "{\"Node Type\":\"Limit\",\"Plans\":[{\"Node Type\":\"Result\"}]}",
  )
  let after = plan("{\"Node Type\":\"Limit\"}")
  let report = @moonplanwatch.compare(
    before,
    after,
    @moonplanwatch.Policy::new(),
  )
  assert_eq(report.exit_code(), 0)
  let findings = report.findings()
  assert_eq(findings.length(), 1)
  assert_eq(findings[0].path, "/0/Plan/Plans/0")
  assert_true(
    findings[0].message.contains("Result at /0/Plan/Plans/0 -> (absent)"),
  )
}

///|
test "snapshot arrays and input rules cannot mutate evidence" {
  let rules = [rule()]
  let policy = @moonplanwatch.Policy::new(access=rules)
  rules.clear()
  let capture = plan(
    "{\"Node Type\":\"Seq Scan\",\"Schema\":\"public\",\"Relation Name\":\"t\",\"Alias\":\"t\"}",
  )
  capture.nodes().clear()
  let report = @moonplanwatch.evaluate(capture, policy)
  report.findings().clear()
  assert_eq(report.exit_code(), 1)
}

///|
test "schema and closed policy reject unsupported config" {
  for
    source in [
      "{}", "{\"schema\":2}", "{\"schema\":1,\"max_shared_reads\":null}", "{\"schema\":1,\"typo\":true}",
      "{\"schema\":1,\"forbid_disk_sort\":0}",
    ] {
    let rejected = try {
      ignore(@moonplanwatch.decode_policy(source))
      false
    } catch {
      @moonplanwatch.InputError::Invalid(_) => true
    }
    assert_true(rejected)
  }
  let duplicated = try {
    ignore(@moonplanwatch.Policy::new(access=[rule(), rule()]))
    false
  } catch {
    @moonplanwatch.InputError::Invalid(_) => true
  }
  assert_true(duplicated)
}

///|
test "malformed nodes and result envelopes" {
  for
    node in [
      "null", "{}", "{\"Node Type\":false}", "{\"Node Type\":\"Result\",\"Plans\":{}}",
      "{\"Node Type\":\"Index Scan\"}", "{\"Node Type\":\"Seq Scan\",\"Relation Name\":\"t\"}",
    ] {
    assert_true(rejects(node))
  }
  for raw in ["[]", "[{},{}]", "{}", "[{}]"] {
    let rejected = try {
      ignore(@moonplanwatch.read_plan(raw, context()))
      false
    } catch {
      @moonplanwatch.InputError::Invalid(_) => true
      _ => false
    }
    assert_true(rejected)
  }
}

///|
test "determinism independent of object member order" {
  let a = plan("{\"Node Type\":\"Result\",\"z\":1,\"a\":2}")
  let b = plan("{\"a\":2,\"z\":1,\"Node Type\":\"Result\"}")
  let policy = @moonplanwatch.Policy::new()
  assert_eq(
    @moonplanwatch.evaluate(a, policy).to_json(),
    @moonplanwatch.evaluate(b, policy).to_json(),
  )
  assert_eq(
    @moonplanwatch.evaluate(a, policy).to_markdown(),
    @moonplanwatch.evaluate(b, policy).to_markdown(),
  )
}

///|
test "archive envelope rejects future versions and unknown fields" {
  let good = plan("{\"Node Type\":\"Result\"}").encode()
  for
    bad in [
      good.replace(old="\"schema\":1", new="\"schema\":2"),
      good.replace(old="\"kind\":", new="\"future\":0,\"kind\":"),
      good.replace(old="moonplanwatch/capture", new="other/capture"),
    ] {
    let rejected = try {
      ignore(@moonplanwatch.decode_capture(bad))
      false
    } catch {
      @moonplanwatch.InputError::Invalid(_) => true
    }
    assert_true(rejected)
  }
}

///|
test "depth and node boundaries" {
  let leaf = "{\"Node Type\":\"Result\"}"
  let children : Array[String] = []
  for _ in 0..<9999 {
    children.push(leaf)
  }
  let make = fn() {
    "{\"Node Type\":\"Append\",\"Plans\":[" + children.join(",") + "]}"
  }
  assert_eq(plan(make()).nodes().length(), 10000)
  children.push(leaf)
  assert_true(rejects(make()))
  let mut deep = leaf
  for _ in 0..<64 {
    deep = "{\"Node Type\":\"Result\",\"Plans\":[" + deep + "]}"
  }
  assert_true(rejects(deep))
}

///|
test "source size boundary and control character roundtrip" {
  let prefix = "[{\"Plan\":{\"Node Type\":\"Result\",\"future\":\""
  let suffix = "\"}}]"
  let padding = "x".repeat(524288 - prefix.length() - suffix.length())
  let raw = prefix + padding + suffix
  let capture = @moonplanwatch.read_plan(raw, context())
  assert_eq(@moonplanwatch.decode_capture(capture.encode()).source(), raw)
  let rejected = try {
    ignore(@moonplanwatch.read_plan(raw + " ", context()))
    false
  } catch {
    @moonplanwatch.InputError::Invalid(_) => true
    _ => false
  }
  assert_true(rejected)
  let unicode = plan(
    "{\"Node Type\":\"Result\",\"future\":\"音乐🎵\\u0000\\n\\\\\\\"\"}",
  )
  assert_eq(
    @moonplanwatch.decode_capture(unicode.encode()).source(),
    unicode.source(),
  )
}

///|
test "context and rule boundaries" {
  let accepted = context(query="x".repeat(256))
  assert_eq(accepted.query_id().length(), 256)
  for query in ["", "  ", "x".repeat(257)] {
    let rejected = try {
      ignore(context(query~))
      false
    } catch {
      @moonplanwatch.InputError::Invalid(_) => true
      _ => false
    }
    assert_true(rejected)
  }
  let rules = [rule()]
  for i in 1..<256 {
    rules.push({
      relation: { schema: "public", name: "t", table_alias: i.to_string(), },
      allow_sequential: true,
    })
  }
  ignore(@moonplanwatch.Policy::new(access=rules))
  rules.push({
    relation: { schema: "public", name: "t", table_alias: "extra", },
    allow_sequential: true,
  })
  let rejected = try {
    ignore(@moonplanwatch.Policy::new(access=rules))
    false
  } catch {
    @moonplanwatch.InputError::Invalid(_) => true
  }
  assert_true(rejected)
}

///|
test "trigger evidence and markdown escape" {
  let capture = @moonplanwatch.read_plan(
    "[{\"Plan\":{\"Node Type\":\"Result\"},\"Triggers\":[{}]}]",
    context(query="<img src=x> [link](url)\n# forged"),
  )
  let report = @moonplanwatch.evaluate(capture, @moonplanwatch.Policy::new())
  assert_eq(report.exit_code(), 3)
  assert_true(!report.to_markdown().contains("<img"))
  assert_true(!report.to_markdown().contains("\n# forged"))
}
