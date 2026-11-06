///|
fn refusal(code : String, path : String, message : String) -> @watch.InputError {
  @watch.InputError::Invalid({ code, path, message, })
}

///|
// Bounded regular-file reads with strict UTF-8. Algorithm adapted from
// MoonTestLedger cli/files.mbt; attribution and source pin: THIRD_PARTY.md.
async fn read_text(path : String) -> String {
  let file = @fs.open(path, mode=ReadOnly)
  defer file.close()
  if file.kind() != @fs.Regular {
    raise refusal("FileKind", path, "expected a regular UTF-8 file")
  }
  let buffer = @buffer.Buffer()
  for ;; {
    match file.read() {
      None => break
      Some(chunk) => {
        if chunk.length() > 16777216 - buffer.length() {
          raise refusal("FileLimit", path, "file exceeds 16 MiB")
        }
        buffer.write_bytes(chunk)
      }
    }
  }
  @utf8.decode(buffer.to_bytes()) catch {
    _ => raise refusal("InvalidUtf8", path, "input is not valid UTF-8")
  }
}

///|
async fn write_new(path : String, source : String) -> Unit {
  let file = @fs.open(path, mode=WriteOnly, create_mode=CreateNew)
  errdefer @fs.remove(path)
  defer file.close()
  file.text.write(source)
  file.sync()
}

///|
async fn inspect_capture(path : String) -> Int32 {
  let capture = @watch.decode_capture(read_text(path))
  let limitations = capture.limitations()
  let code = if limitations.is_empty() { 0 } else { 3 }
  let summary = Json::object({
    "schema": Json::number(1),
    "mode": Json::string("inspect"),
    "query_id": Json::string(capture.context().query_id()),
    "exit_code": Json::number(code.to_double()),
    "nodes": Json::array(
      capture
      .nodes()
      .map(node => {
        Json::object({
          "path": Json::string(node.path),
          "kind": Json::string(node.kind),
          "relation": node.relation
          .map(r => {
            Json::object({
              "schema": Json::string(r.schema),
              "name": Json::string(r.name),
              "alias": Json::string(r.table_alias),
            })
          })
          .unwrap_or(Json::null()),
          "index_name": node.index_name
          .map(name => Json::string(name))
          .unwrap_or(Json::null()),
        })
      }),
    ),
    "limitations": Json::array(
      limitations.map(diag => {
        Json::object({
          "code": Json::string(diag.code),
          "path": Json::string(diag.path),
          "message": Json::string(diag.message),
        })
      }),
    ),
  })
  @stdio.stdout.text.write(summary.stringify() + "\n")
  code
}

///|
pub async fn run(args : Array[String]) -> Int32 {
  try {
    match args {
      ["--version"] => {
        @stdio.stdout.text.write("moonplanwatch 0.1.0\n")
        0
      }
      ["--help"] => {
        @stdio.stdout.text.write(
          "moonplanwatch 0.1.0\n  capture PLAN.json CONTEXT.json --output NEW.json\n  extract CAPTURE.json --output NEW_PLAN.json\n  inspect CAPTURE.json\n  check CAPTURE.json POLICY.json [--markdown]\n  compare BASE.json CURRENT.json POLICY.json [--markdown]\nExit: 0 pass, 1 policy violation, 2 invalid input/I/O, 3 incomplete.\n",
        )
        0
      }
      ["capture", plan, context, "--output", output] => {
        let capture = @watch.read_plan(
          read_text(plan),
          @watch.decode_context(read_text(context)),
        )
        write_new(output, capture.encode() + "\n")
        0
      }
      ["extract", capture, "--output", output] => {
        let evidence = @watch.decode_capture(read_text(capture))
        write_new(output, evidence.source())
        0
      }
      ["inspect", capture] => inspect_capture(capture)
      ["check", capture, policy, .. tail] if tail.is_empty() ||
        tail == ["--markdown"] => {
        let report = @watch.evaluate(
          @watch.decode_capture(read_text(capture)),
          @watch.decode_policy(read_text(policy)),
        )
        @stdio.stdout.text.write(
          (if tail.is_empty() {
            report.to_json()
          } else {
            report.to_markdown()
          }) +
          "\n",
        )
        report.exit_code()
      }
      ["compare", base, current, policy, .. tail] if tail.is_empty() ||
        tail == ["--markdown"] => {
        let report = @watch.compare(
          @watch.decode_capture(read_text(base)),
          @watch.decode_capture(read_text(current)),
          @watch.decode_policy(read_text(policy)),
        )
        @stdio.stdout.text.write(
          (if tail.is_empty() {
            report.to_json()
          } else {
            report.to_markdown()
          }) +
          "\n",
        )
        report.exit_code()
      }
      _ => raise refusal("Usage", "", "run --help for command syntax")
    }
  } catch {
    @watch.InputError::Invalid(diag) => {
      @stdio.stderr.text.write(
        Json::object({
          "code": Json::string(diag.code),
          "path": Json::string(diag.path),
          "message": Json::string(diag.message),
        }).stringify() +
        "\n",
      )
      2
    }
    _ => {
      @stdio.stderr.text.write(
        "{\"code\":\"IO\",\"message\":\"file or stream operation failed; check paths, permissions and existing output\"}\n",
      )
      2
    }
  }
}
