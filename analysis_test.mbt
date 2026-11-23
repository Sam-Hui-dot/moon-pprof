///|
test "compute_top expands inlined frames in leaf-first order and deduplicates recursion" {
  // Location 2 has inlined lines: [fastHash (leaf), handleRequest (caller)].
  // Sample 1 stack (leaf-first loc_ids [2, 1]): main.main -> app.handleRequest -> app.fastHash.
  // Sample 2 recursive stack (loc_ids [1, 1]): main.main -> main.main (cum must count once!).
  let profile = fixture_profile([
    { location_ids: [2UL, 1UL], values: [6L, 60_000_000L], labels: [], },
    { location_ids: [1UL, 1UL], values: [4L, 40_000_000L], labels: [], },
  ])

  let top_cpu = @moon-pprof.compute_top(profile, sort_by=Flat)
  assert_eq(top_cpu.sample_type, "cpu")
  assert_eq(top_cpu.unit, "nanoseconds")
  assert_eq(top_cpu.total, 100_000_000L)
  assert_eq(top_cpu.entries.length(), 3)

  // fastHash is leaf of sample 1: flat=60M, cum=60M
  assert_eq(top_cpu.entries[0].name, "app.fastHash")
  assert_eq(top_cpu.entries[0].flat, 60_000_000L)
  assert_eq(top_cpu.entries[0].cum, 60_000_000L)
  assert_eq(top_cpu.entries[0].flat_pct, 60.0)

  // main.main is leaf of sample 2 (flat=40M) and on both stacks (cum=100M, NOT 140M)
  assert_eq(top_cpu.entries[1].name, "main.main")
  assert_eq(top_cpu.entries[1].flat, 40_000_000L)
  assert_eq(top_cpu.entries[1].cum, 100_000_000L)
  assert_eq(top_cpu.entries[1].cum_pct, 100.0)

  // handleRequest is only an intermediate inlined caller: flat=0, cum=60M
  assert_eq(top_cpu.entries[2].name, "app.handleRequest")
  assert_eq(top_cpu.entries[2].flat, 0L)
  assert_eq(top_cpu.entries[2].cum, 60_000_000L)

  // Selecting explicit sample_type="samples"
  let top_samples = @moon-pprof.compute_top(
    profile,
    sample_type="samples",
    sort_by=Cum,
  )
  assert_eq(top_samples.sample_type, "samples")
  assert_eq(top_samples.total, 10L)
  assert_eq(top_samples.entries[0].name, "main.main")
  assert_eq(top_samples.entries[0].cum, 10L)
}

///|
test "collapse_stacks produces deterministic Brendan Gregg folded format" {
  let profile = fixture_profile([
    { location_ids: [2UL, 1UL], values: [2L, 20L], labels: [], },
    { location_ids: [2UL, 1UL], values: [3L, 30L], labels: [], },
    { location_ids: [3UL, 1UL], values: [5L, 50L], labels: [], },
  ])
  let stacks = @moon-pprof.collapse_stacks(profile)
  assert_eq(stacks, [
    { stack: "main.main;app.handleRequest;app.fastHash", value: 50L, },
    { stack: "main.main;app.slowSort", value: 50L, },
  ])
  let rendered = @moon-pprof.render_folded(stacks)
  assert_true(
    rendered.contains("main.main;app.handleRequest;app.fastHash 50\n"),
  )
  assert_true(rendered.contains("main.main;app.slowSort 50\n"))
}
