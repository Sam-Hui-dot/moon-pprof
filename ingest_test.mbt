///|
test "from_v8_cpuprofile decodes call tree, timeDeltas, and round-trips to pprof .pb.gz" {
  let v8 =
    #|{
    #|  "nodes": [
    #|    { "id": 1, "callFrame": { "functionName": "(root)", "url": "", "lineNumber": -1 }, "children": [2] },
    #|    { "id": 2, "callFrame": { "functionName": "main", "url": "app.js", "lineNumber": 9 }, "children": [3, 4] },
    #|    { "id": 3, "callFrame": { "functionName": "parseProfile", "url": "app.js", "lineNumber": 41 } },
    #|    { "id": 4, "callFrame": { "functionName": "renderSvg", "url": "app.js", "lineNumber": 99 } }
    #|  ],
    #|  "startTime": 1000,
    #|  "endTime": 6000,
    #|  "samples": [3, 3, 4],
    #|  "timeDeltas": [1500, 2500, 1000]
    #|}
  let profile = @moon-pprof.from_v8_cpuprofile(v8)
  assert_eq(profile.duration_nanos, 5_000_000L)
  let top = @moon-pprof.compute_top(profile, sample_type="cpu")
  assert_eq(top.total, 5_000_000L)
  assert_eq(top.entries[0].name, "parseProfile")
  assert_eq(top.entries[0].flat, 4_000_000L)
  assert_eq(top.entries[1].name, "renderSvg")
  assert_eq(top.entries[1].flat, 1_000_000L)

  // Verify round-trip encoding to standard gzipped profile.proto
  let gz = @moon-pprof.encode_profile(profile, gzip=true)
  assert_eq(@moon-pprof.detect_profile_format(gz), "pprof-gzip")
  let decoded = @moon-pprof.decode_any_profile(gz)
  let top2 = @moon-pprof.compute_top(decoded, sample_type="cpu")
  assert_eq(top2.total, 5_000_000L)
}

///|
test "from_folded_stacks and from_perf_script parse accurately and auto-detect" {
  let folded =
    #|# comment
    #|main;parse;decode 30
    #|main;parse;decode 20
    #|main;render 50
    #|
  let p_folded = @moon-pprof.from_folded_stacks(folded)
  let top_f = @moon-pprof.compute_top(p_folded)
  assert_eq(top_f.total, 100L)
  assert_eq(top_f.entries[0].name, "decode")
  assert_eq(top_f.entries[0].flat, 50L)
  assert_eq(top_f.entries[1].name, "render")
  assert_eq(top_f.entries[1].flat, 50L)

  let perf =
    #|moon_app 4321 12.345678: 250000 cpu-clock:
    #|	7f001122 hot_loop+0x18 (/usr/bin/moon_app)
    #|	7f001100 worker+0x4 (/usr/bin/moon_app)
    #|
    #|moon_app 4321 12.346000: 750000 cpu-clock:
    #|	7f001122 hot_loop+0x18 (/usr/bin/moon_app)
    #|	7f001100 worker+0x4 (/usr/bin/moon_app)
    #|
  let p_perf = @moon-pprof.from_perf_script(perf)
  let top_p = @moon-pprof.compute_top(p_perf)
  assert_eq(top_p.total, 1_000_000L)
  assert_eq(top_p.entries[0].name, "hot_loop")
  assert_eq(top_p.entries[0].flat, 1_000_000L)

  assert_eq(
    @moon-pprof.demangle_moonbit_symbol(
      "_M0MP215Sam_2dHui_2ddot12moon_2dpprof10WireReader12read__varint",
    ),
    "Sam-Hui-dot::moon-pprof::WireReader::read_varint",
  )
  assert_eq(
    @moon-pprof.demangle_moonbit_symbol("_M0IPC16string6StringPB4Hash4hash"),
    "string::String::Hash::hash",
  )
}

///|
test "from_v8_heapprofile decodes allocation tree, demangles MoonBit symbols, and auto-detects" {
  let heap_json =
    #|{
    #|  "head": {
    #|    "id": 1,
    #|    "callFrame": { "functionName": "(root)", "url": "", "lineNumber": -1 },
    #|    "selfSize": 0,
    #|    "children": [
    #|      {
    #|        "id": 2,
    #|        "callFrame": { "functionName": "_M0MP215Sam_2dHui_2ddot12moon_2dpprof10WireReader12read__varint", "url": "moon-pprof/web.js", "lineNumber": 20 },
    #|        "selfSize": 16384,
    #|        "children": [
    #|          {
    #|            "id": 3,
    #|            "callFrame": { "functionName": "allocBuffer", "url": "moon-pprof/web.js", "lineNumber": 55 },
    #|            "selfSize": 8192,
    #|            "children": []
    #|          }
    #|        ]
    #|      }
    #|    ]
    #|  },
    #|  "samples": [
    #|    { "size": 4096, "nodeId": 2, "ordinal": 1 },
    #|    { "size": 12288, "nodeId": 2, "ordinal": 2 },
    #|    { "size": 8192, "nodeId": 3, "ordinal": 3 }
    #|  ]
    #|}
  let raw_bytes = Bytes::makei(heap_json.length(), i => {
    heap_json.code_unit_at(i).to_byte()
  })
  assert_eq(@moon-pprof.detect_profile_format(raw_bytes), "v8-heapprofile")
  let profile = @moon-pprof.decode_any_profile(raw_bytes)
  let top_space = @moon-pprof.compute_top(profile, sample_type="alloc_space")
  assert_eq(top_space.total, 24576L)
  assert_eq(
    top_space.entries[0].name,
    "Sam-Hui-dot::moon-pprof::WireReader::read_varint",
  )
  assert_eq(top_space.entries[0].flat, 16384L)
  assert_eq(top_space.entries[0].cum, 24576L)
  assert_eq(top_space.entries[1].name, "allocBuffer")
  assert_eq(top_space.entries[1].flat, 8192L)

  let top_objs = @moon-pprof.compute_top(profile, sample_type="alloc_objects")
  assert_eq(top_objs.total, 3L)

  // Verify round-trip encoding to standard gzipped profile.proto
  let gz = @moon-pprof.encode_profile(profile, gzip=true)
  let rt = @moon-pprof.decode_any_profile(gz)
  let rt_top = @moon-pprof.compute_top(rt)
  assert_eq(rt_top.sample_type, "alloc_space")
  assert_eq(rt_top.total, 24576L)
}
