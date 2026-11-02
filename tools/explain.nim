## Shows each step for one expression: Polars' JSON, untyped NIF, typed NIF
## and the generated Nim kernel.
##   nim c -r -d:nanuqLib=prebuilt explain.nim
import std/options
import nanuq
import nanuqy/[nif, polars2nif, jit, nif2nim]

proc explain*(df: DataFrame, e: Expr) =
  let json = e.meta.serialize(SerializationFormat.Json)
  echo "Polars JSON:\n  ", json
  echo "untyped NIF:\n  ", toNif(json)
  let (plan, kernels) = planKernels(df, [e])
  if plan[0].isNone:
    echo "not supported, Polars evaluates it: ", stats.fallbackReasons[^1]
    return
  echo "typed NIF:\n", kernels.toNifModule("nq-query")
  echo "generated Nim:\n", genKernel(kernels[0])

when isMainModule:
  let df = newDataFrame(series("a", [some(1), none(int), some(3)]), series("b", [1.5, -2.0, 0.5]))
  df.explain(col("a").filter(col("b") > lit(0)).mean())
