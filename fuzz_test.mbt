///|
test "fuzz decode_profile never panics on deterministic pseudo-random malformed bytes" {
  // Deterministic LCG generating 256 arbitrary byte streams (including gzip-prefixed garbage)
  let mut seed : UInt64 = 0x9E3779B97F4A7C15UL
  let next_byte = fn() -> Byte {
    seed = seed * 6364136223846793005UL + 1442695040888963407UL
    ((seed >> 33) & 0xFFUL).to_byte()
  }

  let mut rejected = 0
  for case_idx in 0..<256 {
    let len = case_idx % 64 + 1
    let buf = Buffer()
    if case_idx % 4 == 0 {
      // Prefix with gzip magic to exercise flate error paths
      buf.write_byte(b'\x1F')
      buf.write_byte(b'\x8B')
    }
    for _ in 0..<len {
      buf.write_byte(next_byte())
    }
    let payload = buf.contents()
    try ignore(@moon-pprof.decode_profile(payload)) catch {
      _ => rejected += 1
    } noraise {
      _ => ()
    }
  }
  assert_true(rejected >= 250)
}

///|
test "fuzz truncated prefixes of a valid encoded profile are rejected cleanly" {
  let profile = fixture_profile([
    { location_ids: [2UL, 1UL], values: [5L, 500L], labels: [], },
  ])
  let raw = @moon-pprof.encode_profile(profile, gzip=false)
  let mut truncated_errors = 0
  for cut in 0..<raw.length() {
    let prefix = raw[:cut].to_owned()
    try ignore(@moon-pprof.decode_profile(prefix)) catch {
      _ => truncated_errors += 1
    } noraise {
      _ => ()
    }
  }
  assert_true(truncated_errors > raw.length() / 2)

  let gz = @moon-pprof.encode_profile(profile, gzip=true)
  for cut in 0..<gz.length() {
    let prefix = gz[:cut].to_owned()
    try ignore(@moon-pprof.decode_profile(prefix)) catch {
      _ => ()
    } noraise {
      _ => fail("truncated gzip prefix \{cut} must not decode")
    }
  }
}
