window.BENCHMARK_DATA = {
  "lastUpdate": 1790572855087,
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
          "id": "e6648c76659441bb27cc083721823cca9138bb71",
          "message": "ci: 性能看板落地 /perf/bench/ 并修正 README badge 为真实站点地址\n\n- benchmark.yml: 显式设置 benchmark-data-dir-path: perf/bench（看板 index.html+data.js 写到 gh-pages perf/bench/）\n- docs.yml: 隔离拷贝目标改为 site/perf/bench/（与 benchmark-data-dir-path 一致，无需路径重映射）\n- docs/reports/performance-benchmark.md: 看板链接改为 /perf/bench/\n- README(.zh).md: Benchmark badge 由 bencher.dev 改为真实站点 https://.../lua-yar/perf/bench/",
          "timestamp": "2026-09-28T13:20:26+08:00",
          "tree_id": "fa590234e901611abcc818affaff881bb6a78a23",
          "url": "https://github.com/fangfengxiang/lua-yar/commit/e6648c76659441bb27cc083721823cca9138bb71"
        },
        "date": 1790572854172,
        "tool": "customBiggerIsBetter",
        "benches": [
          {
            "name": "Json.pack",
            "value": 133060.82476422,
            "unit": "ops/s"
          },
          {
            "name": "Json.unpack",
            "value": 70115.6557742,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.pack",
            "value": 145888.49742142,
            "unit": "ops/s"
          },
          {
            "name": "Msgpack.unpack",
            "value": 192209.00037865,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (JSON)",
            "value": 135327.51966309,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (JSON)",
            "value": 71508.763398955,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.render (Msgpack)",
            "value": 142631.37776206,
            "unit": "ops/s"
          },
          {
            "name": "Protocol.parse (Msgpack)",
            "value": 114581.13719487,
            "unit": "ops/s"
          }
        ]
      }
    ]
  }
}