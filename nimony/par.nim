{.feature: "lenientnils".}
## k4 (`a * 2 + b`, nullable output) as Nimony parallel-for loops.
import std/[syncio, monotimes, parfor, bitops]

const n = 10_000_000

proc wmul(a, b: int64): int64 {.inline.} = cast[int64](cast[uint64](a) * cast[uint64](b))

proc k4seq(c0: ptr UncheckedArray[int64], v0: ptr UncheckedArray[uint8], c1: ptr UncheckedArray[float64],
           o: ptr UncheckedArray[float64], ov: ptr UncheckedArray[uint64]) =
  for i in 0 ..< n:
    o[i] = float64(wmul(c0[i], 2)) + c1[i]
  let v64 = cast[ptr UncheckedArray[uint64]](v0)
  for w in 0 ..< (n + 63) div 64:
    ov[w] = v64[w]

proc k4par(c0: ptr UncheckedArray[int64], v0: ptr UncheckedArray[uint8], c1: ptr UncheckedArray[float64],
           o: ptr UncheckedArray[float64], ov: ptr UncheckedArray[uint64]) =
  for i in 0 || (n - 1):
    o[i] = float64(wmul(c0[i], 2)) + c1[i]
  let v64 = cast[ptr UncheckedArray[uint64]](v0)
  for w in 0 ..< (n + 63) div 64:
    ov[w] = v64[w]

proc main() =
  let a = cast[ptr UncheckedArray[int64]](alloc0(n * 8))
  let av = cast[ptr UncheckedArray[uint8]](alloc0((n + 63) div 64 * 8))
  let b = cast[ptr UncheckedArray[float64]](alloc0(n * 8))
  for i in 0 ..< n:
    a[i] = int64(i mod 2001) - 1000
    b[i] = float64(i mod 1000) / 500.0 - 1.0
    if i mod 10 != 0: av[i shr 3] = av[i shr 3] or (1'u8 shl (i and 7))
  let o = cast[ptr UncheckedArray[float64]](alloc0(n * 8))
  let ov = cast[ptr UncheckedArray[uint64]](alloc0((n + 63) div 64 * 8))
  for name in ["seq", "par"]:
    var best = high(int64)
    for rep in 0 ..< 7:
      let t0 = getMonoTime()
      if name == "seq": k4seq(a, av, b, o, ov) else: k4par(a, av, b, o, ov)
      let dt = inNanoseconds(getMonoTime() - t0)
      if dt < best: best = dt
    var s = 0.0
    for i in 0 ..< n: s = s + o[i]
    echo name, " ms=", float64(best) / 1e6, " checksum=", s

main()
