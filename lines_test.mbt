///|
test "compute_line_hotspots, render_annotated_source, and compute_traces work accurately" {
  let st = ["", "cpu", "nanoseconds", "main.run", "main.hash", "hash.go"]
  let fns : Array[@moon-pprof.Function] = [
    {
      id: 1UL,
      name_idx: 3L,
      system_name_idx: 3L,
      filename_idx: 5L,
      start_line: 1L,
    },
    {
      id: 2UL,
      name_idx: 4L,
      system_name_idx: 4L,
      filename_idx: 5L,
      start_line: 4L,
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
      lines: [{ function_id: 2UL, line: 6L, }],
      is_folded: false,
    },
    {
      id: 3UL,
      mapping_id: 0UL,
      address: 0x30UL,
      lines: [{ function_id: 2UL, line: 7L, }],
      is_folded: false,
    },
  ]
  let p : @moon-pprof.Profile = {
    sample_types: [{ type_idx: 1L, unit_idx: 2L, }],
    samples: [
      { location_ids: [2UL, 1UL], values: [70_000_000L], labels: [], },
      { location_ids: [3UL, 1UL], values: [30_000_000L], labels: [], },
    ],
    mappings: [],
    locations: locs,
    functions: fns,
    string_table: st,
    drop_frames: 0L,
    keep_frames: 0L,
    time_nanos: 0L,
    duration_nanos: 0L,
    period_type: None,
    period: 0L,
    comments: [],
    default_sample_type: 1L,
  }

  let lr = @moon-pprof.compute_line_hotspots(p, pattern="main.hash")
  assert_eq(lr.total, 100_000_000L)
  assert_eq(lr.entries.length(), 2)
  assert_eq(lr.entries[0].line, 6L)
  assert_eq(lr.entries[0].flat, 70_000_000L)
  assert_eq(lr.entries[1].line, 7L)
  assert_eq(lr.entries[1].flat, 30_000_000L)

  let src =
    #|package main
    #|func run() { hash() }
    #|
    #|func hash() {
    #|  var x uint64
    #|  x = x*31 + 7 // hot line 6
    #|  x ^= x >> 13 // line 7
    #|}
  let annotated = @moon-pprof.render_annotated_source(
    lr,
    src,
    filename_hint="hash.go",
  )
  assert_true(annotated.contains("70ms"))
  assert_true(annotated.contains("hot line 6"))

  let tr = @moon-pprof.compute_traces(p, limit=10)
  assert_eq(tr.total, 100_000_000L)
  assert_eq(tr.traces.length(), 1)
  assert_eq(tr.traces[0].frames, ["main.run", "main.hash"])
  assert_true(
    @moon-pprof.render_traces_markdown(tr).contains("main.run -> main.hash"),
  )
}
