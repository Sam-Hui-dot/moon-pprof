///|
test "prune_profile filters by focus/hide/label, garbage-collects dead symbols, and round-trips .pb.gz" {
  let st = [
    "", "cpu", "nanoseconds", "main.entry", "runtime.gc", "main.hot", "main.cold",
    "route", "/checkout", "/health", "app.go",
  ]
  let fns : Array[@moon-pprof.Function] = [
    {
      id: 1UL,
      name_idx: 3L,
      system_name_idx: 3L,
      filename_idx: 10L,
      start_line: 1L,
    },
    {
      id: 2UL,
      name_idx: 4L,
      system_name_idx: 4L,
      filename_idx: 10L,
      start_line: 5L,
    },
    {
      id: 3UL,
      name_idx: 5L,
      system_name_idx: 5L,
      filename_idx: 10L,
      start_line: 20L,
    },
    {
      id: 4UL,
      name_idx: 6L,
      system_name_idx: 6L,
      filename_idx: 10L,
      start_line: 40L,
    },
  ]
  let locs : Array[@moon-pprof.Location] = [
    {
      id: 1UL,
      mapping_id: 0UL,
      address: 0x10UL,
      lines: [{ function_id: 1UL, line: 2L, }],
      is_folded: false,
    },
    {
      id: 2UL,
      mapping_id: 0UL,
      address: 0x20UL,
      lines: [{ function_id: 2UL, line: 8L, }],
      is_folded: false,
    },
    {
      id: 3UL,
      mapping_id: 0UL,
      address: 0x30UL,
      lines: [{ function_id: 3UL, line: 25L, }],
      is_folded: false,
    },
    {
      id: 4UL,
      mapping_id: 0UL,
      address: 0x40UL,
      lines: [{ function_id: 4UL, line: 45L, }],
      is_folded: false,
    },
  ]
  let p : @moon-pprof.Profile = {
    sample_types: [{ type_idx: 1L, unit_idx: 2L, }],
    samples: [
      {
        location_ids: [3UL, 2UL, 1UL],
        values: [80_000_000L],
        labels: [{ key_idx: 7L, str_idx: 8L, num: 0L, num_unit_idx: 0L, }],
      },
      {
        location_ids: [4UL, 1UL],
        values: [20_000_000L],
        labels: [{ key_idx: 7L, str_idx: 9L, num: 0L, num_unit_idx: 0L, }],
      },
    ],
    mappings: [],
    locations: locs,
    functions: fns,
    string_table: st,
    drop_frames: 0L,
    keep_frames: 0L,
    time_nanos: 100L,
    duration_nanos: 100_000_000L,
    period_type: None,
    period: 0L,
    comments: [],
    default_sample_type: 1L,
  }

  let spec = @moon-pprof.filter_spec(
    hide="runtime.",
    label_key="route",
    label_value="/checkout",
  )
  let pruned = @moon-pprof.prune_profile(p, spec)
  // Only main.entry and main.hot should survive (runtime.gc hidden, main.cold filtered out)
  assert_eq(pruned.functions.length(), 2)
  assert_eq(pruned.samples.length(), 1)
  assert_true(!pruned.string_table.contains("main.cold"))
  assert_true(!pruned.string_table.contains("runtime.gc"))

  let encoded = @moon-pprof.encode_profile(pruned, gzip=true)
  let roundtrip = @moon-pprof.decode_profile(encoded)
  let top = @moon-pprof.compute_top(roundtrip)
  assert_eq(top.total, 80_000_000L)
  assert_eq(top.entries.length(), 2)
  assert_eq(top.entries[0].name, "main.hot")
  assert_eq(top.entries[0].flat, 80_000_000L)
}
