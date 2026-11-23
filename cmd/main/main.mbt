///|
let usage : String =
  #|moon-pprof top <FILE> [--sample-type NAME] [--sort flat|cum] [--limit N] [--focus TEXT] [--ignore TEXT] [--hide TEXT] [--label KEY=VAL] [--filter TEXT] [--format text|json|md] [--out FILE]
  #|moon-pprof folded <FILE> [--sample-type NAME] [--focus TEXT] [--ignore TEXT] [--hide TEXT] [--label KEY=VAL] [--filter TEXT] [--out FILE]
  #|moon-pprof flamegraph <FILE> [--sample-type NAME] [--title TEXT] [--focus TEXT] [--ignore TEXT] [--hide TEXT] [--label KEY=VAL] [--filter TEXT] [--html] [--out FILE]
  #|moon-pprof diff <BASE> <CANDIDATE> [--sample-type NAME] [--normalize] [--max-total-pct P] [--max-func-pct P] [--min-delta V] [--limit N] [--focus TEXT] [--ignore TEXT] [--hide TEXT] [--label KEY=VAL] [--filter TEXT] [--format text|json|md] [--out FILE] [--flamegraph-out FILE] [--html-out FILE]
  #|moon-pprof merge <FILE1> <FILE2> [FILE...] --out <MERGED.pb.gz> [--raw]
  #|moon-pprof labels <FILE> --key <LABEL_KEY> [--sample-type NAME] [--focus TEXT] [--ignore TEXT] [--hide TEXT] [--format text|json|md] [--out FILE]

///|
fn parse_int_arg(
  name : String,
  raw : String,
) -> Int32 raise @moon-pprof.PprofError {
  @string.parse_int(raw) catch {
    _ =>
      raise @moon-pprof.PprofError::InvalidInput(
        "invalid integer for \{name}: \{raw}",
      )
  }
}

///|
fn parse_int64_arg(
  name : String,
  raw : String,
) -> Int64 raise @moon-pprof.PprofError {
  @string.parse_int64(raw) catch {
    _ =>
      raise @moon-pprof.PprofError::InvalidInput(
        "invalid int64 for \{name}: \{raw}",
      )
  }
}

///|
fn parse_double_arg(
  name : String,
  raw : String,
) -> Double raise @moon-pprof.PprofError {
  @string.parse_double(raw) catch {
    _ =>
      raise @moon-pprof.PprofError::InvalidInput(
        "invalid number for \{name}: \{raw}",
      )
  }
}

///|
fn next_flag_value(
  args : Array[String],
  index : Int32,
  flag : String,
) -> String raise @moon-pprof.PprofError {
  guard index + 1 < args.length() else {
    raise @moon-pprof.PprofError::InvalidInput("\{flag} requires a value")
  }
  args[index + 1]
}

///|
fn parse_label_kv(raw : String) -> (String, String) {
  match raw.split_once("=") {
    Some((k, v)) => (k.to_owned(), v.to_owned())
    None => (raw, "")
  }
}

///|
async fn load_profile(path : String) -> @moon-pprof.Profile {
  let bytes = @fs.read_file(path).binary()
  @moon-pprof.decode_profile(bytes)
}

///|
async fn emit_output(content : String, out_path : String?) -> Unit {
  match out_path {
    Some(path) => @fs.write_file(path, content, create_mode=CreateOrTruncate)
    None => println(content)
  }
}

///|
async fn cmd_top(args : Array[String]) -> Int32 {
  guard args.length() >= 2 else {
    raise @moon-pprof.PprofError::InvalidInput(usage)
  }
  let file = args[1]
  let mut sample_type = ""
  let mut sort_by : @moon-pprof.SortBy = Flat
  let mut limit = 20
  let mut focus = ""
  let mut ignore_pattern = ""
  let mut hide = ""
  let mut label_key = ""
  let mut label_value = ""
  let mut format = "text"
  let mut out_path : String? = None
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--sample-type" => {
        sample_type = next_flag_value(args, i, "--sample-type")
        i += 2
      }
      "--sort" => {
        let v = next_flag_value(args, i, "--sort")
        sort_by = match v {
          "flat" => Flat
          "cum" => Cum
          _ =>
            raise @moon-pprof.PprofError::InvalidInput(
              "unsupported --sort value: \{v} (expected flat or cum)",
            )
        }
        i += 2
      }
      "--limit" => {
        limit = parse_int_arg("--limit", next_flag_value(args, i, "--limit"))
        i += 2
      }
      "--filter" | "--focus" => {
        focus = next_flag_value(args, i, args[i])
        i += 2
      }
      "--ignore" => {
        ignore_pattern = next_flag_value(args, i, "--ignore")
        i += 2
      }
      "--hide" => {
        hide = next_flag_value(args, i, "--hide")
        i += 2
      }
      "--label" => {
        let (k, v) = parse_label_kv(next_flag_value(args, i, "--label"))
        label_key = k
        label_value = v
        i += 2
      }
      "--format" => {
        format = next_flag_value(args, i, "--format")
        i += 2
      }
      "--out" => {
        out_path = Some(next_flag_value(args, i, "--out"))
        i += 2
      }
      other =>
        raise @moon-pprof.PprofError::InvalidInput("unknown option: \{other}")
    }
  }
  let profile = load_profile(file)
  let spec = Some(
    @moon-pprof.filter_spec(
      focus~,
      ignore_pattern~,
      hide~,
      label_key~,
      label_value~,
    ),
  )
  let report = @moon-pprof.compute_top(
    profile,
    sample_type~,
    sort_by~,
    limit~,
    spec~,
  )
  let rendered = match format {
    "text" => @moon-pprof.render_top_text(report)
    "json" => @json.ToJson::to_json(report).stringify()
    "md" | "markdown" => @moon-pprof.render_top_markdown(report)
    _ =>
      raise @moon-pprof.PprofError::InvalidInput(
        "unsupported --format value: \{format}",
      )
  }
  emit_output(rendered, out_path)
  0
}

///|
async fn cmd_folded(args : Array[String]) -> Int32 {
  guard args.length() >= 2 else {
    raise @moon-pprof.PprofError::InvalidInput(usage)
  }
  let file = args[1]
  let mut sample_type = ""
  let mut focus = ""
  let mut ignore_pattern = ""
  let mut hide = ""
  let mut label_key = ""
  let mut label_value = ""
  let mut out_path : String? = None
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--sample-type" => {
        sample_type = next_flag_value(args, i, "--sample-type")
        i += 2
      }
      "--filter" | "--focus" => {
        focus = next_flag_value(args, i, args[i])
        i += 2
      }
      "--ignore" => {
        ignore_pattern = next_flag_value(args, i, "--ignore")
        i += 2
      }
      "--hide" => {
        hide = next_flag_value(args, i, "--hide")
        i += 2
      }
      "--label" => {
        let (k, v) = parse_label_kv(next_flag_value(args, i, "--label"))
        label_key = k
        label_value = v
        i += 2
      }
      "--out" => {
        out_path = Some(next_flag_value(args, i, "--out"))
        i += 2
      }
      other =>
        raise @moon-pprof.PprofError::InvalidInput("unknown option: \{other}")
    }
  }
  let profile = load_profile(file)
  let spec = Some(
    @moon-pprof.filter_spec(
      focus~,
      ignore_pattern~,
      hide~,
      label_key~,
      label_value~,
    ),
  )
  let stacks = @moon-pprof.collapse_stacks(profile, sample_type~, spec~)
  emit_output(@moon-pprof.render_folded(stacks), out_path)
  0
}

///|
async fn cmd_flamegraph(args : Array[String]) -> Int32 {
  guard args.length() >= 2 else {
    raise @moon-pprof.PprofError::InvalidInput(usage)
  }
  let file = args[1]
  let mut sample_type = ""
  let mut title = "MoonBit pprof Flame Graph"
  let mut focus = ""
  let mut ignore_pattern = ""
  let mut hide = ""
  let mut label_key = ""
  let mut label_value = ""
  let mut as_html = false
  let mut out_path : String? = None
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--sample-type" => {
        sample_type = next_flag_value(args, i, "--sample-type")
        i += 2
      }
      "--title" => {
        title = next_flag_value(args, i, "--title")
        i += 2
      }
      "--filter" | "--focus" => {
        focus = next_flag_value(args, i, args[i])
        i += 2
      }
      "--ignore" => {
        ignore_pattern = next_flag_value(args, i, "--ignore")
        i += 2
      }
      "--hide" => {
        hide = next_flag_value(args, i, "--hide")
        i += 2
      }
      "--label" => {
        let (k, v) = parse_label_kv(next_flag_value(args, i, "--label"))
        label_key = k
        label_value = v
        i += 2
      }
      "--html" => {
        as_html = true
        i += 1
      }
      "--out" => {
        out_path = Some(next_flag_value(args, i, "--out"))
        i += 2
      }
      other =>
        raise @moon-pprof.PprofError::InvalidInput("unknown option: \{other}")
    }
  }
  let profile = load_profile(file)
  let spec = Some(
    @moon-pprof.filter_spec(
      focus~,
      ignore_pattern~,
      hide~,
      label_key~,
      label_value~,
    ),
  )
  let rendered = if as_html {
    @moon-pprof.render_top_html(profile, sample_type~, title~, spec~)
  } else {
    @moon-pprof.render_flamegraph_svg(profile, sample_type~, title~, spec~)
  }
  emit_output(rendered, out_path)
  0
}

///|
async fn cmd_diff(args : Array[String]) -> Int32 {
  guard args.length() >= 3 else {
    raise @moon-pprof.PprofError::InvalidInput(usage)
  }
  let base_file = args[1]
  let cand_file = args[2]
  let mut sample_type = ""
  let mut normalize = false
  let mut max_total_pct : Double? = None
  let mut max_func_pct : Double? = None
  let mut min_delta = 0L
  let mut limit = 25
  let mut focus = ""
  let mut ignore_pattern = ""
  let mut hide = ""
  let mut label_key = ""
  let mut label_value = ""
  let mut format = "text"
  let mut out_path : String? = None
  let mut fg_out : String? = None
  let mut html_out : String? = None
  let mut i = 3
  while i < args.length() {
    match args[i] {
      "--sample-type" => {
        sample_type = next_flag_value(args, i, "--sample-type")
        i += 2
      }
      "--normalize" => {
        normalize = true
        i += 1
      }
      "--max-total-pct" => {
        max_total_pct = Some(
          parse_double_arg(
            "--max-total-pct",
            next_flag_value(args, i, "--max-total-pct"),
          ),
        )
        i += 2
      }
      "--max-func-pct" => {
        max_func_pct = Some(
          parse_double_arg(
            "--max-func-pct",
            next_flag_value(args, i, "--max-func-pct"),
          ),
        )
        i += 2
      }
      "--min-delta" => {
        min_delta = parse_int64_arg(
          "--min-delta",
          next_flag_value(args, i, "--min-delta"),
        )
        i += 2
      }
      "--limit" => {
        limit = parse_int_arg("--limit", next_flag_value(args, i, "--limit"))
        i += 2
      }
      "--filter" | "--focus" => {
        focus = next_flag_value(args, i, args[i])
        i += 2
      }
      "--ignore" => {
        ignore_pattern = next_flag_value(args, i, "--ignore")
        i += 2
      }
      "--hide" => {
        hide = next_flag_value(args, i, "--hide")
        i += 2
      }
      "--label" => {
        let (k, v) = parse_label_kv(next_flag_value(args, i, "--label"))
        label_key = k
        label_value = v
        i += 2
      }
      "--format" => {
        format = next_flag_value(args, i, "--format")
        i += 2
      }
      "--out" => {
        out_path = Some(next_flag_value(args, i, "--out"))
        i += 2
      }
      "--flamegraph-out" => {
        fg_out = Some(next_flag_value(args, i, "--flamegraph-out"))
        i += 2
      }
      "--html-out" => {
        html_out = Some(next_flag_value(args, i, "--html-out"))
        i += 2
      }
      other =>
        raise @moon-pprof.PprofError::InvalidInput("unknown option: \{other}")
    }
  }
  let baseline = load_profile(base_file)
  let candidate = load_profile(cand_file)
  let spec = Some(
    @moon-pprof.filter_spec(
      focus~,
      ignore_pattern~,
      hide~,
      label_key~,
      label_value~,
    ),
  )
  let policy = @moon-pprof.gate_policy(
    max_total_regression_pct=max_total_pct,
    max_func_cum_regression_pct=max_func_pct,
    min_abs_delta=min_delta,
    normalize~,
  )
  let report = @moon-pprof.compare_profiles(
    baseline,
    candidate,
    sample_type~,
    policy~,
    limit~,
    spec~,
  )
  match fg_out {
    Some(path) => {
      let svg = @moon-pprof.render_diff_flamegraph_svg(
        baseline,
        candidate,
        sample_type~,
        normalize~,
        spec~,
      )
      @fs.write_file(path, svg, create_mode=CreateOrTruncate)
    }
    None => ()
  }
  match html_out {
    Some(path) => {
      let html = @moon-pprof.render_diff_html(
        baseline,
        candidate,
        sample_type~,
        policy~,
        limit~,
        spec~,
      )
      @fs.write_file(path, html, create_mode=CreateOrTruncate)
    }
    None => ()
  }
  let rendered = match format {
    "text" => @moon-pprof.render_diff_text(report)
    "json" => @json.ToJson::to_json(report).stringify()
    "md" | "markdown" => @moon-pprof.render_diff_markdown(report)
    _ =>
      raise @moon-pprof.PprofError::InvalidInput(
        "unsupported --format value: \{format}",
      )
  }
  emit_output(rendered, out_path)
  report.gate.exit_code
}

///|
async fn cmd_merge(args : Array[String]) -> Int32 {
  let files : Array[String] = []
  let mut out_path : String? = None
  let mut gzip = true
  let mut i = 1
  while i < args.length() {
    match args[i] {
      "--out" => {
        out_path = Some(next_flag_value(args, i, "--out"))
        i += 2
      }
      "--raw" => {
        gzip = false
        i += 1
      }
      other =>
        if other.has_prefix("--") {
          raise @moon-pprof.PprofError::InvalidInput("unknown option: \{other}")
        } else {
          files.push(other)
          i += 1
        }
    }
  }
  guard files.length() >= 2 else {
    raise @moon-pprof.PprofError::InvalidInput(
      "merge requires at least two input profile files",
    )
  }
  guard out_path is Some(dest) else {
    raise @moon-pprof.PprofError::InvalidInput("merge requires --out <FILE>")
  }
  let loaded : Array[@moon-pprof.Profile] = []
  for f in files {
    loaded.push(load_profile(f))
  }
  let merged = @moon-pprof.merge_profiles(loaded)
  let encoded = @moon-pprof.encode_profile(merged, gzip~)
  @fs.write_file(dest, encoded, create_mode=CreateOrTruncate)
  println(
    "merged \{files.length()} profiles -> \{dest} (\{merged.samples.length()} samples, \{encoded.length()} bytes)",
  )
  0
}

///|
async fn cmd_labels(args : Array[String]) -> Int32 {
  guard args.length() >= 2 else {
    raise @moon-pprof.PprofError::InvalidInput(usage)
  }
  let file = args[1]
  let mut key = ""
  let mut sample_type = ""
  let mut focus = ""
  let mut ignore_pattern = ""
  let mut hide = ""
  let mut format = "text"
  let mut out_path : String? = None
  let mut i = 2
  while i < args.length() {
    match args[i] {
      "--key" => {
        key = next_flag_value(args, i, "--key")
        i += 2
      }
      "--sample-type" => {
        sample_type = next_flag_value(args, i, "--sample-type")
        i += 2
      }
      "--focus" | "--filter" => {
        focus = next_flag_value(args, i, args[i])
        i += 2
      }
      "--ignore" => {
        ignore_pattern = next_flag_value(args, i, "--ignore")
        i += 2
      }
      "--hide" => {
        hide = next_flag_value(args, i, "--hide")
        i += 2
      }
      "--format" => {
        format = next_flag_value(args, i, "--format")
        i += 2
      }
      "--out" => {
        out_path = Some(next_flag_value(args, i, "--out"))
        i += 2
      }
      other =>
        raise @moon-pprof.PprofError::InvalidInput("unknown option: \{other}")
    }
  }
  guard !key.is_empty() else {
    raise @moon-pprof.PprofError::InvalidInput("labels requires --key <KEY>")
  }
  let profile = load_profile(file)
  let spec = Some(@moon-pprof.filter_spec(focus~, ignore_pattern~, hide~))
  let report = @moon-pprof.group_by_label(profile, key, sample_type~, spec~)
  let rendered = match format {
    "text" => @moon-pprof.render_label_text(report)
    "json" => @json.ToJson::to_json(report).stringify()
    "md" | "markdown" => @moon-pprof.render_label_markdown(report)
    _ =>
      raise @moon-pprof.PprofError::InvalidInput(
        "unsupported --format value: \{format}",
      )
  }
  emit_output(rendered, out_path)
  0
}

///|
async fn run(args : Array[String]) -> Int32 {
  match args.get(0) {
    Some("top") => cmd_top(args)
    Some("folded") => cmd_folded(args)
    Some("flamegraph") => cmd_flamegraph(args)
    Some("diff") => cmd_diff(args)
    Some("merge") => cmd_merge(args)
    Some("labels") => cmd_labels(args)
    _ => raise @moon-pprof.PprofError::InvalidInput(usage)
  }
}

///|
async fn main {
  let args = @env.args()
  if args.length() == 2 && (args[1] == "--help" || args[1] == "-h") {
    println(usage)
    return
  }
  let exit_code = match
    (@async.with_timeout_opt(60_000, () => run(args[1:].to_owned())) catch {
      error => {
        println(@moon-pprof.error_message(error))
        Some(2)
      }
    }) {
    Some(code) => code
    None => {
      println("operation timed out after 60s")
      2
    }
  }
  @env.exit(exit_code)
}
