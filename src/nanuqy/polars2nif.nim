## Step 1: a Polars expression, as Polars itself describes it (its DSL `Expr`
## serialized to JSON), becomes an *untyped* NIF tree in the small "nq-query"
## language. Anything outside the supported subset raises `Unsupported`, which
## the caller turns into "let Polars do it".
##
##   {"Agg":{"Sum":{"BinaryExpr":{"left":{"Column":"a"},"op":"Multiply",...}}}}
##   ==>  (sum (mul (col "a") 2))

import std/[json, strutils]
import nif

const UdfMarker* = "__nimudf:"  # see udf.nim

type Unsupported* = object of CatchableError

proc unsupported(what: string) {.noreturn.} =
  raise newException(Unsupported, what)

const BinOps = {"Plus": "add", "Minus": "sub", "Multiply": "mul", "TrueDivide": "div",
                "Gt": "gt", "GtEq": "ge", "Lt": "lt", "LtEq": "le", "Eq": "eq",
                "NotEq": "ne", "And": "and", "Or": "or"}

proc lookup(op: string): string =
  for (k, v) in BinOps:
    if k == op: return v
  unsupported("binary operator " & op)

proc single(j: JsonNode): (string, JsonNode) =
  ## Polars' serde form of an enum variant: {"Variant": payload}.
  if j.kind == JString: return (j.getStr, newJNull())
  if j.kind != JObject or j.len != 1: unsupported("expression " & $j)
  for k, v in j: return (k, v)

proc toNif*(j: JsonNode): Nif =
  let (variant, v) = single(j)
  case variant
  of "Column":
    result = tree("col", str(v.getStr))
  of "Literal":
    let (lk, lv) = single(v)
    if lk != "Dyn": unsupported("typed literal " & $v)
    let (dk, dv) = single(lv)
    case dk
    of "Int": result = tree("dynlit", intLit(dv.getBiggestInt))
    of "Float": result = tree("dynlit", floatLit(dv.getFloat))
    else: unsupported("literal " & $v)
  of "BinaryExpr":
    result = tree(lookup(v["op"].getStr), toNif(v["left"]), toNif(v["right"]))
  of "Function":
    let fname = v["function"]
    if fname.kind != JString: unsupported("function " & $fname)
    if fname.getStr == "AsStruct" and v["input"].len >= 1:
      # nimCall's placeholder: as_struct(lit("__nimudf:name"), args...)
      let first = v["input"][0]
      if first.hasKey("Literal") and first["Literal"].hasKey("Scalar") and
         first["Literal"]["Scalar"].hasKey("String"):
        let marker = first["Literal"]["Scalar"]["String"].getStr
        if marker.startsWith(UdfMarker):
          result = tree("call", str(marker[UdfMarker.len .. ^1]))
          for i in 1 ..< v["input"].len: result.kids.add toNif(v["input"][i])
          return
    let tag = case fname.getStr
              of "Negate": "neg"
              of "Abs": "abs"
              else: unsupported("function " & fname.getStr)
    if v["input"].len != 1: unsupported("function arity")
    result = tree(tag, toNif(v["input"][0]))
  of "Filter":
    result = tree("filter", toNif(v["input"]), toNif(v["by"]))
  of "Agg":
    let (ak, av) = single(v)
    case ak
    of "Sum": result = tree("sum", toNif(av))
    of "Mean": result = tree("mean", toNif(av))
    of "Min", "Max":
      if av["propagate_nans"].getBool: unsupported("nan_min / nan_max")
      result = tree(if ak == "Min": "min" else: "max", toNif(av["input"]))
    of "Count":
      result = tree(if av["include_nulls"].getBool: "len" else: "count", toNif(av["input"]))
    else: unsupported("aggregation " & ak)
  of "Alias":
    result = tree("alias", toNif(v[0]), str(v[1].getStr))
  else:
    unsupported("expression kind " & variant)

proc toNif*(polarsJson: string): Nif = toNif(parseJson(polarsJson))
