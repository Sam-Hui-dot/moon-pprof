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
  assert_true(svg.contains("app.fastHash"))
  assert_true(svg.contains("app.slowSort"))
  assert_true(svg.contains("</svg>"))

  let diff_svg = @moon-pprof.render_diff_flamegraph_svg(baseline, candidate)
  assert_true(diff_svg.contains("Improved (faster/smaller)"))
  assert_true(diff_svg.contains("Regressed (slower/larger)"))
  assert_true(diff_svg.contains("baseline: 600 -&gt; candidate: 800"))

  let html = @moon-pprof.render_diff_html(baseline, candidate)
  assert_true(html.contains("<!doctype html>"))
  assert_true(html.contains("Search function name..."))
  assert_true(html.contains("Reset Zoom"))
  assert_true(html.contains("app.slowSort"))

  let md = @moon-pprof.render_diff_markdown(
    @moon-pprof.compare_profiles(baseline, candidate),
  )
  assert_true(md.contains("# pprof Differential Report"))
  assert_true(md.contains("| `app.slowSort` | `regressed` |"))
}
