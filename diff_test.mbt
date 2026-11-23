///|
test "compare_profiles detects regressions, improvements, and triggers CI gate exit code 1" {
  let baseline = fixture_profile([
    { location_ids: [2UL, 1UL], values: [50L, 500L], labels: [], },
    { location_ids: [3UL, 1UL], values: [10L, 100L], labels: [], },
  ])
  let candidate = fixture_profile([
    { location_ids: [2UL, 1UL], values: [40L, 400L], labels: [], },
    { location_ids: [3UL, 1UL], values: [40L, 400L], labels: [], },
  ])

  let policy = @moon-pprof.gate_policy(
    max_total_regression_pct=Some(20.0),
    max_func_cum_regression_pct=Some(50.0),
    min_abs_delta=50L,
  )
  let diff = @moon-pprof.compare_profiles(baseline, candidate, policy~)
  assert_eq(diff.baseline_total, 600L)
  assert_eq(diff.candidate_total, 800L)
  assert_eq(diff.delta_total, 200L)
  assert_eq(diff.delta_total_pct, 33.33)
  assert_eq(diff.gate.passed, false)
  assert_eq(diff.gate.exit_code, 1)
  assert_true(diff.gate.violations.length() >= 2)

  // slowSort regressed +300 (+300%)
  let mut saw_slow = false
  let mut saw_fast = false
  for entry in diff.entries {
    if entry.name == "app.slowSort" {
      saw_slow = true
      assert_eq(entry.delta_cum, 300L)
      assert_eq(entry.classification, "regressed")
    }
    if entry.name == "app.fastHash" {
      saw_fast = true
      assert_eq(entry.delta_cum, -100L)
      assert_eq(entry.classification, "improved")
    }
  }
  assert_true(saw_slow && saw_fast)
}

///|
test "compare_profiles normalized mode compares share deltas independent of run duration" {
  // Candidate ran twice as long with identical proportions -> zero share drift -> gate passes.
  let baseline = fixture_profile([
    { location_ids: [2UL, 1UL], values: [5L, 50L], labels: [], },
    { location_ids: [3UL, 1UL], values: [5L, 50L], labels: [], },
  ])
  let candidate = fixture_profile([
    { location_ids: [2UL, 1UL], values: [10L, 100L], labels: [], },
    { location_ids: [3UL, 1UL], values: [10L, 100L], labels: [], },
  ])
  let policy = @moon-pprof.gate_policy(
    max_func_cum_regression_pct=Some(5.0),
    normalize=true,
  )
  let diff = @moon-pprof.compare_profiles(baseline, candidate, policy~)
  assert_eq(diff.normalized, true)
  assert_eq(diff.gate.passed, true)
  assert_eq(diff.gate.exit_code, 0)
  for entry in diff.entries {
    assert_eq(entry.delta_cum_share_pp, 0.0)
    assert_eq(entry.classification, "unchanged")
  }
}
