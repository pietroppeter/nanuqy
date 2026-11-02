## Step 4: the host (Nim 2). `nimSelect(df, exprs)` evaluates Polars expressions with
## Nim code generated on demand:
##
##   Expr --Polars JSON--> untyped NIF --sem--> typed NIF (written to a .nif file)
##        --nif2nim--> Nim module --nim c --app:lib--> shared library (cached)
##        --dlopen--> kernels run on the frame's Arrow buffers (zero copy)
##        --Arrow C interface--> result Series, back in Polars (zero copy)
##
## Expressions outside the supported subset are evaluated by Polars instead, so
## the result is always complete: the Nim side only takes over what it can.

import std/[os, osproc, strutils, dynlib, hashes, times, options, monotimes]
import nanuq
import nif, polars2nif, sem, nif2nim, kabi

type
  JitStats* = object
    nimKernels*, polarsFallbacks*: int
    fallbackReasons*: seq[string]
    compileSeconds*: float
    kernelMs*: float  # time inside the generated loops only
    cached*: bool
  CompiledLib = object
    lib: LibHandle
    path: string

var stats*: JitStats
var cacheDir* = getTempDir() / "nanuq-nif-cache"
var nimFlags* = "-d:danger --opt:speed --hints:off --warnings:off"

proc nqType(dt: DataType): NqType =
  if dt == Int64: tI64
  elif dt == Float64: tF64
  elif dt == Boolean: tBool
  elif dt == UInt32: tU32
  else: raise newException(Unsupported, "column type " & $dt)

proc schemaOf(df: DataFrame): seq[Input] =
  for name in df.columns:
    try: result.add Input(name: name, typ: nqType(df.dtype(name)),
                          hasNulls: df.getColumn(name).nullCount > 0)
    except Unsupported: discard  # columns of other types simply can't be used

proc compile(module: string): CompiledLib =
  ## Compiles a generated module to a shared library, once per distinct source.
  createDir(cacheDir)
  let h = toHex(hash(module & nimFlags)).toLowerAscii
  let src = cacheDir / ("k_" & h & ".nim")
  let lib = cacheDir / (DynlibFormat % ("k_" & h))
  stats.cached = fileExists(lib)
  if not stats.cached:
    writeFile(src, module)
    let t0 = epochTime()
    let cmd = "nim c --app:lib " & nimFlags & " --nimcache:" & quoteShell(cacheDir / ("nc_" & h)) &
              " -o:" & quoteShell(lib) & " " & quoteShell(src)
    let (output, code) = execCmdEx(cmd)
    stats.compileSeconds = epochTime() - t0
    if code != 0: raise newException(OSError, "kernel compilation failed:\n" & output)
  else:
    stats.compileSeconds = 0
  result.path = lib
  result.lib = loadLib(lib)
  if result.lib == nil: raise newException(OSError, "cannot load " & lib)

# --- results back to Polars through the Arrow C Data Interface ---------------

const FormatOf: array[NqType, cstring] = ["l", "g", "b", "I"]

proc releaseSchema(s: ptr ArrowSchema) {.cdecl, gcsafe, raises: [].} = s.release = nil
proc releaseArray(a: ptr ArrowArray) {.cdecl, gcsafe, raises: [].} =
  for i in 0 ..< a.nBuffers:
    if a.buffers[i] != nil: deallocShared(a.buffers[i])
  deallocShared(a.buffers)
  a.release = nil

proc outputBuffers(t: NqType, n: int): (pointer, pointer) =
  let bitBytes = (n + 63) div 64 * 8  # bitmaps are written 64 bits at a time
  let dataBytes = if t == tBool: bitBytes
                  elif t == tU32: n * 4
                  else: n * 8
  (allocShared0(max(dataBytes, 8)), allocShared0(max(bitBytes, 8)))

proc toSeries(name: string, t: NqType, n: int, data, validity: pointer, nullCount: int): Series =
  ## Hands the buffers the kernel filled to Polars, without copying.
  var schema = ArrowSchema(format: FormatOf[t], name: name.cstring, release: releaseSchema)
  var arr = ArrowArray(length: n, nullCount: nullCount, nBuffers: 2, release: releaseArray)
  arr.buffers = cast[ptr UncheckedArray[pointer]](allocShared0(2 * sizeof(pointer)))
  arr.buffers[1] = data
  if nullCount > 0: arr.buffers[0] = validity
  else: deallocShared(validity)
  fromArrow(schema, arr, name)

proc scalarSeries(name: string, t: NqType, r: KRes): Series =
  case t
  of tI64: series(name, [if r.isNull: none(int) else: some(r.i.int)])
  of tF64: series(name, [if r.isNull: none(float) else: some(r.f)])
  of tU32: series(name, [if r.isNull: none(uint32) else: some(r.u.uint32)])
  of tBool: raise newException(Unsupported, "boolean scalar")

# --- the entry point ---------------------------------------------------------

proc planKernels*(df: DataFrame, exprs: openArray[Expr]): (seq[Option[Kernel]], Nif) =
  ## Front half: which expressions become Nim kernels, and their typed NIF.
  let schema = df.schemaOf
  var kernels = tree("kernels")
  var plan: seq[Option[Kernel]]
  for i, e in exprs:
    try:
      let k = semKernel(toNif(e.meta.serialize(SerializationFormat.Json)), schema, "k" & $i)
      plan.add some(k)
      kernels.kids.add k.nif
    except Unsupported as err:
      plan.add none(Kernel)
      stats.fallbackReasons.add err.msg
  (plan, kernels)

proc nimSelect*(df: DataFrame, exprs: varargs[Expr]): seq[Series] =
  ## One result Series per expression, like the columns of `df.select(e)`
  ## taken one at a time (scalars are length-1 Series).
  stats = JitStats()
  let (plan, kernels) = planKernels(df, exprs)
  var lib: CompiledLib
  if kernels.len > 0:
    # The NIF file is the interface: the code generator reads it back.
    createDir(cacheDir)
    let nifPath = cacheDir / "last.nif"
    writeFile(nifPath, kernels.toNifModule("nq-query"))
    lib = compile(genModule(parseNif(readFile(nifPath))))
  let n = df.height
  for i, e in exprs:
    if plan[i].isNone:
      inc stats.polarsFallbacks
      result.add df.select(e).getColumn(df.select(e).columns[0])
      continue
    inc stats.nimKernels
    let k = plan[i].get
    let f = cast[KernelProc](lib.lib.symAddr("k" & $i))
    var exports = newSeq[ArrowExport](k.inputs.len)
    var cols = newSeq[KCol](max(1, k.inputs.len))
    for j, inp in k.inputs:
      exports[j] = df.getColumn(inp.name).toArrow
      let a = exports[j].array
      let width = if inp.typ == tU32: 4 else: 8
      cols[j] = KCol(data: cast[pointer](cast[int](a.buffers[1]) + a.offset.int * width),
                     validity: (if a.nullCount > 0: cast[ptr UncheckedArray[uint8]](a.buffers[0]) else: nil),
                     bitOff: a.offset.int)
    var res: KRes
    if k.shape == shColumn:
      let (data, validity) = outputBuffers(k.outType, n)
      res.data = data
      res.validity = cast[ptr UncheckedArray[uint8]](validity)
      let t0 = getMonoTime()
      f(cast[ptr UncheckedArray[KCol]](addr cols[0]), n, addr res)
      stats.kernelMs += (getMonoTime() - t0).inNanoseconds.float / 1e6
      result.add toSeries(k.outName, k.outType, n, data, validity, res.nullCount)
    else:
      let t0 = getMonoTime()
      f(cast[ptr UncheckedArray[KCol]](addr cols[0]), n, addr res)
      stats.kernelMs += (getMonoTime() - t0).inNanoseconds.float / 1e6
      result.add scalarSeries(k.outName, k.outType, res)
