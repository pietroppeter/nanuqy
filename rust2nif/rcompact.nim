## NIF -> NIF pass: compacts syn's "rust-parsed" tree into a smaller
## "rust-core" shape. Purely structural, no knowledge of the program.
import std/os
import ../src/nanuqy/nif

proc isEmptyish(n: Nif): bool =
  n.kind == nkEmpty or (n.kind == nkTree and n.tag in ["list", "Some", "tuple"] and n.len == 0) or
    (n.kind == nkSym and n.s in ["Visibility.Inherited", "PathArguments.None",
                                 "TraitBoundModifier.None", "AttrStyle.Outer", "ReturnType.Default",
                                 "StaticMutability.None", "FieldMutability.None"])

proc compact*(n: Nif): Nif =
  if n.kind != nkTree: return n
  var kids: seq[Nif]
  for k in n.kids:
    let c = compact(k)
    if c.isNil or c.isEmptyish: continue
    # (field (list a b)) -> (field a b)
    kids.add c
  var r = tree(n.tag)
  for c in kids:
    if c.kind == nkTree and c.tag == "list" and n.tag != "list":
      for x in c.kids: r.kids.add x
    else:
      r.kids.add c
  # a field whose value was dropped
  if r.len == 0 and r.tag.len > 0 and r.tag[0] in {'a'..'z'}: return nil
  # Path with one plain segment -> the ident
  case r.tag
  of "Path":
    # (Path (segments S1 S2 ...)) ; segment: (PathSegment (ident X) [arguments])
    if r.len == 1 and r[0].isTag("segments"):
      let segs = r[0]
      if segs.len == 1 and segs[0].isTag("PathSegment") and segs[0].len == 1 and segs[0][0].isTag("ident"):
        return segs[0][0][0]
      var p = tree("qpath")
      for s in segs.kids:
        if s.isTag("PathSegment") and s.len == 1 and s[0].isTag("ident"): p.kids.add s[0][0]
        elif s.isTag("PathSegment"):
          var g = tree("generic")
          for x in s.kids:
            if x.isTag("ident"): g.kids.add x[0]
            elif x.isTag("arguments"):
              for y in x.kids:
                if y.isTag("PathArgumentsAngleBracketed"):
                  for z in y.kids:
                    if z.isTag("args"):
                      for a in z.kids: g.kids.add a
                else: g.kids.add y
            else: g.kids.add x
          p.kids.add g
        else: p.kids.add s
      return p
  of "TypePath", "ExprPath", "PatPath":
    if r.len == 1 and r[0].isTag("path"): return r[0][0]
  of "path", "expr", "ty", "pat", "func", "receiver", "body", "output", "init", "cond", "else_branch":
    if r.len == 1: return r   # keep the role label
  else: discard
  # (Some x) -> x
  if r.tag == "Some" and r.len == 1: return r[0]
  r

when isMainModule:
  stdout.write compact(parseNif(readFile(paramStr(1)))).toNifModule("rust-core")
