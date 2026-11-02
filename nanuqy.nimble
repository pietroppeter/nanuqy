version       = "0.0.1"
author        = "Pietro Peterlongo"
description   = "Polars expressions compiled to fused Nim kernels through NIF, with Polars (via Nanuq) as fallback and oracle"
license       = "MIT"
srcDir        = "src"

requires "nim >= 2.2.0"
requires "https://github.com/pietroppeter/nanuq >= 0.6.0"

task difftest, "Differential test against Polars (seed, count)":
  exec "nim c -r -d:nanuqLib=prebuilt tests/difftest.nim 1 300"

task bench, "Benchmark against Polars on 10M rows":
  exec "nim c -r -d:release -d:nanuqLib=prebuilt bench/bench.nim"

task udftest, "Nim UDFs inlined into kernels vs mapElements (rows)":
  exec "nim c -r -d:release -d:nanuqLib=prebuilt tests/udftest.nim 1000000"
