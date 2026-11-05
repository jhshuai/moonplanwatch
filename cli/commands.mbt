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
pub async fn run(args : Array[String]) -> Int32 {
  try {
    match args {
      ["--version"] => {
        @stdio.stdout.text.write("moonplanwatch 0.1.0\n")
        0
      }
      ["--help"] => {
        @stdio.stdout.text.write(
          "moonplanwatch 0.1.0\n  capture PLAN.json CONTEXT.json --output NEW.json\n  check CAPTURE.json POLICY.json [--markdown]\n  compare BASE.json CURRENT.json POLICY.json [--markdown]\nExit: 0 pass, 1 policy violation, 2 invalid input/I/O, 3 incomplete.\n",
        )
        0
      }
      ["capture", plan, context, "--output", output] => {
        let capture = @watch.read_plan(
          read_text(plan),
          @watch.decode_context(read_text(context)),
        )
        let file = @fs.open(output, mode=WriteOnly, create_mode=CreateNew)
        errdefer @fs.remove(output)
        defer file.close()
        file.text.write(capture.encode() + "\n")
        file.sync()
        0
      }
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
