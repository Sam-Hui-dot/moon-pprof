///|
/// A node in a weighted directed function callgraph.
#derive(Debug, Eq, ToJson)
pub(all) struct CallGraphNode {
  id : Int32
  name : String
  filename : String
  flat : Int64
  flat_pct : Double
  cum : Int64
  cum_pct : Double
  layer : Int32
}

///|
pub extend CallGraphNode with @debug.Debug::{to_repr}

///|
pub extend CallGraphNode with Eq::{not_equal, equal}

///|
pub extend CallGraphNode with @json.ToJson::{to_json}

///|
/// A weighted directed caller -> callee edge in a callgraph.
#derive(Debug, Eq, ToJson)
pub(all) struct CallGraphEdge {
  from_id : Int32
  to_id : Int32
  caller : String
  callee : String
  weight : Int64
  weight_pct : Double
  is_back_edge : Bool
}

///|
pub extend CallGraphEdge with @debug.Debug::{to_repr}

///|
pub extend CallGraphEdge with Eq::{not_equal, equal}

///|
pub extend CallGraphEdge with @json.ToJson::{to_json}

///|
/// Complete weighted directed callgraph with Sugiyama layer assignment.
#derive(Debug, Eq, ToJson)
pub(all) struct CallGraph {
  sample_type : String
  unit : String
  total : Int64
  shown_total : Int64
  nodes : Array[CallGraphNode]
  edges : Array[CallGraphEdge]
}

///|
pub extend CallGraph with @debug.Debug::{to_repr}

///|
pub extend CallGraph with Eq::{not_equal, equal}

///|
pub extend CallGraph with @json.ToJson::{to_json}

///|
/// A node in a differential callgraph comparing baseline vs candidate profiles.
#derive(Debug, Eq, ToJson)
pub(all) struct DiffCallGraphNode {
  id : Int32
  name : String
  baseline_cum : Int64
  candidate_cum : Int64
  delta_cum : Int64
  delta_cum_pct : Double
  candidate_cum_pct : Double
  classification : String
  layer : Int32
}

///|
pub extend DiffCallGraphNode with @debug.Debug::{to_repr}

///|
pub extend DiffCallGraphNode with Eq::{not_equal, equal}

///|
pub extend DiffCallGraphNode with @json.ToJson::{to_json}

///|
/// A directed edge in a differential callgraph.
#derive(Debug, Eq, ToJson)
pub(all) struct DiffCallGraphEdge {
  from_id : Int32
  to_id : Int32
  caller : String
  callee : String
  baseline_weight : Int64
  candidate_weight : Int64
  delta_weight : Int64
  is_back_edge : Bool
}

///|
pub extend DiffCallGraphEdge with @debug.Debug::{to_repr}

///|
pub extend DiffCallGraphEdge with Eq::{not_equal, equal}

///|
pub extend DiffCallGraphEdge with @json.ToJson::{to_json}

///|
/// Complete differential callgraph comparing baseline and candidate profiles.
#derive(Debug, Eq, ToJson)
pub(all) struct DiffCallGraph {
  sample_type : String
  unit : String
  normalized : Bool
  baseline_total : Int64
  candidate_total : Int64
  nodes : Array[DiffCallGraphNode]
  edges : Array[DiffCallGraphEdge]
}

///|
pub extend DiffCallGraph with @debug.Debug::{to_repr}

///|
pub extend DiffCallGraph with Eq::{not_equal, equal}

///|
pub extend DiffCallGraph with @json.ToJson::{to_json}

///|
fn aggregate_callgraph_raw(
  profile : Profile,
  value_index : Int32,
  spec : FilterSpec,
) -> (Int64, Int64, Map[String, Acc], Map[String, Int64]) raise PprofError {
  let loc_map = build_location_map(profile)
  let fn_map = build_function_map(profile)
  let stats : Map[String, Acc] = Map([])
  let edge_weights : Map[String, Int64] = Map([])
  let mut total = 0L
  let mut shown_total = 0L

  for sample in profile.samples {
    let v = sample.values[value_index]
    total += v
    if v == 0L {
      continue
    }
    let raw_frames = sample_frames_root_to_leaf(
      profile, loc_map, fn_map, sample,
    )
    let frames = match apply_filter(profile, sample, raw_frames, spec) {
      Some(f) => f
      None => continue
    }
    shown_total += v
    if frames.is_empty() {
      continue
    }
    // Credit flat to leaf frame
    let leaf = frames[frames.length() - 1]
    match stats.get(leaf.0) {
      Some(acc) => acc.flat += v
      None => stats[leaf.0] = { filename: leaf.1, flat: v, cum: 0L, }
    }
    // Credit cum once per unique function in stack
    let seen_fn : Map[String, Bool] = Map([])
    for pair in frames {
      if !seen_fn.contains(pair.0) {
        seen_fn[pair.0] = true
        match stats.get(pair.0) {
          Some(acc) => acc.cum += v
          None => stats[pair.0] = { filename: pair.1, flat: 0L, cum: v, }
        }
      }
    }
    // Credit directed caller -> callee edges once per unique pair per sample
    let seen_edge : Map[String, Bool] = Map([])
    for i in 0..<(frames.length() - 1) {
      let caller = frames[i].0
      let callee = frames[i + 1].0
      if caller == callee {
        continue
      }
      let key = "\{caller}\u0000\{callee}"
      if !seen_edge.contains(key) {
        seen_edge[key] = true
        let prev = edge_weights.get(key).unwrap_or(0L)
        edge_weights[key] = prev + v
      }
    }
  }
  (total, shown_total, stats, edge_weights)
}

///|
/// Detect back edges via DFS and assign longest-path topological layers (0 = top root).
fn compute_dag_layers(
  node_count : Int32,
  edges : Array[(Int32, Int32)],
) -> (Array[Int32], Array[Bool]) {
  let adj : Array[Array[(Int32, Int32)]] = []
  let in_deg : Array[Int32] = []
  for _ in 0..<node_count {
    adj.push([])
    in_deg.push(0)
  }
  for idx, e in edges {
    let (u, v) = e
    if u >= 0 && u < node_count && v >= 0 && v < node_count {
      adj[u].push((v, idx))
      in_deg[v] += 1
    }
  }
  // 0 = unvisited, 1 = on stack, 2 = done
  let state : Array[Int32] = Array::make(node_count, 0)
  let is_back : Array[Bool] = Array::make(edges.length(), false)

  fn dfs(u : Int32) -> Unit {
    state[u] = 1
    for pair in adj[u] {
      let (v, eidx) = pair
      if state[v] == 1 {
        is_back[eidx] = true
      } else if state[v] == 0 {
        dfs(v)
      }
    }
    state[u] = 2
  }

  // Prefer natural roots (in_deg == 0) first
  for i in 0..<node_count {
    if in_deg[i] == 0 && state[i] == 0 {
      dfs(i)
    }
  }
  for i in 0..<node_count {
    if state[i] == 0 {
      dfs(i)
    }
  }

  // Kahn topological relaxation on forward DAG for longest-path layering
  let fwd_adj : Array[Array[Int32]] = []
  let fwd_in : Array[Int32] = Array::make(node_count, 0)
  for _ in 0..<node_count {
    fwd_adj.push([])
  }
  for idx, e in edges {
    if !is_back[idx] {
      let (u, v) = e
      if u >= 0 && u < node_count && v >= 0 && v < node_count {
        fwd_adj[u].push(v)
        fwd_in[v] += 1
      }
    }
  }
  let queue : Array[Int32] = []
  for i in 0..<node_count {
    if fwd_in[i] == 0 {
      queue.push(i)
    }
  }
  let layers : Array[Int32] = Array::make(node_count, 0)
  let mut head = 0
  while head < queue.length() {
    let u = queue[head]
    head += 1
    for v in fwd_adj[u] {
      if layers[u] + 1 > layers[v] {
        layers[v] = layers[u] + 1
      }
      fwd_in[v] -= 1
      if fwd_in[v] == 0 {
        queue.push(v)
      }
    }
  }
  (layers, is_back)
}

///|
/// Build a pruned weighted directed `CallGraph` with Sugiyama topological layers.
pub fn build_callgraph(
  profile : Profile,
  sample_type~ : String = "",
  max_nodes~ : Int32 = 35,
  min_node_pct~ : Double = 0.5,
  min_edge_pct~ : Double = 0.1,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> CallGraph raise PprofError {
  validate_profile(profile)
  let (st_idx, st_name, unit) = resolve_sample_type(profile, sample_type~)
  let eff_spec = resolve_filter(filter, spec)
  let (total, shown_total, stats, edge_weights) = aggregate_callgraph_raw(
    profile, st_idx, eff_spec,
  )
  let denom = if is_filter_empty(eff_spec) { total } else { shown_total }

  let raw_nodes : Array[(String, Acc)] = []
  for name, acc in stats {
    if acc.cum > 0L {
      raw_nodes.push((name, acc))
    }
  }
  raw_nodes.sort_by(fn(a, b) {
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

  let kept_names : Array[(String, Acc)] = []
  let max_n = if max_nodes <= 0 { 35 } else { max_nodes }
  for item in raw_nodes {
    if kept_names.length() >= max_n {
      break
    }
    let cp = pct(item.1.cum, denom)
    if cp >= min_node_pct || kept_names.is_empty() {
      kept_names.push(item)
    }
  }

  let name_to_id : Map[String, Int32] = Map([])
  for i, item in kept_names {
    name_to_id[item.0] = i
  }

  let raw_edges : Array[(Int32, Int32, String, String, Int64, Double)] = []
  for key, weight in edge_weights {
    match key.split_once("\u0000") {
      Some((caller_v, callee_v)) => {
        let caller = caller_v.to_owned()
        let callee = callee_v.to_owned()
        match (name_to_id.get(caller), name_to_id.get(callee)) {
          (Some(u), Some(v)) => {
            let wp = pct(weight, denom)
            if wp >= min_edge_pct {
              raw_edges.push((u, v, caller, callee, weight, wp))
            }
          }
          _ => ()
        }
      }
      None => ()
    }
  }
  raw_edges.sort_by(fn(a, b) {
    let w = b.4.compare(a.4)
    if w != 0 {
      w
    } else {
      let c = lex_cmp(a.2, b.2)
      if c != 0 {
        c
      } else {
        lex_cmp(a.3, b.3)
      }
    }
  })

  let edge_pairs : Array[(Int32, Int32)] = raw_edges.map(e => (e.0, e.1))
  let (layers, back_flags) = compute_dag_layers(kept_names.length(), edge_pairs)

  let nodes : Array[CallGraphNode] = []
  for i, item in kept_names {
    nodes.push({
      id: i,
      name: item.0,
      filename: item.1.filename,
      flat: item.1.flat,
      flat_pct: pct(item.1.flat, denom),
      cum: item.1.cum,
      cum_pct: pct(item.1.cum, denom),
      layer: layers[i],
    })
  }
  let edges : Array[CallGraphEdge] = []
  for i, e in raw_edges {
    edges.push({
      from_id: e.0,
      to_id: e.1,
      caller: e.2,
      callee: e.3,
      weight: e.4,
      weight_pct: e.5,
      is_back_edge: back_flags[i],
    })
  }
  { sample_type: st_name, unit, total, shown_total, nodes, edges, }
}

///|
/// Build a differential callgraph highlighting regressed and improved call paths.
pub fn build_diff_callgraph(
  baseline : Profile,
  candidate : Profile,
  sample_type~ : String = "",
  max_nodes~ : Int32 = 35,
  min_node_pct~ : Double = 0.5,
  normalize~ : Bool = false,
  filter~ : String = "",
  spec~ : FilterSpec? = None,
) -> DiffCallGraph raise PprofError {
  validate_profile(baseline)
  validate_profile(candidate)
  let (b_idx, st_name, b_unit) = resolve_sample_type(baseline, sample_type~)
  let (c_idx, _, c_unit) = resolve_sample_type(candidate, sample_type=st_name)
  guard b_unit == c_unit else {
    raise InvalidInput(
      "unit mismatch for sample type '\{st_name}': baseline=\{b_unit}, candidate=\{c_unit}",
    )
  }
  let eff_spec = resolve_filter(filter, spec)
  let (b_tot, b_shown, b_stats, b_edges) = aggregate_callgraph_raw(
    baseline, b_idx, eff_spec,
  )
  let (c_tot, c_shown, c_stats, c_edges) = aggregate_callgraph_raw(
    candidate, c_idx, eff_spec,
  )
  let b_denom = if is_filter_empty(eff_spec) { b_tot } else { b_shown }
  let c_denom = if is_filter_empty(eff_spec) { c_tot } else { c_shown }
  let scale = if normalize && b_denom > 0L && c_denom > 0L {
    c_denom.to_double() / b_denom.to_double()
  } else {
    1.0
  }

  let all_names : Map[String, Bool] = Map([])
  for k, _ in b_stats {
    all_names[k] = true
  }
  for k, _ in c_stats {
    all_names[k] = true
  }

  let scored : Array[(String, Int64, Int64, Int64, Double, Double, String)] = []
  for name, _ in all_names {
    let bc = match b_stats.get(name) {
      Some(a) => a.cum
      None => 0L
    }
    let cc = match c_stats.get(name) {
      Some(a) => a.cum
      None => 0L
    }
    if bc == 0L && cc == 0L {
      continue
    }
    let adj_bc = (bc.to_double() * scale + 0.5).to_int64()
    let dc = cc - adj_bc
    let dc_pct = if adj_bc == 0L {
      if cc > 0L {
        100.0
      } else {
        0.0
      }
    } else {
      round2(dc.to_double() * 100.0 / adj_bc.to_double())
    }
    let c_pct = pct(cc, c_denom)
    let b_pct = pct(bc, b_denom)
    let cls = if bc == 0L && cc > 0L {
      "added"
    } else if cc == 0L && bc > 0L {
      "removed"
    } else if dc > 0L {
      "regressed"
    } else if dc < 0L {
      "improved"
    } else {
      "unchanged"
    }
    if c_pct >= min_node_pct || b_pct >= min_node_pct {
      scored.push((name, bc, cc, dc, dc_pct, c_pct, cls))
    }
  }
  scored.sort_by(fn(a, b) {
    let ma = if a.3 < 0L { -a.3 } else { a.3 }
    let mb = if b.3 < 0L { -b.3 } else { b.3 }
    let d = mb.compare(ma)
    if d != 0 {
      d
    } else {
      let c = b.2.compare(a.2)
      if c != 0 {
        c
      } else {
        lex_cmp(a.0, b.0)
      }
    }
  })

  let max_n = if max_nodes <= 0 { 35 } else { max_nodes }
  let kept = if scored.length() > max_n {
    scored[:max_n].to_owned()
  } else {
    scored
  }
  let name_to_id : Map[String, Int32] = Map([])
  for i, item in kept {
    name_to_id[item.0] = i
  }

  let all_ekeys : Map[String, Bool] = Map([])
  for k, _ in b_edges {
    all_ekeys[k] = true
  }
  for k, _ in c_edges {
    all_ekeys[k] = true
  }
  let raw_edges : Array[(Int32, Int32, String, String, Int64, Int64, Int64)] = []
  for k, _ in all_ekeys {
    match k.split_once("\u0000") {
      Some((cv, ev)) => {
        let caller = cv.to_owned()
        let callee = ev.to_owned()
        match (name_to_id.get(caller), name_to_id.get(callee)) {
          (Some(u), Some(v)) => {
            let bw = b_edges.get(k).unwrap_or(0L)
            let cw = c_edges.get(k).unwrap_or(0L)
            let adj_bw = (bw.to_double() * scale + 0.5).to_int64()
            raw_edges.push((u, v, caller, callee, bw, cw, cw - adj_bw))
          }
          _ => ()
        }
      }
      None => ()
    }
  }
  raw_edges.sort_by(fn(a, b) {
    let ma = if a.6 < 0L { -a.6 } else { a.6 }
    let mb = if b.6 < 0L { -b.6 } else { b.6 }
    let d = mb.compare(ma)
    if d != 0 {
      d
    } else {
      let c = b.5.compare(a.5)
      if c != 0 {
        c
      } else {
        lex_cmp(a.2, b.2)
      }
    }
  })

  let edge_pairs = raw_edges.map(e => (e.0, e.1))
  let (layers, back_flags) = compute_dag_layers(kept.length(), edge_pairs)
  let nodes : Array[DiffCallGraphNode] = []
  for i, item in kept {
    nodes.push({
      id: i,
      name: item.0,
      baseline_cum: item.1,
      candidate_cum: item.2,
      delta_cum: item.3,
      delta_cum_pct: item.4,
      candidate_cum_pct: item.5,
      classification: item.6,
      layer: layers[i],
    })
  }
  let edges : Array[DiffCallGraphEdge] = []
  for i, e in raw_edges {
    edges.push({
      from_id: e.0,
      to_id: e.1,
      caller: e.2,
      callee: e.3,
      baseline_weight: e.4,
      candidate_weight: e.5,
      delta_weight: e.6,
      is_back_edge: back_flags[i],
    })
  }
  {
    sample_type: st_name,
    unit: b_unit,
    normalized: normalize,
    baseline_total: b_denom,
    candidate_total: c_denom,
    nodes,
    edges,
  }
}

///|
fn short_func_name(name : String, max_len : Int32) -> String {
  let chars = name.to_array()
  if chars.length() <= max_len {
    return name
  }
  // Prefer keeping the tail (package.FuncName) when truncating long paths
  let keep = max_len - 1
  let start = chars.length() - keep
  let out = StringBuilder()
  out.write_char('…')
  for i in start..<chars.length() {
    out.write_char(chars[i])
  }
  out.to_string()
}

///|
fn format_compact_val(val : Int64, unit : String) -> String {
  let abs_v = if val < 0L { -val } else { val }
  let sign = if val < 0L { "-" } else { "" }
  if unit == "nanoseconds" {
    if abs_v >= 1_000_000_000L {
      "\{sign}\{round2(abs_v.to_double() / 1_000_000_000.0)}s"
    } else if abs_v >= 1_000_000L {
      "\{sign}\{round2(abs_v.to_double() / 1_000_000.0)}ms"
    } else if abs_v >= 1_000L {
      "\{sign}\{round2(abs_v.to_double() / 1_000.0)}us"
    } else {
      "\{val}ns"
    }
  } else if unit == "bytes" {
    if abs_v >= 1_048_576L {
      "\{sign}\{round2(abs_v.to_double() / 1_048_576.0)}MB"
    } else if abs_v >= 1_024L {
      "\{sign}\{round2(abs_v.to_double() / 1_024.0)}KB"
    } else {
      "\{val}B"
    }
  } else {
    "\{val}"
  }
}

///|
/// Order nodes within each layer using 2-pass barycenter crossing reduction.
fn order_layers_barycenter(
  node_count : Int32,
  layers : Array[Int32],
  weights : Array[Int64],
  names : Array[String],
  fwd_edges : Array[(Int32, Int32)],
) -> Array[Array[Int32]] {
  let mut max_layer = 0
  for l in layers {
    if l > max_layer {
      max_layer = l
    }
  }
  let buckets : Array[Array[Int32]] = []
  for _ in 0..<=max_layer {
    buckets.push([])
  }
  for id in 0..<node_count {
    buckets[layers[id]].push(id)
  }
  // Initial deterministic sort per layer: weight desc, name asc
  for b in buckets {
    b.sort_by(fn(a, c) {
      let w = weights[c].compare(weights[a])
      if w != 0 {
        w
      } else {
        lex_cmp(names[a], names[c])
      }
    })
  }
  let preds : Array[Array[Int32]] = []
  let succs : Array[Array[Int32]] = []
  for _ in 0..<node_count {
    preds.push([])
    succs.push([])
  }
  for e in fwd_edges {
    preds[e.1].push(e.0)
    succs[e.0].push(e.1)
  }

  let pos : Array[Int32] = Array::make(node_count, 0)
  fn refresh_pos() -> Unit {
    for b in buckets {
      for idx, nid in b {
        pos[nid] = idx
      }
    }
  }
  refresh_pos()

  for _pass in 0..<2 {
    // Downward sweep
    for l in 1..<=max_layer {
      let b = buckets[l]
      let bary : Map[Int32, Double] = Map([])
      for nid in b {
        let ps = preds[nid]
        if ps.is_empty() {
          bary[nid] = pos[nid].to_double()
        } else {
          let mut sum = 0.0
          for p in ps {
            sum += pos[p].to_double()
          }
          bary[nid] = sum / ps.length().to_double()
        }
      }
      b.sort_by(fn(a, c) {
        let ba = bary.get(a).unwrap_or(0.0)
        let bc = bary.get(c).unwrap_or(0.0)
        let cmp = ba.compare(bc)
        if cmp != 0 {
          cmp
        } else {
          weights[c].compare(weights[a])
        }
      })
      refresh_pos()
    }
    // Upward sweep
    for l = max_layer - 1; l >= 0; l = l - 1 {
      let b = buckets[l]
      let bary : Map[Int32, Double] = Map([])
      for nid in b {
        let ss = succs[nid]
        if ss.is_empty() {
          bary[nid] = pos[nid].to_double()
        } else {
          let mut sum = 0.0
          for s in ss {
            sum += pos[s].to_double()
          }
          bary[nid] = sum / ss.length().to_double()
        }
      }
      b.sort_by(fn(a, c) {
        let ba = bary.get(a).unwrap_or(0.0)
        let bc = bary.get(c).unwrap_or(0.0)
        let cmp = ba.compare(bc)
        if cmp != 0 {
          cmp
        } else {
          weights[c].compare(weights[a])
        }
      })
      refresh_pos()
    }
  }
  buckets
}

///|
fn node_heat_fill(cum_pct : Double) -> (String, String) {
  let t = clamp_unit(cum_pct / 100.0)
  let r = 255 - (t * 20.0).to_int()
  let g = 246 - (t * 140.0).to_int()
  let b = 232 - (t * 175.0).to_int()
  let border = if t > 0.45 {
    "#b91c1c"
  } else if t > 0.15 {
    "#d97706"
  } else {
    "#9ca3af"
  }
  ("rgb(\{r},\{g},\{b})", border)
}

///|
/// Render a `CallGraph` directly to a standalone layered SVG (no Graphviz required).
pub fn render_callgraph_svg(
  graph : CallGraph,
  title~ : String = "MoonBit pprof Callgraph",
) -> String {
  if graph.nodes.is_empty() {
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 640 120\" width=\"100%\"><rect width=\"100%\" height=\"100%\" fill=\"#fafafa\"/><text x=\"20\" y=\"60\" font-size=\"14\" font-family=\"system-ui,sans-serif\" fill=\"#6b7280\">No callgraph nodes matched the current filter.</text></svg>\n"
  }
  let n = graph.nodes.length()
  let layers = graph.nodes.map(nd => nd.layer)
  let weights = graph.nodes.map(nd => nd.cum)
  let names = graph.nodes.map(nd => nd.name)
  let fwd_edges : Array[(Int32, Int32)] = []
  for e in graph.edges {
    if !e.is_back_edge {
      fwd_edges.push((e.from_id, e.to_id))
    }
  }
  let buckets = order_layers_barycenter(n, layers, weights, names, fwd_edges)

  let node_w = 196.0
  let node_h = 56.0
  let gap_x = 34.0
  let gap_y = 66.0
  let pad_x = 36.0
  let header_h = 68.0
  let pad_bottom = 36.0

  let mut max_cols = 1
  for b in buckets {
    if b.length() > max_cols {
      max_cols = b.length()
    }
  }
  let content_w = max_cols.to_double() * node_w +
    (max_cols - 1).to_double() * gap_x
  let svg_w = if content_w + 2.0 * pad_x < 720.0 {
    720.0
  } else {
    content_w + 2.0 * pad_x
  }
  let svg_h = header_h +
    buckets.length().to_double() * node_h +
    (buckets.length() - 1).to_double() * gap_y +
    pad_bottom

  let nx : Array[Double] = Array::make(n, 0.0)
  let ny : Array[Double] = Array::make(n, 0.0)
  for l, b in buckets {
    let row_w = b.length().to_double() * node_w +
      (if b.length() > 1 { (b.length() - 1).to_double() * gap_x } else { 0.0 })
    let start_x = (svg_w - row_w) / 2.0
    let y = header_h + l.to_double() * (node_h + gap_y)
    for col, nid in b {
      nx[nid] = start_x + col.to_double() * (node_w + gap_x)
      ny[nid] = y
    }
  }

  let out = StringBuilder()
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \{svg_w.to_int()} \{svg_h.to_int()}\" width=\"100%\" class=\"moon-pprof-cg-svg\">\n",
  )
  out.write_string(
    "<defs><marker id=\"cg-arrow\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M 0 1 L 10 5 L 0 9 z\" fill=\"#6b7280\"/></marker><marker id=\"cg-arrow-hot\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M 0 1 L 10 5 L 0 9 z\" fill=\"#b91c1c\"/></marker><marker id=\"cg-arrow-back\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M 0 1 L 10 5 L 0 9 z\" fill=\"#7c3aed\"/></marker></defs>\n",
  )
  out.write_string("<rect width=\"100%\" height=\"100%\" fill=\"#fafafa\"/>\n")
  out.write_string(
    "<text x=\"20\" y=\"26\" font-size=\"15\" font-weight=\"600\" font-family=\"system-ui,-apple-system,sans-serif\" fill=\"#111827\">\{xml_escape(title)}</text>\n",
  )
  out.write_string(
    "<text x=\"20\" y=\"44\" font-size=\"11\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#4b5563\">metric: \{xml_escape(graph.sample_type)} (\{xml_escape(graph.unit)}) | total: \{format_compact_val(graph.total, graph.unit)} | nodes: \{graph.nodes.length()} | edges: \{graph.edges.length()}</text>\n",
  )

  // Draw edges beneath nodes
  for e in graph.edges {
    let x1 = nx[e.from_id] + node_w / 2.0
    let y1 = ny[e.from_id] + node_h
    let x2 = nx[e.to_id] + node_w / 2.0
    let y2 = ny[e.to_id]
    let sw = 1.2 + clamp_unit(e.weight_pct / 100.0) * 3.8
    let hot = e.weight_pct >= 25.0
    let stroke = if e.is_back_edge {
      "#7c3aed"
    } else if hot {
      "#b91c1c"
    } else {
      "#6b7280"
    }
    let marker = if e.is_back_edge {
      "url(#cg-arrow-back)"
    } else if hot {
      "url(#cg-arrow-hot)"
    } else {
      "url(#cg-arrow)"
    }
    let dash = if e.is_back_edge { " stroke-dasharray=\"5,4\"" } else { "" }
    let d_attr = if e.is_back_edge {
      let sx = nx[e.from_id] + node_w
      let sy = ny[e.from_id] + node_h / 2.0
      let tx = nx[e.to_id] + node_w
      let ty = ny[e.to_id] + node_h / 2.0
      let cx = (if sx > tx { sx } else { tx }) + 56.0
      "M \{sx.to_int()} \{sy.to_int()} C \{cx.to_int()} \{sy.to_int()}, \{cx.to_int()} \{ty.to_int()}, \{tx.to_int()} \{ty.to_int()}"
    } else {
      let mid_y = (y1 + y2) / 2.0
      "M \{x1.to_int()} \{y1.to_int()} C \{x1.to_int()} \{mid_y.to_int()}, \{x2.to_int()} \{mid_y.to_int()}, \{x2.to_int()} \{y2.to_int()}"
    }
    let tip = "\{e.caller} -> \{e.callee}: \{e.weight} \{graph.unit} (\{e.weight_pct}%)"
    out.write_string(
      "<g class=\"cg-edge\"><title>\{xml_escape(tip)}</title><path d=\"\{d_attr}\" fill=\"none\" stroke=\"\{stroke}\" stroke-width=\"\{round2(sw)}\"\{dash} marker-end=\"\{marker}\"/>",
    )
    if !e.is_back_edge && e.weight_pct >= 2.0 {
      let lx = ((x1 + x2) / 2.0).to_int()
      let ly = ((y1 + y2) / 2.0).to_int()
      let lbl = "\{format_compact_val(e.weight, graph.unit)} (\{e.weight_pct}%)"
      out.write_string(
        "<text x=\"\{lx}\" y=\"\{ly - 3}\" text-anchor=\"middle\" font-size=\"9.5\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"\{stroke}\">\{xml_escape(lbl)}</text>",
      )
    }
    out.write_string("</g>\n")
  }

  // Draw nodes
  for nd in graph.nodes {
    let x = nx[nd.id].to_int()
    let y = ny[nd.id].to_int()
    let (fill, border) = node_heat_fill(nd.cum_pct)
    let short_name = short_func_name(nd.name, 26)
    let line2 = "cum \{format_compact_val(nd.cum, graph.unit)} (\{nd.cum_pct}%)"
    let line3 = "flat \{format_compact_val(nd.flat, graph.unit)} (\{nd.flat_pct}%)"
    let tip = "\{nd.name}\ncum: \{nd.cum} \{graph.unit} (\{nd.cum_pct}%)\nflat: \{nd.flat} \{graph.unit} (\{nd.flat_pct}%)"
    out.write_string(
      "<g class=\"cg-node\" data-name=\"\{xml_escape(nd.name)}\"><title>\{xml_escape(tip)}</title>",
    )
    out.write_string(
      "<rect x=\"\{x}\" y=\"\{y}\" width=\"\{node_w.to_int()}\" height=\"\{node_h.to_int()}\" rx=\"7\" fill=\"\{fill}\" stroke=\"\{border}\" stroke-width=\"1.4\"/>",
    )
    out.write_string(
      "<text x=\"\{x + node_w.to_int() / 2}\" y=\"\{y + 18}\" text-anchor=\"middle\" font-size=\"11\" font-weight=\"600\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#111827\">\{xml_escape(short_name)}</text>",
    )
    out.write_string(
      "<text x=\"\{x + node_w.to_int() / 2}\" y=\"\{y + 34}\" text-anchor=\"middle\" font-size=\"10\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#374151\">\{xml_escape(line2)}</text>",
    )
    out.write_string(
      "<text x=\"\{x + node_w.to_int() / 2}\" y=\"\{y + 47}\" text-anchor=\"middle\" font-size=\"9.5\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#6b7280\">\{xml_escape(line3)}</text>",
    )
    out.write_string("</g>\n")
  }

  out.write_string("</svg>\n")
  out.to_string()
}

///|
/// Render a `DiffCallGraph` directly to a standalone layered differential SVG (red = regressed, blue = improved).
pub fn render_diff_callgraph_svg(
  graph : DiffCallGraph,
  title~ : String = "MoonBit pprof Differential Callgraph",
) -> String {
  if graph.nodes.is_empty() {
    return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 640 120\" width=\"100%\"><rect width=\"100%\" height=\"100%\" fill=\"#fafafa\"/><text x=\"20\" y=\"60\" font-size=\"14\" font-family=\"system-ui,sans-serif\" fill=\"#6b7280\">No differential callgraph nodes matched.</text></svg>\n"
  }
  let n = graph.nodes.length()
  let layers = graph.nodes.map(nd => nd.layer)
  let weights = graph.nodes.map(nd => {
    if nd.delta_cum < 0L {
      -nd.delta_cum
    } else {
      nd.delta_cum
    }
  })
  let names = graph.nodes.map(nd => nd.name)
  let fwd_edges : Array[(Int32, Int32)] = []
  for e in graph.edges {
    if !e.is_back_edge {
      fwd_edges.push((e.from_id, e.to_id))
    }
  }
  let buckets = order_layers_barycenter(n, layers, weights, names, fwd_edges)

  let node_w = 204.0
  let node_h = 58.0
  let gap_x = 34.0
  let gap_y = 66.0
  let pad_x = 36.0
  let header_h = 72.0
  let pad_bottom = 36.0

  let mut max_cols = 1
  for b in buckets {
    if b.length() > max_cols {
      max_cols = b.length()
    }
  }
  let content_w = max_cols.to_double() * node_w +
    (max_cols - 1).to_double() * gap_x
  let svg_w = if content_w + 2.0 * pad_x < 740.0 {
    740.0
  } else {
    content_w + 2.0 * pad_x
  }
  let svg_h = header_h +
    buckets.length().to_double() * node_h +
    (buckets.length() - 1).to_double() * gap_y +
    pad_bottom

  let nx : Array[Double] = Array::make(n, 0.0)
  let ny : Array[Double] = Array::make(n, 0.0)
  for l, b in buckets {
    let row_w = b.length().to_double() * node_w +
      (if b.length() > 1 { (b.length() - 1).to_double() * gap_x } else { 0.0 })
    let start_x = (svg_w - row_w) / 2.0
    let y = header_h + l.to_double() * (node_h + gap_y)
    for col, nid in b {
      nx[nid] = start_x + col.to_double() * (node_w + gap_x)
      ny[nid] = y
    }
  }

  let mut max_abs_delta = 1.0
  for nd in graph.nodes {
    let a = (if nd.delta_cum < 0L { -nd.delta_cum } else { nd.delta_cum }).to_double()
    if a > max_abs_delta {
      max_abs_delta = a
    }
  }

  let out = StringBuilder()
  out.write_string(
    "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \{svg_w.to_int()} \{svg_h.to_int()}\" width=\"100%\" class=\"moon-pprof-cg-svg\">\n",
  )
  out.write_string(
    "<defs><marker id=\"dcg-arrow\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M 0 1 L 10 5 L 0 9 z\" fill=\"#6b7280\"/></marker><marker id=\"dcg-arrow-reg\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M 0 1 L 10 5 L 0 9 z\" fill=\"#b91c1c\"/></marker><marker id=\"dcg-arrow-imp\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M 0 1 L 10 5 L 0 9 z\" fill=\"#1d4ed8\"/></marker></defs>\n",
  )
  out.write_string("<rect width=\"100%\" height=\"100%\" fill=\"#fafafa\"/>\n")
  out.write_string(
    "<text x=\"20\" y=\"26\" font-size=\"15\" font-weight=\"600\" font-family=\"system-ui,-apple-system,sans-serif\" fill=\"#111827\">\{xml_escape(title)}</text>\n",
  )
  out.write_string(
    "<text x=\"20\" y=\"44\" font-size=\"11\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#4b5563\">metric: \{xml_escape(graph.sample_type)} (\{xml_escape(graph.unit)}) | baseline: \{format_compact_val(graph.baseline_total, graph.unit)} -&gt; candidate: \{format_compact_val(graph.candidate_total, graph.unit)}</text>\n",
  )

  for e in graph.edges {
    let x1 = nx[e.from_id] + node_w / 2.0
    let y1 = ny[e.from_id] + node_h
    let x2 = nx[e.to_id] + node_w / 2.0
    let y2 = ny[e.to_id]
    let (stroke, marker) = if e.delta_weight > 0L {
      ("#b91c1c", "url(#dcg-arrow-reg)")
    } else if e.delta_weight < 0L {
      ("#1d4ed8", "url(#dcg-arrow-imp)")
    } else {
      ("#6b7280", "url(#dcg-arrow)")
    }
    let mid_y = (y1 + y2) / 2.0
    let d_attr = "M \{x1.to_int()} \{y1.to_int()} C \{x1.to_int()} \{mid_y.to_int()}, \{x2.to_int()} \{mid_y.to_int()}, \{x2.to_int()} \{y2.to_int()}"
    let tip = "\{e.caller} -> \{e.callee}: \{e.baseline_weight} -> \{e.candidate_weight} (\{signed_i64(e.delta_weight)})"
    out.write_string(
      "<g class=\"cg-edge\"><title>\{xml_escape(tip)}</title><path d=\"\{d_attr}\" fill=\"none\" stroke=\"\{stroke}\" stroke-width=\"1.8\" marker-end=\"\{marker}\"/></g>\n",
    )
  }

  for nd in graph.nodes {
    let x = nx[nd.id].to_int()
    let y = ny[nd.id].to_int()
    let fill = diff_color(nd.delta_cum.to_double(), max_abs_delta)
    let border = if nd.delta_cum > 0L {
      "#b91c1c"
    } else if nd.delta_cum < 0L {
      "#1d4ed8"
    } else {
      "#9ca3af"
    }
    let short_name = short_func_name(nd.name, 26)
    let sign_delta = if nd.delta_cum > 0L {
      "+\{format_compact_val(nd.delta_cum, graph.unit)}"
    } else {
      format_compact_val(nd.delta_cum, graph.unit)
    }
    let line2 = "\{sign_delta} (\{signed_f64(nd.delta_cum_pct)}%)"
    let line3 = "\{format_compact_val(nd.baseline_cum, graph.unit)} -> \{format_compact_val(nd.candidate_cum, graph.unit)}"
    let tip = "\{nd.name} [\{nd.classification}]\nbaseline: \{nd.baseline_cum}\ncandidate: \{nd.candidate_cum}\ndelta: \{signed_i64(nd.delta_cum)} (\{signed_f64(nd.delta_cum_pct)}%)"
    out.write_string(
      "<g class=\"cg-node\" data-name=\"\{xml_escape(nd.name)}\"><title>\{xml_escape(tip)}</title>",
    )
    out.write_string(
      "<rect x=\"\{x}\" y=\"\{y}\" width=\"\{node_w.to_int()}\" height=\"\{node_h.to_int()}\" rx=\"7\" fill=\"\{fill}\" stroke=\"\{border}\" stroke-width=\"1.5\"/>",
    )
    out.write_string(
      "<text x=\"\{x + node_w.to_int() / 2}\" y=\"\{y + 18}\" text-anchor=\"middle\" font-size=\"11\" font-weight=\"600\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#111827\">\{xml_escape(short_name)}</text>",
    )
    out.write_string(
      "<text x=\"\{x + node_w.to_int() / 2}\" y=\"\{y + 34}\" text-anchor=\"middle\" font-size=\"10\" font-weight=\"600\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"\{border}\">\{xml_escape(line2)}</text>",
    )
    out.write_string(
      "<text x=\"\{x + node_w.to_int() / 2}\" y=\"\{y + 48}\" text-anchor=\"middle\" font-size=\"9.5\" font-family=\"ui-monospace,Consolas,monospace\" fill=\"#4b5563\">\{xml_escape(line3)}</text>",
    )
    out.write_string("</g>\n")
  }
  out.write_string("</svg>\n")
  out.to_string()
}

///|
fn dot_escape(text : String) -> String {
  text.replace_all(old="\\", new="\\\\").replace_all(old="\"", new="\\\"")
}

///|
/// Export a `CallGraph` in standard Graphviz DOT format.
pub fn render_callgraph_dot(graph : CallGraph) -> String {
  let out = StringBuilder()
  out.write_string("digraph \"moon-pprof\" {\n")
  out.write_string("  rankdir=TB;\n")
  out.write_string(
    "  node [shape=box, style=\"rounded,filled\", fontname=\"monospace\", fontsize=10];\n",
  )
  for nd in graph.nodes {
    let (fill, border) = node_heat_fill(nd.cum_pct)
    let label = "\{dot_escape(nd.name)}\\ncum: \{nd.cum} (\{nd.cum_pct}%)\\nflat: \{nd.flat} (\{nd.flat_pct}%)"
    out.write_string(
      "  n\{nd.id} [label=\"\{label}\", fillcolor=\"\{fill}\", color=\"\{border}\"];\n",
    )
  }
  for e in graph.edges {
    let style = if e.is_back_edge {
      ", style=dashed, color=\"#7c3aed\""
    } else {
      ""
    }
    out.write_string(
      "  n\{e.from_id} -> n\{e.to_id} [label=\"\{e.weight} (\{e.weight_pct}%)\"\{style}];\n",
    )
  }
  out.write_string("}\n")
  out.to_string()
}

///|
/// Export a `DiffCallGraph` in Graphviz DOT format.
pub fn render_diff_callgraph_dot(graph : DiffCallGraph) -> String {
  let out = StringBuilder()
  out.write_string("digraph \"moon-pprof-diff\" {\n")
  out.write_string("  rankdir=TB;\n")
  out.write_string(
    "  node [shape=box, style=\"rounded,filled\", fontname=\"monospace\", fontsize=10];\n",
  )
  for nd in graph.nodes {
    let color = if nd.delta_cum > 0L {
      "#b91c1c"
    } else if nd.delta_cum < 0L {
      "#1d4ed8"
    } else {
      "#6b7280"
    }
    let label = "\{dot_escape(nd.name)}\\n\{nd.baseline_cum} -> \{nd.candidate_cum} (\{signed_i64(nd.delta_cum)}, \{signed_f64(nd.delta_cum_pct)}%)"
    out.write_string("  n\{nd.id} [label=\"\{label}\", color=\"\{color}\"];\n")
  }
  for e in graph.edges {
    out.write_string(
      "  n\{e.from_id} -> n\{e.to_id} [label=\"\{signed_i64(e.delta_weight)}\"];\n",
    )
  }
  out.write_string("}\n")
  out.to_string()
}
