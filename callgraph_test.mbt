///|
fn make_cg_sample_profile(
  samples : Array[(Array[UInt64], Int64)],
) -> @moon-pprof.Profile {
  let st = [
    "", "cpu", "nanoseconds", "main.run", "main.parse", "main.hash", "main.loop",
    "app.go",
  ]
  let fns : Array[@moon-pprof.Function] = [
    {
      id: 1UL,
      name_idx: 3L,
      system_name_idx: 3L,
      filename_idx: 7L,
      start_line: 1L,
    },
    {
      id: 2UL,
      name_idx: 4L,
      system_name_idx: 4L,
      filename_idx: 7L,
      start_line: 10L,
    },
    {
      id: 3UL,
      name_idx: 5L,
      system_name_idx: 5L,
      filename_idx: 7L,
      start_line: 20L,
    },
    {
      id: 4UL,
      name_idx: 6L,
      system_name_idx: 6L,
      filename_idx: 7L,
      start_line: 30L,
    },
  ]
  let locs : Array[@moon-pprof.Location] = [
    {
      id: 1UL,
      mapping_id: 0UL,
      address: 0x100UL,
      lines: [{ function_id: 1UL, line: 5L, }],
      is_folded: false,
    },
    {
      id: 2UL,
      mapping_id: 0UL,
      address: 0x200UL,
      lines: [{ function_id: 2UL, line: 15L, }],
      is_folded: false,
    },
    {
      id: 3UL,
      mapping_id: 0UL,
      address: 0x300UL,
      lines: [{ function_id: 3UL, line: 25L, }],
      is_folded: false,
    },
    {
      id: 4UL,
      mapping_id: 0UL,
      address: 0x400UL,
      lines: [{ function_id: 4UL, line: 35L, }],
      is_folded: false,
    },
  ]
  let ss : Array[@moon-pprof.Sample] = []
  for pair in samples {
    ss.push({ location_ids: pair.0, values: [pair.1], labels: [], })
  }
  {
    sample_types: [{ type_idx: 1L, unit_idx: 2L, }],
    samples: ss,
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
}

///|
test "build_callgraph computes layers, cycle back-edges, SVG, and DOT" {
  // leaf-first location_ids: [hash, parse, run] and a cycle [parse, loop, parse, run]
  let p = make_cg_sample_profile([
    ([3UL, 2UL, 1UL], 60_000_000L),
    ([4UL, 2UL, 1UL], 30_000_000L),
    ([2UL, 4UL, 2UL, 1UL], 10_000_000L),
  ])
  let cg = @moon-pprof.build_callgraph(p)
  assert_eq(cg.total, 100_000_000L)
  assert_eq(cg.nodes.length(), 4)
  // main.run is root at layer 0
  let mut run_layer = -1
  let mut back_edges = 0
  for nd in cg.nodes {
    if nd.name == "main.run" {
      run_layer = nd.layer
    }
  }
  for e in cg.edges {
    if e.is_back_edge {
      back_edges += 1
    }
  }
  assert_eq(run_layer, 0)
  assert_eq(back_edges, 1)

  let svg = @moon-pprof.render_callgraph_svg(cg)
  assert_true(svg.contains("<svg "))
  assert_true(svg.contains("main.run"))
  assert_true(svg.contains("main.hash"))
  assert_true(svg.contains("stroke-dasharray"))

  let dot = @moon-pprof.render_callgraph_dot(cg)
  assert_true(dot.contains("digraph \"moon-pprof\""))
  assert_true(dot.contains("->"))
}

///|
test "build_diff_callgraph highlights regressed and improved call paths" {
  let base = make_cg_sample_profile([
    ([3UL, 2UL, 1UL], 40_000_000L),
    ([4UL, 2UL, 1UL], 60_000_000L),
  ])
  let cand = make_cg_sample_profile([
    ([3UL, 2UL, 1UL], 120_000_000L),
    ([4UL, 2UL, 1UL], 20_000_000L),
  ])
  let dcg = @moon-pprof.build_diff_callgraph(base, cand)
  assert_eq(dcg.baseline_total, 100_000_000L)
  assert_eq(dcg.candidate_total, 140_000_000L)
  let mut saw_reg = false
  let mut saw_imp = false
  for nd in dcg.nodes {
    if nd.name == "main.hash" && nd.classification == "regressed" {
      saw_reg = true
    }
    if nd.name == "main.loop" && nd.classification == "improved" {
      saw_imp = true
    }
  }
  assert_true(saw_reg)
  assert_true(saw_imp)

  let svg = @moon-pprof.render_diff_callgraph_svg(dcg)
  assert_true(svg.contains("dcg-arrow-reg"))
  assert_true(svg.contains("dcg-arrow-imp"))

  let dot = @moon-pprof.render_diff_callgraph_dot(dcg)
  assert_true(dot.contains("digraph \"moon-pprof-diff\""))
}
