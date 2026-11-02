## Timing: Polars (`df.select(e)`) against the generated Nim kernels
## (`df.nimSelect(e)`, compiled once, then cached) on 10 million rows.
## Polars runs multi-threaded; the kernels are one plain loop on one thread.
## Run with POLARS_MAX_THREADS=1 for a single-threaded Polars.
##
##   nim c -r -d:release -d:nanuqLib=prebuilt bench.nim

import std/[times, monotimes, random, options, strutils, os]
import nanuq
import nanuqy

proc best(f: proc ()): float =
  result = Inf
  for _ in 0 ..< 7:
    let t0 = getMonoTime()
    f()
    result = min(result, (getMonoTime() - t0).inNanoseconds.float / 1e6)

when isMainModule:
  let n = 10_000_000
  var r = initRand(7)
  var a: seq[Option[int]]
  var b: seq[float]
  for i in 0 ..< n:
    a.add (if r.rand(1.0) < 0.1: none(int) else: some(r.rand(-1000 .. 1000)))
    b.add r.rand(-1.0 .. 1.0)
  let df = newDataFrame(series("a", a), series("b", b))
  let queries = [
    ("sum of an expression", (col("a") * lit(2) + col("b")).sum()),
    ("filtered mean", col("a").filter(col("b") > lit(0)).mean()),
    ("ratio of two aggregations", col("a").sum() / col("b").mean()),
    ("filtered count, two predicates", col("b").filter((col("a") > lit(10)) and (col("b") < lit(0.5))).count()),
    ("elementwise column", col("a") * lit(2) + col("b")),
    ("boolean column", (col("a") > lit(0)) or (col("b") < lit(0)))]
  # Compile all kernels once (the cache makes later calls skip this).
  var es: seq[Expr]
  for (_, e) in queries: es.add e
  discard df.nimSelect(es)
  echo "kernel compilation (6 kernels, one library): ", formatFloat(stats.compileSeconds, ffDecimal, 2), " s",
       " (POLARS_MAX_THREADS=", getEnv("POLARS_MAX_THREADS", "default"), ", rows=", n, ")"
  echo "| query | Polars ms | Nim kernel ms | of which in the loop | ratio |"
  echo "|---|---:|---:|---:|---:|"
  for (name, e) in queries:
    discard df.nimSelect(e)  # compile this single-kernel library once
    let p = best(proc () = discard df.select(e))
    var loopMs = Inf
    let k = best(proc () =
      discard df.nimSelect(e)
      loopMs = min(loopMs, stats.kernelMs))
    echo "| ", name, " | ", formatFloat(p, ffDecimal, 1), " | ", formatFloat(k, ffDecimal, 1), " | ",
         formatFloat(loopMs, ffDecimal, 1), " | ",
         formatFloat(p / k, ffDecimal, 2), "x |"
