///|
fn lex_cmp(a : String, b : String) -> Int32 {
  let len = if a.length() < b.length() { a.length() } else { b.length() }
  for i in 0..<len {
    let ca = a.code_unit_at(i)
    let cb = b.code_unit_at(i)
    if ca != cb {
      return ca.compare(cb)
    }
  }
  a.length().compare(b.length())
}

///|
fn round2(value : Double) -> Double {
  let scaled = value * 100.0
  let rounded = if scaled >= 0.0 {
    (scaled + 0.5).to_int64().to_double()
  } else {
    (scaled - 0.5).to_int64().to_double()
  }
  rounded / 100.0
}

///|
fn pct(part : Int64, total : Int64) -> Double {
  if total == 0L {
    0.0
  } else {
    round2(part.to_double() * 100.0 / total.to_double())
  }
}

///|
fn uint64_to_hex(value : UInt64) -> String {
  let digits = "0123456789abcdef".to_array()
  if value == 0UL {
    return "0x0"
  }
  let rev : Array[Char] = []
  let mut v = value
  while v > 0UL {
    rev.push(digits[(v & 0xFUL).to_int()])
    v = v >> 4
  }
  let out = StringBuilder()
  out.write_string("0x")
  for i = rev.length() - 1; i >= 0; i = i - 1 {
    out.write_char(rev[i])
  }
  out.to_string()
}

///|
/// List all declared `(type, unit)` sample metric pairs in a profile.
pub fn sample_type_names(
  profile : Profile,
) -> Array[(String, String)] raise PprofError {
  let out : Array[(String, String)] = []
  for st in profile.sample_types {
    out.push((profile.string_at(st.type_idx), profile.string_at(st.unit_idx)))
  }
  out
}

///|
/// Resolve a sample type name (or default following `go tool pprof` semantics) to `(index, name, unit)`.
pub fn resolve_sample_type(
  profile : Profile,
  sample_type~ : String = "",
) -> (Int32, String, String) raise PprofError {
  let types = sample_type_names(profile)
  guard !types.is_empty() else {
    raise InvalidProfile("profile has no sample_types")
  }
  let requested = sample_type.trim().to_owned()
  if !requested.is_empty() {
    for i, pair in types {
      if pair.0 == requested {
        return (i, pair.0, pair.1)
      }
    }
    let avail = types.map(p => p.0).join(", ")
    raise InvalidInput(
      "unknown sample type '\{requested}' (available: \{avail})",
    )
  }
  if profile.default_sample_type != 0L {
    let default_name = profile.string_at(profile.default_sample_type)
    for i, pair in types {
      if pair.0 == default_name {
        return (i, pair.0, pair.1)
      }
    }
  }
  let last = types.length() - 1
  (last, types[last].0, types[last].1)
}

///|
fn build_location_map(profile : Profile) -> Map[UInt64, Location] {
  let map : Map[UInt64, Location] = Map([])
  for loc in profile.locations {
    map[loc.id] = loc
  }
  map
}

///|
fn build_function_map(profile : Profile) -> Map[UInt64, Function] {
  let map : Map[UInt64, Function] = Map([])
  for func in profile.functions {
    map[func.id] = func
  }
  map
}

///|
fn function_identity(
  profile : Profile,
  func : Function,
) -> (String, String) raise PprofError {
  let name = profile.string_at(func.name_idx)
  let resolved_name = if !name.is_empty() {
    name
  } else {
    let sys = profile.string_at(func.system_name_idx)
    if !sys.is_empty() {
      sys
    } else {
      "func#\{func.id}"
    }
  }
  let filename = profile.string_at(func.filename_idx)
  (resolved_name, filename)
}

///|
/// Resolve a sample's call stack from root (index 0) to leaf (last index), expanding inlined frames.
fn sample_frames_root_to_leaf(
  profile : Profile,
  loc_map : Map[UInt64, Location],
  fn_map : Map[UInt64, Function],
  sample : Sample,
) -> Array[(String, String)] raise PprofError {
  let frames : Array[(String, String)] = []
  let loc_count = sample.location_ids.length()
  for li = loc_count - 1; li >= 0; li = li - 1 {
    let loc_id = sample.location_ids[li]
    match loc_map.get(loc_id) {
      None => frames.push(("<unknown loc#\{loc_id}>", ""))
      Some(loc) =>
        if loc.lines.is_empty() {
          frames.push((uint64_to_hex(loc.address), ""))
        } else {
          // Location.line is ordered innermost (leaf) first, outermost (caller) last.
          for fi = loc.lines.length() - 1; fi >= 0; fi = fi - 1 {
            let line = loc.lines[fi]
            match fn_map.get(line.function_id) {
              Some(func) => frames.push(function_identity(profile, func))
              None => frames.push(("<unknown fn#\{line.function_id}>", ""))
            }
          }
        }
    }
  }
  frames
}

///|
/// Build a `FilterSpec` for `focus`, `ignore`, `hide`, and `Sample.label` slicing.
pub fn filter_spec(
  focus~ : String = "",
  ignore_pattern~ : String = "",
  hide~ : String = "",
  label_key~ : String = "",
  label_value~ : String = "",
) -> FilterSpec {
  { focus, ignore_pattern, hide, label_key, label_value, }
}

///|
fn is_filter_empty(spec : FilterSpec) -> Bool {
  spec.focus.is_empty() &&
  spec.ignore_pattern.is_empty() &&
  spec.hide.is_empty() &&
  spec.label_key.is_empty() &&
  spec.label_value.is_empty()
}

///|
fn resolve_filter(filter : String, spec : FilterSpec?) -> FilterSpec {
  match spec {
    Some(s) =>
      if s.focus.is_empty() && !filter.is_empty() {
        { ..s, focus: filter, }
      } else {
        s
      }
    None => filter_spec(focus=filter)
  }
}

///|
fn label_display_value(
  profile : Profile,
  label : Label,
) -> String raise PprofError {
  let s = profile.string_at(label.str_idx)
  if !s.is_empty() {
    s
  } else {
    let unit = profile.string_at(label.num_unit_idx)
    if unit.is_empty() {
      "\{label.num}"
    } else {
      "\{label.num}\{unit}"
    }
  }
}

///|
fn matches_label_filter(
  profile : Profile,
  sample : Sample,
  spec : FilterSpec,
) -> Bool raise PprofError {
  if spec.label_key.is_empty() {
    return true
  }
  for lbl in sample.labels {
    let key = profile.string_at(lbl.key_idx)
    if key == spec.label_key {
      if spec.label_value.is_empty() {
        return true
      }
      let str_val = profile.string_at(lbl.str_idx)
      if str_val == spec.label_value ||
        label_display_value(profile, lbl) == spec.label_value ||
        "\{lbl.num}" == spec.label_value {
        return true
      }
    }
  }
  false
}

///|
fn frame_matches(pair : (String, String), pattern : String) -> Bool {
  pair.0.contains(pattern) || pair.1.contains(pattern)
}

///|
/// Apply `label`, `focus`, `ignore_pattern`, and `hide` to a sample's resolved frames.
fn apply_filter(
  profile : Profile,
  sample : Sample,
  frames : Array[(String, String)],
  spec : FilterSpec,
) -> Array[(String, String)]? raise PprofError {
  if !matches_label_filter(profile, sample, spec) {
    return None
  }
  if !spec.focus.is_empty() {
    let mut hit = false
    for pair in frames {
      if frame_matches(pair, spec.focus) {
        hit = true
        break
      }
    }
    if !hit {
      return None
    }
  }
  if !spec.ignore_pattern.is_empty() {
    for pair in frames {
      if frame_matches(pair, spec.ignore_pattern) {
        return None
      }
    }
  }
  if spec.hide.is_empty() {
    Some(frames)
  } else {
    let kept : Array[(String, String)] = []
    for pair in frames {
      if !frame_matches(pair, spec.hide) {
        kept.push(pair)
      }
    }
    if kept.is_empty() {
      None
    } else {
      Some(kept)
    }
  }
}

///|
priv struct Acc {
  filename : String
  mut flat : Int64
  mut cum : Int64
}

///|
fn aggregate_functions(
  profile : Profile,
  value_index : Int32,
  spec : FilterSpec,
) -> (Int64, Int64, Map[String, Acc]) raise PprofError {
  let loc_map = build_location_map(profile)
  let fn_map = build_function_map(profile)
  let stats : Map[String, Acc] = Map([])
  let mut total = 0L
  let mut shown_total = 0L

  for sample in profile.samples {
    let v = sample.values[value_index]
    total += v
    if v == 0L {
      continue
    }
    let raw_frames = sample_frames_root_to_leaf(
      profile, loc_map, fn_map, sample,
    )
    let frames = match apply_filter(profile, sample, raw_frames, spec) {
      Some(kept) => kept
      None => continue
    }
    shown_total += v
    if frames.is_empty() {
      continue
    }
    // Flat value belongs exclusively to the innermost (leaf) frame.
    let (leaf_name, leaf_file) = frames[frames.length() - 1]
    match stats.get(leaf_name) {
      Some(acc) => acc.flat += v
      None => stats[leaf_name] = { filename: leaf_file, flat: v, cum: 0L, }
    }
    // Cumulative value counts each unique function on the stack once (handles recursion).
    let seen : Set[String] = Set([])
    for pair in frames {
      let (fname, ffile) = pair
      if seen.contains(fname) {
        continue
      }
      seen.insert(fname)
      match stats.get(fname) {
        Some(acc) => acc.cum += v
        None => stats[fname] = { filename: ffile, flat: 0L, cum: v, }
      }
    }
  }
  (total, shown_total, stats)
}

///|
/// Compute per-function `flat` and `cum` statistics aligned with `go tool pprof -top`.
pub fn compute_top(
  profile : Profile,
  sample_type~ : String = "",
  sort_by~ : SortBy = Flat,
  limit~ : Int32 = 20,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> TopReport raise PprofError {
  let effective = resolve_filter(filter, spec)
  let (idx, st_name, st_unit) = resolve_sample_type(profile, sample_type~)
  let (total, shown_total, acc_map) = aggregate_functions(
    profile, idx, effective,
  )
  let denom = if is_filter_empty(effective) { total } else { shown_total }
  let entries : Array[FunctionStat] = []
  for name, acc in acc_map {
    entries.push({
      name,
      filename: acc.filename,
      flat: acc.flat,
      flat_pct: pct(acc.flat, denom),
      cum: acc.cum,
      cum_pct: pct(acc.cum, denom),
    })
  }
  entries.sort_by((a, b) => {
    let primary = match sort_by {
      Flat => b.flat.compare(a.flat)
      Cum => b.cum.compare(a.cum)
    }
    if primary != 0 {
      return primary
    }
    let secondary = match sort_by {
      Flat => b.cum.compare(a.cum)
      Cum => b.flat.compare(a.flat)
    }
    if secondary != 0 {
      return secondary
    }
    lex_cmp(a.name, b.name)
  })
  let capped = if limit > 0 && entries.length() > limit {
    entries[:limit].to_owned()
  } else {
    entries
  }
  {
    sample_type: st_name,
    unit: st_unit,
    total,
    shown_total,
    sample_count: profile.samples.length(),
    duration_nanos: profile.duration_nanos,
    entries: capped,
  }
}

///|
/// Group profile metric totals by the values of a `Sample.label` key (e.g. `route`, `tenant`).
pub fn group_by_label(
  profile : Profile,
  label_key : String,
  sample_type~ : String = "",
  spec~ : FilterSpec? = None,
) -> LabelReport raise PprofError {
  guard !label_key.trim().is_empty() else {
    raise InvalidInput("label_key must be nonempty")
  }
  let effective = resolve_filter("", spec)
  let (idx, st_name, st_unit) = resolve_sample_type(profile, sample_type~)
  let loc_map = build_location_map(profile)
  let fn_map = build_function_map(profile)
  let group_vals : Map[String, Int64] = Map([])
  let group_counts : Map[String, Int32] = Map([])
  let mut total = 0L
  let mut matched_total = 0L

  for sample in profile.samples {
    let v = sample.values[idx]
    total += v
    if v == 0L {
      continue
    }
    let raw_frames = sample_frames_root_to_leaf(
      profile, loc_map, fn_map, sample,
    )
    if apply_filter(profile, sample, raw_frames, effective) is None {
      continue
    }
    let seen_vals : Set[String] = Set([])
    for lbl in sample.labels {
      if profile.string_at(lbl.key_idx) == label_key {
        let lval = label_display_value(profile, lbl)
        if !seen_vals.contains(lval) {
          seen_vals.insert(lval)
          group_vals[lval] = group_vals.get(lval).unwrap_or(0L) + v
          group_counts[lval] = group_counts.get(lval).unwrap_or(0) + 1
        }
      }
    }
    if !seen_vals.is_empty() {
      matched_total += v
    }
  }

  let groups : Array[LabelStat] = []
  for lval, val in group_vals {
    groups.push({
      label_value: lval,
      value: val,
      pct: pct(val, total),
      sample_count: group_counts.get(lval).unwrap_or(0),
    })
  }
  groups.sort_by((a, b) => {
    let primary = b.value.compare(a.value)
    if primary != 0 {
      primary
    } else {
      lex_cmp(a.label_value, b.label_value)
    }
  })
  {
    sample_type: st_name,
    unit: st_unit,
    label_key,
    total,
    matched_total,
    groups,
  }
}

///|
/// Collapse all samples into Brendan Gregg folded call stacks (`root;caller;callee`).
pub fn collapse_stacks(
  profile : Profile,
  sample_type~ : String = "",
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> Array[FoldedStack] raise PprofError {
  let effective = resolve_filter(filter, spec)
  let (idx, _, _) = resolve_sample_type(profile, sample_type~)
  let loc_map = build_location_map(profile)
  let fn_map = build_function_map(profile)
  let totals : Map[String, Int64] = Map([])
  for sample in profile.samples {
    let v = sample.values[idx]
    if v == 0L {
      continue
    }
    let raw_frames = sample_frames_root_to_leaf(
      profile, loc_map, fn_map, sample,
    )
    let frames = match apply_filter(profile, sample, raw_frames, effective) {
      Some(kept) => kept
      None => continue
    }
    if frames.is_empty() {
      continue
    }
    let names = frames.map(p => p.0.replace_all(old=";", new="_"))
    let key = names.join(";")
    totals[key] = totals.get(key).unwrap_or(0L) + v
  }
  let out : Array[FoldedStack] = []
  for stack, value in totals {
    out.push({ stack, value, })
  }
  out.sort_by((a, b) => lex_cmp(a.stack, b.stack))
  out
}

///|
/// Render folded stacks in standard `frame1;frame2 value` line format.
pub fn render_folded(stacks : Array[FoldedStack]) -> String {
  let out = StringBuilder()
  for item in stacks {
    out.write_string("\{item.stack} \{item.value}\n")
  }
  out.to_string()
}
