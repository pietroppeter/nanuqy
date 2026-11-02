## Nim procs as kernel code: a user-defined function (UDF) written in Nim is
## copied, as source, into the generated kernel module, so the C compiler
## inlines it into the fused loop. No callback per row, no Series copies.
##
##   proc toFeet(m: float64): float64 {.nimKernel.} = m * 3.28084
##   df.nimSelect(@[nimCall("toFeet", col("m")).sum])
##
## Polars cannot serialize a callback, so `nimCall` builds a placeholder that it
## can: `as_struct(lit("__nimudf:toFeet"), args...)`. polars2nif reads it as
## `(call "toFeet" args...)`. Polars itself cannot evaluate the placeholder, so
## an expression with a UDF has no Polars fallback: it runs as a Nim kernel or
## fails. (The oracle in tests is the same proc through nanuq's mapElements.)

import std/macros
import nanuq
import polars2nif   # UdfMarker

type UdfDef* = object
  name*: string
  params*: seq[string]   # "float64" | "int64"
  ret*: string           # "float64" | "int64" | "bool"
  src*: string           # the proc, as Nim source

var udfs*: seq[UdfDef]

proc registerUdf*(d: UdfDef) =
  for u in udfs.mitems:
    if u.name == d.name: u = d; return
  udfs.add d

proc findUdf*(name: string): int =
  for i, u in udfs:
    if u.name == name: return i
  -1

macro nimKernel*(p: untyped): untyped =
  ## Keeps the proc as is and registers its source for kernel generation.
  ## Parameters and result must be float64 or int64 (result may be bool).
  expectKind p, nnkProcDef
  var params: seq[string]
  let fp = p.params
  let ret = fp[0].repr
  for i in 1 ..< fp.len:
    let d = fp[i]
    for j in 0 ..< d.len - 2: params.add d[^2].repr
  var copy = p.copyNimTree
  copy.pragma = nnkPragma.newTree(ident"inline")
  copy[0] = ident(p.name.strVal)   # unexported inside the kernel module
  let name = p.name.strVal
  let src = copy.repr
  var paramsLit = nnkBracket.newTree()
  for x in params: paramsLit.add newLit(x)
  result = newStmtList(p, quote do:
    registerUdf(UdfDef(name: `name`, params: @`paramsLit`, ret: `ret`, src: `src`)))

proc nimCall*(name: string, args: varargs[Expr]): Expr =
  ## A call of the `{.nimKernel.}` proc `name` on `args`, for `nimSelect`.
  var xs = @[lit(UdfMarker & name)]
  for a in args: xs.add a
  asStruct(xs)
