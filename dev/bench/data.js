window.BENCHMARK_DATA = {
  "lastUpdate": 1790572384393,
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
          "id": "11d7939e758a830c59fbc92d5748458d06ed1e0c",
          "message": "chore:压测支持",
          "timestamp": "2026-09-28T00:54:43+08:00",
          "tree_id": "16d0ff0f60c11f9c4086f3d52acb9891e75e73cb",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/11d7939e758a830c59fbc92d5748458d06ed1e0c"
        },
        "date": 1790528129526,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 157617.82720673,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 84169.416200929,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 168694.08845306,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 231085.64033831,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 159846.54731458,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 81017.055710568,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 170978.75076086,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 128083.61298256,
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
          "id": "4da5d8084f58c2deb5f9c9b1610f497e557980c1",
          "message": "ci: 接入 benchmark-action 性能看板并集成进文档站\n\n- benchmark.yml: 结果写入 gh-pages 分支 dev/bench/（benchmark-action 看板）\n- docs.yml: 临时仓库隔离拷贝 dev/bench 进 site/（不碰 docs 仓库 .git，无 merge）\n- docs/reports/performance-benchmark.md: 顶部加线上看板链接\n- README(.zh).md: 增加 Benchmark badge\n- test/openresty/Dockerfile: 限定 linux/amd64 + 补 lua5.1 头文件软链",
          "timestamp": "2026-09-28T13:12:34+08:00",
          "tree_id": "728621e079de1c60da24e8b35544beacf690951e",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/4da5d8084f58c2deb5f9c9b1610f497e557980c1"
        },
        "date": 1790572383578,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 190959.95569729,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 102787.70535699,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 206464.82665213,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 285433.74511908,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 181926.01432849,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 95162.871254151,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 203638.61476869,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 170942.5086155,
            "unit": "ops/s"
          }
        ]
      }
    ]
  }
}