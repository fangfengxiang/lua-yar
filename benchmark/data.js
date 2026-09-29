window.BENCHMARK_DATA = {
  "lastUpdate": 1790644417614,
  "repoUrl": "https://github.com/fangfengxiang/lua-yar",
  "entries": {
    "Benchmark": [
      {
        "commit": {
          "author": {
            "email": "fangfengxiang836@qq.com",
            "name": "fangfengxiang"
          },
          "committer": {
            "email": "fangfengxiang836@qq.com",
            "name": "fangfengxiang"
          },
          "distinct": true,
          "id": "54a7a679a12f935fe60d4872137b07282f6fc2f4",
          "message": "docs: refine rockspec summary to 'Yar (Yet Another RPC) Framework'",
          "timestamp": "2026-09-29T01:14:51+08:00",
          "tree_id": "6b4d00483d1ea514e3ff7122b20839efdc128810",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/54a7a679a12f935fe60d4872137b07282f6fc2f4"
        },
        "date": 1790615742505,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 157313.83480789,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 84076.075396061,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 170324.9629969,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 228341.26058076,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 160441.02027654,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 83086.013965097,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 170133.41862689,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 129954.51591943,
            "unit": "ops/s"
          }
        ]
      },
      {
        "commit": {
          "author": {
            "email": "fangfengxiang836@qq.com",
            "name": "fangfengxiang"
          },
          "committer": {
            "email": "fangfengxiang836@qq.com",
            "name": "fangfengxiang"
          },
          "distinct": true,
          "id": "0d015a8b2d882bcd1bfc375edb4b636b8b7df4c5",
          "message": "docs: generate perf wrapper in CI instead of committing to repo\n\n- Remove docs/perf/index.md from version control\n- Add CI step to generate docs/perf/index.md before mkdocs build\n- mkdocs.yml nav still references perf/index.md (generated in CI)",
          "timestamp": "2026-09-29T09:13:01+08:00",
          "tree_id": "299ab28a36f3a3157a8e6bb4a772d2a0c02a3573",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/0d015a8b2d882bcd1bfc375edb4b636b8b7df4c5"
        },
        "date": 1790644417125,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 116753.00551424,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 64527.535835367,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 132004.4881526,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 176176.37369123,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 122383.44200983,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 63791.702230541,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 134541.69716278,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 101539.95495688,
            "unit": "ops/s"
          }
        ]
      }
    ]
  }
}