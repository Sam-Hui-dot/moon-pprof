///|
test "render_flamegraph_svg and render_diff_flamegraph_svg emit valid SVG frames and legend" {
  let baseline = fixture_profile([
    { location_ids: [2UL, 1UL], values: [5L, 500L], labels: [], },
    { location_ids: [3UL, 1UL], values: [1L, 100L], labels: [], },
  ])
  let candidate = fixture_profile([
    { location_ids: [2UL, 1UL], values: [3L, 300L], labels: [], },
    { location_ids: [3UL, 1UL], values: [5L, 500L], labels: [], },
  ])

  let svg = @moon-pprof.render_flamegraph_svg(baseline)
  assert_true(svg.has_prefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
  assert_true(svg.contains("data-layout=\"flame\""))
  assert_true(svg.contains("app.fastHash"))
  assert_true(svg.contains("app.slowSort"))
  assert_true(svg.contains("</svg>"))

  let icicle_svg = @moon-pprof.render_flamegraph_svg(baseline, icicle=true)
  assert_true(icicle_svg.contains("data-layout=\"icicle\""))
  assert_true(icicle_svg.contains("app.fastHash"))
  assert_true(icicle_svg.contains("app.slowSort"))

  let diff_svg = @moon-pprof.render_diff_flamegraph_svg(baseline, candidate)
  assert_true(diff_svg.contains("data-layout=\"flame\""))
  assert_true(diff_svg.contains("Improved (faster/smaller)"))
  assert_true(diff_svg.contains("Regressed (slower/larger)"))
  assert_true(diff_svg.contains("baseline: 600 -&gt; candidate: 800"))

  let diff_icicle_svg = @moon-pprof.render_diff_flamegraph_svg(
    baseline,
    candidate,
    icicle=true,
  )
  assert_true(diff_icicle_svg.contains("data-layout=\"icicle\""))
  assert_true(diff_icicle_svg.contains("app.slowSort"))

  let html = @moon-pprof.render_diff_html(baseline, candidate, icicle=true)
  assert_true(html.contains("<!doctype html>"))
  assert_true(html.contains("data-layout=\"icicle\""))
  assert_true(html.contains("Search function name..."))
  assert_true(html.contains("Reset Zoom"))
  assert_true(html.contains("app.slowSort"))

  let md = @moon-pprof.render_diff_markdown(
    @moon-pprof.compare_profiles(baseline, candidate),
  )
  assert_true(md.contains("# pprof Differential Report"))
  assert_true(md.contains("| `app.slowSort` | `regressed` |"))
}

///|
test "visible_tree_depth ignores sub-pixel deep needles when computing SVG height" {
  let folded =
    #|root;main;hot 100000
    #|root;d1;d2;d3;d4;d5;d6;d7;d8;d9;d10;tiny 1
    #|
  let profile = @moon-pprof.from_folded_stacks(folded)
  // Visible depth is 4 (all -> root -> main -> hot); deep 12-level needle is < 1.5px and pruned.
  let svg = @moon-pprof.render_flamegraph_svg(
    profile,
    width=1200,
    min_width_px=1.5,
    icicle=true,
  )
  // header(50) + 4 * 18 + footer(16) = 138
  assert_true(svg.contains("viewBox=\"0 0 1200 138\""))
  assert_false(svg.contains("tiny"))
}
