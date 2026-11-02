import std/options
import nanuq, nanuqy
let df = newDataFrame(series("a", [some(1), none(int), some(3), some(4)]),
                      series("b", [1.5, 2.5, -1.0, 0.0]))
let exprs = [col("a") * lit(2) + col("b"),
             col("a").filter(col("b") > lit(0)).sum(),
             (col("a").sum() / col("b").mean()).alias("ratio"),
             col("a") > lit(2),
             col("a").count(), col("a").len(),
             col("a").cumSum()]
let got = df.nimSelect(exprs)
for i, e in exprs:
  echo got[i].toFrame
  echo df.select(e)
echo stats
echo readFile(cacheDir & "/last.nif")
