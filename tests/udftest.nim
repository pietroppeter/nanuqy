## Nim procs inlined into generated kernels ({.nimKernel.} + nimCall), checked
## against the same procs run by Polars through nanuq's mapElements (the
## callback route), and timed against both mapElements and native Polars.
##
##   nim c -r -d:release -d:nanuqLib=prebuilt tests/udftest.nim [rows]

import std/[math, random, options, os, strutils, monotimes, times, strformat]
import nanuq, nanuq/testing
import nanuqy

proc toFeet(m: float64): float64 {.nimKernel.} = m * 3.28084

proc haversine(lat1, lon1, lat2, lon2: float64): float64 {.nimKernel.} =
  ## great-circle distance in km
  let p1 = lat1 * PI / 180
  let p2 = lat2 * PI / 180
  let dp = (lat2 - lat1) * PI / 180
  let dl = (lon2 - lon1) * PI / 180
  let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
  2 * 6371.0 * arcsin(sqrt(a))

proc collatzSteps(n: int64): int64 {.nimKernel.} =
  ## a loop with data-dependent length: not expressible as a Polars expression
  var x = n
  while x > 1:
    x = (if x mod 2 == 0: x div 2 else: 3 * x + 1)
    inc result

type Trip = object
  lat1, lon1, lat2, lon2: float

proc frame(n: int, nulls: bool): DataFrame =
  var rng = initRand(7)
  var m: seq[Option[float]]
  var la1, lo1, la2, lo2: seq[float]
  var k: seq[int]
  for i in 0 ..< n:
    m.add (if nulls and rng.rand(1.0) < 0.1: none(float) else: some(rng.rand(0.0 .. 4800.0)))
    la1.add rng.rand(-80.0 .. 80.0); lo1.add rng.rand(-180.0 .. 180.0)
    la2.add rng.rand(-80.0 .. 80.0); lo2.add rng.rand(-180.0 .. 180.0)
    k.add rng.rand(1 .. 100_000)
  newDataFrame(series("m", m), series("lat1", la1), series("lon1", lo1),
               series("lat2", la2), series("lon2", lo2), series("k", k))

proc timed(body: proc (): seq[Series]): (float, seq[Series]) =
  var best = Inf
  for _ in 1 .. 3:
    let t = getMonoTime()
    result[1] = body()
    best = min(best, (getMonoTime() - t).inNanoseconds.float / 1e6)
  result[0] = best

when isMainModule:
  let n = if paramCount() >= 1: parseInt(paramStr(1)) else: 1_000_000
  # correctness first, with nulls and on a sliced frame (Arrow offsets)
  for (label, df) in [("with nulls", frame(5000, true)), ("sliced", frame(5000, true).slice(13, 4000))]:
    let got = df.nimSelect(nimCall("toFeet", col("m")), nimCall("toFeet", col("m")).sum,
                           nimCall("haversine", col("lat1"), col("lon1"), col("lat2"), col("lon2")),
                           nimCall("collatzSteps", col("k")))
    let want = @[
      df.select(col("m").mapElements(proc (x: float): float = toFeet(x))).getColumn("m"),
      df.select(col("m").mapElements(proc (x: float): float = toFeet(x)).sum).getColumn("m"),
      df.select(asStruct("lat1", "lon1", "lat2", "lon2").mapElements(proc (t: Trip): float =
        haversine(t.lat1, t.lon1, t.lat2, t.lon2))).getColumn("lat1"),
      df.select(col("k").mapElements(proc (x: int): int = collatzSteps(x).int)).getColumn("k")]
    doAssert stats.nimKernels == 4, $stats
    for i in 0 ..< want.len:
      assertSeriesEqual(got[i], want[i], checkNames = false, rtol = 1e-12)
    echo label, ": 4 UDF kernels agree with mapElements"

  let df = frame(n, false)
  echo &"\n{n} rows, best of 3 (ms)          Nim kernel   mapElements   native Polars"
  proc row(name: string, nim: proc (): seq[Series], cb: proc (): seq[Series], native: proc (): seq[Series]) =
    let (tn, _) = timed(nim)
    let (tc, _) = timed(cb)
    let tp = if native.isNil: "-" else: formatFloat(timed(native)[0], ffDecimal, 1)
    echo &"{name:<32} {tn:10.1f} {tc:13.1f} {tp:>15}"
  row("m * 3.28084",
      proc (): seq[Series] = df.nimSelect(nimCall("toFeet", col("m"))),
      proc (): seq[Series] = @[df.select(col("m").mapElements(proc (x: float): float = toFeet(x))).getColumn("m")],
      proc (): seq[Series] = @[df.select(col("m") * 3.28084).getColumn("m")])
  row("haversine (4 columns)",
      proc (): seq[Series] = df.nimSelect(nimCall("haversine", col("lat1"), col("lon1"), col("lat2"), col("lon2"))),
      proc (): seq[Series] = @[df.select(asStruct("lat1", "lon1", "lat2", "lon2").mapElements(proc (t: Trip): float =
        haversine(t.lat1, t.lon1, t.lat2, t.lon2))).getColumn("lat1")],
      proc (): seq[Series] =
        let r = PI / 180
        let dp = (col("lat2") - col("lat1")) * r
        let dl = (col("lon2") - col("lon1")) * r
        let a = (dp / 2).sin * (dp / 2).sin + (col("lat1") * r).cos * (col("lat2") * r).cos * (dl / 2).sin * (dl / 2).sin
        @[df.select((a.sqrt.arcsin * (2 * 6371.0)).alias("d")).getColumn("d")])
  row("haversine, then sum",
      proc (): seq[Series] = df.nimSelect(nimCall("haversine", col("lat1"), col("lon1"), col("lat2"), col("lon2")).sum),
      proc (): seq[Series] = @[df.select(asStruct("lat1", "lon1", "lat2", "lon2").mapElements(proc (t: Trip): float =
        haversine(t.lat1, t.lon1, t.lat2, t.lon2)).sum).getColumn("lat1")],
      nil)
  row("collatz steps (a while loop)",
      proc (): seq[Series] = df.nimSelect(nimCall("collatzSteps", col("k"))),
      proc (): seq[Series] = @[df.select(col("k").mapElements(proc (x: int): int = collatzSteps(x).int)).getColumn("k")],
      nil)
