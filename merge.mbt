///|
priv struct StringInterner {
  table : Array[String]
  index : Map[String, Int64]
}

///|
fn StringInterner::new() -> StringInterner {
  let table : Array[String] = [""]
  let index : Map[String, Int64] = Map([("", 0L)])
  { table, index, }
}

///|
fn StringInterner::intern(self : StringInterner, s : String) -> Int64 {
  match self.index.get(s) {
    Some(idx) => idx
    None => {
      let idx = self.table.length().to_int64()
      self.table.push(s)
      self.index[s] = idx
      idx
    }
  }
}

///|
fn canonical_label_key(
  interner : StringInterner,
  profile : Profile,
  labels : Array[Label],
) -> (String, Array[Label]) raise PprofError {
  let remapped : Array[(String, Label)] = []
  for lbl in labels {
    let k_str = profile.string_at(lbl.key_idx)
    let v_str = profile.string_at(lbl.str_idx)
    let u_str = profile.string_at(lbl.num_unit_idx)
    let new_lbl : Label = {
      key_idx: interner.intern(k_str),
      str_idx: interner.intern(v_str),
      num: lbl.num,
      num_unit_idx: interner.intern(u_str),
    }
    let sort_key = "\{k_str}=\u{00}\{v_str}\u{00}\{lbl.num}\u{00}\{u_str}"
    remapped.push((sort_key, new_lbl))
  }
  remapped.sort_by((a, b) => lex_cmp(a.0, b.0))
  let key_parts = remapped.map(pair => pair.0)
  let out_labels = remapped.map(pair => pair.1)
  (key_parts.join("\u{01}"), out_labels)
}

///|
/// Merge multiple compatible `Profile` instances into a single deduplicated `Profile`.
///
/// All input profiles must declare identical `(type, unit)` `sample_types` in the same order.
/// String tables, mappings, functions, locations, and identical `(stack, labels)` samples are
/// merged deterministically so numeric totals are strictly conserved.
pub fn merge_profiles(profiles : Array[Profile]) -> Profile raise PprofError {
  guard !profiles.is_empty() else {
    raise InvalidInput("merge_profiles requires at least one profile")
  }
  let first = profiles[0]
  let ref_types = sample_type_names(first)
  for i = 1; i < profiles.length(); i = i + 1 {
    let other_types = sample_type_names(profiles[i])
    guard other_types == ref_types else {
      raise InvalidProfile(
        "profile #\{i} has incompatible sample_types for merge",
      )
    }
  }

  let strings = StringInterner::new()
  let merged_sample_types : Array[ValueType] = []
  for pair in ref_types {
    merged_sample_types.push({
      type_idx: strings.intern(pair.0),
      unit_idx: strings.intern(pair.1),
    })
  }

  let mappings : Array[Mapping] = []
  let mapping_keys : Map[String, UInt64] = Map([])
  let functions : Array[Function] = []
  let function_keys : Map[String, UInt64] = Map([])
  let locations : Array[Location] = []
  let location_keys : Map[String, UInt64] = Map([])

  // Sample accumulation keyed by remapped location_ids + canonical labels.
  let sample_order : Array[String] = []
  let sample_map : Map[String, Sample] = Map([])

  let mut total_duration = 0L
  let mut earliest_time = 0L
  let mut merged_period_type : ValueType? = None
  let mut merged_period = 0L
  let merged_comments : Array[Int64] = []
  let seen_comments : Set[String] = Set([])

  for prof in profiles {
    total_duration += prof.duration_nanos
    if prof.time_nanos > 0L &&
      (earliest_time == 0L || prof.time_nanos < earliest_time) {
      earliest_time = prof.time_nanos
    }
    if merged_period_type is None {
      match prof.period_type {
        Some(pt) => {
          merged_period_type = Some({
            type_idx: strings.intern(prof.string_at(pt.type_idx)),
            unit_idx: strings.intern(prof.string_at(pt.unit_idx)),
          })
          merged_period = prof.period
        }
        None => ()
      }
    }
    for c_idx in prof.comments {
      let c_str = prof.string_at(c_idx)
      if !seen_comments.contains(c_str) {
        seen_comments.insert(c_str)
        merged_comments.push(strings.intern(c_str))
      }
    }

    // Remap mappings
    let map_id_remap : Map[UInt64, UInt64] = Map([])
    for m in prof.mappings {
      let fname = prof.string_at(m.filename_idx)
      let bid = prof.string_at(m.build_id_idx)
      let mkey = "\{fname}\u{00}\{bid}\u{00}\{m.memory_start}\u{00}\{m.memory_limit}\u{00}\{m.file_offset}"
      let new_id = match mapping_keys.get(mkey) {
        Some(existing) => existing
        None => {
          let id = (mappings.length() + 1).to_uint64()
          mapping_keys[mkey] = id
          mappings.push({
            id,
            memory_start: m.memory_start,
            memory_limit: m.memory_limit,
            file_offset: m.file_offset,
            filename_idx: strings.intern(fname),
            build_id_idx: strings.intern(bid),
            has_functions: m.has_functions,
            has_filenames: m.has_filenames,
            has_line_numbers: m.has_line_numbers,
            has_inline_frames: m.has_inline_frames,
          })
          id
        }
      }
      map_id_remap[m.id] = new_id
    }

    // Remap functions
    let fn_id_remap : Map[UInt64, UInt64] = Map([])
    for f in prof.functions {
      let name = prof.string_at(f.name_idx)
      let sys = prof.string_at(f.system_name_idx)
      let file = prof.string_at(f.filename_idx)
      let fkey = "\{name}\u{00}\{sys}\u{00}\{file}\u{00}\{f.start_line}"
      let new_id = match function_keys.get(fkey) {
        Some(existing) => existing
        None => {
          let id = (functions.length() + 1).to_uint64()
          function_keys[fkey] = id
          functions.push({
            id,
            name_idx: strings.intern(name),
            system_name_idx: strings.intern(sys),
            filename_idx: strings.intern(file),
            start_line: f.start_line,
          })
          id
        }
      }
      fn_id_remap[f.id] = new_id
    }

    // Remap locations
    let loc_id_remap : Map[UInt64, UInt64] = Map([])
    for loc in prof.locations {
      let new_lines : Array[Line] = []
      let line_key_parts : Array[String] = []
      for line in loc.lines {
        let new_fid = fn_id_remap.get(line.function_id).unwrap_or(0UL)
        new_lines.push({ function_id: new_fid, line: line.line, })
        line_key_parts.push("\{new_fid}:\{line.line}")
      }
      let new_mid = map_id_remap.get(loc.mapping_id).unwrap_or(0UL)
      let lkey = if line_key_parts.is_empty() {
        "addr:\{new_mid}:\{loc.address}:\{loc.is_folded}"
      } else {
        "lines:\{loc.is_folded}:" + line_key_parts.join(",")
      }
      let new_id = match location_keys.get(lkey) {
        Some(existing) => existing
        None => {
          let id = (locations.length() + 1).to_uint64()
          location_keys[lkey] = id
          locations.push({
            id,
            mapping_id: new_mid,
            address: loc.address,
            lines: new_lines,
            is_folded: loc.is_folded,
          })
          id
        }
      }
      loc_id_remap[loc.id] = new_id
    }

    // Merge samples
    for s in prof.samples {
      let new_loc_ids : Array[UInt64] = []
      let loc_key_parts : Array[String] = []
      for old_lid in s.location_ids {
        let nl = loc_id_remap.get(old_lid).unwrap_or(0UL)
        new_loc_ids.push(nl)
        loc_key_parts.push("\{nl}")
      }
      let (lbl_key, new_labels) = canonical_label_key(strings, prof, s.labels)
      let skey = loc_key_parts.join(",") + "\u{02}" + lbl_key
      match sample_map.get(skey) {
        Some(existing) =>
          for vi in 0..<existing.values.length() {
            existing.values[vi] += s.values[vi]
          }
        None => {
          let vals : Array[Int64] = []
          for v in s.values {
            vals.push(v)
          }
          sample_order.push(skey)
          sample_map[skey] = {
            location_ids: new_loc_ids,
            values: vals,
            labels: new_labels,
          }
        }
      }
    }
  }

  let merged_samples : Array[Sample] = []
  for skey in sample_order {
    match sample_map.get(skey) {
      Some(s) => merged_samples.push(s)
      None => ()
    }
  }

  let default_st = if first.default_sample_type != 0L {
    strings.intern(first.string_at(first.default_sample_type))
  } else {
    0L
  }

  {
    sample_types: merged_sample_types,
    samples: merged_samples,
    mappings,
    locations,
    functions,
    string_table: strings.table,
    drop_frames: 0L,
    keep_frames: 0L,
    time_nanos: earliest_time,
    duration_nanos: total_duration,
    period_type: merged_period_type,
    period: merged_period,
    comments: merged_comments,
    default_sample_type: default_st,
  }
}
