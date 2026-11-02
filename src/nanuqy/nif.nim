## A tiny reader and writer for the subset of NIF (NIF 2027, see
## https://github.com/nim-lang/nifspec) this experiment needs: compound nodes,
## identifiers, symbols, string literals, integers, floats, the empty node and
## directives. No line information, comments or index: the trees are small and
## generated. Nimony's own `nifreader`/`nifbuilder` (src/lib in nim-lang/nimony)
## are the production versions; this file only avoids depending on them here.

import std/[strutils, math]

type
  NifKind* = enum
    nkTree, nkIdent, nkSym, nkSymDef, nkStr, nkInt, nkUInt, nkFloat, nkEmpty
  Nif* = ref object
    case kind*: NifKind
    of nkTree:
      tag*: string
      kids*: seq[Nif]
    of nkIdent, nkSym, nkSymDef, nkStr: s*: string
    of nkInt: i*: int64
    of nkUInt: u*: uint64
    of nkFloat: f*: float64
    of nkEmpty: discard
  NifError* = object of ValueError

proc tree*(tag: string, kids: varargs[Nif]): Nif = Nif(kind: nkTree, tag: tag, kids: @kids)
proc ident*(s: string): Nif = Nif(kind: nkIdent, s: s)
proc sym*(s: string): Nif = Nif(kind: nkSym, s: s)
proc symDef*(s: string): Nif = Nif(kind: nkSymDef, s: s)
proc str*(s: string): Nif = Nif(kind: nkStr, s: s)
proc intLit*(i: int64): Nif = Nif(kind: nkInt, i: i)
proc uintLit*(u: uint64): Nif = Nif(kind: nkUInt, u: u)
proc floatLit*(f: float64): Nif = Nif(kind: nkFloat, f: f)
proc empty*(): Nif = Nif(kind: nkEmpty)

proc `[]`*(n: Nif, i: int): Nif = n.kids[i]
proc len*(n: Nif): int = (if n.kind == nkTree: n.kids.len else: 0)
proc isTag*(n: Nif, tag: string): bool = n.kind == nkTree and n.tag == tag

# --- writing -----------------------------------------------------------------

const Control = {'(', ')', '[', ']', '{', '}', '~', '#', '\'', '"', '\\', ':', '@'}

proc escapeStr(s: string): string =
  for c in s:
    case c
    of '\\': result.add "\\|"
    of '"': result.add "\\^"
    of '\n': result.add "\\n"
    of '\t': result.add "\\t"
    of '\r': result.add "\\r"
    of '#', ':': result.add c  # allowed inside string literals
    elif c in Control or c.ord < 32: result.add "\\" & toHex(c.ord, 2)
    else: result.add c

proc escapeName(s: string): string =
  for c in s:
    if c in Control or c.ord <= 32: result.add "\\" & toHex(c.ord, 2)
    else: result.add c

proc fmtFloat(f: float64): string =
  if f.isNaN or f.classify in {fcInf, fcNegInf}:
    raise newException(NifError, "NIF has no spelling for " & $f)
  # Nim's `$` is the shortest round-trip spelling; NIF wants an upper-case E.
  result = ($f).replace("e", "E")
  if '.' notin result and 'E' notin result: result.add ".0"

proc write(n: Nif, res: var string, indent: int, pretty: bool) =
  case n.kind
  of nkTree:
    let inline = not pretty or n.kids.len == 0 or
                 (block:
                   var allAtoms = true
                   for k in n.kids:
                     if k.kind == nkTree and k.kids.len > 0 and k.tag notin ["i", "u", "f", "name", "shape"]: allAtoms = false
                   allAtoms)
    res.add "(" & n.tag
    for k in n.kids:
      if inline: res.add " "
      else: res.add "\n" & spaces(indent + 2)
      k.write(res, indent + 2, pretty)
    res.add ")"
  of nkIdent: res.add escapeName(n.s)
  of nkSym: res.add escapeName(n.s)
  of nkSymDef: res.add ":" & escapeName(n.s)
  of nkStr: res.add "\"" & escapeStr(n.s) & "\""
  of nkInt: res.add $n.i
  of nkUInt: res.add $n.u & "u"
  of nkFloat: res.add fmtFloat(n.f)
  of nkEmpty: res.add "."

proc `$`*(n: Nif): string = n.write(result, 0, false)
proc pretty*(n: Nif): string = n.write(result, 0, true)

proc toNifModule*(n: Nif, lang: string): string =
  ## A NIF file: version directive (which must come first), vendor and
  ## language directives, then the tree.
  "(.nif27)\n(.vendor \"nanuq\")\n(.lang \"" & lang & "\")\n" & n.pretty & "\n"

# --- reading -----------------------------------------------------------------

type Parser = object
  s: string
  p: int

proc err(p: Parser, msg: string) {.noreturn.} =
  raise newException(NifError, "NIF parse error at byte " & $p.p & ": " & msg)

proc skipWs(p: var Parser) =
  while p.p < p.s.len and p.s[p.p] in {' ', '\t', '\n', '\r'}: inc p.p

proc unescape(p: var Parser, stop: set[char]): string =
  while p.p < p.s.len and p.s[p.p] notin stop:
    let c = p.s[p.p]
    if c == '\\':
      if p.p + 1 >= p.s.len: p.err "dangling escape"
      let d = p.s[p.p + 1]
      case d
      of 'n': result.add '\n'; inc p.p, 2
      of 't': result.add '\t'; inc p.p, 2
      of 'r': result.add '\r'; inc p.p, 2
      of '|': result.add '\\'; inc p.p, 2
      of '^': result.add '"'; inc p.p, 2
      else:
        if p.p + 2 >= p.s.len: p.err "short hex escape"
        result.add char(parseHexInt(p.s[p.p+1 .. p.p+2])); inc p.p, 3
    else:
      result.add c; inc p.p

proc parseNode(p: var Parser): Nif =
  p.skipWs
  if p.p >= p.s.len: p.err "unexpected end"
  let c = p.s[p.p]
  case c
  of '(':
    inc p.p
    let start = p.p
    while p.p < p.s.len and p.s[p.p] notin {' ', '\t', '\n', '\r', '(', ')'}: inc p.p
    result = tree(p.s[start ..< p.p])
    while true:
      p.skipWs
      if p.p >= p.s.len: p.err "missing )"
      if p.s[p.p] == ')': inc p.p; break
      result.kids.add p.parseNode
  of '"':
    inc p.p
    result = str(p.unescape({'"'}))
    if p.p >= p.s.len: p.err "unterminated string"
    inc p.p
  of '.':
    inc p.p
    result = empty()
  of '-', '0'..'9':
    let start = p.p
    inc p.p
    while p.p < p.s.len and p.s[p.p] in {'0'..'9', '.', 'E', '+', '-', '_', 'x', 'o', 'b', 'u',
                                         'a'..'f', 'A'..'F'}: inc p.p
    let tok = p.s[start ..< p.p].replace("_", "")
    if tok.endsWith("u"): result = uintLit(parseBiggestUInt(tok[0 ..< ^1]))
    elif ('.' in tok or 'E' in tok) and not tok.contains("0x"): result = floatLit(parseFloat(tok))
    else: result = intLit(parseBiggestInt(tok))
  of ':':
    inc p.p
    result = symDef(p.unescape({' ', '\t', '\n', '\r', '(', ')'}))
  else:
    let name = p.unescape({' ', '\t', '\n', '\r', '(', ')'})
    if name.len == 0: p.err "unexpected '" & $c & "'"
    result = if '.' in name: sym(name) else: ident(name)

proc parseNif*(s: string): Nif =
  ## Parses a NIF module and returns its (single) tree, skipping directives.
  var p = Parser(s: s)
  while true:
    let n = p.parseNode
    if n.kind == nkTree and n.tag.startsWith("."): continue
    return n
