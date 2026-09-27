window.BENCHMARK_DATA = {
  "lastUpdate": 1790528130456,
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
      }
    ]
  }
}