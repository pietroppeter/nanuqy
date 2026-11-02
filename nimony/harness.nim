when defined(nimony):
  {.feature: "lenientnils".}
## Runs the six generated bench kernels on 10M synthetic rows and prints
## results and timings. Compiles with Nim 2 (nim c) and with Nimony.
import std/[syncio, monotimes]
when not defined(nimony): import std/times
when defined(nimony): include kny
else: include kn2

const n = 10_000_000

proc main() =
  let a = cast[ptr UncheckedArray[int64]](alloc0(n * 8))
  let av = cast[ptr UncheckedArray[uint8]](alloc0((n + 63) div 64 * 8))
  let b = cast[ptr UncheckedArray[float64]](alloc0(n * 8))
  var s = 12345'u64
  for i in 0 ..< n:
    s = s * 6364136223846793005'u64 + 1442695040888963407'u64
    let r = s shr 33
    a[i] = int64(r mod 2001) - 1000
    if r mod 10 != 0: av[i shr 3] = av[i shr 3] or (1'u8 shl (i and 7))
    b[i] = float64(r mod 1000000) / 500000.0 - 1.0
  let outData = alloc0(n * 8)
  let outValid = alloc0((n + 63) div 64 * 8)
  block:
    var best = high(int64)
    var res = KRes()
    for rep in 0 ..< 7:
      zeroMem(outData, n * 8)
      zeroMem(outValid, (n + 63) div 64 * 8)
      res = KRes(data: outData, validity: cast[ptr UncheckedArray[uint8]](outValid))
      let t0 = getMonoTime()
      var kc = [KCol(data: a, validity: av, bitOff: 0), KCol(data: b, validity: nil, bitOff: 0)]
      k0(cast[ptr UncheckedArray[KCol]](addr kc[0]), n, addr res)
      let dt = inNanoseconds(getMonoTime() - t0)
      if dt < best: best = dt
    var chk = 0'u64
    let w = cast[ptr UncheckedArray[uint64]](outData)
    for i in 0 ..< 1000: chk = chk xor w[i * 997]
    echo "k0 ms=", float64(best) / 1e6, " i=", res.i, " u=", res.u, " f=", res.f,
         " nulls=", res.nullCount, " chk=", chk
  block:
    var best = high(int64)
    var res = KRes()
    for rep in 0 ..< 7:
      zeroMem(outData, n * 8)
      zeroMem(outValid, (n + 63) div 64 * 8)
      res = KRes(data: outData, validity: cast[ptr UncheckedArray[uint8]](outValid))
      let t0 = getMonoTime()
      var kc = [KCol(data: a, validity: av, bitOff: 0), KCol(data: b, validity: nil, bitOff: 0)]
      k1(cast[ptr UncheckedArray[KCol]](addr kc[0]), n, addr res)
      let dt = inNanoseconds(getMonoTime() - t0)
      if dt < best: best = dt
    var chk = 0'u64
    let w = cast[ptr UncheckedArray[uint64]](outData)
    for i in 0 ..< 1000: chk = chk xor w[i * 997]
    echo "k1 ms=", float64(best) / 1e6, " i=", res.i, " u=", res.u, " f=", res.f,
         " nulls=", res.nullCount, " chk=", chk
  block:
    var best = high(int64)
    var res = KRes()
    for rep in 0 ..< 7:
      zeroMem(outData, n * 8)
      zeroMem(outValid, (n + 63) div 64 * 8)
      res = KRes(data: outData, validity: cast[ptr UncheckedArray[uint8]](outValid))
      let t0 = getMonoTime()
      var kc = [KCol(data: a, validity: av, bitOff: 0), KCol(data: b, validity: nil, bitOff: 0)]
      k2(cast[ptr UncheckedArray[KCol]](addr kc[0]), n, addr res)
      let dt = inNanoseconds(getMonoTime() - t0)
      if dt < best: best = dt
    var chk = 0'u64
    let w = cast[ptr UncheckedArray[uint64]](outData)
    for i in 0 ..< 1000: chk = chk xor w[i * 997]
    echo "k2 ms=", float64(best) / 1e6, " i=", res.i, " u=", res.u, " f=", res.f,
         " nulls=", res.nullCount, " chk=", chk
  block:
    var best = high(int64)
    var res = KRes()
    for rep in 0 ..< 7:
      zeroMem(outData, n * 8)
      zeroMem(outValid, (n + 63) div 64 * 8)
      res = KRes(data: outData, validity: cast[ptr UncheckedArray[uint8]](outValid))
      let t0 = getMonoTime()
      var kc = [KCol(data: b, validity: nil, bitOff: 0), KCol(data: a, validity: av, bitOff: 0)]
      k3(cast[ptr UncheckedArray[KCol]](addr kc[0]), n, addr res)
      let dt = inNanoseconds(getMonoTime() - t0)
      if dt < best: best = dt
    var chk = 0'u64
    let w = cast[ptr UncheckedArray[uint64]](outData)
    for i in 0 ..< 1000: chk = chk xor w[i * 997]
    echo "k3 ms=", float64(best) / 1e6, " i=", res.i, " u=", res.u, " f=", res.f,
         " nulls=", res.nullCount, " chk=", chk
  block:
    var best = high(int64)
    var res = KRes()
    for rep in 0 ..< 7:
      zeroMem(outData, n * 8)
      zeroMem(outValid, (n + 63) div 64 * 8)
      res = KRes(data: outData, validity: cast[ptr UncheckedArray[uint8]](outValid))
      let t0 = getMonoTime()
      var kc = [KCol(data: a, validity: av, bitOff: 0), KCol(data: b, validity: nil, bitOff: 0)]
      k4(cast[ptr UncheckedArray[KCol]](addr kc[0]), n, addr res)
      let dt = inNanoseconds(getMonoTime() - t0)
      if dt < best: best = dt
    var chk = 0'u64
    let w = cast[ptr UncheckedArray[uint64]](outData)
    for i in 0 ..< 1000: chk = chk xor w[i * 997]
    echo "k4 ms=", float64(best) / 1e6, " i=", res.i, " u=", res.u, " f=", res.f,
         " nulls=", res.nullCount, " chk=", chk
  block:
    var best = high(int64)
    var res = KRes()
    for rep in 0 ..< 7:
      zeroMem(outData, n * 8)
      zeroMem(outValid, (n + 63) div 64 * 8)
      res = KRes(data: outData, validity: cast[ptr UncheckedArray[uint8]](outValid))
      let t0 = getMonoTime()
      var kc = [KCol(data: a, validity: av, bitOff: 0), KCol(data: b, validity: nil, bitOff: 0)]
      k5(cast[ptr UncheckedArray[KCol]](addr kc[0]), n, addr res)
      let dt = inNanoseconds(getMonoTime() - t0)
      if dt < best: best = dt
    var chk = 0'u64
    let w = cast[ptr UncheckedArray[uint64]](outData)
    for i in 0 ..< 1000: chk = chk xor w[i * 997]
    echo "k5 ms=", float64(best) / 1e6, " i=", res.i, " u=", res.u, " f=", res.f,
         " nulls=", res.nullCount, " chk=", chk

main()
