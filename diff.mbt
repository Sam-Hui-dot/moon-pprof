///|
/// Construct a `GatePolicy` with optional total and per-function cumulative regression limits.
pub fn gate_policy(
  max_total_regression_pct~ : Double? = None,
  max_func_cum_regression_pct~ : Double? = None,
  min_abs_delta~ : Int64 = 0L,
  normalize~ : Bool = false,
) -> GatePolicy {
  {
    max_total_regression_pct,
    max_func_cum_regression_pct,
    min_abs_delta,
    normalize,
  }
}

///|
fn rel_change_pct(before : Int64, after : Int64) -> Double {
  if before == 0L {
    if after == 0L {
      0.0
    } else if after > 0L {
      100.0
    } else {
      -100.0
    }
  } else {
    round2((after - before).to_double() * 100.0 / before.to_double())
  }
}

///|
fn abs_i64(v : Int64) -> Int64 {
  if v < 0L {
    -v
  } else {
    v
  }
}

///|
fn classify_diff(
  baseline_cum : Int64,
  candidate_cum : Int64,
  delta_cum : Int64,
  delta_share_pp : Double,
  normalized : Bool,
) -> String {
  if baseline_cum == 0L && candidate_cum > 0L {
    "added"
  } else if baseline_cum > 0L && candidate_cum == 0L {
    "removed"
  } else if normalized {
    if delta_share_pp > 0.5 {
      "regressed"
    } else if delta_share_pp < -0.5 {
      "improved"
    } else {
      "unchanged"
    }
  } else if delta_cum > 0L {
    "regressed"
  } else if delta_cum < 0L {
    "improved"
  } else {
    "unchanged"
  }
}

///|
/// Compare two profiles on the same metric, producing per-function deltas and CI gate results.
pub fn compare_profiles(
  baseline : Profile,
  candidate : Profile,
  sample_type~ : String = "",
  policy~ : GatePolicy = gate_policy(),
  limit~ : Int32 = 25,
  filter~ : String = "",
) -> DiffReport raise PprofError {
  let (b_idx, st_name, b_unit) = resolve_sample_type(baseline, sample_type~)
  let (c_idx, _, c_unit) = resolve_sample_type(candidate, sample_type=st_name)
  guard b_unit == c_unit else {
    raise InvalidProfile(
      "unit mismatch for sample type '\{st_name}': baseline '\{b_unit}' vs candidate '\{c_unit}'",
    )
  }

  let (b_total_all, b_shown, b_map) = aggregate_functions(
    baseline, b_idx, filter,
  )
  let (c_total_all, c_shown, c_map) = aggregate_functions(
    candidate, c_idx, filter,
  )
  let b_total = if filter.is_empty() { b_total_all } else { b_shown }
  let c_total = if filter.is_empty() { c_total_all } else { c_shown }
  let delta_total = c_total - b_total
  let delta_total_pct = rel_change_pct(b_total, c_total)

  let names : Set[String] = Set([])
  for k, _ in b_map {
    names.add(k)
  }
  for k, _ in c_map {
    names.add(k)
  }

  let all_entries : Array[DiffEntry] = []
  for name in names {
    let (filename, b_flat, b_cum) = match b_map.get(name) {
      Some(acc) => (acc.filename, acc.flat, acc.cum)
      None => ("", 0L, 0L)
    }
    let (c_file, c_flat, c_cum) = match c_map.get(name) {
      Some(acc) => (acc.filename, acc.flat, acc.cum)
      None => ("", 0L, 0L)
    }
    let resolved_file = if !c_file.is_empty() { c_file } else { filename }
    let d_flat = c_flat - b_flat
    let d_cum = c_cum - b_cum
    let b_share = pct(b_cum, b_total)
    let c_share = pct(c_cum, c_total)
    let d_share_pp = round2(c_share - b_share)
    let classification = classify_diff(
      b_cum,
      c_cum,
      d_cum,
      d_share_pp,
      policy.normalize,
    )
    all_entries.push({
      name,
      filename: resolved_file,
      baseline_flat: b_flat,
      candidate_flat: c_flat,
      delta_flat: d_flat,
      delta_flat_pct: rel_change_pct(b_flat, c_flat),
      baseline_cum: b_cum,
      candidate_cum: c_cum,
      delta_cum: d_cum,
      delta_cum_pct: rel_change_pct(b_cum, c_cum),
      baseline_cum_share_pct: b_share,
      candidate_cum_share_pct: c_share,
      delta_cum_share_pp: d_share_pp,
      classification,
    })
  }

  // Sort regressions first by largest impact (share delta when normalized, else abs cum delta).
  all_entries.sort_by((a, b) => {
    let primary = if policy.normalize {
      let da = if a.delta_cum_share_pp < 0.0 {
        -a.delta_cum_share_pp
      } else {
        a.delta_cum_share_pp
      }
      let db = if b.delta_cum_share_pp < 0.0 {
        -b.delta_cum_share_pp
      } else {
        b.delta_cum_share_pp
      }
      db.compare(da)
    } else {
      abs_i64(b.delta_cum).compare(abs_i64(a.delta_cum))
    }
    if primary != 0 {
      return primary
    }
    let secondary = abs_i64(b.delta_flat).compare(abs_i64(a.delta_flat))
    if secondary != 0 {
      return secondary
    }
    lex_cmp(a.name, b.name)
  })

  let violations : Array[String] = []
  match policy.max_total_regression_pct {
    Some(max_pct) =>
      if !policy.normalize &&
        delta_total > policy.min_abs_delta &&
        delta_total_pct > max_pct {
        violations.push(
          "total \{st_name} regressed by +\{delta_total_pct}% (+\{delta_total} \{b_unit}), exceeding limit +\{max_pct}%",
        )
      }
    None => ()
  }
  match policy.max_func_cum_regression_pct {
    Some(max_fn_pct) =>
      for entry in all_entries {
        if policy.normalize {
          if entry.delta_cum_share_pp > max_fn_pct &&
            entry.candidate_cum >= policy.min_abs_delta {
            violations.push(
              "function `\{entry.name}` share grew by +\{entry.delta_cum_share_pp}pp (\{entry.baseline_cum_share_pct}% -> \{entry.candidate_cum_share_pct}%), exceeding +\{max_fn_pct}pp",
            )
          }
        } else if entry.delta_cum > policy.min_abs_delta &&
          entry.delta_cum_pct > max_fn_pct {
          violations.push(
            "function `\{entry.name}` cum regressed by +\{entry.delta_cum_pct}% (+\{entry.delta_cum} \{b_unit}), exceeding +\{max_fn_pct}%",
          )
        }
      }
    None => ()
  }

  let passed = violations.is_empty()
  let gate : GateResult = {
    passed,
    exit_code: if passed {
      0
    } else {
      1
    },
    violations,
  }
  let capped = if limit > 0 && all_entries.length() > limit {
    all_entries[:limit].to_owned()
  } else {
    all_entries
  }
  {
    sample_type: st_name,
    unit: b_unit,
    normalized: policy.normalize,
    baseline_total: b_total,
    candidate_total: c_total,
    delta_total,
    delta_total_pct,
    entries: capped,
    gate,
  }
}
