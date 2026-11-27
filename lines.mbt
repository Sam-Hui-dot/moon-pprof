///|
/// Per-source-line `flat` and `cum` hotspot attribution (aligned with `go tool pprof -list`).
#derive(Debug, Eq, ToJson)
pub(all) struct LineHotspot {
  function_name : String
  filename : String
  line : Int64
  flat : Int64
  flat_pct : Double
  cum : Int64
  cum_pct : Double
}

///|
pub extend LineHotspot with @debug.Debug::{to_repr}

///|
pub extend LineHotspot with Eq::{not_equal, equal}

///|
pub extend LineHotspot with @json.ToJson::{to_json}

///|
/// Structured source-line hotspot report for functions/files matching `pattern`.
#derive(Debug, Eq, ToJson)
pub(all) struct LineReport {
  pattern : String
  sample_type : String
  unit : String
  total : Int64
  shown_total : Int64
  entries : Array[LineHotspot]
}

///|
pub extend LineReport with @debug.Debug::{to_repr}

///|
pub extend LineReport with Eq::{not_equal, equal}

///|
pub extend LineReport with @json.ToJson::{to_json}

///|
/// A single ranked full call stack path with percentage and cumulative coverage.
#derive(Debug, Eq, ToJson)
pub(all) struct TraceEntry {
  rank : Int32
  value : Int64
  pct : Double
  cumulative_pct : Double
  frames : Array[String]
}

///|
pub extend TraceEntry with @debug.Debug::{to_repr}

///|
pub extend TraceEntry with Eq::{not_equal, equal}

///|
pub extend TraceEntry with @json.ToJson::{to_json}

///|
/// Structured top critical call-stack paths report (aligned with `go tool pprof -traces`).
#derive(Debug, Eq, ToJson)
pub(all) struct TracesReport {
  sample_type : String
  unit : String
  total : Int64
  shown_total : Int64
  traces : Array[TraceEntry]
}

///|
pub extend TracesReport with @debug.Debug::{to_repr}

///|
pub extend TracesReport with Eq::{not_equal, equal}

///|
pub extend TracesReport with @json.ToJson::{to_json}

///|
priv struct LineAcc {
  function_name : String
  filename : String
  line : Int64
  mut flat : Int64
  mut cum : Int64
}

///|
fn sample_line_frames_root_to_leaf(
  profile : Profile,
  loc_map : Map[UInt64, Location],
  fn_map : Map[UInt64, Function],
  sample : Sample,
) -> Array[(String, String, Int64)] raise PprofError {
  let frames : Array[(String, String, Int64)] = []
  let loc_count = sample.location_ids.length()
  for li = loc_count - 1; li >= 0; li = li - 1 {
    let loc_id = sample.location_ids[li]
    match loc_map.get(loc_id) {
      None => frames.push(("<unknown loc#\{loc_id}>", "", 0L))
      Some(loc) =>
        if loc.lines.is_empty() {
          frames.push((uint64_to_hex(loc.address), "", 0L))
        } else {
          for fi = loc.lines.length() - 1; fi >= 0; fi = fi - 1 {
            let ln = loc.lines[fi]
            match fn_map.get(ln.function_id) {
              Some(func) => {
                let (name, file) = function_identity(profile, func)
                frames.push((name, file, ln.line))
              }
              None =>
                frames.push(("<unknown fn#\{ln.function_id}>", "", ln.line))
            }
          }
        }
    }
  }
  frames
}

///|
/// Compute source-line level `flat` and `cum` hotspots (aligned with `go tool pprof -list`).
pub fn compute_line_hotspots(
  profile : Profile,
  pattern~ : String = "",
  sample_type~ : String = "",
  limit~ : Int32 = 50,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> LineReport raise PprofError {
  validate_profile(profile)
  let (st_idx, st_name, unit) = resolve_sample_type(profile, sample_type~)
  let eff_spec = resolve_filter(filter, spec)
  let loc_map = build_location_map(profile)
  let fn_map = build_function_map(profile)
  let stats : Map[String, LineAcc] = Map([])
  let mut total = 0L
  let mut shown_total = 0L

  for sample in profile.samples {
    let v = sample.values[st_idx]
    total += v
    if v == 0L {
      continue
    }
    let raw_frames = sample_line_frames_root_to_leaf(
      profile, loc_map, fn_map, sample,
    )
    let pairs = raw_frames.map(t => (t.0, t.1))
    if apply_filter(profile, sample, pairs, eff_spec) is None {
      continue
    }
    let kept : Array[(String, String, Int64)] = if eff_spec.hide.is_empty() {
      raw_frames
    } else {
      let arr : Array[(String, String, Int64)] = []
      for t in raw_frames {
        if !frame_matches((t.0, t.1), eff_spec.hide) {
          arr.push(t)
        }
      }
      arr
    }
    if kept.is_empty() {
      continue
    }
    shown_total += v

    let leaf = kept[kept.length() - 1]
    let leaf_key = "\{leaf.0}\u{00}\{leaf.1}\u{00}\{leaf.2}"
    match stats.get(leaf_key) {
      Some(acc) => acc.flat += v
      None =>
        stats[leaf_key] = {
          function_name: leaf.0,
          filename: leaf.1,
          line: leaf.2,
          flat: v,
          cum: 0L,
        }
    }
    let seen : Set[String] = Set([])
    for t in kept {
      let key = "\{t.0}\u{00}\{t.1}\u{00}\{t.2}"
      if seen.contains(key) {
        continue
      }
      seen.insert(key)
      match stats.get(key) {
        Some(acc) => acc.cum += v
        None =>
          stats[key] = {
            function_name: t.0,
            filename: t.1,
            line: t.2,
            flat: 0L,
            cum: v,
          }
      }
    }
  }

  let denom = if is_filter_empty(eff_spec) { total } else { shown_total }
  let pat = pattern.trim().to_owned()
  let entries : Array[LineHotspot] = []
  for _, acc in stats {
    if !pat.is_empty() &&
      !acc.function_name.contains(pat) &&
      !acc.filename.contains(pat) {
      continue
    }
    entries.push({
      function_name: acc.function_name,
      filename: acc.filename,
      line: acc.line,
      flat: acc.flat,
      flat_pct: pct(acc.flat, denom),
      cum: acc.cum,
      cum_pct: pct(acc.cum, denom),
    })
  }
  entries.sort_by(fn(a, b) {
    let c = b.cum.compare(a.cum)
    if c != 0 {
      return c
    }
    let f = b.flat.compare(a.flat)
    if f != 0 {
      return f
    }
    let fn_cmp = lex_cmp(a.function_name, b.function_name)
    if fn_cmp != 0 {
      fn_cmp
    } else {
      a.line.compare(b.line)
    }
  })
  let capped = if limit > 0 && entries.length() > limit {
    entries[:limit].to_owned()
  } else {
    entries
  }
  {
    pattern: pat,
    sample_type: st_name,
    unit,
    total,
    shown_total,
    entries: capped,
  }
}

///|
/// Render a `LineReport` as compact plain text.
pub fn render_lines_text(report : LineReport) -> String {
  let out = StringBuilder()
  out.write_string(
    "Lines '\{report.pattern}' | Type: \{report.sample_type} (\{report.unit}) | Total: \{report.total}\n",
  )
  out.write_string("flat\tflat%\tcum\tcum%\tlocation\tfunction\n")
  for e in report.entries {
    let loc = if e.filename.is_empty() {
      ":\{e.line}"
    } else {
      "\{e.filename}:\{e.line}"
    }
    out.write_string(
      "\{e.flat}\t\{e.flat_pct}%\t\{e.cum}\t\{e.cum_pct}%\t\{loc}\t\{e.function_name}\n",
    )
  }
  out.to_string()
}

///|
/// Render a `LineReport` as GitHub-flavored Markdown.
pub fn render_lines_markdown(report : LineReport) -> String {
  let out = StringBuilder()
  out.write_string(
    "# pprof Source Line Hotspots (`\{md_escape(report.pattern)}`)\n\n",
  )
  out.write_string(
    "- **Metric**: `\{report.sample_type}` (`\{report.unit}`) | **Total**: `\{report.total}`\n\n",
  )
  out.write_string("| Location | Function | Flat | Flat % | Cum | Cum % |\n")
  out.write_string("| --- | --- | ---: | ---: | ---: | ---: |\n")
  for e in report.entries {
    let loc = if e.filename.is_empty() {
      ":\{e.line}"
    } else {
      "\{e.filename}:\{e.line}"
    }
    out.write_string(
      "| `\{md_escape(loc)}` | `\{md_escape(e.function_name)}` | \{e.flat} | \{e.flat_pct}% | \{e.cum} | \{e.cum_pct}% |\n",
    )
  }
  out.to_string()
}

///|
/// Annotate source code lines with per-line `flat` and `cum` values around hotspots (like `go tool pprof -list`).
pub fn render_annotated_source(
  report : LineReport,
  source_text : String,
  filename_hint~ : String = "",
  context_lines~ : Int32 = 3,
) -> String {
  let by_line : Map[Int64, (Int64, Int64)] = Map([])
  for e in report.entries {
    if e.line <= 0L {
      continue
    }
    if !filename_hint.is_empty() &&
      !e.filename.is_empty() &&
      !e.filename.contains(filename_hint) &&
      !filename_hint.contains(e.filename) {
      continue
    }
    match by_line.get(e.line) {
      Some((f, c)) => by_line[e.line] = (f + e.flat, c + e.cum)
      None => by_line[e.line] = (e.flat, e.cum)
    }
  }
  let src_lines = source_text
    .replace_all(old="\r", new="")
    .split("\n")
    .to_array()
  let total_lines = src_lines.length()
  let show_mask : Array[Bool] = Array::make(total_lines, false)
  let ctx = if context_lines < 0 { 0 } else { context_lines }
  let mut any_hit = false
  for ln, _ in by_line {
    let idx = ln.to_int() - 1
    if idx >= 0 && idx < total_lines {
      any_hit = true
      let lo = if idx - ctx < 0 { 0 } else { idx - ctx }
      let hi = if idx + ctx >= total_lines {
        total_lines - 1
      } else {
        idx + ctx
      }
      for k in lo..<=hi {
        show_mask[k] = true
      }
    }
  }
  let out = StringBuilder()
  out.write_string(
    "ROUTINE ======================== \{report.pattern} (\{report.sample_type} / \{report.unit}, total \{report.total})\n",
  )
  if !any_hit {
    out.write_string("(no matching source lines found in provided file)\n")
    return out.to_string()
  }
  out.write_string("      flat        cum  line  source\n")
  let mut prev_shown = -2
  for i in 0..<total_lines {
    if !show_mask[i] {
      continue
    }
    if prev_shown >= 0 && i > prev_shown + 1 {
      out.write_string("  ...\n")
    }
    prev_shown = i
    let ln = (i + 1).to_int64()
    let (f_str, c_str) = match by_line.get(ln) {
      Some((f, c)) =>
        (
          if f > 0L {
            format_compact_val(f, report.unit)
          } else {
            "."
          },
          if c > 0L {
            format_compact_val(c, report.unit)
          } else {
            "."
          },
        )
      None => (".", ".")
    }
    out.write_string("\{f_str}\t\{c_str}\t\{ln}:\t\{src_lines[i]}\n")
  }
  out.to_string()
}

///|
/// Extract top critical call-stack traces sorted by sample weight (aligned with `go tool pprof -traces`).
pub fn compute_traces(
  profile : Profile,
  sample_type~ : String = "",
  limit~ : Int32 = 25,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> TracesReport raise PprofError {
  validate_profile(profile)
  let (_, st_name, unit) = resolve_sample_type(profile, sample_type~)
  let stacks = collapse_stacks(profile, sample_type~, filter~, spec~)
  let mut shown_total = 0L
  for s in stacks {
    shown_total += s.value
  }
  let sorted = stacks.copy()
  sorted.sort_by(fn(a, b) {
    let v = b.value.compare(a.value)
    if v != 0 {
      v
    } else {
      lex_cmp(a.stack, b.stack)
    }
  })
  let capped = if limit > 0 && sorted.length() > limit {
    sorted[:limit].to_owned()
  } else {
    sorted
  }
  let traces : Array[TraceEntry] = []
  let mut running = 0L
  for i, item in capped {
    running += item.value
    let frames = item.stack.split(";").to_array().map(v => v.to_owned())
    traces.push({
      rank: i + 1,
      value: item.value,
      pct: pct(item.value, shown_total),
      cumulative_pct: pct(running, shown_total),
      frames,
    })
  }
  { sample_type: st_name, unit, total: shown_total, shown_total, traces, }
}

///|
/// Render a `TracesReport` as plain text.
pub fn render_traces_text(report : TracesReport) -> String {
  let out = StringBuilder()
  out.write_string(
    "Traces | Type: \{report.sample_type} (\{report.unit}) | Total: \{report.total} | Shown: \{report.traces.length()}\n",
  )
  for tr in report.traces {
    out.write_string(
      "--------------------------------------------------\n#\{tr.rank}  \{tr.value} \{report.unit} (\{tr.pct}%, cum \{tr.cumulative_pct}%)\n",
    )
    for f in tr.frames {
      out.write_string("  \{f}\n")
    }
  }
  out.to_string()
}

///|
/// Render a `TracesReport` as GitHub-flavored Markdown.
pub fn render_traces_markdown(report : TracesReport) -> String {
  let out = StringBuilder()
  out.write_string("# pprof Top Call Traces\n\n")
  out.write_string(
    "- **Metric**: `\{report.sample_type}` (`\{report.unit}`) | **Total**: `\{report.total}`\n\n",
  )
  out.write_string(
    "| Rank | Value | Share % | Cum % | Call Path (root -> leaf) |\n",
  )
  out.write_string("| ---: | ---: | ---: | ---: | --- |\n")
  for tr in report.traces {
    let path = tr.frames.join(" -> ")
    out.write_string(
      "| #\{tr.rank} | \{tr.value} | \{tr.pct}% | \{tr.cumulative_pct}% | `\{md_escape(path)}` |\n",
    )
  }
  out.to_string()
}
