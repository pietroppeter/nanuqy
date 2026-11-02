## The safety net: random expressions from the supported subset, evaluated by
## the generated Nim kernels and by Polars, must give the same Series (name,
## type, values, nulls; floats within 1e-9 relative, NaN equals NaN).
## Polars is the oracle: any difference is a bug in sem.nim / nif2nim.nim.
##
##   nim c -r -d:nanuqLib=prebuilt difftest.nim [seed] [count]

import std/[random, options, os, strutils, math]
import nanuq, nanuq/testing
import nanuqy

var rng: Rand

proc pick[T](xs: openArray[T]): T = xs[rng.rand(xs.high)]

proc dynLit(): Expr =
  if rng.rand(1.0) < 0.5: lit(rng.rand(-5 .. 5)) else: lit(pick([0.5, -2.25, 3.0, 0.0, 1e300]))

proc num(depth: int): Expr
proc pred(depth: int): Expr =
  if depth > 0 and rng.rand(1.0) < 0.3:
    let a = pred(depth - 1)
    let b = pred(depth - 1)
    return (if rng.rand(1.0) < 0.5: a and b else: a or b)
  let a = num(depth - 1)
  let b = if rng.rand(1.0) < 0.5: dynLit() else: num(depth - 1)
  case rng.rand(5)
  of 0: a > b
  of 1: a >= b
  of 2: a < b
  of 3: a <= b
  of 4: a == b
  else: a != b

proc num(depth: int): Expr =
  if depth <= 0 or rng.rand(1.0) < 0.3:
    return col(pick(["i", "j", "x", "y", "big"]))
  case rng.rand(6)
  of 0: -num(depth - 1)
  of 1: num(depth - 1).abs
  else:
    let a = num(depth - 1)
    let b = if rng.rand(1.0) < 0.4: dynLit() else: num(depth - 1)
    let (l, r) = (if rng.rand(1.0) < 0.2: (b, a) else: (a, b))
    case rng.rand(3)
    of 0: l + r
    of 1: l - r
    of 2: l * r
    else: l / r

proc agg(depth: int): Expr =
  var x = num(depth)
  if rng.rand(1.0) < 0.4: x = x.filter(pred(depth))
  case rng.rand(5)
  of 0: x.sum
  of 1: x.mean
  of 2: x.min
  of 3: x.max
  of 4: x.count
  else: x.len

proc scalar(depth: int): Expr =
  if depth > 0 and rng.rand(1.0) < 0.3:
    let a = scalar(depth - 1)
    let b = if rng.rand(1.0) < 0.5: dynLit() else: scalar(depth - 1)
    return (case rng.rand(3)
            of 0: a + b
            of 1: a - b
            of 2: a * b
            else: a / b)
  agg(depth)

proc gen(): Expr =
  result = case rng.rand(2)
           of 0: num(3)
           of 1: pred(3)
           else: scalar(3)
  if rng.rand(1.0) < 0.1: result = result.alias("out")

proc testFrame(n: int): DataFrame =
  var i, big: seq[Option[int]]
  var j: seq[int]
  var x: seq[Option[float]]
  var y: seq[float]
  for k in 0 ..< n:
    i.add (if rng.rand(1.0) < 0.1: none(int) else: some(rng.rand(-20 .. 20)))
    j.add rng.rand(-3 .. 3)
    big.add (if rng.rand(1.0) < 0.05: none(int) else: some(pick([high(int), low(int), high(int) div 3, 7])))
    x.add (if rng.rand(1.0) < 0.1: none(float)
           elif rng.rand(1.0) < 0.05: some(NaN)
           else: some(pick([-0.0, 0.0, 1.5, -7.25, 1e-300]) + rng.rand(10.0)))
    y.add rng.rand(-100.0 .. 100.0)
  newDataFrame(series("i", i), series("j", j), series("x", x), series("y", y), series("big", big))

proc check(df: DataFrame, exprs: seq[Expr], label: string): (int, int, int) =
  ## (agreeing, disagreeing, Polars errors). Kernels Polars rejects are skipped.
  var ok, bad, polarsErr = 0
  var want: seq[Option[Series]]
  var valid: seq[Expr]
  for e in exprs:
    try:
      let r = df.select(e)
      valid.add e
      want.add some(r.getColumn(r.columns[0]))
    except CatchableError:
      inc polarsErr
  let got = df.nimSelect(valid)
  for k, e in valid:
    try:
      assertSeriesEqual(got[k], want[k].get, rtol = 1e-9, atol = 1e-300)
      inc ok
    except AssertionDefect as err:
      inc bad
      if bad <= 8:
        echo "  MISMATCH [", label, "] ", e
        echo "    ", err.msg.splitLines[0]
  echo label, ": ", ok, " agree, ", bad, " differ, ", polarsErr, " rejected by Polars, ",
       stats.nimKernels, " ran as Nim kernels, ", stats.polarsFallbacks, " fell back to Polars",
       (if stats.cached: " (kernels cached)" else: " (kernels compiled in " & formatFloat(stats.compileSeconds, ffDecimal, 1) & " s)")
  (ok, bad, polarsErr)

when isMainModule:
  let seed = if paramCount() >= 1: parseInt(paramStr(1)) else: 2026
  let count = if paramCount() >= 2: parseInt(paramStr(2)) else: 300
  rng = initRand(seed)
  var exprs: seq[Expr]
  for _ in 0 ..< count: exprs.add gen()
  let df = testFrame(2000)
  var bad = 0
  bad += check(df, exprs, "full frame")[1]
  bad += check(df.slice(37, 1500), exprs, "sliced frame (Arrow offsets)")[1]
  bad += check(df.slice(0, 0), exprs, "empty frame")[1]
  bad += check(df.filter(col("i").isNull), exprs, "only-null rows")[1]
  if paramCount() >= 3:
    for r in stats.fallbackReasons: echo "  fallback: ", r
  if bad > 0: quit "differences found", 1
