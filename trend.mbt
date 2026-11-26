///|
/// Per-revision total cost summary and regression inflection status in a multi-version trend.
#derive(Debug, Eq, ToJson)
pub(all) struct TrendPoint {
  label : String
  total : Int64
  delta_prev_pct : Double
  delta_first_pct : Double
  regressed : Bool
}

///|
pub extend TrendPoint with @debug.Debug::{to_repr}

///|
pub extend TrendPoint with Eq::{not_equal, equal}

///|
pub extend TrendPoint with @json.ToJson::{to_json}

///|
/// Per-function cumulative trajectory across a series of profile revisions.
#derive(Debug, Eq, ToJson)
pub(all) struct TrendSeries {
  name : String
  values : Array[Int64]
  delta_first_pct : Double
  peak : Int64
  regressed_at : Array[String]
}

///|
pub extend TrendSeries with @debug.Debug::{to_repr}

///|
pub extend TrendSeries with Eq::{not_equal, equal}

///|
pub extend TrendSeries with @json.ToJson::{to_json}

///|
/// Multi-version performance evolution report tracking totals, Top-K functions, and regression inflection alerts.
#derive(Debug, Eq, ToJson)
pub(all) struct TrendReport {
  sample_type : String
  unit : String
  threshold_pct : Double
  labels : Array[String]
  totals : Array[TrendPoint]
  series : Array[TrendSeries]
  alerts : Array[String]
}

///|
pub extend TrendReport with @debug.Debug::{to_repr}

///|
pub extend TrendReport with Eq::{not_equal, equal}

///|
pub extend TrendReport with @json.ToJson::{to_json}

///|
fn calc_growth_pct(prev : Int64, cur : Int64) -> Double {
  if prev == 0L {
    if cur > 0L {
      100.0
    } else if cur < 0L {
      -100.0
    } else {
      0.0
    }
  } else {
    round2((cur - prev).to_double() * 100.0 / prev.to_double())
  }
}

///|
fn format_compact_axis(value : Int64) -> String {
  let abs_v = if value < 0L { -value } else { value }
  let sign = if value < 0L { "-" } else { "" }
  if abs_v >= 1_000_000_000L {
    "\{sign}\{round2(abs_v.to_double() / 1_000_000_000.0)}G"
  } else if abs_v >= 1_000_000L {
    "\{sign}\{round2(abs_v.to_double() / 1_000_000.0)}M"
  } else if abs_v >= 1_000L {
    "\{sign}\{round2(abs_v.to_double() / 1_000.0)}K"
  } else {
    "\{value}"
  }
}

///|
fn trend_signed_pct(p : Double) -> String {
  if p > 0.0 {
    "+\{p}%"
  } else {
    "\{p}%"
  }
}

///|
/// Compute a multi-version performance trend across 2 or more labeled profile snapshots.
pub fn compute_trend(
  labeled_profiles : Array[(String, Profile)],
  sample_type~ : String = "",
  top_k~ : Int32 = 5,
  regression_threshold_pct~ : Double = 15.0,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> TrendReport raise PprofError {
  guard labeled_profiles.length() >= 2 else {
    raise InvalidInput(
      "compute_trend requires at least 2 labeled profiles (got \{labeled_profiles.length()})",
    )
  }
  let (_, st_name, st_unit) = resolve_sample_type(
    labeled_profiles[0].1,
    sample_type~,
  )
  let labels : Array[String] = []
  let snap_totals : Array[Int64] = []
  let snap_maps : Array[Map[String, Int64]] = []
  let func_peak : Map[String, Int64] = Map([])
  let func_first : Map[String, Int64] = Map([])
  let func_last : Map[String, Int64] = Map([])

  let n = labeled_profiles.length()
  let mut peak_total = 0L

  for idx, pair in labeled_profiles {
    let raw_label = pair.0.trim().to_owned()
    let label = if raw_label.is_empty() { "rev\{idx + 1}" } else { raw_label }
    let prof = pair.1
    let (_, _, unit_i) = resolve_sample_type(prof, sample_type=st_name)
    guard unit_i == st_unit else {
      raise InvalidProfile(
        "unit mismatch at '\{label}' for sample type '\{st_name}': expected '\{st_unit}', got '\{unit_i}'",
      )
    }
    let top = compute_top(
      prof,
      sample_type=st_name,
      sort_by=Cum,
      limit=100_000,
      filter~,
      spec~,
    )
    labels.push(label)
    snap_totals.push(top.total)
    if top.total > peak_total {
      peak_total = top.total
    }
    let fm : Map[String, Int64] = Map([])
    for e in top.entries {
      fm[e.name] = e.cum
      let cur_peak = func_peak.get(e.name).unwrap_or(0L)
      if e.cum > cur_peak {
        func_peak[e.name] = e.cum
      }
      if idx == 0 {
        func_first[e.name] = e.cum
      }
      if idx == n - 1 {
        func_last[e.name] = e.cum
      }
    }
    snap_maps.push(fm)
  }

  let totals : Array[TrendPoint] = []
  let alerts : Array[String] = []
  let first_total = snap_totals[0]
  for i in 0..<n {
    let cur = snap_totals[i]
    let d_prev = if i == 0 {
      0.0
    } else {
      calc_growth_pct(snap_totals[i - 1], cur)
    }
    let d_first = if i == 0 { 0.0 } else { calc_growth_pct(first_total, cur) }
    let regressed = i > 0 &&
      cur > snap_totals[i - 1] &&
      d_prev > regression_threshold_pct
    totals.push({
      label: labels[i],
      total: cur,
      delta_prev_pct: d_prev,
      delta_first_pct: d_first,
      regressed,
    })
    if regressed {
      alerts.push(
        "total regressed at \{labels[i]}: \{snap_totals[i - 1]} -> \{cur} \{st_unit} (\{trend_signed_pct(d_prev)} vs \{labels[i - 1]})",
      )
    }
  }

  // Rank candidate functions by peak cost + absolute drift to highlight both dominant and regressing functions.
  let candidates : Array[(String, Int64)] = []
  for name, pk in func_peak {
    let first_v = func_first.get(name).unwrap_or(0L)
    let last_v = func_last.get(name).unwrap_or(0L)
    let diff_v = if last_v >= first_v {
      last_v - first_v
    } else {
      first_v - last_v
    }
    candidates.push((name, pk + diff_v))
  }
  candidates.sort_by((a, b) => {
    let cmp = b.1.compare(a.1)
    if cmp != 0 {
      cmp
    } else {
      lex_cmp(a.0, b.0)
    }
  })

  let max_k = if top_k < 1 { 1 } else { top_k }
  let series : Array[TrendSeries] = []
  let take = if candidates.length() < max_k {
    candidates.length()
  } else {
    max_k
  }
  for k in 0..<take {
    let name = candidates[k].0
    let values : Array[Int64] = []
    let regressed_at : Array[String] = []
    let mut pk = 0L
    for i in 0..<n {
      let v = snap_maps[i].get(name).unwrap_or(0L)
      values.push(v)
      if v > pk {
        pk = v
      }
      if i > 0 {
        let prev = values[i - 1]
        let delta = v - prev
        let dp = calc_growth_pct(prev, v)
        let significant = if peak_total > 0L {
          delta * 100L >= peak_total
        } else {
          delta > 0L
        }
        let is_reg = if prev == 0L {
          peak_total > 0L && v * 100L >= peak_total * 5L
        } else {
          delta > 0L && dp > regression_threshold_pct && significant
        }
        if is_reg {
          regressed_at.push(labels[i])
          alerts.push(
            "function `\{name}` regressed at \{labels[i]}: \{prev} -> \{v} \{st_unit} (\{trend_signed_pct(dp)} vs \{labels[i - 1]})",
          )
        }
      }
    }
    let d_first = calc_growth_pct(values[0], values[n - 1])
    series.push({
      name,
      values,
      delta_first_pct: d_first,
      peak: pk,
      regressed_at,
    })
  }

  {
    sample_type: st_name,
    unit: st_unit,
    threshold_pct: regression_threshold_pct,
    labels,
    totals,
    series,
    alerts,
  }
}

///|
/// Render a multi-version performance trend report as aligned plain text.
pub fn render_trend_text(report : TrendReport) -> String {
  let out = StringBuilder()
  out.write_string(
    "Trend (\{report.sample_type} / \{report.unit}, threshold=+\{report.threshold_pct}%, versions=\{report.labels.length()})\n",
  )
  out.write_string("Totals:\n")
  for p in report.totals {
    let flag = if p.regressed { " [REGRESSED]" } else { "" }
    out.write_string(
      "  \{p.label}: \{p.total} \{report.unit} (prev \{trend_signed_pct(p.delta_prev_pct)}, vs first \{trend_signed_pct(p.delta_first_pct)})\{flag}\n",
    )
  }
  if !report.series.is_empty() {
    out.write_string("Top-\{report.series.length()} Functions:\n")
    for s in report.series {
      let vals = s.values.map(v => "\{v}").join(" -> ")
      let reg = if s.regressed_at.is_empty() {
        ""
      } else {
        " [regressed at: \{s.regressed_at.join(", ")}]"
      }
      out.write_string(
        "  \{s.name}: \{vals} (vs first \{trend_signed_pct(s.delta_first_pct)})\{reg}\n",
      )
    }
  }
  if !report.alerts.is_empty() {
    out.write_string("Inflection Alerts (\{report.alerts.length()}):\n")
    for a in report.alerts {
      out.write_string("  - \{a}\n")
    }
  }
  out.to_string()
}

///|
/// Render a multi-version performance trend report as GitHub-flavored Markdown.
pub fn render_trend_markdown(report : TrendReport) -> String {
  let out = StringBuilder()
  out.write_string("# pprof Multi-Version Performance Trend\n\n")
  let status = if report.alerts.is_empty() {
    "STABLE"
  } else {
    "REGRESSION INFLECTION DETECTED"
  }
  out.write_string(
    "- **Status**: `\{status}`\n- **Metric**: `\{report.sample_type}` (`\{report.unit}`)\n- **Step Threshold**: `+\{report.threshold_pct}%`\n- **Revisions**: `\{report.labels.join(" -> ")}`\n\n",
  )
  if !report.alerts.is_empty() {
    out.write_string("## Inflection Alerts\n\n")
    for a in report.alerts {
      out.write_string("- \{a}\n")
    }
    out.write_string("\n")
  }
  out.write_string("## Revision Totals\n\n")
  out.write_string(
    "| Revision | Total (\{report.unit}) | vs Prev | vs First | Status |\n",
  )
  out.write_string("|---|---:|---:|---:|---|\n")
  for p in report.totals {
    let st = if p.regressed { "`regressed`" } else { "`ok`" }
    out.write_string(
      "| `\{p.label}` | \{p.total} | \{trend_signed_pct(p.delta_prev_pct)} | \{trend_signed_pct(p.delta_first_pct)} | \{st} |\n",
    )
  }
  if !report.series.is_empty() {
    out.write_string(
      "\n## Top-\{report.series.length()} Function Trajectories\n\n",
    )
    out.write_string("| Function |")
    for lbl in report.labels {
      out.write_string(" `\{lbl}` |")
    }
    out.write_string(" vs First | Regressed At |\n")
    out.write_string("|---|")
    for _ in report.labels {
      out.write_string("---:|")
    }
    out.write_string("---:|---|\n")
    for s in report.series {
      out.write_string("| `\{s.name}` |")
      for v in s.values {
        out.write_string(" \{v} |")
      }
      let reg = if s.regressed_at.is_empty() {
        "-"
      } else {
        s.regressed_at.join(", ")
      }
      out.write_string(" \{trend_signed_pct(s.delta_first_pct)} | \{reg} |\n")
    }
  }
  out.to_string()
}

///|
/// Render a pure-MoonBit native multi-series SVG line chart with axes, gridlines, legend, tooltips, and highlighted regression inflection points.
pub fn render_trend_svg(
  report : TrendReport,
  title~ : String = "MoonBit pprof Performance Trend",
  width~ : Int32 = 1000,
) -> String {
  let w = if width < 640 { 640.0 } else { width.to_double() }
  let pad_left = 84.0
  let pad_right = 36.0
  let pad_top = 64.0
  let chart_h = 260.0
  let axis_bottom_h = 34.0
  let legend_rows = 1 + report.series.length()
  let legend_h = 22.0 + legend_rows.to_double() * 20.0
  let h = pad_top + chart_h + axis_bottom_h + legend_h + 16.0
  let chart_w = w - pad_left - pad_right

  let mut max_val = 1L
  for p in report.totals {
    if p.total > max_val {
      max_val = p.total
    }
  }
  for s in report.series {
    for v in s.values {
      if v > max_val {
        max_val = v
      }
    }
  }
  // Add 10% headroom so top points do not clip the frame.
  let y_max = max_val.to_double() * 1.1
  let n = report.labels.length()

  fn x_at(idx : Int32) -> Double {
    if n <= 1 {
      pad_left + chart_w / 2.0
    } else {
      pad_left + chart_w * idx.to_double() / (n - 1).to_double()
    }
  }

  fn y_at(val : Int64) -> Double {
    let frac = if y_max <= 0.0 { 0.0 } else { val.to_double() / y_max }
    pad_top + chart_h * (1.0 - clamp_unit(frac))
  }

  let palette = [
    "#2563eb", "#dc2626", "#d97706", "#059669", "#7c3aed", "#0891b2", "#db2777",
    "#4f46e5",
  ]

  let out = StringBuilder()
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \{w.to_int()} \{h.to_int()}\" width=\"100%\" class=\"moon-pprof-trend-svg\" data-metric=\"\{xml_escape(report.sample_type)}\" data-alerts=\"\{report.alerts.length()}\">\n",
  )
  out.write_string("<rect width=\"100%\" height=\"100%\" fill=\"#fafafa\"/>\n")
  out.write_string(
    "<text x=\"20\" y=\"26\" font-size=\"15\" font-weight=\"600\" font-family=\"system-ui,-apple-system,sans-serif\" fill=\"#111827\">\{xml_escape(title)}</text>\n",
  )
  out.write_string(
    "<text x=\"20\" y=\"44\" font-size=\"11\" font-family=\"ui-monospace,SFMono-Regular,Consolas,monospace\" fill=\"#4b5563\">metric: \{xml_escape(report.sample_type)} (\{xml_escape(report.unit)}) | revisions: \{n} | step threshold: +\{report.threshold_pct}% | alerts: \{report.alerts.length()}</text>\n",
  )

  // Chart backdrop
  out.write_string(
    "<rect x=\"\{round2(pad_left)}\" y=\"\{round2(pad_top)}\" width=\"\{round2(chart_w)}\" height=\"\{round2(chart_h)}\" fill=\"#ffffff\" stroke=\"#e5e7eb\" stroke-width=\"1\"/>\n",
  )

  // Horizontal gridlines + Y-axis labels (5 steps)
  for step in 0..<=4 {
    let frac = step.to_double() / 4.0
    let y = pad_top + chart_h * (1.0 - frac)
    let tick_val = (y_max * frac).to_int64()
    out.write_string(
      "<line x1=\"\{round2(pad_left)}\" y1=\"\{round2(y)}\" x2=\"\{round2(pad_left + chart_w)}\" y2=\"\{round2(y)}\" stroke=\"#f3f4f6\" stroke-width=\"1\"/>\n",
    )
    out.write_string(
      "<text x=\"\{round2(pad_left - 8.0)}\" y=\"\{round2(y + 4.0)}\" text-anchor=\"end\" font-size=\"10\" font-family=\"ui-monospace,monospace\" fill=\"#6b7280\">\{xml_escape(format_compact_axis(tick_val))}</text>\n",
    )
  }

  // Vertical guide lines + X-axis labels
  let x_axis_y = pad_top + chart_h
  for i, lbl in report.labels {
    let x = x_at(i)
    out.write_string(
      "<line x1=\"\{round2(x)}\" y1=\"\{round2(pad_top)}\" x2=\"\{round2(x)}\" y2=\"\{round2(x_axis_y)}\" stroke=\"#f3f4f6\" stroke-width=\"1\"/>\n",
    )
    out.write_string(
      "<text x=\"\{round2(x)}\" y=\"\{round2(x_axis_y + 18.0)}\" text-anchor=\"middle\" font-size=\"11\" font-family=\"ui-monospace,monospace\" fill=\"#374151\">\{xml_escape(lbl)}</text>\n",
    )
  }

  // Plot Top-K function polylines
  for s_idx, s in report.series {
    let color = palette[s_idx % palette.length()]
    let pts = StringBuilder()
    for i, v in s.values {
      if i > 0 {
        pts.write_char(' ')
      }
      pts.write_string("\{round2(x_at(i))},\{round2(y_at(v))}")
    }
    out.write_string(
      "<polyline fill=\"none\" stroke=\"\{color}\" stroke-width=\"2\" stroke-linejoin=\"round\" stroke-linecap=\"round\" points=\"\{pts.to_string()}\"/>\n",
    )
    let reg_set : Set[String] = Set([])
    for rl in s.regressed_at {
      reg_set.add(rl)
    }
    for i, v in s.values {
      let cx = round2(x_at(i))
      let cy = round2(y_at(v))
      let lbl = report.labels[i]
      let is_reg = reg_set.contains(lbl)
      let tip = "\{lbl} | \{s.name}: \{v} \{report.unit} (vs first \{trend_signed_pct(s.delta_first_pct)})"
      if is_reg {
        out.write_string(
          "<circle class=\"trend-regressed\" cx=\"\{cx}\" cy=\"\{cy}\" r=\"7\" fill=\"none\" stroke=\"#dc2626\" stroke-width=\"2\"/>\n",
        )
      }
      out.write_string(
        "<circle cx=\"\{cx}\" cy=\"\{cy}\" r=\"3.5\" fill=\"\{color}\" stroke=\"#ffffff\" stroke-width=\"1.2\"><title>\{xml_escape(tip)}</title></circle>\n",
      )
    }
  }

  // Plot Total polyline prominently in dark slate
  let total_pts = StringBuilder()
  for i, p in report.totals {
    if i > 0 {
      total_pts.write_char(' ')
    }
    total_pts.write_string("\{round2(x_at(i))},\{round2(y_at(p.total))}")
  }
  out.write_string(
    "<polyline fill=\"none\" stroke=\"#111827\" stroke-width=\"2.8\" stroke-dasharray=\"6,3\" stroke-linejoin=\"round\" points=\"\{total_pts.to_string()}\"/>\n",
  )
  for i, p in report.totals {
    let cx = round2(x_at(i))
    let cy = round2(y_at(p.total))
    let tip = "\{p.label} | TOTAL: \{p.total} \{report.unit} (prev \{trend_signed_pct(p.delta_prev_pct)}, vs first \{trend_signed_pct(p.delta_first_pct)})"
    if p.regressed {
      out.write_string(
        "<circle class=\"trend-regressed\" cx=\"\{cx}\" cy=\"\{cy}\" r=\"8\" fill=\"rgba(220,38,38,0.12)\" stroke=\"#dc2626\" stroke-width=\"2\"/>\n",
      )
    }
    out.write_string(
      "<circle cx=\"\{cx}\" cy=\"\{cy}\" r=\"4.2\" fill=\"#111827\" stroke=\"#ffffff\" stroke-width=\"1.4\"><title>\{xml_escape(tip)}</title></circle>\n",
    )
  }

  // Legend
  let leg_top = x_axis_y + axis_bottom_h + 6.0
  let total_last = report.totals[report.totals.length() - 1]
  out.write_string(
    "<line x1=\"\{round2(pad_left)}\" y1=\"\{round2(leg_top)}\" x2=\"\{round2(pad_left + 18.0)}\" y2=\"\{round2(leg_top)}\" stroke=\"#111827\" stroke-width=\"2.8\" stroke-dasharray=\"5,2\"/>\n",
  )
  out.write_string(
    "<text x=\"\{round2(pad_left + 24.0)}\" y=\"\{round2(leg_top + 4.0)}\" font-size=\"11\" font-weight=\"600\" font-family=\"ui-monospace,monospace\" fill=\"#111827\">TOTAL (\{total_last.total} \{xml_escape(report.unit)}, vs first \{trend_signed_pct(total_last.delta_first_pct)})</text>\n",
  )
  for s_idx, s in report.series {
    let ly = leg_top + (s_idx + 1).to_double() * 20.0
    let color = palette[s_idx % palette.length()]
    let last_v = s.values[s.values.length() - 1]
    let reg_note = if s.regressed_at.is_empty() {
      ""
    } else {
      " | REGRESSED@" + s.regressed_at.join(",")
    }
    out.write_string(
      "<rect x=\"\{round2(pad_left)}\" y=\"\{round2(ly - 5.0)}\" width=\"14\" height=\"10\" rx=\"2\" fill=\"\{color}\"/>\n",
    )
    out.write_string(
      "<text x=\"\{round2(pad_left + 24.0)}\" y=\"\{round2(ly + 4.0)}\" font-size=\"11\" font-family=\"ui-monospace,monospace\" fill=\"#374151\">\{xml_escape(s.name)} (\{last_v} \{xml_escape(report.unit)}, \{trend_signed_pct(s.delta_first_pct)}\{xml_escape(reg_note)})</text>\n",
    )
  }

  out.write_string("</svg>\n")
  out.to_string()
}
