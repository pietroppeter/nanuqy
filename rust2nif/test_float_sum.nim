## Is the Nim translated from Polars' own Rust (float_sum.rs -> NIF -> Nim)
## the same algorithm? Floating point addition is not associative, so only the
## exact same summation order gives the same bits. We compare the bit patterns
## of Polars' `col("x").sum()` and of the translated `sum_arr_as_f64` on the
## same Arrow buffers, and also show that a plain left-to-right loop does not
## match (so agreement is not luck).
##
## Polars itself is only deterministic on one thread with the in-memory
## engine: with more threads, or the streaming engine (which `Auto` picks for
## large frames), it splits the column into pieces summed in parallel and the
## last bit can change from run to run. So the oracle runs with
## POLARS_MAX_THREADS=1 and Engine.InMemory.
##
##   nim c -r -d:danger -d:nanuqLib=prebuilt rust2nif/test_float_sum.nim [seed] [cases]

import std/[random, options, os, strutils, math, monotimes, times]
import nanuq
import rshim, float_sum_gen

proc bits(x: float64): uint64 = cast[uint64](x)

proc view(s: Series): (PrimitiveArray[float64], ArrowExport) =
  let ex = s.toArrow
  let a = ex.array
  let vals = toSlice[float64](cast[pointer](cast[int](a.buffers[1]) + a.offset.int * 8), a.length.int)
  var valid = none(Bitmap)
  if a.buffers[0] != nil:
    valid = some(Bitmap(bytes: cast[ptr UncheckedArray[uint8]](a.buffers[0]),
                        offset: a.offset.int, n: a.length.int))
  (PrimitiveArray[float64](vals: vals, valid: valid, nulls: a.nullCount.int), ex)

proc naive(s: Series): float64 =
  ## what a hand-written kernel would do
  let (arr, _) = view(s)
  result = -0.0
  for i in 0 ..< arr.vals.len:
    if arr.valid.isNone or arr.valid.get.get(i): result += arr.vals[i]

var rng: Rand

proc value(): float64 =
  case rng.rand(9)
  of 0: rng.rand(1.0) * 1e16          # large magnitudes make rounding order-sensitive
  of 1: -rng.rand(1.0) * 1e16
  of 2: -0.0
  of 3: rng.rand(1e-3)
  else: rng.rand(-1000.0 .. 1000.0)

proc polarsSum(df: DataFrame): float64 =
  df.lazy.select(col("x").sum).collect(Engine.InMemory).getColumn("x").item(float64)

when isMainModule:
  putEnv("POLARS_MAX_THREADS", "1")   # before the first Polars call
  let seed = if paramCount() >= 1: parseInt(paramStr(1)) else: 2026
  let cases = if paramCount() >= 2: parseInt(paramStr(2)) else: 400
  rng = initRand(seed)
  const lens = [0, 1, 2, 15, 16, 127, 128, 129, 255, 256, 257, 383, 384, 1000, 4096, 10_000, 100_003, 1_000_000]
  var same, differ, naiveSame, total = 0
  for c in 0 ..< cases:
    let n = if c < lens.len * 2: lens[c mod lens.len] else: rng.rand(0 .. 20_000)
    let nullRate = if c mod 2 == 0: 0.0 else: rng.sample([0.01, 0.3, 0.9, 1.0])
    var xs: seq[Option[float64]]
    for _ in 0 ..< n:
      xs.add (if rng.rand(1.0) < nullRate: none(float64) else: some(value()))
    var s = series("x", xs)
    if n > 40 and rng.rand(1.0) < 0.5:           # an Arrow offset (sliced view)
      let lo = rng.rand(1 .. 37)
      s = newDataFrame(s).slice(lo, n - lo - rng.rand(0 .. 3)).getColumn("x")
    let df = newDataFrame(s)
    let want = polarsSum(df)
    let (arr, keep) = view(s)
    let got = sum_arr_as_f64(arr)
    discard keep
    inc total
    if bits(got) == bits(want): inc same
    else:
      inc differ
      if differ <= 5: echo "  DIFFER n=", s.len, " nulls=", s.nullCount, " polars=", want, " nim=", got
    if bits(naive(s)) == bits(want): inc naiveSame
  echo total, " arrays: translated Polars kernel bit-identical in ", same, ", different in ", differ,
       "; a plain loop is bit-identical in only ", naiveSame
  # speed on 10M values, no nulls
  var big = newSeq[float64](10_000_000)
  for v in big.mitems: v = value()
  let bs = series("x", big)
  let bdf = newDataFrame(bs)
  let (barr, bkeep) = view(bs)
  discard bkeep
  var t0 = getMonoTime()
  var w: float64
  for _ in 0 ..< 10: w = polarsSum(bdf)
  let tp = (getMonoTime() - t0).inNanoseconds.float / 1e7
  t0 = getMonoTime()
  var g: float64
  for _ in 0 ..< 10: g = sum_arr_as_f64(barr)
  let tn = (getMonoTime() - t0).inNanoseconds.float / 1e7
  echo "10M values, one thread: Polars ", formatFloat(tp, ffDecimal, 2), " ms, translated Nim ",
       formatFloat(tn, ffDecimal, 2), " ms, same bits: ", bits(w) == bits(g)
  if differ > 0: quit 1
