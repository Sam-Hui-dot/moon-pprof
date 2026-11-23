///|
test "merge_profiles combines string tables, deduplicates functions, and conserves totals" {
  let p1 = fixture_profile(
    [
      {
        location_ids: [2UL, 1UL],
        values: [10L, 100L],
        labels: [{ key_idx: 13L, str_idx: 14L, num: 0L, num_unit_idx: 0L, }],
      },
      { location_ids: [3UL, 1UL], values: [5L, 50L], labels: [], },
    ],
    duration_nanos=500_000_000L,
  )

  // Second profile with reordered string table and function IDs
  let p2 : @moon-pprof.Profile = {
    sample_types: [
      { type_idx: 1L, unit_idx: 2L, },
      { type_idx: 3L, unit_idx: 4L, },
    ],
    samples: [
      {
        location_ids: [20UL, 10UL],
        values: [20L, 200L],
        labels: [{ key_idx: 8L, str_idx: 9L, num: 0L, num_unit_idx: 0L, }],
      },
      { location_ids: [30UL, 10UL], values: [7L, 70L], labels: [], },
    ],
    mappings: [],
    locations: [
      {
        id: 10UL,
        mapping_id: 0UL,
        address: 0x401000UL,
        lines: [{ function_id: 100UL, line: 10L, }],
        is_folded: false,
      },
      {
        id: 20UL,
        mapping_id: 0UL,
        address: 0x401100UL,
        lines: [
          { function_id: 300UL, line: 42L, },
          { function_id: 200UL, line: 25L, },
        ],
        is_folded: false,
      },
      {
        id: 30UL,
        mapping_id: 0UL,
        address: 0x401200UL,
        lines: [{ function_id: 400UL, line: 80L, }],
        is_folded: false,
      },
    ],
    functions: [
      {
        id: 100UL,
        name_idx: 5L,
        system_name_idx: 5L,
        filename_idx: 10L,
        start_line: 1L,
      },
      {
        id: 200UL,
        name_idx: 6L,
        system_name_idx: 6L,
        filename_idx: 10L,
        start_line: 20L,
      },
      {
        id: 300UL,
        name_idx: 7L,
        system_name_idx: 7L,
        filename_idx: 11L,
        start_line: 40L,
      },
      {
        id: 400UL,
        name_idx: 12L,
        system_name_idx: 12L,
        filename_idx: 11L,
        start_line: 70L,
      },
    ],
    string_table: [
      "", "samples", "count", "cpu", "nanoseconds", "main.main", "app.handleRequest",
      "app.fastHash", "route", "/api/search", "main.go", "work.go", "app.slowSort",
    ],
    drop_frames: 0L,
    keep_frames: 0L,
    time_nanos: 1_699_000_000_000_000_000L,
    duration_nanos: 700_000_000L,
    period_type: None,
    period: 0L,
    comments: [],
    default_sample_type: 3L,
  }

  let merged = @moon-pprof.merge_profiles([p1, p2])
  assert_eq(merged.duration_nanos, 1_200_000_000L)
  assert_eq(merged.time_nanos, 1_699_000_000_000_000_000L)
  // Identical (stack, labels) samples must coalesce into 2 samples instead of 4.
  assert_eq(merged.samples.length(), 2)
  assert_eq(merged.functions.length(), 4)

  // Round-trip merged profile through gzip encode/decode and verify totals.
  let reloaded = @moon-pprof.decode_profile(
    @moon-pprof.encode_profile(merged, gzip=true),
  )
  let top = @moon-pprof.compute_top(reloaded)
  assert_eq(top.total, 420L)
  assert_eq(top.entries[0].name, "app.fastHash")
  assert_eq(top.entries[0].flat, 300L)
  assert_eq(top.entries[1].name, "app.slowSort")
  assert_eq(top.entries[1].flat, 120L)
}

///|
test "filter_spec supports focus, ignore, hide, and Sample.label slicing and grouping" {
  let profile : @moon-pprof.Profile = {
    ..fixture_profile([
      {
        location_ids: [2UL, 1UL],
        values: [6L, 600L],
        labels: [{ key_idx: 13L, str_idx: 14L, num: 0L, num_unit_idx: 0L, }],
      },
      {
        location_ids: [3UL, 1UL],
        values: [4L, 400L],
        labels: [{ key_idx: 13L, str_idx: 15L, num: 0L, num_unit_idx: 0L, }],
      },
    ]),
    string_table: [
      "", "samples", "count", "cpu", "nanoseconds", "main.main", "app.handleRequest",
      "app.fastHash", "app.slowSort", "/usr/bin/demo", "build-abc", "main.go", "work.go",
      "route", "/api/search", "/api/checkout",
    ],
  }

  // Group by route label
  let lbl_report = @moon-pprof.group_by_label(profile, "route")
  assert_eq(lbl_report.total, 1000L)
  assert_eq(lbl_report.matched_total, 1000L)
  assert_eq(lbl_report.groups.length(), 2)
  assert_eq(lbl_report.groups[0].label_value, "/api/search")
  assert_eq(lbl_report.groups[0].value, 600L)
  assert_eq(lbl_report.groups[0].pct, 60.0)
  assert_eq(lbl_report.groups[1].label_value, "/api/checkout")
  assert_eq(lbl_report.groups[1].value, 400L)

  // Label slice filter
  let sliced = @moon-pprof.compute_top(
    profile,
    spec=Some(
      @moon-pprof.filter_spec(label_key="route", label_value="/api/checkout"),
    ),
  )
  assert_eq(sliced.shown_total, 400L)
  assert_eq(sliced.entries[0].name, "app.slowSort")
  assert_eq(sliced.entries[0].flat, 400L)

  // Ignore filter drops stacks containing slowSort
  let ignored = @moon-pprof.compute_top(
    profile,
    spec=Some(@moon-pprof.filter_spec(ignore_pattern="slowSort")),
  )
  assert_eq(ignored.shown_total, 600L)

  // Hide filter removes main.main frame while preserving inner business frames
  let hidden_stacks = @moon-pprof.collapse_stacks(
    profile,
    spec=Some(@moon-pprof.filter_spec(hide="main.main")),
  )
  assert_eq(hidden_stacks, [
    { stack: "app.handleRequest;app.fastHash", value: 600L, },
    { stack: "app.slowSort", value: 400L, },
  ])

  let md = @moon-pprof.render_label_markdown(lbl_report)
  assert_true(md.contains("# pprof Label Breakdown (`route`)"))
  assert_true(md.contains("| `/api/search` | 600 | 60% | 1 |"))
}
