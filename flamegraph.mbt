///|
priv struct FlameNode {
  name : String
  path : String
  mut total : Int64
  mut self_value : Int64
  children : Map[String, FlameNode]
}

///|
fn FlameNode::new(name : String, path : String) -> FlameNode {
  { name, path, total: 0L, self_value: 0L, children: Map([]), }
}

///|
fn insert_stack(root : FlameNode, stack : String, value : Int64) -> Unit {
  root.total += value
  let mut node = root
  let parts = stack.split(";").to_array()
  let mut prefix = ""
  for i, part_view in parts {
    let frame = part_view.to_owned()
    prefix = if prefix.is_empty() { frame } else { "\{prefix};\{frame}" }
    let child = match node.children.get(frame) {
      Some(existing) => existing
      None => {
        let created = FlameNode::new(frame, prefix)
        node.children[frame] = created
        created
      }
    }
    child.total += value
    if i == parts.length() - 1 {
      child.self_value += value
    }
    node = child
  }
}

///|
fn build_flame_tree(stacks : Array[FoldedStack]) -> FlameNode {
  let root = FlameNode::new("all", "")
  for item in stacks {
    if item.value > 0L {
      insert_stack(root, item.stack, item.value)
    }
  }
  root
}

///|
fn tree_depth(node : FlameNode) -> Int32 {
  let mut max_child = 0
  for _, child in node.children {
    let d = tree_depth(child)
    if d > max_child {
      max_child = d
    }
  }
  1 + max_child
}

///|
fn collect_path_totals(node : FlameNode, out : Map[String, Int64]) -> Unit {
  out[node.path] = node.total
  for _, child in node.children {
    collect_path_totals(child, out)
  }
}

///|
fn xml_escape(text : String) -> String {
  text
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\"", new="&quot;")
  .replace_all(old="'", new="&#39;")
}

///|
fn warm_color(name : String) -> String {
  let mut h : UInt32 = 2166136261U
  for ch in name {
    h = (h ^ ch.to_int().reinterpret_as_uint()) * 16777619U
  }
  let r = 205 + (h % 50U).reinterpret_as_int()
  let g = 85 + ((h >> 8) % 135U).reinterpret_as_int()
  let b = 45 + ((h >> 16) % 55U).reinterpret_as_int()
  "rgb(\{r},\{g},\{b})"
}

///|
fn clamp_unit(v : Double) -> Double {
  if v < 0.0 {
    0.0
  } else if v > 1.0 {
    1.0
  } else {
    v
  }
}

///|
/// Brendan Gregg differential color scale: red = regression, blue = improvement, light grey = flat.
fn diff_color(delta : Double, scale : Double) -> String {
  if scale <= 0.0 {
    return "rgb(242,242,245)"
  }
  let ratio = delta / scale
  let mag = clamp_unit(if ratio < 0.0 { -ratio } else { ratio })
  if mag < 0.02 {
    return "rgb(242,242,245)"
  }
  if ratio > 0.0 {
    // White-pink -> intense crimson
    let r = 250 - (mag * 35.0).to_int()
    let g = 225 - (mag * 185.0).to_int()
    let b = 225 - (mag * 175.0).to_int()
    "rgb(\{r},\{g},\{b})"
  } else {
    // White-blue -> deep steel blue
    let r = 225 - (mag * 190.0).to_int()
    let g = 236 - (mag * 130.0).to_int()
    let b = 252 - (mag * 80.0).to_int()
    "rgb(\{r},\{g},\{b})"
  }
}

///|
fn fit_label(label : String, width_px : Double) -> String {
  if width_px < 28.0 {
    return ""
  }
  let max_chars = ((width_px - 8.0) / 6.8).to_int()
  if max_chars <= 0 {
    return ""
  }
  let chars = label.to_array()
  if chars.length() <= max_chars {
    return label
  }
  if max_chars <= 2 {
    return ""
  }
  let out = StringBuilder()
  for i in 0..<(max_chars - 1) {
    out.write_char(chars[i])
  }
  out.write_char('…')
  out.to_string()
}

///|
fn sorted_children(node : FlameNode) -> Array[FlameNode] {
  let list : Array[FlameNode] = []
  for _, child in node.children {
    list.push(child)
  }
  list.sort_by((a, b) => lex_cmp(a.name, b.name))
  list
}

///|
fn render_frame_svg(
  out : StringBuilder,
  node : FlameNode,
  depth : Int32,
  x : Double,
  w : Double,
  base_y : Double,
  frame_h : Double,
  root_total : Int64,
  unit : String,
  min_width_px : Double,
  diff_mode : Bool,
  base_totals : Map[String, Int64],
  base_scale : Double,
  diff_scale : Double,
) -> Unit {
  if w < min_width_px || node.total <= 0L {
    return
  }
  let y = base_y - (depth + 1).to_double() * frame_h
  let share = pct(node.total, root_total)
  let (fill, tooltip) = if diff_mode {
    let raw_base = base_totals.get(node.path).unwrap_or(0L)
    let scaled_base = raw_base.to_double() * base_scale
    let cand_val = node.total.to_double()
    let delta = cand_val - scaled_base
    let delta_pct = if scaled_base <= 0.0 {
      if cand_val > 0.0 {
        100.0
      } else {
        0.0
      }
    } else {
      round2(delta * 100.0 / scaled_base)
    }
    let sign = if delta >= 0.0 { "+" } else { "" }
    let color = diff_color(delta, diff_scale)
    let tip = "\{node.name} | candidate: \{node.total} \{unit} (\{share}%) | baseline(adj): \{scaled_base.to_int64()} \{unit} | delta: \{sign}\{delta.to_int64()} \{unit} (\{sign}\{delta_pct}%)"
    (color, tip)
  } else {
    let tip = "\{node.name} | cum: \{node.total} \{unit} (\{share}%) | self: \{node.self_value} \{unit}"
    (warm_color(node.name), tip)
  }
  let shown = fit_label(node.name, w)
  let x_s = round2(x)
  let y_s = round2(y)
  let w_s = round2(w - 0.6)
  let h_s = round2(frame_h - 1.0)
  out.write_string(
    "<g class=\"fg-frame\" data-name=\"\{xml_escape(node.name)}\" data-val=\"\{node.total}\" data-x=\"\{x_s}\" data-w=\"\{round2(w)}\" data-depth=\"\{depth}\">",
  )
  out.write_string("<title>\{xml_escape(tooltip)}</title>")
  out.write_string(
    "<rect x=\"\{x_s}\" y=\"\{y_s}\" width=\"\{w_s}\" height=\"\{h_s}\" rx=\"2\" fill=\"\{fill}\" stroke=\"rgba(0,0,0,0.12)\" stroke-width=\"0.5\"/>",
  )
  if !shown.is_empty() {
    let tx = round2(x + 4.0)
    let ty = round2(y + frame_h - 5.0)
    out.write_string(
      "<text x=\"\{tx}\" y=\"\{ty}\" font-size=\"11\" font-family=\"ui-monospace,SFMono-Regular,Consolas,monospace\" fill=\"#111827\">\{xml_escape(shown)}</text>",
    )
  }
  out.write_string("</g>\n")

  let mut cursor = x
  for child in sorted_children(node) {
    let cw = w * child.total.to_double() / node.total.to_double()
    render_frame_svg(
      out,
      child,
      depth + 1,
      cursor,
      cw,
      base_y,
      frame_h,
      root_total,
      unit,
      min_width_px,
      diff_mode,
      base_totals,
      base_scale,
      diff_scale,
    )
    cursor += cw
  }
}

///|
/// Render an interactive-ready native SVG flame graph for a single profile.
pub fn render_flamegraph_svg(
  profile : Profile,
  sample_type~ : String = "",
  title~ : String = "MoonBit pprof Flame Graph",
  width~ : Int32 = 1200,
  min_width_px~ : Double = 1.5,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> String raise PprofError {
  let (_, st_name, st_unit) = resolve_sample_type(profile, sample_type~)
  let stacks = collapse_stacks(profile, sample_type=st_name, filter~, spec~)
  let root = build_flame_tree(stacks)
  let depth = tree_depth(root)
  let frame_h = 18.0
  let pad_x = 12.0
  let header_h = 46.0
  let footer_h = 20.0
  let svg_w = width.to_double()
  let inner_w = svg_w - 2.0 * pad_x
  let svg_h = header_h + depth.to_double() * frame_h + footer_h
  let base_y = svg_h - footer_h

  let out = StringBuilder()
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \{width} \{svg_h.to_int()}\" width=\"100%\" class=\"moon-pprof-svg\" data-total=\"\{root.total}\" data-unit=\"\{xml_escape(st_unit)}\">\n",
  )
  out.write_string("<rect width=\"100%\" height=\"100%\" fill=\"#fafafa\"/>\n")
  out.write_string(
    "<text x=\"\{pad_x}\" y=\"24\" font-size=\"15\" font-weight=\"600\" font-family=\"system-ui,-apple-system,sans-serif\" fill=\"#111827\">\{xml_escape(title)}</text>\n",
  )
  out.write_string(
    "<text x=\"\{pad_x}\" y=\"40\" font-size=\"11\" font-family=\"ui-monospace,SFMono-Regular,Consolas,monospace\" fill=\"#4b5563\">metric: \{xml_escape(st_name)} (\{xml_escape(st_unit)}) | total: \{root.total} | samples: \{profile.samples.length()}</text>\n",
  )
  let empty_map : Map[String, Int64] = Map([])
  render_frame_svg(
    out,
    root,
    0,
    pad_x,
    inner_w,
    base_y,
    frame_h,
    root.total,
    st_unit,
    min_width_px,
    false,
    empty_map,
    1.0,
    1.0,
  )
  out.write_string("</svg>\n")
  out.to_string()
}

///|
/// Render a Brendan Gregg red/blue Differential Flame Graph SVG comparing baseline vs candidate.
pub fn render_diff_flamegraph_svg(
  baseline : Profile,
  candidate : Profile,
  sample_type~ : String = "",
  title~ : String = "MoonBit pprof Differential Flame Graph",
  width~ : Int32 = 1200,
  min_width_px~ : Double = 1.5,
  normalize~ : Bool = false,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> String raise PprofError {
  let (_, st_name, b_unit) = resolve_sample_type(baseline, sample_type~)
  let (_, _, c_unit) = resolve_sample_type(candidate, sample_type=st_name)
  guard b_unit == c_unit else {
    raise InvalidProfile(
      "unit mismatch for sample type '\{st_name}': baseline '\{b_unit}' vs candidate '\{c_unit}'",
    )
  }
  let base_stacks = collapse_stacks(
    baseline,
    sample_type=st_name,
    filter~,
    spec~,
  )
  let cand_stacks = collapse_stacks(
    candidate,
    sample_type=st_name,
    filter~,
    spec~,
  )
  let base_root = build_flame_tree(base_stacks)
  let cand_root = build_flame_tree(cand_stacks)
  let base_totals : Map[String, Int64] = Map([])
  collect_path_totals(base_root, base_totals)

  let base_scale = if normalize && base_root.total > 0L && cand_root.total > 0L {
    cand_root.total.to_double() / base_root.total.to_double()
  } else {
    1.0
  }
  let diff_scale = if cand_root.total > 0L {
    cand_root.total.to_double() * 0.25
  } else {
    1.0
  }

  let depth = tree_depth(cand_root)
  let frame_h = 18.0
  let pad_x = 12.0
  let header_h = 62.0
  let footer_h = 20.0
  let svg_w = width.to_double()
  let inner_w = svg_w - 2.0 * pad_x
  let svg_h = header_h + depth.to_double() * frame_h + footer_h
  let base_y = svg_h - footer_h

  let out = StringBuilder()
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \{width} \{svg_h.to_int()}\" width=\"100%\" class=\"moon-pprof-svg\" data-total=\"\{cand_root.total}\" data-unit=\"\{xml_escape(b_unit)}\">\n",
  )
  out.write_string("<rect width=\"100%\" height=\"100%\" fill=\"#fafafa\"/>\n")
  out.write_string(
    "<text x=\"\{pad_x}\" y=\"24\" font-size=\"15\" font-weight=\"600\" font-family=\"system-ui,-apple-system,sans-serif\" fill=\"#111827\">\{xml_escape(title)}</text>\n",
  )
  let mode_label = if normalize { "normalized" } else { "absolute" }
  out.write_string(
    "<text x=\"\{pad_x}\" y=\"40\" font-size=\"11\" font-family=\"ui-monospace,SFMono-Regular,Consolas,monospace\" fill=\"#4b5563\">metric: \{xml_escape(st_name)} (\{xml_escape(b_unit)}) | mode: \{mode_label} | baseline: \{base_root.total} -&gt; candidate: \{cand_root.total}</text>\n",
  )
  // Color legend
  out.write_string(
    "<rect x=\"\{pad_x}\" y=\"47\" width=\"12\" height=\"10\" rx=\"2\" fill=\"rgb(35,106,172)\"/><text x=\"\{pad_x + 16.0}\" y=\"56\" font-size=\"10\" font-family=\"system-ui,sans-serif\" fill=\"#374151\">Improved (faster/smaller)</text>\n",
  )
  out.write_string(
    "<rect x=\"\{pad_x + 165.0}\" y=\"47\" width=\"12\" height=\"10\" rx=\"2\" fill=\"rgb(242,242,245)\" stroke=\"#d1d5db\"/><text x=\"\{pad_x + 181.0}\" y=\"56\" font-size=\"10\" font-family=\"system-ui,sans-serif\" fill=\"#374151\">Unchanged</text>\n",
  )
  out.write_string(
    "<rect x=\"\{pad_x + 255.0}\" y=\"47\" width=\"12\" height=\"10\" rx=\"2\" fill=\"rgb(215,40,50)\"/><text x=\"\{pad_x + 271.0}\" y=\"56\" font-size=\"10\" font-family=\"system-ui,sans-serif\" fill=\"#374151\">Regressed (slower/larger)</text>\n",
  )
  render_frame_svg(
    out,
    cand_root,
    0,
    pad_x,
    inner_w,
    base_y,
    frame_h,
    cand_root.total,
    b_unit,
    min_width_px,
    true,
    base_totals,
    base_scale,
    diff_scale,
  )
  out.write_string("</svg>\n")
  out.to_string()
}

///|
/// Render a self-contained offline interactive HTML report with flamegraph search, zoom, and summary table.
pub fn render_interactive_html(
  title : String,
  svg : String,
  summary_html : String,
) -> String {
  let out = StringBuilder()
  out.write_string(
    "<!doctype html>\n<html lang=\"en\">\n<head>\n<meta charset=\"utf-8\">\n<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">\n",
  )
  out.write_string("<title>\{xml_escape(title)}</title>\n")
  out.write_string(
    "<style>body{margin:0;padding:20px;font-family:system-ui,-apple-system,sans-serif;background:#f3f4f6;color:#111827} .card{background:#fff;border:1px solid #e5e7eb;border-radius:10px;padding:16px;margin-bottom:16px;box-shadow:0 1px 2px rgba(0,0,0,0.04)} .toolbar{display:flex;gap:10px;align-items:center;flex-wrap:wrap;margin-bottom:12px} input{padding:6px 10px;border:1px solid #d1d5db;border-radius:6px;min-width:260px;font-family:ui-monospace,monospace} button{padding:6px 12px;border:1px solid #d1d5db;border-radius:6px;background:#fff;cursor:pointer} button:hover{background:#f9fafb} .fg-frame{cursor:pointer} .fg-frame.matched rect{stroke:#7c3aed;stroke-width:1.8} .fg-frame.dimmed{opacity:0.25} table{width:100%;border-collapse:collapse;font-size:13px} th,td{text-align:left;padding:6px 8px;border-bottom:1px solid #e5e7eb} th{background:#f9fafb;font-weight:600} code{font-family:ui-monospace,monospace;font-size:12px} .badge-reg{color:#b91c1c;font-weight:600} .badge-imp{color:#1d4ed8;font-weight:600}</style>\n",
  )
  out.write_string("</head>\n<body>\n<div class=\"card\">\n")
  out.write_string(
    "<div class=\"toolbar\"><input id=\"q\" placeholder=\"Search function name...\" /><button id=\"reset\">Reset Zoom</button><span id=\"status\" style=\"font-size:12px;color:#4b5563\">Click any frame to zoom.</span></div>\n",
  )
  out.write_string(svg)
  out.write_string("</div>\n<div class=\"card\">\n")
  out.write_string(summary_html)
  out.write_string("</div>\n<script>\n")
  out.write_string(
    "(function(){const svg=document.querySelector('.moon-pprof-svg');if(!svg)return;const frames=[...svg.querySelectorAll('.fg-frame')];const orig=frames.map(f=>({el:f,x:+f.dataset.x,w:+f.dataset.w,d:+f.dataset.depth,name:f.dataset.name.toLowerCase(),val:+f.dataset.val}));const root=orig[0];const q=document.getElementById('q');const st=document.getElementById('status');function applyZoom(target){const tx=target?target.x:root.x;const tw=target?target.w:root.w;const td=target?target.d:0;const scale=root.w/tw;orig.forEach(o=>{const r=o.el.querySelector('rect');const t=o.el.querySelector('text');if(o.x+o.w<=tx||o.x>=tx+tw){o.el.style.display='none';return;}o.el.style.display='';const nx=root.x+(o.x-tx)*scale;const nw=Math.max(0.5,o.w*scale-0.6);r.setAttribute('x',nx.toFixed(2));r.setAttribute('width',nw.toFixed(2));if(t){t.setAttribute('x',(nx+4).toFixed(2));t.style.display=nw<28?'none':'';}o.el.classList.toggle('dimmed',o.d<td);});st.textContent=target?'Zoomed: '+target.el.dataset.name+' ('+target.val+')':'Click any frame to zoom.';}orig.forEach(o=>o.el.addEventListener('click',()=>applyZoom(o)));document.getElementById('reset').addEventListener('click',()=>applyZoom(null));q.addEventListener('input',()=>{const term=q.value.trim().toLowerCase();let hits=0;orig.forEach(o=>{const m=term!==''&&o.name.includes(term);o.el.classList.toggle('matched',m);if(m)hits++;});st.textContent=term?('Matched frames: '+hits):'Click any frame to zoom.';});})();\n",
  )
  out.write_string("</script>\n</body>\n</html>\n")
  out.to_string()
}

///|
/// Render a complete interactive single-file HTML report for a single profile.
pub fn render_top_html(
  profile : Profile,
  sample_type~ : String = "",
  title~ : String = "MoonBit pprof Report",
  limit~ : Int32 = 25,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> String raise PprofError {
  let top = compute_top(
    profile,
    sample_type~,
    sort_by=Flat,
    limit~,
    filter~,
    spec~,
  )
  let svg = render_flamegraph_svg(profile, sample_type~, title~, filter~, spec~)
  let tbl = StringBuilder()
  tbl.write_string(
    "<h3>Top Functions (\{xml_escape(top.sample_type)} / \{xml_escape(top.unit)})</h3>\n",
  )
  tbl.write_string(
    "<table><thead><tr><th>Function</th><th>Flat</th><th>Flat %</th><th>Cum</th><th>Cum %</th></tr></thead><tbody>\n",
  )
  for e in top.entries {
    tbl.write_string(
      "<tr><td><code>\{xml_escape(e.name)}</code></td><td>\{e.flat}</td><td>\{e.flat_pct}%</td><td>\{e.cum}</td><td>\{e.cum_pct}%</td></tr>\n",
    )
  }
  tbl.write_string("</tbody></table>\n")
  render_interactive_html(title, svg, tbl.to_string())
}

///|
/// Render a complete interactive single-file HTML differential report comparing baseline vs candidate.
pub fn render_diff_html(
  baseline : Profile,
  candidate : Profile,
  sample_type~ : String = "",
  title~ : String = "MoonBit pprof Differential Report",
  policy~ : GatePolicy = gate_policy(),
  limit~ : Int32 = 25,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> String raise PprofError {
  let diff = compare_profiles(
    baseline,
    candidate,
    sample_type~,
    policy~,
    limit~,
    filter~,
    spec~,
  )
  let svg = render_diff_flamegraph_svg(
    baseline,
    candidate,
    sample_type~,
    title~,
    normalize=policy.normalize,
    filter~,
    spec~,
  )
  let tbl = StringBuilder()
  let verdict = if diff.gate.passed { "PASS" } else { "REGRESSION DETECTED" }
  tbl.write_string(
    "<h3>Differential Summary: \{verdict} (\{xml_escape(diff.sample_type)} / \{xml_escape(diff.unit)}, total \{diff.baseline_total} -&gt; \{diff.candidate_total}, \{diff.delta_total_pct}%)</h3>\n",
  )
  if !diff.gate.violations.is_empty() {
    tbl.write_string("<ul>")
    for v in diff.gate.violations {
      tbl.write_string("<li class=\"badge-reg\">\{xml_escape(v)}</li>")
    }
    tbl.write_string("</ul>\n")
  }
  tbl.write_string(
    "<table><thead><tr><th>Function</th><th>Status</th><th>Base Cum</th><th>Cand Cum</th><th>Delta Cum</th><th>Delta %</th><th>Share Delta</th></tr></thead><tbody>\n",
  )
  for e in diff.entries {
    let cls = if e.classification == "regressed" || e.classification == "added" {
      " class=\"badge-reg\""
    } else if e.classification == "improved" || e.classification == "removed" {
      " class=\"badge-imp\""
    } else {
      ""
    }
    tbl.write_string(
      "<tr><td><code>\{xml_escape(e.name)}</code></td><td\{cls}>\{xml_escape(e.classification)}</td><td>\{e.baseline_cum}</td><td>\{e.candidate_cum}</td><td>\{e.delta_cum}</td><td>\{e.delta_cum_pct}%</td><td>\{e.delta_cum_share_pp}pp</td></tr>\n",
    )
  }
  tbl.write_string("</tbody></table>\n")
  render_interactive_html(title, svg, tbl.to_string())
}
