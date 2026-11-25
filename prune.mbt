///|
/// Filter and prune a `Profile` using a `FilterSpec` (`focus`, `ignore_pattern`, `hide`, `label_key`, `label_value`),
/// garbage-collecting unreferenced strings, functions, locations, and mappings into a compact canonical `Profile`
/// ready for re-encoding to `.pb.gz`.
pub fn prune_profile(
  profile : Profile,
  spec : FilterSpec,
) -> Profile raise PprofError {
  validate_profile(profile)
  let loc_map = build_location_map(profile)
  let fn_map = build_function_map(profile)
  let mapping_map : Map[UInt64, Mapping] = Map([])
  for mp in profile.mappings {
    mapping_map[mp.id] = mp
  }

  let strings = StringInterner::new()
  let out_sample_types : Array[ValueType] = []
  for st in profile.sample_types {
    out_sample_types.push({
      type_idx: strings.intern(profile.string_at(st.type_idx)),
      unit_idx: strings.intern(profile.string_at(st.unit_idx)),
    })
  }
  let out_period_type : ValueType? = match profile.period_type {
    Some(pt) =>
      Some({
        type_idx: strings.intern(profile.string_at(pt.type_idx)),
        unit_idx: strings.intern(profile.string_at(pt.unit_idx)),
      })
    None => None
  }
  let out_default_type = if profile.default_sample_type != 0L {
    strings.intern(profile.string_at(profile.default_sample_type))
  } else {
    0L
  }
  let out_comments : Array[Int64] = []
  for c in profile.comments {
    out_comments.push(strings.intern(profile.string_at(c)))
  }

  let out_mappings : Array[Mapping] = []
  let mapping_remap : Map[UInt64, UInt64] = Map([])
  let out_functions : Array[Function] = []
  let fn_remap : Map[UInt64, UInt64] = Map([])
  let out_locations : Array[Location] = []
  let loc_keys : Map[String, UInt64] = Map([])

  fn remap_mapping(old_id : UInt64) -> UInt64 raise PprofError {
    if old_id == 0UL {
      return 0UL
    }
    match mapping_remap.get(old_id) {
      Some(new_id) => new_id
      None =>
        match mapping_map.get(old_id) {
          None => 0UL
          Some(mp) => {
            let new_id = (out_mappings.length() + 1).to_uint64()
            out_mappings.push({
              id: new_id,
              memory_start: mp.memory_start,
              memory_limit: mp.memory_limit,
              file_offset: mp.file_offset,
              filename_idx: strings.intern(profile.string_at(mp.filename_idx)),
              build_id_idx: strings.intern(profile.string_at(mp.build_id_idx)),
              has_functions: mp.has_functions,
              has_filenames: mp.has_filenames,
              has_line_numbers: mp.has_line_numbers,
              has_inline_frames: mp.has_inline_frames,
            })
            mapping_remap[old_id] = new_id
            new_id
          }
        }
    }
  }

  fn remap_function(old_id : UInt64) -> UInt64 raise PprofError {
    match fn_remap.get(old_id) {
      Some(new_id) => new_id
      None =>
        match fn_map.get(old_id) {
          None => 0UL
          Some(f) => {
            let new_id = (out_functions.length() + 1).to_uint64()
            out_functions.push({
              id: new_id,
              name_idx: strings.intern(profile.string_at(f.name_idx)),
              system_name_idx: strings.intern(
                profile.string_at(f.system_name_idx),
              ),
              filename_idx: strings.intern(profile.string_at(f.filename_idx)),
              start_line: f.start_line,
            })
            fn_remap[old_id] = new_id
            new_id
          }
        }
    }
  }

  fn remap_location(old_id : UInt64) -> UInt64? raise PprofError {
    match loc_map.get(old_id) {
      None => None
      Some(loc) => {
        let kept_lines : Array[Line] = []
        if loc.lines.is_empty() {
          if !spec.hide.is_empty() {
            let addr_name = uint64_to_hex(loc.address)
            if addr_name.contains(spec.hide) {
              return None
            }
          }
        } else {
          for ln in loc.lines {
            let keep = match fn_map.get(ln.function_id) {
              Some(f) =>
                if spec.hide.is_empty() {
                  true
                } else {
                  let pair = function_identity(profile, f)
                  !frame_matches(pair, spec.hide)
                }
              None => true
            }
            if keep {
              let new_fid = remap_function(ln.function_id)
              if new_fid != 0UL {
                kept_lines.push({ function_id: new_fid, line: ln.line, })
              }
            }
          }
          if kept_lines.is_empty() {
            return None
          }
        }
        let new_mid = remap_mapping(loc.mapping_id)
        let lkey_parts = kept_lines
          .map(l => "\{l.function_id}:\{l.line}")
          .join(",")
        let lkey = "\{new_mid}|\{loc.address}|\{loc.is_folded}|\{lkey_parts}"
        match loc_keys.get(lkey) {
          Some(existing) => Some(existing)
          None => {
            let new_id = (out_locations.length() + 1).to_uint64()
            out_locations.push({
              id: new_id,
              mapping_id: new_mid,
              address: loc.address,
              lines: kept_lines,
              is_folded: loc.is_folded,
            })
            loc_keys[lkey] = new_id
            Some(new_id)
          }
        }
      }
    }
  }

  let sample_order : Array[String] = []
  let sample_map : Map[String, Sample] = Map([])

  for sample in profile.samples {
    if !matches_label_filter(profile, sample, spec) {
      continue
    }
    let raw_frames = sample_frames_root_to_leaf(
      profile, loc_map, fn_map, sample,
    )
    if apply_filter(profile, sample, raw_frames, spec) is None {
      continue
    }
    let new_loc_ids : Array[UInt64] = []
    for old_lid in sample.location_ids {
      match remap_location(old_lid) {
        Some(new_lid) => new_loc_ids.push(new_lid)
        None => ()
      }
    }
    if new_loc_ids.is_empty() {
      continue
    }
    let (lbl_key, new_labels) = canonical_label_key(
      strings,
      profile,
      sample.labels,
    )
    let stack_key = new_loc_ids.map(id => "\{id}").join(",")
    let skey = "\{stack_key}\u{02}\{lbl_key}"
    match sample_map.get(skey) {
      Some(existing) =>
        for i in 0..<existing.values.length() {
          existing.values[i] = existing.values[i] + sample.values[i]
        }
      None => {
        sample_order.push(skey)
        sample_map[skey] = {
          location_ids: new_loc_ids,
          values: sample.values.copy(),
          labels: new_labels,
        }
      }
    }
  }

  let out_samples : Array[Sample] = []
  for key in sample_order {
    match sample_map.get(key) {
      Some(s) => out_samples.push(s)
      None => ()
    }
  }
  {
    sample_types: out_sample_types,
    samples: out_samples,
    mappings: out_mappings,
    locations: out_locations,
    functions: out_functions,
    string_table: strings.table,
    drop_frames: 0L,
    keep_frames: 0L,
    time_nanos: profile.time_nanos,
    duration_nanos: profile.duration_nanos,
    period_type: out_period_type,
    period: profile.period,
    comments: out_comments,
    default_sample_type: out_default_type,
  }
}
