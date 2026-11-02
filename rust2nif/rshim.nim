## Hand-written Nim stand-ins for the Rust std and polars-arrow pieces that
## translated code calls. This is the part a translator cannot derive from the
## Polars source alone: each proc mirrors one Rust API's documented behaviour.

import std/options
export options
import std/enumerate
export enumerate

{.push raises: [].}

type
  RSlice*[T] = object        ## &[T] and &[T; N]: a borrowed view
    p*: ptr UncheckedArray[T]
    n*: int
  RChunks*[T] = object       ## &[[T; N]] from as_chunks
    s*: RSlice[T]
    k*: int
  RRange* = object
    lo*, hi*: int            ## hi == -1: open end
  BitMask* = object          ## polars_arrow::bitmap::bitmask::BitMask
    bytes*: ptr UncheckedArray[uint8]
    offset*, n*: int
  Bitmap* = BitMask          ## the owning Bitmap only matters as a view here

proc toSlice*[T](p: pointer, n: int): RSlice[T] = RSlice[T](p: cast[ptr UncheckedArray[T]](p), n: n)

proc len*[T](s: RSlice[T]): int {.inline.} = s.n
proc `[]`*[T](s: RSlice[T], i: int): T {.inline.} = s.p[i]
iterator iter*[T](s: RSlice[T]): T =
  for i in 0 ..< s.n: yield s.p[i]
iterator items*[T](s: RSlice[T]): T =
  for i in 0 ..< s.n: yield s.p[i]

proc sub[T](s: RSlice[T], lo, hi: int): RSlice[T] {.inline.} =
  RSlice[T](p: cast[ptr UncheckedArray[T]](addr s.p[lo]), n: hi - lo)

proc rrange*(lo, hi: int): RRange = RRange(lo: lo, hi: hi)
proc get_unchecked*[T](s: RSlice[T], r: RRange): RSlice[T] {.inline.} =
  s.sub(r.lo, (if r.hi < 0: s.n else: r.hi))
proc split_at*[T](s: RSlice[T], k: int): (RSlice[T], RSlice[T]) {.inline.} =
  (s.sub(0, k), s.sub(k, s.n))

proc as_chunks*[T](s: RSlice[T], k: static int): (RChunks[T], RSlice[T]) {.inline.} =
  ## <[T]>::as_chunks::<N>: whole chunks first, the remainder last
  let whole = s.n div k * k
  (RChunks[T](s: s.sub(0, whole), k: k), s.sub(whole, s.n))
iterator iter*[T](c: RChunks[T]): RSlice[T] =
  var i = 0
  while i < c.s.n:
    yield c.s.sub(i, i + c.k); i += c.k
iterator items*[T](c: RChunks[T]): RSlice[T] =
  for x in c.iter: yield x

proc tryIntoArr*[T](s: RSlice[T], n: int): Option[RSlice[T]] {.inline.} =
  ## <&[T; N]>::try_from(&[T]).ok()
  if s.n == n: some(s) else: none(RSlice[T])

template rrepeat*(n: static int, v: typed): untyped =
  ## [v; n]
  block:
    var a {.noinit.}: array[n, typeof(v)]
    for i in 0 ..< n: a[i] = v
    a

template rfilter*(o, cond: untyped): untyped =
  ## Option::filter(|_| cond)
  (if cond: o else: typeof(o).default)

# Rust `/` and `%`: integer division truncates; floats divide.
proc rdiv*(a, b: SomeInteger): auto {.inline.} = a div b
proc rdiv*(a, b: SomeFloat): auto {.inline.} = a / b
proc rmod*(a, b: SomeInteger): auto {.inline.} = a mod b

proc rsumInit*(T: typedesc[SomeFloat]): T {.inline.} =
  ## `impl Sum for f64` folds from -0.0 (rust-lang/rust#129321), so that the
  ## sum of [-0.0] is -0.0 and the empty sum is -0.0.
  T(-0.0)

proc from_bitmap*(b: Bitmap): BitMask {.inline.} = b
proc len*(m: BitMask): int {.inline.} = m.n
proc get*(m: BitMask, i: int): bool {.inline.} =
  let j = m.offset + i
  ((m.bytes[j shr 3] shr (j and 7)) and 1) == 1
proc split_at*(m: BitMask, k: int): (BitMask, BitMask) {.inline.} =
  (BitMask(bytes: m.bytes, offset: m.offset, n: k),
   BitMask(bytes: m.bytes, offset: m.offset + k, n: m.n - k))
proc split_at_unchecked*(m: BitMask, k: int): (BitMask, BitMask) {.inline.} = m.split_at(k)

type PrimitiveArray*[T] = object   ## polars_arrow::array::PrimitiveArray, as a view
  vals*: RSlice[T]
  valid*: Option[Bitmap]
  nulls*: int
proc values*[T](a: PrimitiveArray[T]): RSlice[T] {.inline.} = a.vals
proc validity*[T](a: PrimitiveArray[T]): Option[Bitmap] {.inline.} = a.valid
proc null_count*[T](a: PrimitiveArray[T]): int {.inline.} = a.nulls

{.pop.}
