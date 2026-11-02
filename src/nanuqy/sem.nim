## Step 2: type the untyped "nq-query" tree against the frame's schema,
## following Polars' rules for the supported subset. The result is a *typed*
## NIF tree in the style of Nimony's IR: every operation carries its result type
## as first child, and int-to-float promotions are explicit `(conv ...)` nodes.
##
##   (sum (mul (col "a") 2))   with a: Int64
##   ==>  (sum (i 64) (mul (i 64) (col (i 64) 0 "a") (lit (i 64) 2)))
##
## The rules here are the Polars semantics this experiment re-implements, so
## they are exactly what the differential test (difftest.nim) checks.

import nif, polars2nif

type
  NqType* = enum tI64 = "i64", tF64 = "f64", tBool = "bool", tU32 = "u32"
  Shape* = enum shColumn = "column", shScalar = "scalar"
  Input* = object
    name*: string
    typ*: NqType
    hasNulls*: bool  # Arrow knows; the kernel is specialized on it
  Typed = object
    n: Nif
    t: NqType
    shape: Shape
    isDynLit: bool    # an untyped literal that adopts the other operand's type
    hasFilter: bool   # changes the length: only allowed right under an aggregation
  Sem = object
    schema: seq[Input]  # columns of the frame
    used*: seq[Input]   # columns the kernel reads, in slot order
  Kernel* = object
    nif*: Nif           # the typed `(kernel ...)` tree
    inputs*: seq[Input]
    outName*: string
    outType*: NqType
    shape*: Shape

proc typeNode*(t: NqType): Nif =
  case t
  of tI64: tree("i", intLit(64))
  of tF64: tree("f", intLit(64))
  of tU32: tree("u", intLit(32))
  of tBool: tree("bool")

proc parseType*(n: Nif): NqType =
  case n.tag
  of "i": tI64
  of "f": tF64
  of "u": tU32
  else: tBool

proc unsupported(what: string) {.noreturn.} = raise newException(Unsupported, what)

proc slot(s: var Sem, name: string): (int, NqType) =
  for i, u in s.used:
    if u.name == name: return (i, u.typ)
  for c in s.schema:
    if c.name == name:
      if c.typ notin {tI64, tF64}: unsupported("column type " & $c.typ)
      s.used.add c
      return (s.used.high, c.typ)
  unsupported("unknown column " & name)  # let Polars report the error

proc isNumeric(t: NqType): bool = t in {tI64, tF64, tU32}

proc coerce(x: Typed, t: NqType): Nif =
  ## `x` as type `t`: literals are retyped, i64 values get an explicit conv.
  if x.t == t: return x.n
  if x.isDynLit:
    let v = x.n[1]
    return tree("lit", typeNode(t), (if t == tF64 and v.kind == nkInt: floatLit(v.i.float) else: v))
  if (x.t == tI64 and t == tF64) or (x.t == tU32 and t in {tI64, tF64}):
    return tree("conv", typeNode(t), x.n)
  unsupported("conversion " & $x.t & " -> " & $t)

proc outName*(n: Nif): string =
  ## Polars' output name: the alias, else the left-most leaf's name.
  case n.tag
  of "col": n[0].s
  of "dynlit": "literal"
  of "alias": n[1].s
  else: outName(n[0])

proc check(s: var Sem, n: Nif): Typed =
  case n.tag
  of "col":
    let (i, t) = s.slot(n[0].s)
    let nullable = ident(if s.used[i].hasNulls: "nullable" else: "notnull")
    Typed(n: tree("col", typeNode(t), intLit(i), str(n[0].s), nullable), t: t)
  of "dynlit":
    let t = if n[0].kind == nkInt: tI64 else: tF64
    Typed(n: tree("lit", typeNode(t), n[0]), t: t, isDynLit: true, shape: shScalar)
  of "alias":
    s.check(n[0])
  of "add", "sub", "mul", "div", "gt", "ge", "lt", "le", "eq", "ne", "and", "or":
    let a = s.check(n[0])
    let b = s.check(n[1])
    if a.isDynLit and b.isDynLit: unsupported("literal-only arithmetic")
    if a.hasFilter or b.hasFilter: unsupported("filter outside an aggregation")
    if a.shape != b.shape and not (a.isDynLit or b.isDynLit):
      unsupported("broadcasting a scalar over a column")
    let shape = if a.isDynLit: b.shape elif b.isDynLit: a.shape else: a.shape
    if n.tag in ["and", "or"]:
      if a.t != tBool or b.t != tBool: unsupported("bitwise and/or on numbers")
      return Typed(n: tree(n.tag, typeNode(tBool), a.n, b.n), t: tBool, shape: shape)
    if not (a.t.isNumeric and b.t.isNumeric): unsupported("arithmetic on " & $a.t & ", " & $b.t)
    # Operand type: f64 wins; a dyn literal adopts the other side's type unless
    # it is a float literal.
    var opT = if a.t == tF64 or b.t == tF64: tF64
              elif a.t == tI64 or b.t == tI64: tI64
              else: tU32
    # A dyn literal adopts the other side's type; an int literal next to u32
    # stays u32 (Polars), a float literal makes it f64.
    if a.isDynLit and a.t == tF64 or b.isDynLit and b.t == tF64: opT = tF64
    elif (a.isDynLit and b.t == tU32) or (b.isDynLit and a.t == tU32):
      let l = if a.isDynLit: a else: b
      opT = tU32
      if l.n[1].i < 0: unsupported("negative literal with u32")
    if n.tag == "div": opT = tF64  # true division always yields floats
    let resT = if n.tag in ["gt", "ge", "lt", "le", "eq", "ne"]: tBool else: opT
    Typed(n: tree(n.tag, typeNode(resT), coerce(a, opT), coerce(b, opT)), t: resT, shape: shape)
  of "neg", "abs":
    let a = s.check(n[0])
    if not a.t.isNumeric or a.isDynLit: unsupported(n.tag & " of " & $a.t)
    Typed(n: tree(n.tag, typeNode(a.t), a.n), t: a.t, shape: a.shape, hasFilter: a.hasFilter)
  of "filter":
    let a = s.check(n[0])
    let p = s.check(n[1])
    if a.shape != shColumn or a.isDynLit or p.shape != shColumn or p.isDynLit:
      unsupported("filter of scalars")
    if p.t != tBool: unsupported("filter by " & $p.t)
    if p.hasFilter: unsupported("filtered predicate")
    Typed(n: tree("filter", typeNode(a.t), a.n, p.n), t: a.t, shape: shColumn, hasFilter: true)
  of "sum", "mean", "min", "max", "count", "len":
    let a = s.check(n[0])
    if a.shape != shColumn or a.isDynLit: unsupported("nested aggregation")
    if not a.t.isNumeric: unsupported(n.tag & " of " & $a.t)
    let t = case n.tag
            of "mean": tF64
            of "count", "len": tU32
            else: a.t
    Typed(n: tree(n.tag, typeNode(t), a.n), t: t, shape: shScalar)
  else:
    unsupported("tag " & n.tag)

proc semKernel*(untyped: Nif, schema: seq[Input], name: string): Kernel =
  var s = Sem(schema: schema)
  let r = s.check(untyped)
  if r.isDynLit: unsupported("a bare literal")
  if r.hasFilter: unsupported("filter at the top (changes the length)")
  if r.shape == shScalar and r.t == tBool: unsupported("boolean scalar")
  var ins = tree("inputs")
  for i, u in s.used:
    ins.kids.add tree("input", intLit(i), str(u.name), typeNode(u.typ),
                      ident(if u.hasNulls: "nullable" else: "notnull"))
  result = Kernel(inputs: s.used, outName: outName(untyped), outType: r.t, shape: r.shape)
  result.nif = tree("kernel", symDef(name & ".0.nq"), tree("name", str(result.outName)),
                    tree("shape", ident($r.shape)), ins, r.n)
