///|
/// Errors raised while decompressing, decoding, validating, or analyzing pprof profiles.
#derive(Debug, Eq)
pub(all) suberror PprofError {
  InvalidGzip(String)
  InvalidProtobuf(String)
  InvalidProfile(String)
  InvalidInput(String)
}

///|
pub extend PprofError with @debug.Debug::{to_repr}

///|
pub extend PprofError with Eq::{not_equal, equal}

///|
/// Convert any error into a concise human-readable diagnostic message.
pub fn error_message(error : Error) -> String {
  match error {
    InvalidGzip(msg)
    | InvalidProtobuf(msg)
    | InvalidProfile(msg)
    | InvalidInput(msg) => msg
    other => other.to_string()
  }
}

///|
/// Describes the type and measurement unit of a sample value (e.g. `cpu` / `nanoseconds`).
#derive(Debug, Eq, ToJson)
pub(all) struct ValueType {
  type_idx : Int64
  unit_idx : Int64
}

///|
pub extend ValueType with @debug.Debug::{to_repr}

///|
pub extend ValueType with Eq::{not_equal, equal}

///|
pub extend ValueType with @json.ToJson::{to_json}

///|
/// Structured key/value metadata attached to an individual sample.
#derive(Debug, Eq, ToJson)
pub(all) struct Label {
  key_idx : Int64
  str_idx : Int64
  num : Int64
  num_unit_idx : Int64
}

///|
pub extend Label with @debug.Debug::{to_repr}

///|
pub extend Label with Eq::{not_equal, equal}

///|
pub extend Label with @json.ToJson::{to_json}

///|
/// Source line reference inside a `Location` (ordered leaf-first when inlined).
#derive(Debug, Eq, ToJson)
pub(all) struct Line {
  function_id : UInt64
  line : Int64
}

///|
pub extend Line with @debug.Debug::{to_repr}

///|
pub extend Line with Eq::{not_equal, equal}

///|
pub extend Line with @json.ToJson::{to_json}

///|
/// Code location referenced by samples, optionally expanding to inlined `lines`.
#derive(Debug, Eq, ToJson)
pub(all) struct Location {
  id : UInt64
  mapping_id : UInt64
  address : UInt64
  lines : Array[Line]
  is_folded : Bool
}

///|
pub extend Location with @debug.Debug::{to_repr}

///|
pub extend Location with Eq::{not_equal, equal}

///|
pub extend Location with @json.ToJson::{to_json}

///|
/// Binary image mapping metadata for a profiled process.
#derive(Debug, Eq, ToJson)
pub(all) struct Mapping {
  id : UInt64
  memory_start : UInt64
  memory_limit : UInt64
  file_offset : UInt64
  filename_idx : Int64
  build_id_idx : Int64
  has_functions : Bool
  has_filenames : Bool
  has_line_numbers : Bool
  has_inline_frames : Bool
}

///|
pub extend Mapping with @debug.Debug::{to_repr}

///|
pub extend Mapping with Eq::{not_equal, equal}

///|
pub extend Mapping with @json.ToJson::{to_json}

///|
/// Symbol metadata for a profiled function.
#derive(Debug, Eq, ToJson)
pub(all) struct Function {
  id : UInt64
  name_idx : Int64
  system_name_idx : Int64
  filename_idx : Int64
  start_line : Int64
}

///|
pub extend Function with @debug.Debug::{to_repr}

///|
pub extend Function with Eq::{not_equal, equal}

///|
pub extend Function with @json.ToJson::{to_json}

///|
/// A single recorded stack trace (`location_ids` leaf-first) with parallel metric `values`.
#derive(Debug, Eq, ToJson)
pub(all) struct Sample {
  location_ids : Array[UInt64]
  values : Array[Int64]
  labels : Array[Label]
}

///|
pub extend Sample with @debug.Debug::{to_repr}

///|
pub extend Sample with Eq::{not_equal, equal}

///|
pub extend Sample with @json.ToJson::{to_json}

///|
/// Decoded Google `perftools.profiles.Profile` message (`profile.proto`).
#derive(Debug, Eq, ToJson)
pub(all) struct Profile {
  sample_types : Array[ValueType]
  samples : Array[Sample]
  mappings : Array[Mapping]
  locations : Array[Location]
  functions : Array[Function]
  string_table : Array[String]
  drop_frames : Int64
  keep_frames : Int64
  time_nanos : Int64
  duration_nanos : Int64
  period_type : ValueType?
  period : Int64
  comments : Array[Int64]
  default_sample_type : Int64
}

///|
pub extend Profile with @debug.Debug::{to_repr}

///|
pub extend Profile with Eq::{not_equal, equal}

///|
pub extend Profile with @json.ToJson::{to_json}

///|
/// Sort criterion for `compute_top`.
#derive(Debug, Eq)
pub(all) enum SortBy {
  Flat
  Cum
}

///|
pub extend SortBy with @debug.Debug::{to_repr}

///|
pub extend SortBy with Eq::{not_equal, equal}

///|
/// Per-function flat and cumulative aggregation statistics.
#derive(Debug, Eq, ToJson)
pub(all) struct FunctionStat {
  name : String
  filename : String
  flat : Int64
  flat_pct : Double
  cum : Int64
  cum_pct : Double
}

///|
pub extend FunctionStat with @debug.Debug::{to_repr}

///|
pub extend FunctionStat with Eq::{not_equal, equal}

///|
pub extend FunctionStat with @json.ToJson::{to_json}

///|
/// Top-N aggregation report for a single profile and metric.
#derive(Debug, Eq, ToJson)
pub(all) struct TopReport {
  sample_type : String
  unit : String
  total : Int64
  shown_total : Int64
  sample_count : Int32
  duration_nanos : Int64
  entries : Array[FunctionStat]
}

///|
pub extend TopReport with @debug.Debug::{to_repr}

///|
pub extend TopReport with Eq::{not_equal, equal}

///|
pub extend TopReport with @json.ToJson::{to_json}

///|
/// A single folded call stack (`root;caller;callee`) with aggregated weight.
#derive(Debug, Eq, ToJson)
pub(all) struct FoldedStack {
  stack : String
  value : Int64
}

///|
pub extend FoldedStack with @debug.Debug::{to_repr}

///|
pub extend FoldedStack with Eq::{not_equal, equal}

///|
pub extend FoldedStack with @json.ToJson::{to_json}

///|
/// Per-function difference between a baseline profile and a candidate profile.
#derive(Debug, Eq, ToJson)
pub(all) struct DiffEntry {
  name : String
  filename : String
  baseline_flat : Int64
  candidate_flat : Int64
  delta_flat : Int64
  delta_flat_pct : Double
  baseline_cum : Int64
  candidate_cum : Int64
  delta_cum : Int64
  delta_cum_pct : Double
  baseline_cum_share_pct : Double
  candidate_cum_share_pct : Double
  delta_cum_share_pp : Double
  classification : String
}

///|
pub extend DiffEntry with @debug.Debug::{to_repr}

///|
pub extend DiffEntry with Eq::{not_equal, equal}

///|
pub extend DiffEntry with @json.ToJson::{to_json}

///|
/// Threshold policy for CI performance regression gating.
#derive(Debug, Eq, ToJson)
pub(all) struct GatePolicy {
  max_total_regression_pct : Double?
  max_func_cum_regression_pct : Double?
  min_abs_delta : Int64
  normalize : Bool
}

///|
pub extend GatePolicy with @debug.Debug::{to_repr}

///|
pub extend GatePolicy with Eq::{not_equal, equal}

///|
pub extend GatePolicy with @json.ToJson::{to_json}

///|
/// Outcome of applying a `GatePolicy` to a `DiffReport`.
#derive(Debug, Eq, ToJson)
pub(all) struct GateResult {
  passed : Bool
  exit_code : Int32
  violations : Array[String]
}

///|
pub extend GateResult with @debug.Debug::{to_repr}

///|
pub extend GateResult with Eq::{not_equal, equal}

///|
pub extend GateResult with @json.ToJson::{to_json}

///|
/// Full differential comparison between a baseline and candidate profile.
#derive(Debug, Eq, ToJson)
pub(all) struct DiffReport {
  sample_type : String
  unit : String
  normalized : Bool
  baseline_total : Int64
  candidate_total : Int64
  delta_total : Int64
  delta_total_pct : Double
  entries : Array[DiffEntry]
  gate : GateResult
}

///|
pub extend DiffReport with @debug.Debug::{to_repr}

///|
pub extend DiffReport with Eq::{not_equal, equal}

///|
pub extend DiffReport with @json.ToJson::{to_json}

///|
/// Stack and sample-label filtering specification (`focus`, `ignore`, `hide`, `label`).
#derive(Debug, Eq, ToJson)
pub(all) struct FilterSpec {
  focus : String
  ignore_pattern : String
  hide : String
  label_key : String
  label_value : String
}

///|
pub extend FilterSpec with @debug.Debug::{to_repr}

///|
pub extend FilterSpec with Eq::{not_equal, equal}

///|
pub extend FilterSpec with @json.ToJson::{to_json}

///|
/// Aggregated metric total for one value of a `Sample.label` key.
#derive(Debug, Eq, ToJson)
pub(all) struct LabelStat {
  label_value : String
  value : Int64
  pct : Double
  sample_count : Int32
}

///|
pub extend LabelStat with @debug.Debug::{to_repr}

///|
pub extend LabelStat with Eq::{not_equal, equal}

///|
pub extend LabelStat with @json.ToJson::{to_json}

///|
/// Grouped breakdown of a profile by a `Sample.label` key (e.g. HTTP route or tenant).
#derive(Debug, Eq, ToJson)
pub(all) struct LabelReport {
  sample_type : String
  unit : String
  label_key : String
  total : Int64
  matched_total : Int64
  groups : Array[LabelStat]
}

///|
pub extend LabelReport with @debug.Debug::{to_repr}

///|
pub extend LabelReport with Eq::{not_equal, equal}

///|
pub extend LabelReport with @json.ToJson::{to_json}
