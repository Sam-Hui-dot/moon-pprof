///|
fn fixture_profile(
  samples : Array[@moon-pprof.Sample],
  duration_nanos~ : Int64 = 1_000_000_000L,
) -> @moon-pprof.Profile {
  {
    sample_types: [
      { type_idx: 1L, unit_idx: 2L, },
      { type_idx: 3L, unit_idx: 4L, },
    ],
    samples,
    mappings: [
      {
        id: 1UL,
        memory_start: 0x400000UL,
        memory_limit: 0x500000UL,
        file_offset: 0UL,
        filename_idx: 9L,
        build_id_idx: 10L,
        has_functions: true,
        has_filenames: true,
        has_line_numbers: true,
        has_inline_frames: true,
      },
    ],
    locations: [
      {
        id: 1UL,
        mapping_id: 1UL,
        address: 0x401000UL,
        lines: [{ function_id: 1UL, line: 10L, }],
        is_folded: false,
      },
      {
        id: 2UL,
        mapping_id: 1UL,
        address: 0x401100UL,
        lines: [
          { function_id: 3UL, line: 42L, },
          { function_id: 2UL, line: 25L, },
        ],
        is_folded: false,
      },
      {
        id: 3UL,
        mapping_id: 1UL,
        address: 0x401200UL,
        lines: [{ function_id: 4UL, line: 80L, }],
        is_folded: false,
      },
    ],
    functions: [
      {
        id: 1UL,
        name_idx: 5L,
        system_name_idx: 5L,
        filename_idx: 11L,
        start_line: 1L,
      },
      {
        id: 2UL,
        name_idx: 6L,
        system_name_idx: 6L,
        filename_idx: 11L,
        start_line: 20L,
      },
      {
        id: 3UL,
        name_idx: 7L,
        system_name_idx: 7L,
        filename_idx: 12L,
        start_line: 40L,
      },
      {
        id: 4UL,
        name_idx: 8L,
        system_name_idx: 8L,
        filename_idx: 12L,
        start_line: 70L,
      },
    ],
    string_table: [
      "", "samples", "count", "cpu", "nanoseconds", "main.main", "app.handleRequest",
      "app.fastHash", "app.slowSort", "/usr/bin/demo", "build-abc", "main.go", "work.go",
      "route", "/api/search",
    ],
    drop_frames: 0L,
    keep_frames: 0L,
    time_nanos: 1_700_000_000_000_000_000L,
    duration_nanos,
    period_type: Some({ type_idx: 3L, unit_idx: 4L, }),
    period: 10_000_000L,
    comments: [14L],
    default_sample_type: 3L,
  }
}

///|
test "encode_profile and decode_profile round-trip both raw protobuf and gzip" {
  let profile = fixture_profile([
    {
      location_ids: [2UL, 1UL],
      values: [5L, 50_000_000L],
      labels: [{ key_idx: 13L, str_idx: 14L, num: 0L, num_unit_idx: 0L, }],
    },
    { location_ids: [3UL, 1UL], values: [3L, 30_000_000L], labels: [], },
  ])

  let raw = @moon-pprof.encode_profile(profile, gzip=false)
  assert_true(!@moon-pprof.is_gzip(raw))
  let decoded_raw = @moon-pprof.decode_profile(raw)
  assert_eq(decoded_raw, profile)

  let gz = @moon-pprof.encode_profile(profile, gzip=true)
  assert_true(@moon-pprof.is_gzip(gz))
  let decoded_gz = @moon-pprof.decode_profile(gz)
  assert_eq(decoded_gz, profile)
}

///|
test "decode_profile rejects empty input, corrupted gzip, truncated varint, and invalid invariants" {
  try @moon-pprof.decode_profile(b"") catch {
    InvalidProfile(msg) => assert_true(msg.contains("empty"))
    _ => fail("expected InvalidProfile")
  } noraise {
    _ => fail("empty input must fail")
  }

  // Corrupted gzip header/body
  try @moon-pprof.decode_profile(b"\x1F\x8B\x08\x00\xFF\xFF") catch {
    InvalidGzip(msg) => assert_true(msg.contains("decompress"))
    _ => fail("expected InvalidGzip")
  } noraise {
    _ => fail("corrupted gzip must fail")
  }

  // Truncated varint
  try @moon-pprof.decode_profile(b"\x80") catch {
    InvalidProtobuf(msg) => assert_true(msg.contains("truncated"))
    _ => fail("expected InvalidProtobuf")
  } noraise {
    _ => fail("truncated varint must fail")
  }

  // Mismatched sample values count
  let bad = fixture_profile([{ location_ids: [1UL], values: [1L], labels: [], }])
  let bad_bytes = @moon-pprof.encode_profile(bad)
  try @moon-pprof.decode_profile(bad_bytes) catch {
    InvalidProfile(msg) => assert_true(msg.contains("expected 2"))
    _ => fail("expected InvalidProfile")
  } noraise {
    _ => fail("value length mismatch must fail")
  }
}
