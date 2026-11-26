///|
test "compute_trend tracks multi-version series, detects regression inflection, and renders SVG + Markdown" {
  let v1 = fixture_profile([
    { location_ids: [2UL, 1UL], values: [5L, 500L], labels: [], },
    { location_ids: [3UL, 1UL], values: [1L, 100L], labels: [], },
  ])
  let v2 = fixture_profile([
    { location_ids: [2UL, 1UL], values: [5L, 500L], labels: [], },
    { location_ids: [3UL, 1UL], values: [1L, 110L], labels: [], },
  ])
  let v3 = fixture_profile([
    { location_ids: [2UL, 1UL], values: [5L, 500L], labels: [], },
    { location_ids: [3UL, 1UL], values: [5L, 500L], labels: [], },
  ])

  let report = @moon-pprof.compute_trend(
    [("v1", v1), ("v2", v2), ("v3", v3)],
    sample_type="cpu",
    top_k=3,
    regression_threshold_pct=15.0,
  )
  assert_eq(report.sample_type, "cpu")
  assert_eq(report.labels, ["v1", "v2", "v3"])
  assert_eq(report.totals[0].total, 600L)
  assert_eq(report.totals[1].total, 610L)
  assert_false(report.totals[1].regressed)
  assert_eq(report.totals[2].total, 1000L)
  assert_true(report.totals[2].regressed)
  assert_true(report.alerts.length() >= 2)

  let mut saw_slow_reg = false
  for s in report.series {
    if s.name == "app.slowSort" {
      assert_eq(s.values, [100L, 110L, 500L])
      assert_eq(s.regressed_at, ["v3"])
      saw_slow_reg = true
    }
  }
  assert_true(saw_slow_reg)

  let svg = @moon-pprof.render_trend_svg(report)
  assert_true(svg.has_prefix("<svg xmlns=\"http://www.w3.org/2000/svg\""))
  assert_true(svg.contains("moon-pprof-trend-svg"))
  assert_true(svg.contains("trend-regressed"))
  assert_true(svg.contains("app.slowSort"))
  assert_true(svg.contains("</svg>"))

  let md = @moon-pprof.render_trend_markdown(report)
  assert_true(md.contains("# pprof Multi-Version Performance Trend"))
  assert_true(md.contains("REGRESSION INFLECTION DETECTED"))
  assert_true(md.contains("| `v3` | 1000 |"))

  let txt = @moon-pprof.render_trend_text(report)
  assert_true(txt.contains("[REGRESSED]"))
}
