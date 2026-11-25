///|
fn b64_val(ch : Int32) -> Int32 {
  if ch >= 65 && ch <= 90 {
    ch - 65
  } else if ch >= 97 && ch <= 122 {
    ch - 97 + 26
  } else if ch >= 48 && ch <= 57 {
    ch - 48 + 52
  } else if ch == 43 || ch == 45 {
    62
  } else if ch == 47 || ch == 95 {
    63
  } else {
    -1
  }
}

///|
fn decode_base64(input : String) -> Bytes raise @moon-pprof.PprofError {
  let buf = @buffer.Buffer()
  let mut acc = 0
  let mut bits = 0
  for ch in input {
    let code = ch.to_int()
    if code == 61 {
      break
    }
    if code == 32 || code == 10 || code == 13 || code == 9 {
      continue
    }
    let v = b64_val(code)
    guard v >= 0 else {
      raise @moon-pprof.PprofError::InvalidInput("invalid base64 character")
    }
    acc = (acc << 6) | v
    bits += 6
    if bits >= 8 {
      bits -= 8
      buf.write_byte(((acc >> bits) & 0xFF).to_byte())
    }
  }
  buf.to_bytes()
}

///|
fn json_err(err : Error) -> String {
  @json.Json::object({
    "ok": @json.ToJson::to_json(false),
    "error": @json.ToJson::to_json(@moon-pprof.error_message(err)),
  }).stringify()
}

///|
fn collect_label_keys(
  profile : @moon-pprof.Profile,
) -> Array[String] raise @moon-pprof.PprofError {
  let seen : Map[String, Bool] = Map([])
  let keys : Array[String] = []
  for s in profile.samples {
    for lbl in s.labels {
      let k = profile.string_at(lbl.key_idx)
      if !k.is_empty() && !seen.contains(k) {
        seen[k] = true
        keys.push(k)
      }
    }
  }
  keys.sort()
  keys
}

///|
/// Inspect a base64-encoded `.pb` or `.pb.gz` profile and return metadata as JSON.
pub fn inspect_profile_b64(b64 : String) -> String {
  try {
    let bytes = decode_base64(b64)
    let profile = @moon-pprof.decode_profile(bytes)
    let types = @moon-pprof.sample_type_names(profile)
    let (_, default_name, _) = @moon-pprof.resolve_sample_type(profile)
    let label_keys = collect_label_keys(profile)
    let metrics_json : Array[@json.Json] = []
    for pair in types {
      metrics_json.push(
        @json.Json::object({
          "name": @json.ToJson::to_json(pair.0),
          "unit": @json.ToJson::to_json(pair.1),
        }),
      )
    }
    @json.Json::object({
      "ok": @json.ToJson::to_json(true),
      "default_sample_type": @json.ToJson::to_json(default_name),
      "sample_count": @json.ToJson::to_json(profile.samples.length()),
      "function_count": @json.ToJson::to_json(profile.functions.length()),
      "location_count": @json.ToJson::to_json(profile.locations.length()),
      "metrics": @json.Json::array(metrics_json),
      "label_keys": @json.ToJson::to_json(label_keys),
    }).stringify()
  } catch {
    err => json_err(err)
  }
}

///|
/// Analyze a single base64-encoded profile and return Top, Flamegraph SVG, Callgraph SVG/DOT, Markdown, and optional Label breakdown.
pub fn analyze_profile_b64(
  b64 : String,
  sample_type : String,
  focus : String,
  ignore_pattern : String,
  hide : String,
  label_key : String,
  label_value : String,
  max_nodes : Int32,
) -> String {
  try {
    let bytes = decode_base64(b64)
    let profile = @moon-pprof.decode_profile(bytes)
    let spec = Some(
      @moon-pprof.filter_spec(
        focus~,
        ignore_pattern~,
        hide~,
        label_key~,
        label_value~,
      ),
    )
    let top = @moon-pprof.compute_top(
      profile,
      sample_type~,
      sort_by=Flat,
      limit=40,
      spec~,
    )
    let fg_svg = @moon-pprof.render_flamegraph_svg(
      profile,
      sample_type~,
      title="Flamegraph (\{top.sample_type})",
      spec~,
    )
    let cg = @moon-pprof.build_callgraph(
      profile,
      sample_type~,
      max_nodes~,
      spec~,
    )
    let cg_svg = @moon-pprof.render_callgraph_svg(
      cg,
      title="Callgraph (\{top.sample_type})",
    )
    let cg_dot = @moon-pprof.render_callgraph_dot(cg)
    let md = @moon-pprof.render_top_markdown(top)
    let label_json : @json.Json = if !label_key.is_empty() {
      let lr = @moon-pprof.group_by_label(
        profile,
        label_key,
        sample_type~,
        spec=Some(@moon-pprof.filter_spec(focus~, ignore_pattern~, hide~)),
      )
      @json.ToJson::to_json(lr)
    } else {
      @json.Json::null()
    }
    @json.Json::object({
      "ok": @json.ToJson::to_json(true),
      "top": @json.ToJson::to_json(top),
      "flamegraph_svg": @json.ToJson::to_json(fg_svg),
      "callgraph_svg": @json.ToJson::to_json(cg_svg),
      "callgraph_dot": @json.ToJson::to_json(cg_dot),
      "markdown": @json.ToJson::to_json(md),
      "label_report": label_json,
    }).stringify()
  } catch {
    err => json_err(err)
  }
}

///|
/// Compare two base64-encoded profiles and return DiffReport, Diff Flamegraph SVG, Diff Callgraph SVG/DOT, and Markdown.
pub fn compare_profiles_b64(
  base_b64 : String,
  cand_b64 : String,
  sample_type : String,
  normalize : Bool,
  focus : String,
  ignore_pattern : String,
  hide : String,
  label_key : String,
  label_value : String,
  max_nodes : Int32,
) -> String {
  try {
    let base = @moon-pprof.decode_profile(decode_base64(base_b64))
    let cand = @moon-pprof.decode_profile(decode_base64(cand_b64))
    let spec = Some(
      @moon-pprof.filter_spec(
        focus~,
        ignore_pattern~,
        hide~,
        label_key~,
        label_value~,
      ),
    )
    let policy = @moon-pprof.gate_policy(normalize~)
    let diff = @moon-pprof.compare_profiles(
      base,
      cand,
      sample_type~,
      policy~,
      limit=40,
      spec~,
    )
    let fg_svg = @moon-pprof.render_diff_flamegraph_svg(
      base,
      cand,
      sample_type~,
      title="Differential Flamegraph (\{diff.sample_type})",
      normalize~,
      spec~,
    )
    let dcg = @moon-pprof.build_diff_callgraph(
      base,
      cand,
      sample_type~,
      max_nodes~,
      normalize~,
      spec~,
    )
    let cg_svg = @moon-pprof.render_diff_callgraph_svg(
      dcg,
      title="Differential Callgraph (\{diff.sample_type})",
    )
    let cg_dot = @moon-pprof.render_diff_callgraph_dot(dcg)
    let md = @moon-pprof.render_diff_markdown(diff)
    @json.Json::object({
      "ok": @json.ToJson::to_json(true),
      "diff": @json.ToJson::to_json(diff),
      "flamegraph_svg": @json.ToJson::to_json(fg_svg),
      "callgraph_svg": @json.ToJson::to_json(cg_svg),
      "callgraph_dot": @json.ToJson::to_json(cg_dot),
      "markdown": @json.ToJson::to_json(md),
    }).stringify()
  } catch {
    err => json_err(err)
  }
}

///|
/// Compute callers/callees peek view for a base64-encoded profile.
pub fn peek_profile_b64(
  b64 : String,
  pattern : String,
  sample_type : String,
  focus : String,
) -> String {
  try {
    let profile = @moon-pprof.decode_profile(decode_base64(b64))
    let spec = Some(@moon-pprof.filter_spec(focus~))
    let report = @moon-pprof.compute_peek(profile, pattern, sample_type~, spec~)
    @json.Json::object({
      "ok": @json.ToJson::to_json(true),
      "peek": @json.ToJson::to_json(report),
      "markdown": @json.ToJson::to_json(
        @moon-pprof.render_peek_markdown(report),
      ),
    }).stringify()
  } catch {
    err => json_err(err)
  }
}

///|
extern "js" fn register_browser_api(
  inspect : (String) -> String,
  analyze : (String, String, String, String, String, String, String, Int32) -> String,
  compare : (
    String,
    String,
    String,
    Bool,
    String,
    String,
    String,
    String,
    String,
    Int32,
  ) -> String,
  peek : (String, String, String, String) -> String,
) -> Unit =
  #|(inspect, analyze, compare, peek) => {
  #|  globalThis.MoonPprof = {
  #|    inspectProfile: (b64) => JSON.parse(inspect(b64)),
  #|    analyzeProfile: (b64, opts = {}) => JSON.parse(analyze(
  #|      b64,
  #|      opts.sampleType || "",
  #|      opts.focus || "",
  #|      opts.ignore || "",
  #|      opts.hide || "",
  #|      opts.labelKey || "",
  #|      opts.labelValue || "",
  #|      opts.maxNodes || 35
  #|    )),
  #|    compareProfiles: (baseB64, candB64, opts = {}) => JSON.parse(compare(
  #|      baseB64,
  #|      candB64,
  #|      opts.sampleType || "",
  #|      !!opts.normalize,
  #|      opts.focus || "",
  #|      opts.ignore || "",
  #|      opts.hide || "",
  #|      opts.labelKey || "",
  #|      opts.labelValue || "",
  #|      opts.maxNodes || 35
  #|    )),
  #|    peekProfile: (b64, pattern, opts = {}) => JSON.parse(peek(
  #|      b64,
  #|      pattern || "",
  #|      opts.sampleType || "",
  #|      opts.focus || ""
  #|    )),
  #|  };
  #|}

///|
fn main {
  register_browser_api(
    inspect_profile_b64, analyze_profile_b64, compare_profiles_b64, peek_profile_b64,
  )
}
