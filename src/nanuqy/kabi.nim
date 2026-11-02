## The ABI between the host (jit.nim) and the generated kernels, plus the
## few helpers generated code calls. nif2nim.nim pastes this file at the top of
## every generated module, so host and kernels always agree on the layout.

import std/bitops

{.push raises: [].}  # no exception checks inside the row loops

type
  KCol* {.bycopy.} = object
    ## One input column: its values (Arrow offset already applied) and Arrow
    ## validity bitmap (nil when the column has no nulls).
    data*: pointer
    validity*: ptr UncheckedArray[uint8]
    bitOff*: int
  KRes* {.bycopy.} = object
    ## The output. Columns: `data`/`validity` are allocated by the host, the
    ## kernel fills them and sets `nullCount`. Scalars: `i`/`u`/`f`, `isNull`.
    data*: pointer
    validity*: ptr UncheckedArray[uint8]
    nullCount*: int
    i*: int64
    u*: uint64
    f*: float64
    isNull*: bool
  KernelProc* = proc (cols: ptr UncheckedArray[KCol], n: int, res: ptr KRes) {.cdecl, gcsafe, raises: [].}

template isValid*(c: KCol, i: int): bool =
  c.validity == nil or ((c.validity[(c.bitOff + i) shr 3] shr ((c.bitOff + i) and 7)) and 1'u8) != 0

template isValid*(v: ptr UncheckedArray[uint8], off, i: int): bool =
  ((v[(off + i) shr 3] shr ((off + i) and 7)) and 1'u8) != 0

proc setBit*(p: ptr UncheckedArray[uint8], i: int) {.inline.} =
  p[i shr 3] = p[i shr 3] or (1'u8 shl (i and 7))

# Nim's `and`/`or` short-circuit, which becomes a branch per row; on random
# data those mispredict about half the time. Generated code uses these
# branch-free versions instead.
template `&&`*(a, b: bool): bool = cast[bool](uint8(a) and uint8(b))
template `||`*(a, b: bool): bool = cast[bool](uint8(a) or uint8(b))

proc keep*(take: bool, x: float64): float64 {.inline.} =
  ## `x` if `take`, else +0.0, with a bit mask instead of a branch (gcc keeps
  ## a branch for a float `if`, which mispredicts on filters).
  cast[float64](cast[uint64](x) and (0'u64 - uint64(take)))
proc keep*(take: bool, x: int64): int64 {.inline.} = x and (0'i64 - int64(take))

proc orBit*(p: ptr UncheckedArray[uint8], i: int, b: bool) {.inline.} =
  ## Branch-free: ORs bit `i` with `b` (the buffer starts zeroed).
  p[i shr 3] = p[i shr 3] or (uint8(b) shl (i and 7))

# Polars integer arithmetic wraps around; in Nim (and C) signed overflow must
# not happen, so go through uint64.
proc wadd*(a, b: int64): int64 {.inline.} = cast[int64](cast[uint64](a) + cast[uint64](b))
proc wsub*(a, b: int64): int64 {.inline.} = cast[int64](cast[uint64](a) - cast[uint64](b))
proc wmul*(a, b: int64): int64 {.inline.} = cast[int64](cast[uint64](a) * cast[uint64](b))
proc wneg*(a: int64): int64 {.inline.} = cast[int64](0'u64 - cast[uint64](a))
proc wabs*(a: int64): int64 {.inline.} = (if a < 0: wneg(a) else: a)

# Polars compares floats with a total order: NaN equals NaN and is greater than
# every other value; -0.0 equals 0.0. (Found by difftest.nim, see README.)
proc feq*(a, b: float64): bool {.inline.} =
  # Bitwise and/or on uint8 instead of `and`/`or`: no branches.
  ((uint8(a == b)) or (uint8(a != a) and uint8(b != b))) != 0
proc flt*(a, b: float64): bool {.inline.} =
  (uint8(a == a) and (uint8(b != b) or uint8(a < b))) != 0
proc fgt*(a, b: float64): bool {.inline.} = flt(b, a)
proc fle*(a, b: float64): bool {.inline.} = not flt(b, a)
proc fge*(a, b: float64): bool {.inline.} = not flt(a, b)
proc fne*(a, b: float64): bool {.inline.} = not feq(a, b)

{.pop.}
