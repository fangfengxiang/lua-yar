window.BENCHMARK_DATA = {
  "lastUpdate": 1790846671511,
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
          "id": "90f5620fb0ae349709a0b279cccb4bce96ccf88a",
          "message": "release: v0.1.2 — 升版本号至 0.1.2，标记 wire format 对齐与 CI/测试改造发布\n\n本次发布含三项主要变更：协议布局对齐 PHP Yar（header-first, body_len 含\npackager name）、test/ 目录重组为 e2e/benchmark/openresty 三层、CI 接入\nbenchmark-action 与 release 流程优化。升级版本号至 0.1.2 作为发布标记。\n\n1 新建 lua-yar-0.1.2-1.rockspec（source 用 tag 引用）\n2 删除 lua-yar-0.1.0-1.rockspec、lua-yar-0.1.1-3.rockspec\n3 更新 lua-yar-scm-1.rockspec：summary 改为 \"Yar (Yet Another RPC) Framework\"\n4 更新 CHANGELOG.md：新增 v0.1.2 条目（wire format 对齐 / 常量重构 / 测试重组 / CI）\n5 更新 CITATION.cff：version 改 0.1.2，date-released 改 2026-09-30",
          "timestamp": "2026-09-30T00:33:10+08:00",
          "tree_id": "c37cb93f74091d09f536362b31ed4b4c5dd874f6",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/90f5620fb0ae349709a0b279cccb4bce96ccf88a"
        },
        "date": 1790699649214,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 110174.01986438,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 64073.936196456,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 133362.49526563,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 176642.55495791,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 117433.46806867,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 57428.951772315,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 132329.39432836,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 100907.35897188,
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
          "id": "9b54d71a9daa5fabc5f6036258b4413d06b4b8f3",
          "message": "release: v0.1.2 — 升版本号至 0.1.2，标记 wire format 对齐与 CI/测试改造发布\n\n本次发布含三项主要变更：协议布局对齐 PHP Yar（header-first, body_len 含\npackager name）、test/ 目录重组为 e2e/benchmark/openresty 三层、CI 接入\nbenchmark-action 与 release 流程优化。升级版本号至 0.1.2 作为发布标记。\n\n1 新建 lua-yar-0.1.2-1.rockspec（source 用 tag 引用）\n2 删除 lua-yar-0.1.0-1.rockspec、lua-yar-0.1.1-3.rockspec\n3 更新 lua-yar-scm-1.rockspec：summary 改为 \"Yar (Yet Another RPC) Framework\"\n4 更新 CHANGELOG.md：新增 v0.1.2 条目（wire format 对齐 / 常量重构 / 测试重组 / CI）\n5 更新 CITATION.cff：version 改 0.1.2，date-released 改 2026-09-30",
          "timestamp": "2026-09-30T01:05:13+08:00",
          "tree_id": "e2cef167c9485824205013dacc6c931585874005",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/9b54d71a9daa5fabc5f6036258b4413d06b4b8f3"
        },
        "date": 1790701737346,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 108054.37296047,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 63570.325626279,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 133860.0279232,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 175113.25449735,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 120460.73823159,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 63349.677550141,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 132178.97032582,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 101108.14527218,
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
          "id": "239dd5a20831d3f779068e8a8560c94cfc237f9c",
          "message": "release: v0.1.2 — 升版本号至 0.1.2，标记 wire format 对齐与 CI/测试改造发布\n\n本次发布含三项主要变更：协议布局对齐 PHP Yar（header-first, body_len 含\npackager name）、test/ 目录重组为 e2e/benchmark/openresty 三层、CI 接入\nbenchmark-action 与 release 流程优化。升级版本号至 0.1.2 作为发布标记。\n\n1 新建 lua-yar-0.1.2-1.rockspec（source 用 tag 引用）\n2 删除 lua-yar-0.1.0-1.rockspec、lua-yar-0.1.1-3.rockspec\n3 更新 lua-yar-scm-1.rockspec：summary 改为 \"Yar (Yet Another RPC) Framework\"\n4 更新 CHANGELOG.md：新增 v0.1.2 条目（wire format 对齐 / 常量重构 / 测试重组 / CI）\n5 更新 CITATION.cff：version 改 0.1.2，date-released 改 2026-09-30",
          "timestamp": "2026-09-30T01:13:24+08:00",
          "tree_id": "dacd14a384dbdd3e4527a906b16147e0ba401c7e",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/239dd5a20831d3f779068e8a8560c94cfc237f9c"
        },
        "date": 1790702047186,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 123627.73217288,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 64198.326606419,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 134136.54295253,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 179138.91506307,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 126143.808988,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 63915.733496958,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 135687.05138469,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 99677.443791889,
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
          "id": "511075fdeb77ad54123512e84b1f94cd0c6ecbcb",
          "message": "release: v0.1.2 — 升版本号至 0.1.2，标记 wire format 对齐与 CI/测试改造发布\n\n本次发布含三项主要变更：协议布局对齐 PHP Yar（header-first, body_len 含\npackager name）、test/ 目录重组为 e2e/benchmark/openresty 三层、CI 接入\nbenchmark-action 与 release 流程优化。升级版本号至 0.1.2 作为发布标记。\n\n1 新建 lua-yar-0.1.2-1.rockspec（source 用 tag 引用）\n2 删除 lua-yar-0.1.0-1.rockspec、lua-yar-0.1.1-3.rockspec\n3 更新 lua-yar-scm-1.rockspec：summary 改为 \"Yar (Yet Another RPC) Framework\"\n4 更新 CHANGELOG.md：新增 v0.1.2 条目（wire format 对齐 / 常量重构 / 测试重组 / CI）\n5 更新 CITATION.cff：version 改 0.1.2，date-released 改 2026-09-30",
          "timestamp": "2026-10-01T11:34:15+08:00",
          "tree_id": "a22e9518b831a245e14281454df991eee62a8129",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/511075fdeb77ad54123512e84b1f94cd0c6ecbcb"
        },
        "date": 1790825786883,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 132403.15702088,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 74008.015068032,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 146913.85412336,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 201903.5466377,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 139737.40546765,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 75461.105082607,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 147960.51229848,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 122035.45374002,
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
          "id": "0a9f29babfa2307f2c468727e463602bc4f18d47",
          "message": "release: v0.1.2 — 升版本号至 0.1.2，标记 wire format 对齐与 CI/测试改造发布\n\n本次发布含三项主要变更：协议布局对齐 PHP Yar（header-first, body_len 含\npackager name）、test/ 目录重组为 e2e/benchmark/openresty 三层、CI 接入\nbenchmark-action 与 release 流程优化。升级版本号至 0.1.2 作为发布标记。\n\n1 新建 lua-yar-0.1.2-1.rockspec（source 用 tag 引用）\n2 删除 lua-yar-0.1.0-1.rockspec、lua-yar-0.1.1-3.rockspec\n3 更新 lua-yar-scm-1.rockspec：summary 改为 \"Yar (Yet Another RPC) Framework\"\n4 更新 CHANGELOG.md：新增 v0.1.2 条目（wire format 对齐 / 常量重构 / 测试重组 / CI）\n5 更新 CITATION.cff：version 改 0.1.2，date-released 改 2026-09-30",
          "timestamp": "2026-10-01T12:38:24+08:00",
          "tree_id": "339cbb5ae90031ddb41704e33398852799b51fee",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/0a9f29babfa2307f2c468727e463602bc4f18d47"
        },
        "date": 1790829676893,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 155838.48899001,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 86241.021231677,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 174387.37714409,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 236455.25202583,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 163232.79281515,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 89190.789802282,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 174940.78254511,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 142534.60740268,
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
          "id": "405c64b213a81e899859ba67d69775b3830bbfbb",
          "message": "release: v0.1.2 — 升版本号至 0.1.2，标记 wire format 对齐与 CI/测试改造发布\n\n本次发布含三项主要变更：协议布局对齐 PHP Yar（header-first, body_len 含\npackager name）、test/ 目录重组为 e2e/benchmark/openresty 三层、CI 接入\nbenchmark-action 与 release 流程优化。升级版本号至 0.1.2 作为发布标记。\n\n1 新建 lua-yar-0.1.2-1.rockspec（source 用 tag 引用）\n2 删除 lua-yar-0.1.0-1.rockspec、lua-yar-0.1.1-3.rockspec\n3 更新 lua-yar-scm-1.rockspec：summary 改为 \"Yar (Yet Another RPC) Framework\"\n4 更新 CHANGELOG.md：新增 v0.1.2 条目（wire format 对齐 / 常量重构 / 测试重组 / CI）\n5 更新 CITATION.cff：version 改 0.1.2，date-released 改 2026-09-30",
          "timestamp": "2026-10-01T12:45:38+08:00",
          "tree_id": "ee6c23a3dc2733786386d8c39b8307688251f191",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/405c64b213a81e899859ba67d69775b3830bbfbb"
        },
        "date": 1790840686731,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 156409.34201718,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 83514.629675253,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 171434.54714707,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 232583.02050917,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 160865.84432047,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 80376.031224481,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 171408.98183065,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 125246.42233595,
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
          "id": "f7c187866d328d0c462de534f35bc1f44d07ce49",
          "message": "release: v0.1.2 — 升版本号至 0.1.2，标记 wire format 对齐与 CI/测试改造发布\n\n本次发布含三项主要变更：协议布局对齐 PHP Yar（header-first, body_len 含\npackager name）、test/ 目录重组为 e2e/benchmark/openresty 三层、CI 接入\nbenchmark-action 与 release 流程优化。升级版本号至 0.1.2 作为发布标记。\n\n1 新建 lua-yar-0.1.2-1.rockspec（source 用 tag 引用）\n2 删除 lua-yar-0.1.0-1.rockspec、lua-yar-0.1.1-3.rockspec\n3 更新 lua-yar-scm-1.rockspec：summary 改为 \"Yar (Yet Another RPC) Framework\"\n4 更新 CHANGELOG.md：新增 v0.1.2 条目（wire format 对齐 / 常量重构 / 测试重组 / CI）\n5 更新 CITATION.cff：version 改 0.1.2，date-released 改 2026-09-30",
          "timestamp": "2026-10-01T17:21:09+08:00",
          "tree_id": "bffd415b4293b46ba0bf3e63a1ef3270dd542048",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/f7c187866d328d0c462de534f35bc1f44d07ce49"
        },
        "date": 1790846670947,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 157128.44621965,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 87472.686653592,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 174335.08598206,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 239118.89469682,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 166801.21965052,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 89608.464774016,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 176993.03001448,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 143815.77774134,
            "unit": "ops/s"
          }
        ]
      }
    ]
  }
}