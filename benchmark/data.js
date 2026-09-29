window.BENCHMARK_DATA = {
  "lastUpdate": 1790699137385,
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
          "id": "051375192b4716f618c6118f66a3bb4d4974d9d8",
          "message": "release: v0.1.2 — 升版本号至 0.1.2，标记 wire format 对齐与 CI/测试改造发布\n\n本次发布含三项主要变更：协议布局对齐 PHP Yar（header-first, body_len 含\npackager name）、test/ 目录重组为 e2e/benchmark/openresty 三层、CI 接入\nbenchmark-action 与 release 流程优化。升级版本号至 0.1.2 作为发布标记。\n\n1 新建 lua-yar-0.1.2-1.rockspec（source 用 tag 引用）\n2 删除 lua-yar-0.1.0-1.rockspec、lua-yar-0.1.1-3.rockspec\n3 更新 lua-yar-scm-1.rockspec：summary 改为 \"Yar (Yet Another RPC) Framework\"\n4 更新 CHANGELOG.md：新增 v0.1.2 条目（wire format 对齐 / 常量重构 / 测试重组 / CI）\n5 更新 CITATION.cff：version 改 0.1.2，date-released 改 2026-09-30",
          "timestamp": "2026-09-30T00:18:32+08:00",
          "tree_id": "516fe48a43db1598d2edca7ebcb3fe107ecff8f8",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/051375192b4716f618c6118f66a3bb4d4974d9d8"
        },
        "date": 1790699136562,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 132300.85744186,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 71376.619446274,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 142478.75997886,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 190971.99013821,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 137426.06477715,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 74111.18456353,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 146236.88620723,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 117054.89874751,
            "unit": "ops/s"
          }
        ]
      }
    ]
  }
}