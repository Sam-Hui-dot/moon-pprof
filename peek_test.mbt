///|
test "compute_peek extracts callers and callees accurately and renders text and markdown" {
  let st = [
    "", "alloc_objects", "count", "alloc_space", "bytes", "main.entry", "main.worker",
    "main.alloc", "main.go",
  ]
  let fns : Array[@moon-pprof.Function] = [
    {
      id: 1UL,
      name_idx: 5L,
      system_name_idx: 5L,
      filename_idx: 8L,
      start_line: 1L,
    },
    {
      id: 2UL,
      name_idx: 6L,
      system_name_idx: 6L,
      filename_idx: 8L,
      start_line: 10L,
    },
    {
      id: 3UL,
      name_idx: 7L,
      system_name_idx: 7L,
      filename_idx: 8L,
      start_line: 20L,
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
      lines: [{ function_id: 2UL, line: 12L, }],
      is_folded: false,
    },
    {
      id: 3UL,
      mapping_id: 0UL,
      address: 0x30UL,
      lines: [{ function_id: 3UL, line: 22L, }],
      is_folded: false,
    },
  ]
  let p : @moon-pprof.Profile = {
    sample_types: [
      { type_idx: 1L, unit_idx: 2L, },
      { type_idx: 3L, unit_idx: 4L, },
    ],
    samples: [
      { location_ids: [3UL, 2UL, 1UL], values: [10L, 4096L], labels: [], },
      { location_ids: [2UL, 1UL], values: [5L, 1024L], labels: [], },
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
    default_sample_type: 3L,
  }
  let peek = @moon-pprof.compute_peek(p, "worker", sample_type="alloc_space")
  assert_eq(peek.total, 5120L)
  assert_eq(peek.functions.length(), 1)
  let wf = peek.functions[0]
  assert_eq(wf.name, "main.worker")
  assert_eq(wf.flat, 1024L)
  assert_eq(wf.cum, 5120L)
  assert_eq(wf.callers.length(), 1)
  assert_eq(wf.callers[0].name, "main.entry")
  assert_eq(wf.callers[0].weight, 5120L)
  assert_eq(wf.callees.length(), 1)
  assert_eq(wf.callees[0].name, "main.alloc")
  assert_eq(wf.callees[0].weight, 4096L)

  let txt = @moon-pprof.render_peek_text(peek)
  assert_true(txt.contains("caller  5120"))
  assert_true(txt.contains("callee  4096"))

  let md = @moon-pprof.render_peek_markdown(peek)
  assert_true(md.contains("# pprof Peek Report"))
  assert_true(md.contains("`main.alloc`"))

  let multi_html = @moon-pprof.render_multi_metric_html(p)
  assert_true(multi_html.contains("alloc_objects (count)"))
  assert_true(multi_html.contains("alloc_space (bytes)"))
  assert_true(multi_html.contains("moon-pprof-cg-svg"))
  assert_true(multi_html.contains("moon-pprof-svg"))
}
