## Turns syn's `{:#?}` dump of a Rust file into NIF ("rust-parsed" dialect).
import std/[strutils, os]
import ../src/nanuqy/nif

type Tok = object
  kind: char   # 'w' word, 's' string, '{', '}', '(', ')', '[', ']', ',', ':'
  s: string

proc lexChar(src: string, i: var int): Tok =
  ## char literal at src[i]: 'x' or '\x'
  var j = i + 1
  var s = ""
  if src[j] == '\\': s.add src[j+1]; j += 2
  else: s.add src[j]; inc j
  doAssert src[j] == '\''
  i = j + 1
  Tok(kind: 's', s: s)

proc lex(src: string): seq[Tok] =
  var i = 0
  while i < src.len:
    let c = src[i]
    case c
    of ' ', '\n', '\t', '\r': inc i
    of '{', '}', '(', ')', '[', ']', ',':
      result.add Tok(kind: c); inc i
    of ':':
      if i + 1 < src.len and src[i+1] == ':':
        result.add Tok(kind: 'w', s: "::"); inc i, 2
      else:
        result.add Tok(kind: ':'); inc i
    of '\'':
      result.add lexChar(src, i)
      continue
    of '"':
      var j = i + 1
      var s = ""
      while src[j] != '"':
        if src[j] == '\\':
          case src[j+1]
          of 'n': s.add '\n'
          of 't': s.add '\t'
          of '\\': s.add '\\'
          of '"': s.add '"'
          of '\'': s.add '\''
          else: s.add src[j+1]
          inc j, 2
        else:
          s.add src[j]; inc j
      result.add Tok(kind: 's', s: s); i = j + 1
    else:
      if c == 'b' and i + 1 < src.len and src[i+1] in {'\'', '"'}:   # b'x', b"xy"
        inc i
        continue
      var j = i
      while j < src.len and src[j] notin {' ', '\n', '\t', '\r', '{', '}', '(', ')', '[', ']', ',', ':', '"'}: inc j
      if j == i: inc j
      let w = src[i ..< j]
      # merge `A::B::C` into one word
      if result.len > 0 and result[^1].kind == 'w' and result[^1].s.endsWith("::"):
        result[^1].s.add w
      elif w.len > 0 and result.len > 0 and result[^1].kind == 'w' and result[^1].s == "::":
        result[^1].s.add w
      else:
        result.add Tok(kind: 'w', s: w)
      i = j
    # glue "X" "::" -> "X::"
    if result.len >= 2 and result[^1].kind == 'w' and result[^1].s == "::" and result[^2].kind == 'w':
      result[^2].s.add "::"; result.setLen(result.len - 1)

const Punct = ["Paren", "Brace", "Bracket", "Dot", "Semi", "Comma", "Colon", "PathSep", "Eq", "Lt", "Gt",
  "And", "Let", "Fn", "Use", "Pound", "Not", "Mut", "Const", "Impl", "For", "In", "If", "Else", "While",
  "Return", "Unsafe", "Pub", "Where", "As", "RArrow", "FatArrow", "Or", "Underscore", "Star", "Plus",
  "Minus", "Slash", "DotDot", "DotDotEq", "Loop", "Break", "Continue", "Match", "Struct", "Enum", "Trait",
  "Type", "Static", "Mod", "Macro", "SelfValue", "SelfType", "Ref", "Move", "Question", "Shl", "Shr",
  "Caret", "Percent", "AndAnd", "OrOr", "EqEq", "Ne", "Le", "Ge", "PlusEq", "MinusEq", "StarEq", "SlashEq",
  "Crate", "Super", "Dyn", "Where", "Async", "Await", "Pound", "Tilde", "At", "Dollar", "Alone", "Joint",
  "Parenthesis", "Bracket", "None", "ShlEq", "ShrEq", "AndEq", "OrEq", "CaretEq", "PercentEq"]

type P = object
  t: seq[Tok]
  i: int

proc peek(p: P): Tok = p.t[p.i]
proc next(p: var P): Tok = (result = p.t[p.i]; inc p.i)

proc tagOf(name: string): string = name.replace("::", "")

proc value(p: var P): Nif
proc fields(p: var P, tag: string): Nif =
  ## after '{': `name: value,` ... '}'
  result = tree(tag)
  while p.peek.kind != '}':
    let name = p.next.s
    if tag == "Ident" and name == "sym" and p.t[p.i+1].kind == 'w':
      # an identifier from the source: keep it verbatim (even `None`, `Some`)
      discard p.next
      result.kids.add tree(name, ident(p.next.s))
      if p.peek.kind == ',': discard p.next
      continue
    if p.peek.kind != ':':
      echo "at tok ", p.i, " ", p.t[max(0, p.i-6) .. min(p.t.high, p.i+3)]
      quit 1
    discard p.next
    let v = p.value
    if p.peek.kind == ',': discard p.next
    if name == "span" or name.endsWith("_token") or v.isNil: continue
    if v.kind == nkEmpty and false: continue
    result.kids.add tree(name, v)
  discard p.next

proc value(p: var P): Nif =
  let t = p.next
  case t.kind
  of 's': return str(t.s)
  of '(':
    result = tree("tuple")
    while p.peek.kind != ')':
      let v = p.value
      if p.peek.kind == ',': discard p.next
      if not v.isNil: result.kids.add v
    discard p.next
    if result.len == 1: return result[0]
  of '[':
    result = tree("list")
    while p.peek.kind != ']':
      let v = p.value
      if p.peek.kind == ',': discard p.next
      if not v.isNil: result.kids.add v
    discard p.next
  of 'w':
    let w = t.s
    if p.i < p.t.len and p.peek.kind == '{':
      discard p.next
      let f = p.fields(tagOf(w))
      # Ident { sym: x } -> ident atom
      if w == "Ident" and f.len >= 1 and f[0].tag == "sym": return f[0][0]
      # Lit::Int { token: 16 } -> (LitInt "16")
      return f
    if p.i < p.t.len and p.peek.kind == '[':
      let l = p.value
      l.tag = tagOf(w)
      return l
    if p.i < p.t.len and p.peek.kind == '(':
      discard p.next
      var r = tree(tagOf(w))
      while p.peek.kind != ')':
        let v = p.value
        if p.peek.kind == ',': discard p.next
        if not v.isNil: r.kids.add v
      discard p.next
      if w == "Some" and r.len == 1: return r[0]
      if w == "bytes": return nil
      if r.len == 1 and r[0].kind == nkTree: return r[0]
      return r
    if w == "Mut": return ident("mut")
    if w == "Semi": return ident("semi")
    if w in Punct: return (if w == "None": empty() else: nil)
    if w.len > 0 and (w[0] in {'0'..'9'} or w[0] == '-'): return str(w)
    return ident(w.replace("::", "."))
  else:
    doAssert false, "unexpected token " & $t

when isMainModule:
  var p = P(t: lex(readFile(paramStr(1))))
  let n = p.value
  stdout.write n.toNifModule("rust-parsed")
