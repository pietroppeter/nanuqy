## Step 3: the code generator. It reads typed "nq-query" NIF (from sem.nim) and
## writes a Nim module with one exported C-ABI proc per kernel: a single fused
## loop over the rows, with no intermediate columns. It only sees the NIF text,
## like a Nimony plugin or `{.build.}` backend would, so it can also run as its
## own program:  nif2nim kernels.nif > kernels.nim

import std/[strutils, os]  # os: paramStr
import nif, sem

const Prelude = staticRead("kabi.nim")

type
  Val = object
    v, ok, act: string   # value, "is not null", "row is selected" (Nim expressions)
  Gen = object
    pre, loop, post: string  # code before / inside / after the row loop
    tmp: int
    aggs: seq[(Nif, Val)]    # aggregation node -> its result after the loop

proc nimType(t: NqType): string =
  case t
  of tI64: "int64"
  of tF64: "float64"
  of tU32: "uint32"
  of tBool: "bool"

proc fresh(g: var Gen, prefix = "t"): string =
  inc g.tmp
  prefix & $g.tmp

proc emit(code: var string, indent: int, line: string) =
  code.add spaces(indent) & line & "\n"

proc lit(n: Nif): string =
  let t = parseType(n[0])
  let v = n[1]
  case t
  of tF64:
    let f = (if v.kind == nkInt: v.i.float else: v.f)
    "float64(" & $f & ")"
  of tU32: "uint32(" & $v.i & ")"
  else: "int64(" & $v.i & ")"

proc gen(g: var Gen, n: Nif, inLoop: bool): Val

proc put(g: var Gen, inLoop: bool, indent: int, line: string) =
  if inLoop: g.loop.emit(indent, line) else: g.post.emit(indent, line)

proc genAgg(g: var Gen, n: Nif): Val =
  ## Accumulators live before the loop, are updated inside it, and give the
  ## aggregation's value after it.
  for (k, val) in g.aggs:
    if k == n: return val
  let t = parseType(n[0])
  let x = g.gen(n[1], inLoop = true)
  let a = g.fresh("acc")
  let inT = nimType(parseType(n[1][0]))
  case n.tag
  of "sum":
    g.pre.emit 2, "var " & a & ": " & inT & " = 0"
    # Branch-free: load the value unconditionally, then select it or 0, so the
    # C compiler can use conditional moves or vectorize.
    let (take, xv) = (g.fresh("take"), g.fresh("x"))
    g.loop.emit 4, "let " & take & " = " & x.act & " && " & x.ok
    g.loop.emit 4, "let " & xv & " = keep(" & take & ", " & x.v & ")"
    g.loop.emit 4, (if inT == "int64": a & " = wadd(" & a & ", " & xv & ")" else: a & " += " & xv)
    result = Val(v: a, ok: "true", act: "true")
  of "mean":
    let c = g.fresh("cnt")
    g.pre.emit 2, "var " & a & ": float64 = 0"
    g.pre.emit 2, "var " & c & " = 0"
    let (take, xv) = (g.fresh("take"), g.fresh("x"))
    g.loop.emit 4, "let " & take & " = " & x.act & " && " & x.ok
    g.loop.emit 4, "let " & xv & " = float64(" & x.v & ")"
    g.loop.emit 4, a & " += keep(" & take & ", " & xv & ")"
    g.loop.emit 4, c & " += int(" & take & ")"
    result = Val(v: "(" & a & " / float64(" & c & "))", ok: "(" & c & " > 0)", act: "true")
  of "min", "max":
    let has = g.fresh("has")
    let op = if n.tag == "min": "<" else: ">"
    g.pre.emit 2, "var " & a & ": " & inT & " = 0"
    g.pre.emit 2, "var " & has & " = false"
    if inT == "float64":
      # Polars' min/max skip NaN, unless every value is NaN.
      let nan = g.fresh("nan")
      g.pre.emit 2, "var " & nan & " = false"
      g.loop.emit 4, "if " & x.act & " && " & x.ok & ":"
      g.loop.emit 6, "if " & x.v & " != " & x.v & ": " & nan & " = true"
      g.loop.emit 6, "elif not " & has & " || (" & x.v & " " & op & " " & a & "): " & a & " = " & x.v & "; " & has & " = true"
      result = Val(v: "(if " & has & ": " & a & " else: NaN)", ok: "(" & has & " || " & nan & ")", act: "true")
    else:
      g.loop.emit 4, "if " & x.act & " && " & x.ok & " and (not " & has & " || (" & x.v & " " & op &
                     " " & a & ")): " & a & " = " & x.v & "; " & has & " = true"
      result = Val(v: a, ok: has, act: "true")
  of "count", "len":
    g.pre.emit 2, "var " & a & ": uint32 = 0"
    let cond = if n.tag == "count": x.act & " && " & x.ok else: x.act
    g.loop.emit 4, a & " += uint32(" & cond & ")"
    result = Val(v: a, ok: "true", act: "true")
  else: doAssert false
  discard t
  g.aggs.add (n, result)

proc gen(g: var Gen, n: Nif, inLoop: bool): Val =
  ## Code for node `n`. Row-level nodes are computed inside the loop, nodes
  ## above the aggregations after it.
  let ind = if inLoop: 4 else: 2
  case n.tag
  of "col":
    let t = parseType(n[0])
    let i = n[1].i
    let nullable = n[3].s == "nullable"
    result = Val(v: "c" & $i & "[i]", ok: (if nullable: "isValid(v" & $i & ", o" & $i & ", i)" else: "true"),
                 act: "true")
    if t == tBool: doAssert false, "boolean input columns are not supported"
  of "lit":
    result = Val(v: lit(n), ok: "true", act: "true")
  of "conv":
    let x = g.gen(n[1], inLoop)
    result = Val(v: nimType(parseType(n[0])) & "(" & x.v & ")", ok: x.ok, act: x.act)
  of "add", "sub", "mul", "div", "gt", "ge", "lt", "le", "eq", "ne":
    let a = g.gen(n[1], inLoop)
    let b = g.gen(n[2], inLoop)
    let opT = parseType(n[1][0])
    let t = g.fresh()
    let e =
      if opT == tI64 and n.tag in ["add", "sub", "mul"]:
        "w" & n.tag & "(" & a.v & ", " & b.v & ")"
      elif opT == tF64 and n.tag in ["gt", "ge", "lt", "le", "eq", "ne"]:
        "f" & n.tag & "(" & a.v & ", " & b.v & ")"
      else:
        let op = case n.tag
                 of "add": "+"
                 of "sub": "-"
                 of "mul": "*"
                 of "div": "/"
                 of "gt": ">"
                 of "ge": ">="
                 of "lt": "<"
                 of "le": "<="
                 of "eq": "=="
                 else: "!="
        "(" & a.v & " " & op & " " & b.v & ")"
    g.put(inLoop, ind, "let " & t & " = " & e)
    result = Val(v: t, ok: "(" & a.ok & " && " & b.ok & ")", act: "true")
  of "and", "or":
    # Kleene logic, as in Polars: false and null = false, true or null = true.
    let a = g.gen(n[1], inLoop)
    let b = g.gen(n[2], inLoop)
    let (t, k) = (g.fresh(), g.fresh("k"))
    if n.tag == "and":
      g.put(inLoop, ind, "let " & t & " = not ((" & a.ok & " && not " & a.v &  ") || (" & b.ok & " && not " & b.v & "))")
      g.put(inLoop, ind, "let " & k & " = (" & a.ok & " && " & b.ok &  ") || (" & a.ok & " && not " & a.v &  ") || (" & b.ok & " && not " & b.v & ")")
    else:
      g.put(inLoop, ind, "let " & t & " = (" & a.ok & " && " & a.v &  ") || (" & b.ok & " && " & b.v & ")")
      g.put(inLoop, ind, "let " & k & " = (" & a.ok & " && " & b.ok & ") || " & t)
    result = Val(v: t, ok: k, act: "true")
  of "neg", "abs":
    let x = g.gen(n[1], inLoop)
    let isInt = parseType(n[0]) == tI64
    let t = g.fresh()
    let e = if n.tag == "neg": (if isInt: "wneg(" & x.v & ")" else: "-" & x.v)
            else: (if isInt: "wabs(" & x.v & ")" else: "abs(" & x.v & ")")
    g.put(inLoop, ind, "let " & t & " = " & e)
    result = Val(v: t, ok: x.ok, act: x.act)
  of "filter":
    let x = g.gen(n[1], inLoop)
    let p = g.gen(n[2], inLoop)
    result = Val(v: x.v, ok: x.ok, act: "(" & x.act & " && " & p.act & " && " & p.ok & " && " & p.v & ")")
  of "sum", "mean", "min", "max", "count", "len":
    doAssert not inLoop, "aggregation inside a row expression"
    result = g.genAgg(n)
  else:
    doAssert false, "unknown tag " & n.tag

proc genKernel*(k: Nif): string =
  ## Nim source for one `(kernel :name ...)` tree.
  doAssert k.isTag("kernel")
  let name = k[0].s.split('.')[0]
  let shape = k[2][0].s
  let inputs = k[3]
  let body = k[4]
  var g: Gen
  var head = "proc " & name & "(cols: ptr UncheckedArray[KCol], n: int, res: ptr KRes) " &
             "{.exportc: \"" & name & "\", dynlib, cdecl, gcsafe, raises: [].} =\n"
  for inp in inputs.kids:
    let i = inp[0].i
    head.emit 2, "let c" & $i & " = cast[ptr UncheckedArray[" & nimType(parseType(inp[2])) &
                 "]](cols[" & $i & "].data)  # " & inp[1].s
    # Copy everything the loop reads into locals: writes through the output
    # pointers could alias `cols`, which would force a reload on every row.
    head.emit 2, "let v" & $i & " = cols[" & $i & "].validity"
    head.emit 2, "let o" & $i & " = cols[" & $i & "].bitOff"
  let outT = parseType(body[0])
  var blocked = false
  if shape == "column":
    # Rows go in blocks of 64 so that bits (boolean values, validity) are
    # gathered in a register and stored one 64-bit word at a time.
    blocked = true
    let r = g.gen(body, inLoop = true)
    let neverNull = r.ok == "true"
    var store = ""
    if outT == tBool:
      g.pre.emit 2, "let o = cast[ptr UncheckedArray[uint64]](res.data)"
      g.loop.emit 4, "wbits = wbits or (uint64(" & (if neverNull: r.v else: "(" & r.ok & " && " & r.v & ")") & ") shl j)"
      store.emit 4, "o[base shr 6] = wbits"
    else:
      g.pre.emit 2, "let o = cast[ptr UncheckedArray[" & nimType(outT) & "]](res.data)"
      g.loop.emit 4, "o[i] = " & r.v  # garbage under nulls is fine: they are masked
    if neverNull:
      g.post.emit 2, "res.nullCount = 0"
    else:
      g.pre.emit 2, "var nulls = 0"
      g.pre.emit 2, "let ov = cast[ptr UncheckedArray[uint64]](res.validity)"
      g.loop.emit 4, "let ok = " & r.ok
      g.loop.emit 4, "vbits = vbits or (uint64(ok) shl j)"
      store.emit 4, "ov[base shr 6] = vbits"
      store.emit 4, "nulls += m - countSetBits(vbits)"
      g.post.emit 2, "res.nullCount = nulls"
    var loop = "  var base = 0\n  while base < n:\n    let m = min(64, n - base)\n" &
               "    var wbits, vbits = 0'u64\n    for j in 0 ..< m:\n      let i = base + j\n"
    for line in g.loop.splitLines:
      if line.len > 0: loop.add "  " & line & "\n"
    loop.add store & "    base += 64\n"
    g.loop = loop
  else:
    let r = g.gen(body, inLoop = false)
    let field = case outT
                of tF64: "f"
                of tU32: "u"
                else: "i"
    g.post.emit 2, "res.isNull = not " & r.ok
    g.post.emit 2, "if " & r.ok & ": res." & field & " = " & r.v
  result = head & g.pre
  if blocked:
    result.add g.loop
  elif g.loop.len > 0:
    result.add "  for i in 0 ..< n:\n" & g.loop
  result.add g.post

proc genModule*(kernels: Nif, nimony = false): string =
  ## A whole generated module for a `(kernels ...)` tree. With `nimony`, for
  ## the Nimony compiler instead of Nim 2: its pointers are not-nil by default
  ## (the validity pointers are nil for columns without nulls, hence
  ## `lenientnils`), it has no `overflowChecks`-style push pragmas (`-d:danger`
  ## turns checks off), and kernels are linked into the program, not a dynlib.
  result = "# Generated by nif2nim from nq-query NIF. Do not edit.\n"
  if nimony: result.add "{.feature: \"lenientnils\".}\n"
  else: result.add "{.push overflowChecks: off, boundChecks: off, rangeChecks: off.}\n"
  result.add Prelude & "\n"
  for k in kernels.kids:
    var code = genKernel(k)
    if nimony: code = code.replace(", dynlib, cdecl", ", cdecl")
    result.add code & "\n"

when isMainModule:
  if paramCount() notin 1..2: quit "usage: nif2nim [--nimony] kernels.nif"
  stdout.write genModule(parseNif(readFile(paramStr(paramCount()))), nimony = paramStr(1) == "--nimony")
