///|
/// A direct caller or callee weighted edge shown in a `peek` report.
#derive(Debug, Eq, ToJson)
pub(all) struct PeekEdge {
  name : String
  weight : Int64
  pct : Double
}

///|
pub extend PeekEdge with @debug.Debug::{to_repr}

///|
pub extend PeekEdge with Eq::{not_equal, equal}

///|
pub extend PeekEdge with @json.ToJson::{to_json}

///|
/// Caller/callee breakdown for a single matched function (like `go tool pprof -peek`).
#derive(Debug, Eq, ToJson)
pub(all) struct PeekFunction {
  name : String
  filename : String
  flat : Int64
  flat_pct : Double
  cum : Int64
  cum_pct : Double
  callers : Array[PeekEdge]
  callees : Array[PeekEdge]
}

///|
pub extend PeekFunction with @debug.Debug::{to_repr}

///|
pub extend PeekFunction with Eq::{not_equal, equal}

///|
pub extend PeekFunction with @json.ToJson::{to_json}

///|
/// Structured callers/callees report for all functions matching `pattern`.
#derive(Debug, Eq, ToJson)
pub(all) struct PeekReport {
  pattern : String
  sample_type : String
  unit : String
  total : Int64
  shown_total : Int64
  functions : Array[PeekFunction]
}

///|
pub extend PeekReport with @debug.Debug::{to_repr}

///|
pub extend PeekReport with Eq::{not_equal, equal}

///|
pub extend PeekReport with @json.ToJson::{to_json}

///|
/// Compute callers and callees for functions matching `pattern` (`go tool pprof -peek` semantics).
pub fn compute_peek(
  profile : Profile,
  pattern : String,
  sample_type~ : String = "",
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> PeekReport raise PprofError {
  validate_profile(profile)
  let (st_idx, st_name, unit) = resolve_sample_type(profile, sample_type~)
  let eff_spec = resolve_filter(filter, spec)
  let (total, shown_total, stats, edge_weights) = aggregate_callgraph_raw(
    profile, st_idx, eff_spec,
  )
  let denom = if is_filter_empty(eff_spec) { total } else { shown_total }

  // Index callers and callees by function name
  let incoming : Map[String, Array[(String, Int64)]] = Map([])
  let outgoing : Map[String, Array[(String, Int64)]] = Map([])
  for key, weight in edge_weights {
    match key.split_once("\u0000") {
      Some((caller_v, callee_v)) => {
        let caller = caller_v.to_owned()
        let callee = callee_v.to_owned()
        match incoming.get(callee) {
          Some(arr) => arr.push((caller, weight))
          None => incoming[callee] = [(caller, weight)]
        }
        match outgoing.get(caller) {
          Some(arr) => arr.push((callee, weight))
          None => outgoing[caller] = [(callee, weight)]
        }
      }
      None => ()
    }
  }

  let matched : Array[(String, Acc)] = []
  let pat = pattern.trim().to_owned()
  for name, acc in stats {
    if acc.cum == 0L {
      continue
    }
    if pat.is_empty() || name.contains(pat) || acc.filename.contains(pat) {
      matched.push((name, acc))
    }
  }
  matched.sort_by(fn(a, b) {
    let c = b.1.cum.compare(a.1.cum)
    if c != 0 {
      c
    } else {
      let f = b.1.flat.compare(a.1.flat)
      if f != 0 {
        f
      } else {
        lex_cmp(a.0, b.0)
      }
    }
  })

  let functions : Array[PeekFunction] = []
  for item in matched {
    let (name, acc) = item
    let raw_in = incoming.get(name).unwrap_or([])
    raw_in.sort_by(fn(a, b) {
      let w = b.1.compare(a.1)
      if w != 0 {
        w
      } else {
        lex_cmp(a.0, b.0)
      }
    })
    let raw_out = outgoing.get(name).unwrap_or([])
    raw_out.sort_by(fn(a, b) {
      let w = b.1.compare(a.1)
      if w != 0 {
        w
      } else {
        lex_cmp(a.0, b.0)
      }
    })
    let callers = raw_in.map(fn(e) {
      { name: e.0, weight: e.1, pct: pct(e.1, denom), }
    })
    let callees = raw_out.map(fn(e) {
      { name: e.0, weight: e.1, pct: pct(e.1, denom), }
    })
    functions.push({
      name,
      filename: acc.filename,
      flat: acc.flat,
      flat_pct: pct(acc.flat, denom),
      cum: acc.cum,
      cum_pct: pct(acc.cum, denom),
      callers,
      callees,
    })
  }
  { pattern: pat, sample_type: st_name, unit, total, shown_total, functions, }
}

///|
/// Render a `PeekReport` as terminal-friendly plain text.
pub fn render_peek_text(report : PeekReport) -> String {
  let out = StringBuilder()
  out.write_string(
    "Peek '\{report.pattern}' | Type: \{report.sample_type} (\{report.unit}) | Total: \{report.total} | Matches: \{report.functions.length()}\n",
  )
  for f in report.functions {
    out.write_string("--------------------------------------------------\n")
    for c in f.callers {
      out.write_string("  caller  \{c.weight}\t(\{c.pct}%)\t\{c.name}\n")
    }
    out.write_string(
      "* \{f.flat} (\{f.flat_pct}%) flat | \{f.cum} (\{f.cum_pct}%) cum | \{f.name}\n",
    )
    for c in f.callees {
      out.write_string("  callee  \{c.weight}\t(\{c.pct}%)\t\{c.name}\n")
    }
  }
  out.to_string()
}

///|
/// Render a `PeekReport` as GitHub-flavored Markdown.
pub fn render_peek_markdown(report : PeekReport) -> String {
  let out = StringBuilder()
  out.write_string("# pprof Peek Report (`\{md_escape(report.pattern)}`)\n\n")
  out.write_string(
    "- **Metric**: `\{report.sample_type}` (`\{report.unit}`) | **Total**: `\{report.total}` | **Matches**: `\{report.functions.length()}`\n\n",
  )
  for f in report.functions {
    out.write_string("## `\{md_escape(f.name)}`\n\n")
    out.write_string(
      "- **Flat**: `\{f.flat}` (`\{f.flat_pct}%`) | **Cum**: `\{f.cum}` (`\{f.cum_pct}%`)\n\n",
    )
    if !f.callers.is_empty() {
      out.write_string("| Direction | Function | Weight | Share % |\n")
      out.write_string("| --- | --- | ---: | ---: |\n")
      for c in f.callers {
        out.write_string(
          "| `caller` | `\{md_escape(c.name)}` | \{c.weight} | \{c.pct}% |\n",
        )
      }
      for c in f.callees {
        out.write_string(
          "| `callee` | `\{md_escape(c.name)}` | \{c.weight} | \{c.pct}% |\n",
        )
      }
      out.write_string("\n")
    } else if !f.callees.is_empty() {
      out.write_string("| Direction | Function | Weight | Share % |\n")
      out.write_string("| --- | --- | ---: | ---: |\n")
      for c in f.callees {
        out.write_string(
          "| `callee` | `\{md_escape(c.name)}` | \{c.weight} | \{c.pct}% |\n",
        )
      }
      out.write_string("\n")
    }
  }
  out.to_string()
}

///|
/// Render a single-file offline HTML report bundling all declared metrics with interactive Flamegraph, Callgraph, and Top views.
pub fn render_multi_metric_html(
  profile : Profile,
  title~ : String = "MoonBit pprof Multi-Metric Report",
  limit~ : Int32 = 25,
  max_nodes~ : Int32 = 30,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> String raise PprofError {
  validate_profile(profile)
  let metrics = sample_type_names(profile)
  guard !metrics.is_empty() else {
    raise InvalidProfile("profile has no sample_types")
  }
  let out = StringBuilder()
  out.write_string(
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n",
  )
  out.write_string("<title>\{xml_escape(title)}</title>\n")
  out.write_string(
    "<style>body{margin:0;padding:20px;font-family:system-ui,-apple-system,sans-serif;background:#f3f4f6;color:#111827} .card{background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:16px;margin-bottom:16px;box-shadow:0 1px 2px rgba(0,0,0,0.04)} .bar{display:flex;gap:8px;flex-wrap:wrap;align-items:center;margin-bottom:12px} .btn{padding:6px 12px;border:1px solid #d1d5db;border-radius:6px;background:#fff;cursor:pointer;font-size:13px} .btn.active{background:#111827;color:#fff;border-color:#111827} .pane{display:none} .pane.active{display:block} .subpane{display:none} .subpane.active{display:block} table{width:100%;border-collapse:collapse;font-size:13px} th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #e5e7eb} th{background:#f9fafb;font-weight:600} code{font-family:ui-monospace,Consolas,monospace;font-size:12px}</style>\n",
  )
  out.write_string("</head>\n<body>\n<div class=\"card\">\n")
  out.write_string(
    "<h1 style=\"margin:0 0 10px;font-size:20px\">\{xml_escape(title)}</h1>\n",
  )
  out.write_string(
    "<div class=\"bar\" id=\"metric-tabs\"><strong>Metric:</strong>",
  )
  for idx, pair in metrics {
    let active = if idx == metrics.length() - 1 { " active" } else { "" }
    out.write_string(
      "<button class=\"btn metric-btn\{active}\" data-metric=\"\{idx}\">\{xml_escape(pair.0)} (\{xml_escape(pair.1)})</button>",
    )
  }
  out.write_string("</div>\n")
  out.write_string(
    "<div class=\"bar\" id=\"view-tabs\"><strong>View:</strong><button class=\"btn view-btn active\" data-view=\"fg\">Flamegraph</button><button class=\"btn view-btn\" data-view=\"cg\">Callgraph</button><button class=\"btn view-btn\" data-view=\"top\">Top Table</button></div>\n</div>\n",
  )

  for idx, pair in metrics {
    let (st_name, st_unit) = pair
    let active = if idx == metrics.length() - 1 { " active" } else { "" }
    let fg_svg = render_flamegraph_svg(
      profile,
      sample_type=st_name,
      title="\{title} - \{st_name}",
      filter~,
      spec~,
    )
    let cg = build_callgraph(
      profile,
      sample_type=st_name,
      max_nodes~,
      filter~,
      spec~,
    )
    let cg_svg = render_callgraph_svg(
      cg,
      title="\{title} - \{st_name} Callgraph",
    )
    let top = compute_top(
      profile,
      sample_type=st_name,
      sort_by=Flat,
      limit~,
      filter~,
      spec~,
    )
    out.write_string(
      "<div class=\"pane\{active}\" data-metric-pane=\"\{idx}\">\n",
    )
    out.write_string(
      "<div class=\"card subpane active\" data-view-pane=\"fg\">\{fg_svg}</div>\n",
    )
    out.write_string(
      "<div class=\"card subpane\" data-view-pane=\"cg\">\{cg_svg}</div>\n",
    )
    out.write_string("<div class=\"card subpane\" data-view-pane=\"top\">")
    out.write_string(
      "<h3>Top Functions: \{xml_escape(st_name)} (\{xml_escape(st_unit)}, total \{top.total})</h3>\n",
    )
    out.write_string(
      "<table><thead><tr><th>Function</th><th>Flat</th><th>Flat %</th><th>Cum</th><th>Cum %</th></tr></thead><tbody>\n",
    )
    for e in top.entries {
      out.write_string(
        "<tr><td><code>\{xml_escape(e.name)}</code></td><td>\{e.flat}</td><td>\{e.flat_pct}%</td><td>\{e.cum}</td><td>\{e.cum_pct}%</td></tr>\n",
      )
    }
    out.write_string("</tbody></table></div>\n</div>\n")
  }
  out.write_string(
    "<script>(function(){const mBtns=[...document.querySelectorAll('.metric-btn')];const vBtns=[...document.querySelectorAll('.view-btn')];const mPanes=[...document.querySelectorAll('[data-metric-pane]')];let curV='fg';function showView(){mPanes.forEach(p=>{p.querySelectorAll('[data-view-pane]').forEach(s=>s.classList.toggle('active',s.dataset.viewPane===curV));});}mBtns.forEach(b=>b.addEventListener('click',()=>{mBtns.forEach(x=>x.classList.remove('active'));b.classList.add('active');mPanes.forEach(p=>p.classList.toggle('active',p.dataset.metricPane===b.dataset.metric));}));vBtns.forEach(b=>b.addEventListener('click',()=>{vBtns.forEach(x=>x.classList.remove('active'));b.classList.add('active');curV=b.dataset.view;showView();}));})();</script>\n</body>\n</html>\n",
  )
  out.to_string()
}
