///|
fn md_escape(text : String) -> String {
  text
  .replace_all(old="|", new="\\|")
  .replace_all(old="\r", new="")
  .replace_all(old="\n", new=" ")
}

///|
fn signed_i64(v : Int64) -> String {
  if v > 0L {
    "+\{v}"
  } else {
    "\{v}"
  }
}

///|
fn signed_f64(v : Double) -> String {
  if v > 0.0 {
    "+\{v}"
  } else {
    "\{v}"
  }
}

///|
/// Render a `TopReport` as compact plain text suitable for terminal output.
pub fn render_top_text(report : TopReport) -> String {
  let out = StringBuilder()
  out.write_string(
    "Type: \{report.sample_type} (\{report.unit}) | Total: \{report.total} | Samples: \{report.sample_count}\n",
  )
  out.write_string("flat\tflat%\tcum\tcum%\tfunction\n")
  for e in report.entries {
    out.write_string(
      "\{e.flat}\t\{e.flat_pct}%\t\{e.cum}\t\{e.cum_pct}%\t\{e.name}\n",
    )
  }
  out.to_string()
}

///|
/// Render a `TopReport` as a GitHub-flavored Markdown table.
pub fn render_top_markdown(report : TopReport) -> String {
  let out = StringBuilder()
  out.write_string("# pprof Top Report\n\n")
  out.write_string(
    "- **Metric**: `\{report.sample_type}` (`\{report.unit}`) | **Total**: `\{report.total}` | **Samples**: `\{report.sample_count}`\n\n",
  )
  out.write_string("| Function | Flat | Flat % | Cum | Cum % |\n")
  out.write_string("| --- | ---: | ---: | ---: | ---: |\n")
  for e in report.entries {
    out.write_string(
      "| `\{md_escape(e.name)}` | \{e.flat} | \{e.flat_pct}% | \{e.cum} | \{e.cum_pct}% |\n",
    )
  }
  out.to_string()
}

///|
/// Render a `DiffReport` as compact plain text suitable for terminal output.
pub fn render_diff_text(report : DiffReport) -> String {
  let out = StringBuilder()
  let gate_label = if report.gate.passed { "PASS" } else { "FAIL" }
  out.write_string(
    "Diff [\{gate_label}] \{report.sample_type} (\{report.unit}): \{report.baseline_total} -> \{report.candidate_total} (\{signed_i64(report.delta_total)}, \{signed_f64(report.delta_total_pct)}%)\n",
  )
  for v in report.gate.violations {
    out.write_string("VIOLATION: \{v}\n")
  }
  out.write_string(
    "status\tbase_cum\tcand_cum\tdelta_cum\tdelta%\tshare_pp\tfunction\n",
  )
  for e in report.entries {
    out.write_string(
      "\{e.classification}\t\{e.baseline_cum}\t\{e.candidate_cum}\t\{signed_i64(e.delta_cum)}\t\{signed_f64(e.delta_cum_pct)}%\t\{signed_f64(e.delta_cum_share_pp)}pp\t\{e.name}\n",
    )
  }
  out.to_string()
}

///|
/// Render a `DiffReport` as GitHub-flavored Markdown (ready for CI Step Summaries).
pub fn render_diff_markdown(report : DiffReport) -> String {
  let out = StringBuilder()
  let verdict = if report.gate.passed { "PASS" } else { "REGRESSION" }
  out.write_string("# pprof Differential Report\n\n")
  out.write_string(
    "- **Verdict**: `\{verdict}` (exit code `\{report.gate.exit_code}`)\n",
  )
  out.write_string(
    "- **Metric**: `\{report.sample_type}` (`\{report.unit}`) | **Normalized**: `\{report.normalized}`\n",
  )
  out.write_string(
    "- **Total**: `\{report.baseline_total}` -> `\{report.candidate_total}` (`\{signed_i64(report.delta_total)}`, `\{signed_f64(report.delta_total_pct)}%`)\n",
  )
  if !report.gate.violations.is_empty() {
    out.write_string("\n## Gate Violations\n\n")
    for v in report.gate.violations {
      out.write_string("- \{v}\n")
    }
  }
  out.write_string("\n## Function Changes\n\n")
  out.write_string(
    "| Function | Status | Baseline Cum | Candidate Cum | Delta Cum | Delta % | Share Delta |\n",
  )
  out.write_string("| --- | --- | ---: | ---: | ---: | ---: | ---: |\n")
  for e in report.entries {
    out.write_string(
      "| `\{md_escape(e.name)}` | `\{e.classification}` | \{e.baseline_cum} | \{e.candidate_cum} | \{signed_i64(e.delta_cum)} | \{signed_f64(e.delta_cum_pct)}% | \{signed_f64(e.delta_cum_share_pp)}pp |\n",
    )
  }
  out.to_string()
}
