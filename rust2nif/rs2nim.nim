## Lowers "rust-core" NIF (Rust source as parsed by syn, compacted by rcompact)
## to Nim source. It is a small, honest translator for a Rust subset: it knows
## Rust *syntax* in general, and a handful of std/polars-arrow idioms by name.
## Everything it does not know is counted and reported, never guessed.
##
##   rs2nim file.core.nif [--mono T=float64,F=float64] [--skip name,...] > out.nim
##
## Monomorphization: generic params listed in --mono are substituted (Rust
## would instantiate them per use; we pick one instantiation). Other generic
## params stay Nim generics.

import std/[strutils, os, tables, sets, sequtils]
import ../src/nanuqy/nif

type Ctx = object
  mono: Table[string, string]
  skip: HashSet[string]
  generics: HashSet[string]
  selfTy: string
  lines: seq[string]
  unsupported: CountTable[string]
  dropped: seq[string]
  emitted: seq[string]
  fnsClean, fnsTotal: int

const NimKw = ["addr", "and", "as", "asm", "binding", "block", "break", "case", "cast", "concept",
  "const", "continue", "converter", "defer", "discard", "distinct", "div", "do", "elif", "else",
  "end", "enum", "except", "export", "finally", "for", "from", "func", "if", "import", "in",
  "include", "interface", "is", "isnot", "iterator", "let", "macro", "method", "mixin", "mod",
  "nil", "not", "notin", "object", "of", "or", "out", "proc", "ptr", "raise", "ref", "return",
  "shl", "shr", "static", "template", "try", "tuple", "type", "using", "var", "when", "while",
  "xor", "yield", "result"]

proc id(s: string): string =
  if s == "self": "self"
  elif s in NimKw: "`" & s & "`"
  else: s

proc unsup(c: var Ctx, what: string): string =
  c.unsupported.inc what
  "UNSUPPORTED(" & what & ")"

# --- tree access -----------------------------------------------------------
proc f(n: Nif, name: string): Nif =
  ## first kid of the role-labelled child `name`, or nil
  if n.isNil or n.kind != nkTree: return nil
  for k in n.kids:
    if k.isTag(name): return (if k.len > 0: k[0] else: nil)
  nil

proc fs(n: Nif, name: string): seq[Nif] =
  if n.isNil or n.kind != nkTree: return
  for k in n.kids:
    if k.isTag(name): return k.kids

proc has(n: Nif, name: string): bool =
  not n.isNil and n.kind == nkTree and n.kids.anyIt(it.isTag(name))

proc name(n: Nif): string =
  ## an ident atom, or the last segment of a qpath
  if n.isNil: ""
  elif n.kind == nkIdent: n.s
  elif n.isTag("qpath"): name(n.kids[^1])
  elif n.isTag("generic"): name(n[0])
  else: ""

proc tagOrAtom(n: Nif): string =
  if n.isNil: "nil" elif n.kind == nkTree: n.tag else: "atom:" & n.s

# --- cfg ----------------------------------------------------------------------
proc cfgTokens(ts: Nif): bool =
  ## evaluates `feature = "x"` / `not(...)` with every feature disabled
  if ts.isNil or ts.kind != nkTree: return true
  let toks = ts.kids
  if toks.len >= 1 and toks[0].kind == nkIdent and toks[0].s == "not":
    return not cfgTokens(toks[1].f("stream"))
  if toks.len >= 1 and toks[0].kind == nkIdent and toks[0].s == "feature": return false
  true

proc enabled(item: Nif): bool =
  for a in item.fs("attrs"):
    let m = a.f("meta")
    if m.isTag("MetaList") and m.f("path").name == "cfg":
      if not cfgTokens(m.f("tokens")): return false
  true

# --- types ----------------------------------------------------------------------
proc ty(c: var Ctx, n: Nif): string =
  if n.isNil: return "void"
  if n.kind == nkIdent:
    let s = n.s
    if s in c.mono: return c.mono[s]
    case s
    of "Self": return c.selfTy
    of "usize", "isize": return "int"
    of "f64": return "float64"
    of "f32": return "float32"
    of "bool": return "bool"
    of "i64", "i32", "u64", "u32", "u8", "i8", "u16", "i16":
      return (if s[0] == 'i': "int" else: "uint") & s[1..^1]
    else: return s
  case n.tag
  of "TypeReference", "TypeParen": c.ty(n.f("elem"))
  of "TypeSlice", "TypeArray": "RSlice[" & c.ty(n.f("elem")) & "]"   # borrowed views
  of "qpath": c.ty(n.kids[^1])
  of "generic":
    let args = n.kids[1..^1].filterIt(not it.isTag("GenericArgumentLifetime") and
                                      not it.isTag("Lifetime"))
    if args.len == 0: c.ty(n[0])
    else: name(n[0]) & "[" & args.mapIt(c.ty(it)).join(", ") & "]"
  of "GenericArgumentType": c.ty(n[0])
  of "TypePtr": "ptr " & c.ty(n.f("elem"))
  of "TypeTuple": "(" & n.fs("elems").mapIt(c.ty(it)).join(", ") & ")"
  else: c.unsup("type " & n.tag)

# --- expressions ------------------------------------------------------------------
proc ex(c: var Ctx, n: Nif): string
proc pat(c: var Ctx, p: Nif): tuple[s: string, mutable: bool, ty: Nif]
proc value(c: var Ctx, n: Nif, ind: string, hint: Nif = nil)
proc blockBody(c: var Ctx, blk: Nif, ind: string, asValue: bool)
proc stmt(c: var Ctx, s: Nif, ind: string, last, asValue: bool)

const BinOps = {"BinOpAdd": "+", "BinOpSub": "-", "BinOpMul": "*", "BinOpAnd": "and",
  "BinOpOr": "or", "BinOpEq": "==", "BinOpLt": "<", "BinOpLe": "<=", "BinOpNe": "!=",
  "BinOpGe": ">=", "BinOpGt": ">", "BinOpBitAnd": "and", "BinOpBitOr": "or",
  "BinOpBitXor": "xor", "BinOpShl": "shl", "BinOpShr": "shr",
  # Rust's `/` and `%` mean div/mod on integers and / on floats: overloaded in the shim
  "BinOpDiv": "rdiv", "BinOpRem": "rmod"}.toTable
const AssignOps = {"BinOpAddAssign": "BinOpAdd", "BinOpSubAssign": "BinOpSub",
  "BinOpMulAssign": "BinOpMul", "BinOpDivAssign": "BinOpDiv", "BinOpRemAssign": "BinOpRem",
  "BinOpBitAndAssign": "BinOpBitAnd", "BinOpBitOrAssign": "BinOpBitOr",
  "BinOpBitXorAssign": "BinOpBitXor", "BinOpShlAssign": "BinOpShl", "BinOpShrAssign": "BinOpShr"}.toTable

proc opName(n: Nif): string = n.f("op").tagOrAtom

proc binary(c: var Ctx, op, l, r: string): string =
  let o = BinOps[op]
  if o in ["rdiv", "rmod"]: o & "(" & l & ", " & r & ")" else: l & " " & o & " " & r

proc isComplex(n: Nif): bool =
  ## needs statements to express in Nim (rendered with `value`)
  if n.isNil or n.kind != nkTree: return false
  case n.tag
  of "ExprBlock", "ExprUnsafe": true
  of "ExprIf", "ExprMatch": true
  of "ExprMethodCall": n.f("method").name == "sum"   # iterator pipelines
  else: false

proc lit(n: Nif): string =
  let l = n.f("lit")
  case l.tag
  of "LitInt":
    var t = l.f("token").s.replace("_", "")
    for suf in ["usize", "isize", "u64", "i64", "u32", "i32", "u8", "i8"]:
      t.removeSuffix(suf)
    t
  of "LitFloat": l.f("token").s.replace("_", "").replace("f64", "").replace("f32", "")
  of "LitBool": l.f("value").s
  else: "UNSUPPORTED(lit " & l.tag & ")"

proc call(c: var Ctx, fn: Nif, args: seq[Nif]): string =
  let a = args.mapIt(c.ex(it)).join(", ")
  if fn.isTag("qpath"):
    let last = name(fn)
    if last in ["zero", "default"] and args.len == 0:
      return c.ty(fn[0]) & "(0)"          # F::zero(), F::default()
    return id(last) & "(" & a & ")"       # Trait::method(x), Type::ctor(x)
  id(fn.name) & "(" & a & ")"

proc ex(c: var Ctx, n: Nif): string =
  if n.isNil: return "UNSUPPORTED(nil)"
  if n.kind == nkIdent: return id(n.s)
  if n.kind != nkTree: return c.unsup("atom " & $n.kind)
  case n.tag
  of "qpath": id(name(n))
  of "ExprLit": lit(n)
  of "ExprParen": "(" & c.ex(n.f("expr")) & ")"
  of "ExprBinary":
    let op = n.opName
    if op in AssignOps:
      let l = c.ex(n.f("left"))
      l & " = " & c.binary(AssignOps[op], l, c.ex(n.f("right")))
    elif op in BinOps: c.binary(op, c.ex(n.f("left")), c.ex(n.f("right")))
    else: c.unsup("binop " & op)
  of "ExprUnary":
    let op = n.f("op").tagOrAtom
    let e = c.ex(n.f("expr"))
    case op
    of "UnOpNot": "not " & e
    of "UnOpNeg": "-" & e
    of "UnOpDeref": e
    else: c.unsup("unop " & op)
  of "ExprReference": c.ex(n.f("expr"))   # borrows are views already
  of "ExprAssign": c.ex(n.f("left")) & " = " & c.ex(n.f("right"))
  of "ExprIndex": c.ex(n.f("expr")) & "[" & c.ex(n.f("index")) & "]"
  of "ExprField":
    let m = n.f("member")
    if m.isTag("Index"): c.ex(n.f("base")) & "[" & m.f("index").s & "]"
    else: c.ex(n.f("base")) & "." & id(m.name)
  of "ExprTuple": "(" & n.fs("elems").mapIt(c.ex(it)).join(", ") & ")"
  of "ExprRange":
    let lo = if n.has("start"): c.ex(n.f("start")) else: "0"
    let hi = if n.has("end"): c.ex(n.f("end")) else: "-1"
    if n.f("limits").tagOrAtom != "RangeLimitsHalfOpen": return c.unsup("closed range")
    "rrange(" & lo & ", " & hi & ")"
  of "ExprRepeat": "rrepeat(" & c.ex(n.f("len")) & ", " & c.ex(n.f("expr")) & ")"
  of "ExprCall": c.call(n.f("func"), n.fs("args"))
  of "ExprReturn": "return " & c.ex(n.f("expr"))
  of "ExprMethodCall":
    let m = n.f("method").name
    let recv = n.f("receiver")
    let args = n.fs("args")
    if m == "as_" and args.len == 0:
      # AsPrimitive<F>::as_: the target is the F of the bound (our mono F)
      return c.mono.getOrDefault("F", "F") & "(" & c.ex(recv) & ")"
    if m == "filter" and args.len == 1 and args[0].isTag("ExprClosure"):
      let ins = args[0].fs("inputs")
      if ins.len == 1 and ins[0].isTag("PatWild"):
        # Option::filter(|_| cond): the closure ignores its argument
        return "rfilter(" & c.ex(recv) & ", " & c.ex(args[0].f("body")) & ")"
    var targs: seq[string]
    for t in n.fs("turbofish"):
      for a in t.fs("args"): targs.add c.ex(a)   # const generic args -> static params
    let all = @[c.ex(recv)] & args.mapIt(c.ex(it)) & targs
    if all.len == 1: all[0] & "." & id(m) & "()"
    else: id(m) & "(" & all.join(", ") & ")"
  of "ExprMacro": c.unsup("macro in expression")
  of "ExprCast": c.ty(n.f("ty")) & "(" & c.ex(n.f("expr")) & ")"
  of "ExprArray": "[" & n.fs("elems").mapIt(c.ex(it)).join(", ") & "]"
  of "ExprBreak": "break"
  of "ExprContinue": "continue"
  of "ExprUnsafe", "ExprBlock":
    # a block holding just one tail expression is that expression
    let ss = n.f("block").fs("stmts")
    if ss.len == 1 and ss[0].isTag("StmtExpr") and ss[0].len == 1 and not ss[0][0].isComplex:
      c.ex(ss[0][0])
    else: c.unsup(n.tag & " in expression")
  of "ExprClosure":
    # |a, b| body  ->  (a, b) => body   (std/sugar; types come from the callee)
    let body = n.f("body")
    if body.isComplex: return c.unsup("closure with statements")
    "((" & n.fs("inputs").mapIt(c.pat(it).s).join(", ") & ") => " & c.ex(body) & ")"
  else: c.unsup(n.tag)

# --- statements and values ----------------------------------------------------------
proc emit(c: var Ctx, s: string) = c.lines.add s

proc pat(c: var Ctx, p: Nif): tuple[s: string, mutable: bool, ty: Nif] =
  case p.tagOrAtom
  of "PatIdent": (id(p.f("ident").s), p.has("mutability"), nil)
  of "PatType":
    let (s, m, _) = c.pat(p.f("pat"))
    (s, m, p.f("ty"))
  of "PatTuple": ("(" & p.fs("elems").mapIt(c.pat(it).s).join(", ") & ")", false, nil)
  of "PatWild": ("_", false, nil)
  of "PatReference": c.pat(p.f("pat"))
  else: (c.unsup("pattern " & p.tagOrAtom), false, nil)

proc iterPipeline(c: var Ctx, n: Nif, ind: string) =
  ## `xs.iter()[.enumerate()].map(|p| body).sum()` as a loop. Rust's float Sum
  ## folds left to right starting from -0.0 (rsumInit in the shim).
  var cur = n.f("receiver")
  var clo: Nif = nil
  var enumerate = false
  if cur.isTag("ExprMethodCall") and cur.f("method").name == "map":
    clo = cur.fs("args")[0]; cur = cur.f("receiver")
  if cur.isTag("ExprMethodCall") and cur.f("method").name == "enumerate":
    enumerate = true; cur = cur.f("receiver")
  if not (cur.isTag("ExprMethodCall") and cur.f("method").name == "iter"):
    c.emit ind & c.unsup("iterator pipeline"); return
  let src = c.ex(cur.f("receiver"))
  let F = c.mono.getOrDefault("F", "F")
  let p = if clo.isNil: "x" else: c.pat(clo.fs("inputs")[0]).s
  c.emit ind & "block:"
  c.emit ind & "  var acc = rsumInit(" & F & ")"
  c.emit ind & "  for " & p & " in " & (if enumerate: "enumerate(" & src & ".iter())" else: src & ".iter()") & ":"
  if not clo.isNil and clo.f("body").isComplex:
    c.emit ind & "    acc = acc + ("
    c.value(clo.f("body"), ind & "      ")
    c.emit ind & "    )"
  else:
    c.emit ind & "    acc = acc + " & (if clo.isNil: "x" else: c.ex(clo.f("body")))
  c.emit ind & "  acc"

proc ifChain(c: var Ctx, n: Nif, ind: string, asValue: bool, kw = "if") =
  let cond = n.f("cond")
  var binding = ""
  if cond.isTag("ExprLet"):
    # if let Some(x) = e  ->  if e.isSome: let x = e.get
    let p = cond.f("pat")
    if not (p.isTag("PatTupleStruct") and p.f("path").name == "Some"):
      c.emit ind & c.unsup("if let pattern"); return
    let e = c.ex(cond.f("expr"))
    c.emit ind & kw & " " & e & ".isSome:"
    binding = "let " & c.pat(p.fs("elems")[0]).s & " = " & e & ".get"
  else:
    c.emit ind & kw & " " & c.ex(cond) & ":"
  if binding.len > 0: c.emit ind & "  " & binding
  c.blockBody(n.f("then_branch"), ind & "  ", asValue)
  let e = n.f("else_branch")
  if e.isNil: return
  if e.isTag("ExprIf"): c.ifChain(e, ind, asValue, "elif")
  else:
    c.emit ind & "else:"
    if e.isTag("ExprBlock"): c.blockBody(e.f("block"), ind & "  ", asValue)
    elif asValue: c.value(e, ind & "  ")
    else: c.stmt(tree("StmtExpr", e, ident("semi")), ind & "  ", true, false)

proc findArray(x: Nif): Nif =
  if x.isNil or x.kind != nkTree: return nil
  if x.isTag("TypeArray"): return x
  for k in x.kids:
    let r = findArray(k)
    if not r.isNil: return r

var matchCounter = 0

proc armCond(c: var Ctx, p: Nif, scrut: string, binds: var seq[string]): string =
  ## the condition under which pattern `p` matches `scrut` ("" = always)
  case p.tagOrAtom
  of "PatWild": ""
  of "PatIdent":
    let nm = p.f("ident").s
    if nm == "None": scrut & ".isNone"
    elif nm.len > 0 and nm[0] in {'A'..'Z'}: scrut & " == " & nm   # unit variant / const
    else: (binds.add "let " & id(nm) & " = " & scrut; "")
  of "PatLit": scrut & " == " & lit(p)
  of "qpath": scrut & " == " & c.ex(p)   # Enum::Variant
  of "PatTuple":
    var cs: seq[string]
    for i, q in p.fs("elems"):
      let x = c.armCond(q, scrut & "[" & $i & "]", binds)
      if x != "": cs.add "(" & x & ")"
    cs.join(" and ")
  of "PatOr":
    var cs: seq[string]
    for q in p.fs("cases"):
      let x = c.armCond(q, scrut, binds)
      if x == "": return ""
      cs.add "(" & x & ")"
    cs.join(" or ")
  of "PatTupleStruct":
    let es = p.fs("elems")
    if p.f("path").name == "Some" and es.len == 1:
      let inner = c.armCond(es[0], scrut & ".get", binds)
      scrut & ".isSome" & (if inner == "": "" else: " and " & inner)
    else: c.unsup("pattern " & p.f("path").name & "(..)")
  else: c.unsup("match pattern " & p.tagOrAtom)

proc matchExpr(c: var Ctx, n: Nif, ind: string, asValue: bool) =
  ## match -> if/elif chain; rustc checked exhaustiveness, so the last arm is `else`
  inc matchCounter
  let scrut = "m" & $matchCounter
  c.emit ind & "block:"
  c.emit ind & "  let " & scrut & " = " & c.ex(n.f("expr"))
  let arms = n.fs("arms")
  for i, arm in arms:
    if arm.has("guard"): c.emit ind & "  " & c.unsup("match guard"); return
    var binds: seq[string]
    let cond = c.armCond(arm.f("pat"), scrut, binds)
    let kw = if i == 0: "if " elif i == arms.high or cond == "": "else" else: "elif "
    c.emit ind & "  " & (if kw == "else": "else:" else: kw & cond & ":")
    for b in binds: c.emit ind & "    " & b
    let body = arm.f("body")
    if body.isTag("ExprBlock"): c.blockBody(body.f("block"), ind & "    ", asValue)
    elif asValue: c.value(body, ind & "    ")
    else: c.emit ind & "    " & c.ex(body)
    if kw == "else": break

proc value(c: var Ctx, n: Nif, ind: string, hint: Nif = nil) =
  ## an expression in value position, possibly needing statements
  case n.tagOrAtom
  of "ExprBlock", "ExprUnsafe":
    c.emit ind & "block:"
    c.blockBody(n.f("block"), ind & "  ", true)
  of "ExprIf": c.ifChain(n, ind, true)
  of "ExprMatch": c.matchExpr(n, ind, true)
  of "ExprMethodCall":
    let m = n.f("method").name
    if m == "sum": c.iterPipeline(n, ind)
    elif m == "ok" and n.f("receiver").isTag("ExprMethodCall") and
         n.f("receiver").f("method").name == "try_into" and not hint.isNil:
      # slice.try_into().ok() as Option<&[T; N]>: Some iff len == N
      let arr = findArray(hint)
      let lenN = if arr.isNil: c.unsup("try_into target") else: c.ex(arr.f("len"))
      c.emit ind & "tryIntoArr(" & c.ex(n.f("receiver").f("receiver")) & ", " & lenN & ")"
    else: c.emit ind & c.ex(n)
  else: c.emit ind & c.ex(n)

proc isSemi(n: Nif): bool = n.kind == nkIdent and n.s == "semi"

proc stmt(c: var Ctx, s: Nif, ind: string, last, asValue: bool) =
  case s.tag
  of "StmtLocal":
    let (p, mutable, t) = c.pat(s.f("pat"))
    let init = s.f("init")
    let kw = if mutable: "var " else: "let "
    let ann = if t.isNil: "" else: ": " & c.ty(t)
    if init.isNil: c.emit ind & "var " & p & ann; return
    let e = init.f("expr")
    if e.isComplex or (e.isTag("ExprMethodCall") and e.f("method").name == "ok"):
      c.emit ind & kw & p & ann & " ="
      c.value(e, ind & "  ", t)
    else:
      c.emit ind & kw & p & ann & " = " & c.ex(e)
  of "ItemUse", "ItemConst", "ItemFn", "ItemStruct", "ItemEnum", "ItemImpl", "ItemStatic":
    # Stmt::Item(x) arrives as x (dbg2nif unwraps one-child tuple variants)
    let it = s
    if it.isTag("ItemUse"): discard
    elif it.isTag("ItemConst"): c.emit ind & "const " & it.f("ident").s & " = " & c.ex(it.f("expr"))
    else: c.emit ind & c.unsup("nested " & it.tag)
  of "StmtMacro":
    let m = s.f("mac")
    let mname = if m.isNil: s.tag else: m.f("path").name
    c.dropped.add mname & "!"
    c.emit ind & "discard # " & mname & "!(...) dropped: macro bodies are token streams"
  of "StmtExpr":
    let e = s[0]
    let tail = last and asValue and not (s.len > 1 and s[1].isSemi)
    if tail:
      c.value(e, ind)
      return
    case e.tagOrAtom
    of "ExprWhile":
      c.emit ind & "while " & c.ex(e.f("cond")) & ":"
      c.blockBody(e.f("body"), ind & "  ", false)
    of "ExprForLoop":
      let p = c.pat(e.f("pat")).s
      let it = e.f("expr")
      var src: string
      if it.isTag("ExprRange") and it.has("start") and it.has("end"):
        src = c.ex(it.f("start")) & " ..< " & c.ex(it.f("end"))
      elif it.isTag("ExprMethodCall") and it.f("method").name == "enumerate":
        src = "enumerate(" & c.ex(it.f("receiver")) & ")"
      else: src = c.ex(it)
      c.emit ind & "for " & p & " in " & src & ":"
      c.blockBody(e.f("body"), ind & "  ", false)
    of "ExprIf": c.ifChain(e, ind, false)
    of "ExprMatch": c.matchExpr(e, ind, false)
    of "ExprLoop":
      c.emit ind & "while true:"
      c.blockBody(e.f("body"), ind & "  ", false)
    of "ExprBlock", "ExprUnsafe":
      c.emit ind & "block:"
      c.blockBody(e.f("block"), ind & "  ", false)
    of "ExprMacro":
      let mname = e.f("mac").f("path").name
      c.dropped.add mname & "!"
      c.emit ind & "discard # " & mname & "!(...) dropped"
    else:
      let x = c.ex(e)
      c.emit ind & (if e.isTag("ExprMethodCall") or e.isTag("ExprCall"): "discard " & x else: x)
  else: c.emit ind & c.unsup("stmt " & s.tag)

proc blockBody(c: var Ctx, blk: Nif, ind: string, asValue: bool) =
  let ss = blk.fs("stmts")
  if ss.len == 0: c.emit ind & "discard"; return
  for i, s in ss: c.stmt(s, ind, i == ss.high, asValue)

# --- items ---------------------------------------------------------------------------
proc fnItem(c: var Ctx, sig, body: Nif) =
  let fname = sig.f("ident").s
  if fname in c.skip: c.dropped.add fname & " (skipped)"; return
  var gens: seq[string]
  let saved = c.generics
  for g in sig.f("generics").fs("params"):
    if g.isTag("TypeParam"):
      let gn = g.f("ident").s
      if gn notin c.mono: gens.add gn; c.generics.incl gn
  var params: seq[string]
  var shadows: seq[string]
  for inp in sig.fs("inputs"):
    if inp.isTag("Receiver"): params.add "self: " & c.selfTy
    else:
      let (p, mutable, t) = c.pat(inp)
      params.add p & ": " & c.ty(t)
      if mutable: shadows.add p
  let outT = sig.f("output")
  var ret = c.ty(outT)
  # a generic that appears only in the output (inferred in Rust) -> auto
  if not outT.isNil and outT.kind == nkIdent and outT.s in gens and
     not params.anyIt(it.endsWith(": " & outT.s)): ret = "auto"
  var before = 0
  for _, v in c.unsupported: before += v
  let gp = if gens.len > 0: "[" & gens.join(", ") & "]" else: ""
  c.emit "proc " & id(fname) & "*" & gp & "(" & params.join(", ") & "): " & ret & " ="
  for s in shadows: c.emit "  var " & s & " = " & s
  c.blockBody(body, "  ", ret != "void")
  c.emit ""
  c.emitted.add fname
  var after = 0
  for _, v in c.unsupported: after += v
  inc c.fnsTotal
  if after == before: inc c.fnsClean
  c.generics = saved

proc item(c: var Ctx, it: Nif) =
  if not it.enabled:
    c.dropped.add it.tag & " (cfg off)"; return
  case it.tag
  of "ItemUse", "ItemTrait": discard   # imports and trait declarations: nothing to emit
  of "ItemMacro": c.dropped.add "macro item " & it.f("mac").f("path").name & "!"
  of "ItemConst":
    c.emit "const " & it.f("ident").s & "* = " & c.ex(it.f("expr"))
    c.emit ""
  of "ItemFn": c.fnItem(it.f("sig"), it.f("block"))
  of "ItemImpl":
    let saved = c.selfTy
    c.selfTy = c.ty(it.f("self_ty"))
    for m in it.fs("items"):
      if m.isTag("ImplItemFn") and m.enabled: c.fnItem(m.f("sig"), m.f("block"))
    c.selfTy = saved
  else: c.dropped.add it.tag

when isMainModule:
  var c = Ctx()
  var file = ""
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    if a == "--mono":
      inc i
      for kv in paramStr(i).split(','):
        let p = kv.split('='); c.mono[p[0]] = p[1]
    elif a == "--skip":
      inc i
      for s in paramStr(i).split(','): c.skip.incl s
    else: file = a
    inc i
  let root = parseNif(readFile(file))
  c.emit "# Generated by rs2nim from " & file.extractFilename & " (rust-core NIF). Do not edit."
  c.emit "# mono: " & toSeq(c.mono.pairs).mapIt(it[0] & "=" & it[1]).join(", ")
  c.emit "import rshim"
  c.emit ""
  for it in root.fs("items"):
    let mark = c.lines.len
    try: c.item(it)
    except CatchableError, Defect:
      c.lines.setLen mark
      discard c.unsup("crash in " & it.tag)
  stdout.write c.lines.join("\n")
  stderr.writeLine "emitted: ", c.emitted.join(", ")
  stderr.writeLine "functions: ", c.fnsClean, " clean of ", c.fnsTotal
  stderr.writeLine "dropped: ", c.dropped.deduplicate.join(", ")
  if c.unsupported.len > 0:
    stderr.writeLine "UNSUPPORTED:"
    for k, v in c.unsupported: stderr.writeLine "  ", v, "x ", k
