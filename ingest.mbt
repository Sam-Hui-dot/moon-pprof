///|
fn parse_i64_ascii(raw : StringView) -> Int64? {
  let trimmed = raw.trim()
  if trimmed.is_empty() {
    return None
  }
  let chars = trimmed.to_array()
  let mut idx = 0
  let mut neg = false
  if chars[0] == '-' {
    neg = true
    idx = 1
  } else if chars[0] == '+' {
    idx = 1
  }
  if idx >= chars.length() {
    return None
  }
  let mut acc = 0L
  for i in idx..<chars.length() {
    let c = chars[i]
    if c < '0' || c > '9' {
      return None
    }
    acc = acc * 10L + (c.to_int() - '0'.to_int()).to_int64()
  }
  Some(if neg { -acc } else { acc })
}

///|
fn looks_like_text(bytes : Bytes) -> Bool {
  if bytes.is_empty() || is_gzip(bytes) {
    return false
  }
  let limit = if bytes.length() < 512 { bytes.length() } else { 512 }
  for i in 0..<limit {
    let b = bytes[i].to_int()
    if b == 0 || b < 9 || (b > 13 && b < 32) {
      return false
    }
  }
  true
}

///|
fn json_int64_field(obj : Map[String, @json.Json], key : String) -> Int64? {
  match obj.get(key) {
    Some(Number(n, ..)) => Some(n.to_int64())
    Some(String(s)) => parse_i64_ascii(s)
    _ => None
  }
}

///|
fn json_int32_field(obj : Map[String, @json.Json], key : String) -> Int32? {
  match obj.get(key) {
    Some(Number(n, ..)) => Some(n.to_int())
    Some(String(s)) =>
      match parse_i64_ascii(s) {
        Some(v) => Some(v.to_int())
        None => None
      }
    _ => None
  }
}

///|
fn json_str_field(obj : Map[String, @json.Json], key : String) -> String {
  match obj.get(key) {
    Some(String(s)) => s
    _ => ""
  }
}

///|
fn unescape_moonbit_ident(raw : String) -> String {
  raw
  .replace_all(old="_2d", new="-")
  .replace_all(old="_2e", new=".")
  .replace_all(old="_2f", new="/")
  .replace_all(old="__", new="_")
}

///|
/// Demangle MoonBit JS backend symbol names (e.g. `_M0MP215Sam_2dHui_2ddot12moon_2dpprof10WireReader12read__varint`)
/// into readable `pkg::Type::method` names; returns non-MoonBit symbols unchanged.
pub fn demangle_moonbit_symbol(name : String) -> String {
  if !name.has_prefix("_M0") || name.length() < 8 {
    return name
  }
  let chars = name.to_array()
  let n = chars.length()
  let mut i = 3
  // Skip leading tag letters (F/M/I/P/C/B etc.) until the first digit sequence.
  let parts : Array[String] = []
  while i < n {
    // Skip uppercase/lowercase descriptor tags like P2, P3, FP, MP, IP, C, PB, GmR, etc.
    if (chars[i] == 'P' || chars[i] == 'C') &&
      i + 1 < n &&
      chars[i + 1] >= '1' &&
      chars[i + 1] <= '9' {
      // Package/core depth prefix like P2, P3, C1; skip prefix letter and single depth digit.
      i += 2
      continue
    }
    if chars[i] >= '1' && chars[i] <= '9' {
      let mut len = 0
      let mut j = i
      while j < n && chars[j] >= '0' && chars[j] <= '9' {
        len = len * 10 + (chars[j].to_int() - '0'.to_int())
        j += 1
      }
      if len > 0 && j + len <= n {
        let seg = StringBuilder()
        for k in j..<(j + len) {
          seg.write_char(chars[k])
        }
        parts.push(unescape_moonbit_ident(seg.to_string()))
        i = j + len
        continue
      }
    }
    i += 1
  }
  if parts.length() >= 2 {
    parts.join("::")
  } else {
    name
  }
}

///|
priv struct V8NodeInfo {
  func_name : String
  filename : String
  line : Int64
  hit_count : Int64
}

///|
/// Convert a Node.js (`node --cpu-prof`) or Chrome DevTools V8 `.cpuprofile` JSON into a canonical `Profile`.
///
/// Sample types emitted are `("samples", "count")` and `("cpu", "nanoseconds")` (default `cpu`).
/// This directly enables profiling MoonBit programs compiled to JS/Wasm on Node.js or browsers.
pub fn from_v8_cpuprofile(json_text : String) -> Profile raise PprofError {
  let parsed = @json.parse(json_text) catch {
    err => raise InvalidInput("invalid V8 .cpuprofile JSON: \{err}")
  }
  guard parsed is Object(root) else {
    raise InvalidInput("V8 .cpuprofile root must be a JSON object")
  }
  guard root.get("nodes") is Some(Array(raw_nodes)) else {
    raise InvalidInput("V8 .cpuprofile missing 'nodes' array")
  }
  guard !raw_nodes.is_empty() else {
    raise InvalidInput("V8 .cpuprofile has empty 'nodes' array")
  }

  let nodes : Map[Int32, V8NodeInfo] = Map([])
  let parent : Map[Int32, Int32] = Map([])
  let node_ids : Array[Int32] = []

  for item in raw_nodes {
    guard item is Object(nobj) else { continue }
    let id = match json_int32_field(nobj, "id") {
      Some(v) => v
      None => continue
    }
    let mut func_name = ""
    let mut filename = ""
    let mut line_num = 0L
    match nobj.get("callFrame") {
      Some(Object(cf)) => {
        func_name = json_str_field(cf, "functionName")
        filename = json_str_field(cf, "url")
        let ln = json_int64_field(cf, "lineNumber").unwrap_or(-1L)
        if ln >= 0L {
          line_num = ln + 1L
        }
      }
      _ => ()
    }
    if func_name.is_empty() {
      func_name = if filename.is_empty() {
        "(anonymous)"
      } else {
        "(anonymous)@\{filename}"
      }
    } else if func_name.has_prefix("_M0") {
      func_name = demangle_moonbit_symbol(func_name)
    }
    let hit_count = json_int64_field(nobj, "hitCount").unwrap_or(0L)
    nodes[id] = { func_name, filename, line: line_num, hit_count, }
    node_ids.push(id)
    match nobj.get("children") {
      Some(Array(children)) =>
        for ch in children {
          match ch {
            Number(cn, ..) => parent[cn.to_int()] = id
            _ => ()
          }
        }
      _ => ()
    }
  }

  let start_us = json_int64_field(root, "startTime").unwrap_or(0L)
  let end_us = json_int64_field(root, "endTime").unwrap_or(start_us)
  let duration_nanos = if end_us >= start_us {
    (end_us - start_us) * 1000L
  } else {
    0L
  }

  let strings = StringInterner::new()
  let st_samples = strings.intern("samples")
  let st_count = strings.intern("count")
  let st_cpu = strings.intern("cpu")
  let st_nanos = strings.intern("nanoseconds")

  let functions : Array[Function] = []
  let fn_keys : Map[String, UInt64] = Map([])
  let locations : Array[Location] = []
  let loc_keys : Map[String, UInt64] = Map([])

  fn intern_loc(info : V8NodeInfo) -> UInt64 {
    let fkey = "\{info.func_name}\u{00}\{info.filename}"
    let fn_id = match fn_keys.get(fkey) {
      Some(id) => id
      None => {
        let id = (functions.length() + 1).to_uint64()
        let name_idx = strings.intern(info.func_name)
        let file_idx = strings.intern(info.filename)
        functions.push({
          id,
          name_idx,
          system_name_idx: name_idx,
          filename_idx: file_idx,
          start_line: info.line,
        })
        fn_keys[fkey] = id
        id
      }
    }
    let lkey = "\{fn_id}:\{info.line}"
    match loc_keys.get(lkey) {
      Some(id) => id
      None => {
        let id = (locations.length() + 1).to_uint64()
        locations.push({
          id,
          mapping_id: 0UL,
          address: id,
          lines: [{ function_id: fn_id, line: info.line, }],
          is_folded: false,
        })
        loc_keys[lkey] = id
        id
      }
    }
  }

  fn build_stack_loc_ids(leaf_id : Int32) -> Array[UInt64] {
    let stack : Array[UInt64] = []
    let visited : Set[Int32] = Set([])
    let mut cur = leaf_id
    while !visited.contains(cur) {
      visited.add(cur)
      match nodes.get(cur) {
        Some(info) => {
          // Omit synthetic V8 container "(root)" unless it is the sole frame.
          let is_synthetic_root = info.func_name == "(root)" &&
            !parent.contains(cur)
          if !is_synthetic_root || stack.is_empty() {
            if !is_synthetic_root {
              stack.push(intern_loc(info))
            }
          }
        }
        None => break
      }
      match parent.get(cur) {
        Some(p) => cur = p
        None => break
      }
    }
    if stack.is_empty() {
      match nodes.get(leaf_id) {
        Some(info) => stack.push(intern_loc(info))
        None => ()
      }
    }
    stack
  }

  let sample_order : Array[String] = []
  let sample_map : Map[String, Sample] = Map([])

  fn record_sample(
    loc_ids : Array[UInt64],
    count_v : Int64,
    cpu_ns : Int64,
  ) -> Unit {
    if loc_ids.is_empty() || (count_v == 0L && cpu_ns == 0L) {
      return
    }
    let key = loc_ids.map(id => "\{id}").join(",")
    match sample_map.get(key) {
      Some(existing) => {
        existing.values[0] = existing.values[0] + count_v
        existing.values[1] = existing.values[1] + cpu_ns
      }
      None => {
        sample_order.push(key)
        sample_map[key] = {
          location_ids: loc_ids,
          values: [count_v, cpu_ns],
          labels: [],
        }
      }
    }
  }

  let raw_samples : Array[Int32] = []
  match root.get("samples") {
    Some(Array(arr)) =>
      for el in arr {
        match el {
          Number(n, ..) => raw_samples.push(n.to_int())
          _ => ()
        }
      }
    _ => ()
  }
  let raw_deltas : Array[Int64] = []
  match root.get("timeDeltas") {
    Some(Array(arr)) =>
      for el in arr {
        match el {
          Number(n, ..) => {
            let v = n.to_int64()
            raw_deltas.push(if v < 0L { 0L } else { v })
          }
          _ => raw_deltas.push(0L)
        }
      }
    _ => ()
  }

  if !raw_samples.is_empty() {
    for i, leaf_id in raw_samples {
      // V8 associates timeDeltas[i] with the time elapsed prior to sample[i] (or next tick).
      let delta_us = if i < raw_deltas.length() { raw_deltas[i] } else { 1000L }
      let loc_ids = build_stack_loc_ids(leaf_id)
      record_sample(loc_ids, 1L, delta_us * 1000L)
    }
  } else {
    for nid in node_ids {
      match nodes.get(nid) {
        Some(info) =>
          if info.hit_count > 0L {
            let loc_ids = build_stack_loc_ids(nid)
            record_sample(loc_ids, info.hit_count, info.hit_count * 1_000_000L)
          }
        None => ()
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
  let comment_idx = strings.intern(
    "converted from V8 .cpuprofile by moon-pprof",
  )
  {
    sample_types: [
      { type_idx: st_samples, unit_idx: st_count, },
      { type_idx: st_cpu, unit_idx: st_nanos, },
    ],
    samples: out_samples,
    mappings: [],
    locations,
    functions,
    string_table: strings.table,
    drop_frames: 0L,
    keep_frames: 0L,
    time_nanos: start_us * 1000L,
    duration_nanos,
    period_type: Some({ type_idx: st_cpu, unit_idx: st_nanos, }),
    period: 1_000_000L,
    comments: [comment_idx],
    default_sample_type: st_cpu,
  }
}

///|
fn split_last_whitespace(line : String) -> (String, String)? {
  let chars = line.to_array()
  let mut idx = chars.length() - 1
  while idx >= 0 && (chars[idx] == ' ' || chars[idx] == '\t') {
    idx -= 1
  }
  let val_end = idx + 1
  while idx >= 0 && chars[idx] != ' ' && chars[idx] != '\t' {
    idx -= 1
  }
  if idx <= 0 {
    return None
  }
  let lhs = StringBuilder()
  for i in 0..<idx {
    lhs.write_char(chars[i])
  }
  let rhs = StringBuilder()
  for i in (idx + 1)..<val_end {
    rhs.write_char(chars[i])
  }
  Some((lhs.to_string().trim().to_owned(), rhs.to_string().trim().to_owned()))
}

///|
/// Convert Brendan Gregg folded stack lines (`a;b;c 42`) into a canonical `Profile`.
pub fn from_folded_stacks(
  text : String,
  sample_type~ : String = "samples",
  unit~ : String = "count",
) -> Profile raise PprofError {
  let clean = text.replace_all(old="\r", new="")
  let lines = clean.split("\n").to_array()
  let strings = StringInterner::new()
  let st_idx = strings.intern(
    if sample_type.trim().is_empty() {
      "samples"
    } else {
      sample_type.trim().to_owned()
    },
  )
  let unit_idx = strings.intern(
    if unit.trim().is_empty() {
      "count"
    } else {
      unit.trim().to_owned()
    },
  )
  let functions : Array[Function] = []
  let fn_keys : Map[String, UInt64] = Map([])
  let locations : Array[Location] = []
  let loc_keys : Map[UInt64, UInt64] = Map([])
  let sample_order : Array[String] = []
  let sample_map : Map[String, Sample] = Map([])

  fn intern_frame(name : String) -> UInt64 {
    let fn_id = match fn_keys.get(name) {
      Some(id) => id
      None => {
        let id = (functions.length() + 1).to_uint64()
        let n_idx = strings.intern(name)
        functions.push({
          id,
          name_idx: n_idx,
          system_name_idx: n_idx,
          filename_idx: 0L,
          start_line: 0L,
        })
        fn_keys[name] = id
        id
      }
    }
    match loc_keys.get(fn_id) {
      Some(id) => id
      None => {
        let id = (locations.length() + 1).to_uint64()
        locations.push({
          id,
          mapping_id: 0UL,
          address: id,
          lines: [{ function_id: fn_id, line: 0L, }],
          is_folded: false,
        })
        loc_keys[fn_id] = id
        id
      }
    }
  }

  let mut parsed_lines = 0
  for raw_view in lines {
    let line = raw_view.trim().to_owned()
    if line.is_empty() || line.has_prefix("#") {
      continue
    }
    guard split_last_whitespace(line) is Some((stack_str, val_str)) else {
      raise InvalidInput("invalid folded stack line: \{line}")
    }
    guard parse_i64_ascii(val_str) is Some(val) else {
      raise InvalidInput(
        "invalid folded stack value '\{val_str}' in line: \{line}",
      )
    }
    let parts = stack_str.split(";").to_array()
    let loc_ids : Array[UInt64] = []
    // Folded format is root;...;leaf, while pprof location_ids are leaf-first.
    for i = parts.length() - 1; i >= 0; i = i - 1 {
      let frame = parts[i].trim().to_owned()
      if !frame.is_empty() {
        loc_ids.push(intern_frame(frame))
      }
    }
    if loc_ids.is_empty() {
      continue
    }
    parsed_lines += 1
    let key = loc_ids.map(id => "\{id}").join(",")
    match sample_map.get(key) {
      Some(existing) => existing.values[0] = existing.values[0] + val
      None => {
        sample_order.push(key)
        sample_map[key] = { location_ids: loc_ids, values: [val], labels: [], }
      }
    }
  }
  guard parsed_lines > 0 else {
    raise InvalidInput("no folded stack entries found")
  }
  let out_samples : Array[Sample] = []
  for key in sample_order {
    match sample_map.get(key) {
      Some(s) => out_samples.push(s)
      None => ()
    }
  }
  {
    sample_types: [{ type_idx: st_idx, unit_idx, }],
    samples: out_samples,
    mappings: [],
    locations,
    functions,
    string_table: strings.table,
    drop_frames: 0L,
    keep_frames: 0L,
    time_nanos: 0L,
    duration_nanos: 0L,
    period_type: None,
    period: 0L,
    comments: [strings.intern("converted from folded stacks by moon-pprof")],
    default_sample_type: st_idx,
  }
}

///|
fn parse_perf_frame(raw : String) -> (String, String) {
  let trimmed = raw.trim().to_owned()
  // Typical perf script frame: `7f9b1c2d3e40 my_func+0x24 (/usr/bin/app)`
  let rest = match trimmed.split_once(" ") {
    Some((_, tail)) => tail.trim().to_owned()
    None => trimmed
  }
  let (sym_raw, binary) = match rest.split_once(" (") {
    Some((s, b)) => {
      let b_clean = if b.has_suffix(")") {
        b[:b.length() - 1].to_owned()
      } else {
        b.to_owned()
      }
      (s.trim().to_owned(), b_clean)
    }
    None => (rest, "")
  }
  let sym = match sym_raw.split_once("+0x") {
    Some((name, _)) => name.trim().to_owned()
    None => sym_raw
  }
  let final_sym = if sym.is_empty() || sym == "[unknown]" {
    if binary.is_empty() {
      "[unknown]"
    } else {
      "[\{binary}]"
    }
  } else {
    sym
  }
  (final_sym, binary)
}

///|
fn parse_perf_header(line : String) -> (String, Int64) {
  // Typical header: `myapp 12345 1234.567890:   250000 cpu-clock:` or `myapp 12345 [001] 12.34: cycles:`
  let tokens : Array[String] = []
  for part in line.split(" ") {
    let t = part.trim().to_owned()
    if !t.is_empty() {
      tokens.push(t)
    }
  }
  let comm = if tokens.is_empty() { "perf" } else { tokens[0] }
  let mut weight = 1L
  // Look for numeric period right after the timestamp token ending with ':'
  for i, tok in tokens {
    if tok.has_suffix(":") && i + 1 < tokens.length() {
      match parse_i64_ascii(tokens[i + 1]) {
        Some(w) => if w > 0L { weight = w }
        None => ()
      }
      break
    }
  }
  (comm, weight)
}

///|
/// Convert Linux `perf script` text output directly into a canonical `Profile` (zero Perl dependency).
pub fn from_perf_script(text : String) -> Profile raise PprofError {
  let clean = text.replace_all(old="\r", new="")
  let lines = clean.split("\n").to_array()

  let strings = StringInterner::new()
  let st_samples = strings.intern("samples")
  let st_count = strings.intern("count")
  let st_weight = strings.intern("weight")
  let functions : Array[Function] = []
  let fn_keys : Map[String, UInt64] = Map([])
  let locations : Array[Location] = []
  let loc_keys : Map[UInt64, UInt64] = Map([])
  let sample_order : Array[String] = []
  let sample_map : Map[String, Sample] = Map([])

  fn intern_perf_loc(name : String, binary : String) -> UInt64 {
    let fkey = "\{name}\u{00}\{binary}"
    let fn_id = match fn_keys.get(fkey) {
      Some(id) => id
      None => {
        let id = (functions.length() + 1).to_uint64()
        let n_idx = strings.intern(name)
        let f_idx = strings.intern(binary)
        functions.push({
          id,
          name_idx: n_idx,
          system_name_idx: n_idx,
          filename_idx: f_idx,
          start_line: 0L,
        })
        fn_keys[fkey] = id
        id
      }
    }
    match loc_keys.get(fn_id) {
      Some(id) => id
      None => {
        let id = (locations.length() + 1).to_uint64()
        locations.push({
          id,
          mapping_id: 0UL,
          address: id,
          lines: [{ function_id: fn_id, line: 0L, }],
          is_folded: false,
        })
        loc_keys[fn_id] = id
        id
      }
    }
  }

  let mut cur_comm = ""
  let mut cur_weight = 1L
  let mut cur_frames : Array[UInt64] = []
  let mut sample_blocks = 0

  fn flush_block() -> Unit {
    if cur_comm.is_empty() && cur_frames.is_empty() {
      return
    }
    let loc_ids : Array[UInt64] = []
    for id in cur_frames {
      loc_ids.push(id)
    }
    if !cur_comm.is_empty() {
      loc_ids.push(intern_perf_loc(cur_comm, ""))
    }
    if !loc_ids.is_empty() {
      sample_blocks += 1
      let key = loc_ids.map(id => "\{id}").join(",")
      match sample_map.get(key) {
        Some(existing) => {
          existing.values[0] = existing.values[0] + 1L
          existing.values[1] = existing.values[1] + cur_weight
        }
        None => {
          sample_order.push(key)
          sample_map[key] = {
            location_ids: loc_ids,
            values: [1L, cur_weight],
            labels: [],
          }
        }
      }
    }
    cur_comm = ""
    cur_weight = 1L
    cur_frames = []
  }

  for raw_view in lines {
    let raw = raw_view.to_owned()
    let trimmed = raw.trim().to_owned()
    if trimmed.is_empty() {
      flush_block()
      continue
    }
    if trimmed.has_prefix("#") {
      continue
    }
    if raw.has_prefix("\t") || raw.has_prefix(" ") {
      let (sym, bin) = parse_perf_frame(trimmed)
      cur_frames.push(intern_perf_loc(sym, bin))
    } else {
      flush_block()
      let (comm, weight) = parse_perf_header(trimmed)
      cur_comm = comm
      cur_weight = weight
    }
  }
  flush_block()

  guard sample_blocks > 0 else {
    raise InvalidInput("no perf script sample blocks found")
  }
  let out_samples : Array[Sample] = []
  for key in sample_order {
    match sample_map.get(key) {
      Some(s) => out_samples.push(s)
      None => ()
    }
  }
  {
    sample_types: [
      { type_idx: st_samples, unit_idx: st_count, },
      { type_idx: st_weight, unit_idx: st_count, },
    ],
    samples: out_samples,
    mappings: [],
    locations,
    functions,
    string_table: strings.table,
    drop_frames: 0L,
    keep_frames: 0L,
    time_nanos: 0L,
    duration_nanos: 0L,
    period_type: None,
    period: 0L,
    comments: [strings.intern("converted from Linux perf script by moon-pprof")],
    default_sample_type: st_weight,
  }
}

///|
/// Detect the profiling format of raw input bytes: `"pprof-gzip"`, `"pprof-raw"`, `"v8-cpuprofile"`, `"perf-script"`, or `"folded"`.
pub fn detect_profile_format(bytes : Bytes) -> String {
  if bytes.is_empty() {
    return "unknown"
  }
  if is_gzip(bytes) {
    return "pprof-gzip"
  }
  if looks_like_text(bytes) {
    let text = decode_utf8_slice(bytes, 0, bytes.length())
    let trimmed = text.trim()
    if trimmed.has_prefix("{") && trimmed.contains("\"nodes\"") {
      return "v8-cpuprofile"
    }
    let mut has_indented = false
    let mut has_header_colon = false
    let mut has_folded = false
    for line_v in text.replace_all(old="\r", new="").split("\n") {
      let raw = line_v.to_owned()
      let t = raw.trim().to_owned()
      if t.is_empty() || t.has_prefix("#") {
        continue
      }
      if raw.has_prefix("\t") || raw.has_prefix("    ") {
        has_indented = true
      } else if t.contains(":") && !t.contains(";") {
        has_header_colon = true
      } else {
        match split_last_whitespace(t) {
          Some((_, rhs)) =>
            if parse_i64_ascii(rhs) is Some(_) {
              has_folded = true
            }
          None => ()
        }
      }
    }
    if has_indented && has_header_colon {
      return "perf-script"
    }
    if has_folded {
      return "folded"
    }
  }
  "pprof-raw"
}

///|
/// Auto-detect and decode any supported profiling format (`.pb.gz`, `.pb`, V8 `.cpuprofile`, `perf script`, or `folded`).
pub fn decode_any_profile(bytes : Bytes) -> Profile raise PprofError {
  match detect_profile_format(bytes) {
    "pprof-gzip" | "pprof-raw" => decode_profile(bytes)
    "v8-cpuprofile" =>
      from_v8_cpuprofile(decode_utf8_slice(bytes, 0, bytes.length()))
    "perf-script" =>
      from_perf_script(decode_utf8_slice(bytes, 0, bytes.length()))
    "folded" => from_folded_stacks(decode_utf8_slice(bytes, 0, bytes.length()))
    _ => raise InvalidInput("empty or unrecognized profile input")
  }
}
