///|
/// Return true when `data` begins with the RFC 1952 gzip magic header (`0x1F 0x8B`).
pub fn is_gzip(data : Bytes) -> Bool {
  data.length() >= 2 && data[0] == b'\x1F' && data[1] == b'\x8B'
}

///|
/// Decompress gzip-encoded bytes or return raw protobuf bytes unchanged.
pub fn gunzip_if_needed(data : Bytes) -> Bytes raise PprofError {
  if is_gzip(data) {
    @gzip.decompress(data[:]) catch {
      GzipError(_, msg) =>
        raise InvalidGzip("failed to decompress gzip stream: \{msg}")
    }
  } else {
    data
  }
}

///|
/// Look up a string in `profile.string_table` with bounds checking.
pub fn Profile::string_at(
  self : Profile,
  index : Int64,
) -> String raise PprofError {
  guard index >= 0L && index < self.string_table.length().to_int64() else {
    raise InvalidProfile("string_table index out of bounds: \{index}")
  }
  self.string_table[index.to_int()]
}

///|
fn decode_value_type(
  bytes : Bytes,
  start : Int32,
  end : Int32,
) -> ValueType raise PprofError {
  let r = WireReader::new(bytes, start, end)
  let mut type_idx = 0L
  let mut unit_idx = 0L
  while !r.eof() {
    let (field, wt) = r.read_tag()
    match (field, wt) {
      (1, 0) => type_idx = r.read_int64()
      (2, 0) => unit_idx = r.read_int64()
      _ => r.skip_field(wt)
    }
  }
  { type_idx, unit_idx, }
}

///|
fn decode_label(
  bytes : Bytes,
  start : Int32,
  end : Int32,
) -> Label raise PprofError {
  let r = WireReader::new(bytes, start, end)
  let mut key_idx = 0L
  let mut str_idx = 0L
  let mut num = 0L
  let mut num_unit_idx = 0L
  while !r.eof() {
    let (field, wt) = r.read_tag()
    match (field, wt) {
      (1, 0) => key_idx = r.read_int64()
      (2, 0) => str_idx = r.read_int64()
      (3, 0) => num = r.read_int64()
      (4, 0) => num_unit_idx = r.read_int64()
      _ => r.skip_field(wt)
    }
  }
  { key_idx, str_idx, num, num_unit_idx, }
}

///|
fn decode_sample(
  bytes : Bytes,
  start : Int32,
  end : Int32,
) -> Sample raise PprofError {
  let r = WireReader::new(bytes, start, end)
  let location_ids : Array[UInt64] = []
  let values : Array[Int64] = []
  let labels : Array[Label] = []
  while !r.eof() {
    let (field, wt) = r.read_tag()
    match (field, wt) {
      (1, 0) => location_ids.push(r.read_varint())
      (1, 2) => {
        let (ps, pe) = r.read_len_slice()
        let pr = WireReader::new(bytes, ps, pe)
        while !pr.eof() {
          location_ids.push(pr.read_varint())
        }
      }
      (2, 0) => values.push(r.read_int64())
      (2, 2) => {
        let (ps, pe) = r.read_len_slice()
        let pr = WireReader::new(bytes, ps, pe)
        while !pr.eof() {
          values.push(pr.read_int64())
        }
      }
      (3, 2) => {
        let (ls, le) = r.read_len_slice()
        labels.push(decode_label(bytes, ls, le))
      }
      _ => r.skip_field(wt)
    }
  }
  { location_ids, values, labels, }
}

///|
fn decode_mapping(
  bytes : Bytes,
  start : Int32,
  end : Int32,
) -> Mapping raise PprofError {
  let r = WireReader::new(bytes, start, end)
  let mut id = 0UL
  let mut memory_start = 0UL
  let mut memory_limit = 0UL
  let mut file_offset = 0UL
  let mut filename_idx = 0L
  let mut build_id_idx = 0L
  let mut has_functions = false
  let mut has_filenames = false
  let mut has_line_numbers = false
  let mut has_inline_frames = false
  while !r.eof() {
    let (field, wt) = r.read_tag()
    match (field, wt) {
      (1, 0) => id = r.read_varint()
      (2, 0) => memory_start = r.read_varint()
      (3, 0) => memory_limit = r.read_varint()
      (4, 0) => file_offset = r.read_varint()
      (5, 0) => filename_idx = r.read_int64()
      (6, 0) => build_id_idx = r.read_int64()
      (7, 0) => has_functions = r.read_bool()
      (8, 0) => has_filenames = r.read_bool()
      (9, 0) => has_line_numbers = r.read_bool()
      (10, 0) => has_inline_frames = r.read_bool()
      _ => r.skip_field(wt)
    }
  }
  {
    id,
    memory_start,
    memory_limit,
    file_offset,
    filename_idx,
    build_id_idx,
    has_functions,
    has_filenames,
    has_line_numbers,
    has_inline_frames,
  }
}

///|
fn decode_line(
  bytes : Bytes,
  start : Int32,
  end : Int32,
) -> Line raise PprofError {
  let r = WireReader::new(bytes, start, end)
  let mut function_id = 0UL
  let mut line = 0L
  while !r.eof() {
    let (field, wt) = r.read_tag()
    match (field, wt) {
      (1, 0) => function_id = r.read_varint()
      (2, 0) => line = r.read_int64()
      _ => r.skip_field(wt)
    }
  }
  { function_id, line, }
}

///|
fn decode_location(
  bytes : Bytes,
  start : Int32,
  end : Int32,
) -> Location raise PprofError {
  let r = WireReader::new(bytes, start, end)
  let mut id = 0UL
  let mut mapping_id = 0UL
  let mut address = 0UL
  let lines : Array[Line] = []
  let mut is_folded = false
  while !r.eof() {
    let (field, wt) = r.read_tag()
    match (field, wt) {
      (1, 0) => id = r.read_varint()
      (2, 0) => mapping_id = r.read_varint()
      (3, 0) => address = r.read_varint()
      (4, 2) => {
        let (ls, le) = r.read_len_slice()
        lines.push(decode_line(bytes, ls, le))
      }
      (5, 0) => is_folded = r.read_bool()
      _ => r.skip_field(wt)
    }
  }
  { id, mapping_id, address, lines, is_folded, }
}

///|
fn decode_function(
  bytes : Bytes,
  start : Int32,
  end : Int32,
) -> Function raise PprofError {
  let r = WireReader::new(bytes, start, end)
  let mut id = 0UL
  let mut name_idx = 0L
  let mut system_name_idx = 0L
  let mut filename_idx = 0L
  let mut start_line = 0L
  while !r.eof() {
    let (field, wt) = r.read_tag()
    match (field, wt) {
      (1, 0) => id = r.read_varint()
      (2, 0) => name_idx = r.read_int64()
      (3, 0) => system_name_idx = r.read_int64()
      (4, 0) => filename_idx = r.read_int64()
      (5, 0) => start_line = r.read_int64()
      _ => r.skip_field(wt)
    }
  }
  { id, name_idx, system_name_idx, filename_idx, start_line, }
}

///|
/// Decode and validate a Google `pprof` binary profile (`.pb` or gzipped `.pb.gz`).
pub fn decode_profile(data : Bytes) -> Profile raise PprofError {
  guard data.length() > 0 else { raise InvalidProfile("pprof input is empty") }
  let raw = gunzip_if_needed(data)
  let r = WireReader::new(raw, 0, raw.length())
  let sample_types : Array[ValueType] = []
  let samples : Array[Sample] = []
  let mappings : Array[Mapping] = []
  let locations : Array[Location] = []
  let functions : Array[Function] = []
  let string_table : Array[String] = []
  let mut drop_frames = 0L
  let mut keep_frames = 0L
  let mut time_nanos = 0L
  let mut duration_nanos = 0L
  let mut period_type : ValueType? = None
  let mut period = 0L
  let comments : Array[Int64] = []
  let mut default_sample_type = 0L

  while !r.eof() {
    let (field, wt) = r.read_tag()
    match (field, wt) {
      (1, 2) => {
        let (s, e) = r.read_len_slice()
        sample_types.push(decode_value_type(raw, s, e))
      }
      (2, 2) => {
        let (s, e) = r.read_len_slice()
        samples.push(decode_sample(raw, s, e))
      }
      (3, 2) => {
        let (s, e) = r.read_len_slice()
        mappings.push(decode_mapping(raw, s, e))
      }
      (4, 2) => {
        let (s, e) = r.read_len_slice()
        locations.push(decode_location(raw, s, e))
      }
      (5, 2) => {
        let (s, e) = r.read_len_slice()
        functions.push(decode_function(raw, s, e))
      }
      (6, 2) => string_table.push(r.read_utf8())
      (7, 0) => drop_frames = r.read_int64()
      (8, 0) => keep_frames = r.read_int64()
      (9, 0) => time_nanos = r.read_int64()
      (10, 0) => duration_nanos = r.read_int64()
      (11, 2) => {
        let (s, e) = r.read_len_slice()
        period_type = Some(decode_value_type(raw, s, e))
      }
      (12, 0) => period = r.read_int64()
      (13, 0) => comments.push(r.read_int64())
      (13, 2) => {
        let (ps, pe) = r.read_len_slice()
        let pr = WireReader::new(raw, ps, pe)
        while !pr.eof() {
          comments.push(pr.read_int64())
        }
      }
      (14, 0) => default_sample_type = r.read_int64()
      _ => r.skip_field(wt)
    }
  }

  let profile : Profile = {
    sample_types,
    samples,
    mappings,
    locations,
    functions,
    string_table,
    drop_frames,
    keep_frames,
    time_nanos,
    duration_nanos,
    period_type,
    period,
    comments,
    default_sample_type,
  }
  validate_profile(profile)
  profile
}

///|
/// Validate invariants mandated by `profile.proto` (string table index 0, value counts, indices).
pub fn validate_profile(profile : Profile) -> Unit raise PprofError {
  guard !profile.string_table.is_empty() && profile.string_table[0] == "" else {
    raise InvalidProfile("profile string_table[0] must be the empty string")
  }
  guard !profile.sample_types.is_empty() else {
    raise InvalidProfile("profile must declare at least one sample_type")
  }
  let str_len = profile.string_table.length().to_int64()
  for st in profile.sample_types {
    guard st.type_idx >= 0L &&
      st.type_idx < str_len &&
      st.unit_idx >= 0L &&
      st.unit_idx < str_len else {
      raise InvalidProfile("sample_type string index out of bounds")
    }
  }
  let expected_values = profile.sample_types.length()
  for i, sample in profile.samples {
    guard sample.values.length() == expected_values else {
      raise InvalidProfile(
        "sample \{i} has \{sample.values.length()} values, expected \{expected_values}",
      )
    }
  }
  for f in profile.functions {
    guard f.name_idx >= 0L &&
      f.name_idx < str_len &&
      f.system_name_idx >= 0L &&
      f.system_name_idx < str_len &&
      f.filename_idx >= 0L &&
      f.filename_idx < str_len else {
      raise InvalidProfile("function \{f.id} string index out of bounds")
    }
  }
}

///|
fn encode_value_type(vt : ValueType) -> Bytes {
  let buf = Buffer()
  write_int64_field(buf, 1, vt.type_idx)
  write_int64_field(buf, 2, vt.unit_idx)
  buf.contents()
}

///|
fn encode_label(label : Label) -> Bytes {
  let buf = Buffer()
  write_int64_field(buf, 1, label.key_idx)
  write_int64_field(buf, 2, label.str_idx)
  write_int64_field(buf, 3, label.num)
  write_int64_field(buf, 4, label.num_unit_idx)
  buf.contents()
}

///|
fn encode_sample(sample : Sample) -> Bytes {
  let buf = Buffer()
  if !sample.location_ids.is_empty() {
    let packed = Buffer()
    for id in sample.location_ids {
      write_varint(packed, id)
    }
    write_bytes_field(buf, 1, packed.contents())
  }
  if !sample.values.is_empty() {
    let packed = Buffer()
    for v in sample.values {
      write_varint(packed, v.reinterpret_as_uint64())
    }
    write_bytes_field(buf, 2, packed.contents())
  }
  for label in sample.labels {
    write_bytes_field(buf, 3, encode_label(label))
  }
  buf.contents()
}

///|
fn encode_mapping(m : Mapping) -> Bytes {
  let buf = Buffer()
  write_uint64_field(buf, 1, m.id)
  write_uint64_field(buf, 2, m.memory_start)
  write_uint64_field(buf, 3, m.memory_limit)
  write_uint64_field(buf, 4, m.file_offset)
  write_int64_field(buf, 5, m.filename_idx)
  write_int64_field(buf, 6, m.build_id_idx)
  write_bool_field(buf, 7, m.has_functions)
  write_bool_field(buf, 8, m.has_filenames)
  write_bool_field(buf, 9, m.has_line_numbers)
  write_bool_field(buf, 10, m.has_inline_frames)
  buf.contents()
}

///|
fn encode_line(line : Line) -> Bytes {
  let buf = Buffer()
  write_uint64_field(buf, 1, line.function_id)
  write_int64_field(buf, 2, line.line)
  buf.contents()
}

///|
fn encode_location(loc : Location) -> Bytes {
  let buf = Buffer()
  write_uint64_field(buf, 1, loc.id)
  write_uint64_field(buf, 2, loc.mapping_id)
  write_uint64_field(buf, 3, loc.address)
  for line in loc.lines {
    write_bytes_field(buf, 4, encode_line(line))
  }
  write_bool_field(buf, 5, loc.is_folded)
  buf.contents()
}

///|
fn encode_function(f : Function) -> Bytes {
  let buf = Buffer()
  write_uint64_field(buf, 1, f.id)
  write_int64_field(buf, 2, f.name_idx)
  write_int64_field(buf, 3, f.system_name_idx)
  write_int64_field(buf, 4, f.filename_idx)
  write_int64_field(buf, 5, f.start_line)
  buf.contents()
}

///|
/// Encode a `Profile` into canonical `profile.proto` binary bytes (optionally gzip-compressed).
pub fn encode_profile(profile : Profile, gzip~ : Bool = false) -> Bytes {
  let buf = Buffer()
  for st in profile.sample_types {
    write_bytes_field(buf, 1, encode_value_type(st))
  }
  for s in profile.samples {
    write_bytes_field(buf, 2, encode_sample(s))
  }
  for m in profile.mappings {
    write_bytes_field(buf, 3, encode_mapping(m))
  }
  for loc in profile.locations {
    write_bytes_field(buf, 4, encode_location(loc))
  }
  for f in profile.functions {
    write_bytes_field(buf, 5, encode_function(f))
  }
  for s in profile.string_table {
    write_string_field(buf, 6, s)
  }
  write_int64_field(buf, 7, profile.drop_frames)
  write_int64_field(buf, 8, profile.keep_frames)
  write_int64_field(buf, 9, profile.time_nanos)
  write_int64_field(buf, 10, profile.duration_nanos)
  match profile.period_type {
    Some(pt) => write_bytes_field(buf, 11, encode_value_type(pt))
    None => ()
  }
  write_int64_field(buf, 12, profile.period)
  if !profile.comments.is_empty() {
    let packed = Buffer()
    for c in profile.comments {
      write_varint(packed, c.reinterpret_as_uint64())
    }
    write_bytes_field(buf, 13, packed.contents())
  }
  write_int64_field(buf, 14, profile.default_sample_type)
  let raw = buf.contents()
  if gzip {
    @gzip.compress(raw[:])
  } else {
    raw
  }
}
