///|
fn main raise {
  guard arguments() is [plan, context, policy] else {
    fail("Pass raw plan JSON, context JSON and policy JSON as three arguments")
  }
  let capture = @watch.read_plan(plan, @watch.decode_context(context))
  let restored = @watch.decode_capture(capture.encode())
  assert_eq(restored.source(), plan)
  println(@watch.evaluate(restored, @watch.decode_policy(policy)).to_json())
}

///|
#cfg(target="js")
fn arguments() -> Array[String] { @env.args()[2:].to_owned() }

///|
#cfg(not(target="js"))
fn arguments() -> Array[String] { @env.args()[1:].to_owned() }
