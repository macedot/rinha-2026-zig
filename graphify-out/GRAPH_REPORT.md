# Graph Report - .  (2026-05-11)

## Corpus Check
- cluster-only mode — file stats not available

## Summary
- 150 nodes · 278 edges · 15 communities (13 shown, 2 thin omitted)
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 16 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Graph Freshness
- Built from commit: `12fd35f8`
- Run `git rev-parse HEAD` and compare to check if the graph is stale.
- Run `graphify update .` after code changes (no API cost).

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]

## God Nodes (most connected - your core abstractions)
1. `rinha_search()` - 14 edges
2. `build()` - 12 edges
3. `main()` - 8 edges
4. `search()` - 8 edges
5. `isoToEpochSeconds()` - 8 edges
6. `rinha_set_search_params()` - 7 edges
7. `main()` - 7 edges
8. `test_instrumentation()` - 6 edges
9. `kmeansPlusPlusInit()` - 6 edges
10. `scanBlocksAvx2()` - 6 edges

## Surprising Connections (you probably didn't know these)
- `test_instrumentation()` --calls--> `rinha_get_inst()`  [INFERRED]
  bridge/test/test_bridge.c → bridge/bridge.c
- `test_instrumentation()` --calls--> `rinha_reset_inst()`  [INFERRED]
  bridge/test/test_bridge.c → bridge/bridge.c
- `writeIndex()` --calls--> `writeAll()`  [INFERRED]
  zig/src/build_index.zig → zig/src/http_server.zig
- `test_load_index()` --calls--> `rinha_load_index()`  [INFERRED]
  bridge/test/test_bridge.c → bridge/bridge.c
- `test_search_basic()` --calls--> `rinha_set_search_params()`  [INFERRED]
  bridge/test/test_bridge.c → bridge/bridge.c

## Communities (15 total, 2 thin omitted)

### Community 0 - "Community 0"
Cohesion: 0.14
Nodes (29): centroid_sqdist_scalar(), compute_centroid_dists_avx2(), compute_centroid_dists_scalar(), count_frauds5(), get_nanos(), insert_probe_cluster(), quantize_fixed(), read_exact() (+21 more)

### Community 1 - "Community 1"
Cohesion: 0.24
Nodes (22): arrayContainsString(), build(), clamp01(), daysFromCivil(), findChar(), findKeyRange(), isoDay(), isoHourUTC() (+14 more)

### Community 2 - "Community 2"
Cohesion: 0.21
Nodes (17): computeCentroidDistsAvx2(), computeCentroidDistsScalar(), countFrauds5(), dimFma(), loadBlock8I16(), prefetch(), quantize(), scanBlocks() (+9 more)

### Community 3 - "Community 3"
Cohesion: 0.23
Nodes (12): assignParallel(), distSq(), Item, kmeansPlusPlusInit(), Lcg, main(), nearestCentroid(), parseReferences() (+4 more)

### Community 4 - "Community 4"
Cohesion: 0.25
Nodes (9): createSocket(), createTcpSocket(), createUdsSocket(), __errno_location(), findContentLength(), getErrno(), octalFromDecimal(), Server (+1 more)

### Community 6 - "Community 6"
Cohesion: 0.54
Nodes (7): Config, envBool(), envFloat(), envInt(), envStr(), getenvZ(), load()

### Community 7 - "Community 7"
Cohesion: 0.73
Nodes (5): benchCBridge(), benchPureZig(), main(), nanos(), searchInstrumented()

## Knowledge Gaps
- **2 isolated node(s):** `Item`, `Config`
  These have ≤1 connection - possible missing edges or undocumented components.
- **2 thin communities (<3 nodes) omitted from report** — run `graphify query` to explore isolated nodes.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `writeAll()` connect `Community 4` to `Community 3`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Why does `writeIndex()` connect `Community 3` to `Community 4`?**
  _High betweenness centrality (0.022) - this node is a cross-community bridge._
- **Are the 6 inferred relationships involving `rinha_search()` (e.g. with `test_search_basic()` and `test_search_consistency()`) actually correct?**
  _`rinha_search()` has 6 INFERRED edges - model-reasoned connections that need verification._
- **What connects `Item`, `Config` to the rest of the system?**
  _2 weakly-connected nodes found - possible documentation gaps or missing edges._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.14 - nodes in this community are weakly interconnected._