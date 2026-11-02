## Proof of concept, as a nimib page: one Polars Rust function through NIF into
## Nim, step by step, then a Nim proc inside a generated kernel. Every block runs.
##
##   rust2nif/run.sh        # builds the tools once
##   nim r -d:release -d:nanuqLib=prebuilt docs/poc.nim

import nimib
import std/[os, osproc, strutils, strformat, sequtils]
import ../../nanuq/docs/nanuqtheme

nbInit
nb.title = "Rust to Nim through NIF"
nb.useNanuqTheme(
  titleHtml = "From Polars' Rust to Nim, <em>through NIF</em>",
  eyebrow = "nanuqy · proof of concept",
  epigraph = "One real Polars function, followed through every step: Rust source, syn's tree, NIF, compacted NIF, generated Nim, and a run that shows why the details matter.",
  meta = "Research · nanuqy (pietroppeter/nanuqy#1) · Nim " & NimVersion & " · rendered with nimib",
  summary = "A step-by-step proof of concept: Polars' Rust translated mechanically to Nim through NIF, plus a Nim proc inlined into a generated kernel.")

const root = currentSourcePath.parentDir.parentDir
const tools = root / "rust2nif"
let work = getTempDir() / "nanuqy-poc"
createDir(work)

proc run(cmd: string): string =
  ## runs a pipeline tool; stops the page build if it fails
  let (output, code) = execCmdEx(cmd)
  doAssert code == 0, cmd & "\n" & output
  output

proc excerpt(path, marker: string, before, after: int): string =
  ## the lines around the first line containing `marker`, shifted left: the
  ## statement sits deep inside the file's tree (File, items, fn, block,
  ## while, body, ...), and each level of nesting adds indentation
  let lines = readFile(path).splitLines
  for i, l in lines:
    if marker in l:
      let part = lines[max(0, i - before) .. min(lines.high, i + after)]
      var cut = high(int)
      for x in part:
        if x.strip.len > 0: cut = min(cut, x.len - x.strip(trailing = false).len)
      return part.mapIt(if it.len >= cut: it[cut .. ^1] else: it.strip).join("\n")
  "(marker not found)"

proc lineCount(path: string): int = readFile(path).strip.splitLines.len

nbText: """
Araq's suggestion on the forum, as you read it: put Polars' *Rust source* into NIF and
generate Nim from it, instead of wrapping the compiled library. This page does that for
one small, real function and shows what each step produces. A second part shows the
other direction: your own Nim proc running inside a kernel generated for a Polars query.

## The function

`vector_horizontal_sum` is a helper in Polars' `float_sum.rs` (polars-compute, tag
py-2.1.0). It adds up 16 partial sums, but in a specific order, folding the array onto
itself, because that order maps to SIMD shuffle instructions. Float addition is not
associative, so the order is part of what the function *means*: a different order gives
different bits.
"""

nbCode:
  let rust = """
const STRIPE: usize = 16;

fn vector_horizontal_sum<V, T>(mut v: V) -> T
where
    V: IndexMut<usize, Output = T>,
    T: Add<T, Output = T> + Sized + Copy,
{
    let mut width = STRIPE;
    while width > 4 {
        for j in 0..width / 2 {
            v[j] = v[j] + v[width / 2 + j];
        }
        width /= 2;
    }

    (v[0] + v[2]) + (v[1] + v[3])
}
"""
  writeFile(work / "tiny.rs", rust)

nbText: """
## Step 1: Rust parses it

The only Rust in the pipeline is `rs2nif`, six lines that call
[syn](https://docs.rs/syn) (the parser Rust macros use) and print its tree with
`{:#?}`. We follow one statement, `width /= 2;`, through every step. The statement
sits about ten levels deep in the file's tree (file, items, function, body, while,
for body, ...), so the excerpts below are shifted left; the closing brackets at the
end of each excerpt close those outer levels.
"""

nbCode:
  discard run(&"{tools}/rs2nif/target/release/rs2nif {work}/tiny.rs > {work}/tiny.dbg")
  echo lineCount(work / "tiny.dbg"), " lines. The statement `width /= 2;`:"
  echo excerpt(work / "tiny.dbg", "BinOp::DivAssign", 19, 13)

nbText: """
## Step 2: the same tree as NIF

`dbg2nif` rewrites that text as NIF: `Name { field: value }` becomes
`(Name (field value))`, lists become `(list ...)`, source spans are dropped. Nothing
here knows what the program does; it is a change of notation. From now on every tool reads
and writes NIF, so each step can be inspected, diffed, or replaced on its own.
"""

nbCode:
  discard run(&"{tools}/dbg2nif {work}/tiny.dbg > {work}/tiny.nif")
  echo lineCount(work / "tiny.nif"), " lines of NIF (dialect \"rust-parsed\"). The statement:"
  echo excerpt(work / "tiny.nif", "BinOpDivAssign", 14, 7)

nbText: """
## Step 3: a NIF-to-NIF pass removes the noise

`rcompact` is a purely structural pass: it drops empty fields and default values
(`(attrs (list))`, `(qself .)`, `PathArguments.None`) and turns a one-segment path into
a plain identifier. The result is the "rust-core" dialect. Passes like this are cheap to
write because NIF is just trees.
"""

nbCode:
  discard run(&"{tools}/rcompact {work}/tiny.nif > {work}/tiny.core.nif")
  echo lineCount(work / "tiny.core.nif"), " lines (dialect \"rust-core\"). The statement:"
  echo excerpt(work / "tiny.core.nif", "BinOpDivAssign", 3, 6)

nbText: """
## Step 4: rust-core NIF becomes Nim

`rs2nim` knows Rust *syntax* (let, while, for over a range, indexing, compound
assignment, the tail expression as the result) and a few idioms by name. Two choices
are visible here:

- `T` is monomorphized to `float64` (`--mono T=float64`), the instantiation Polars uses
  for a Float64 column. `V` appears only in a where clause, so it stays a Nim generic.
- Rust's `/` is integer division on integers and true division on floats. Instead of
  inferring types, the translator writes `rdiv`, which a small hand-written shim
  overloads per type.
"""

nbCode:
  discard run(&"{tools}/rs2nim {work}/tiny.core.nif --mono T=float64 > {work}/tinygen.nim 2> {work}/tiny.log")
  echo readFile(work / "tinygen.nim")

nbText: """
## Step 5: run it, and see why the order matters

Sixteen values: 1e16 at position 0, -1e16 at position 8, and 1.0 everywhere else. The
exact sum is 14. In float64, 1e16 + 1 rounds back to 1e16, so a left-to-right loop loses
every 1.0 that comes before the -1e16. The translated Polars order pairs position 0 with
position 8 first, so the large values cancel before any 1.0 is added.
"""

nbCode:
  copyFile(tools / "rshim.nim", work / "rshim.nim")
  writeFile(work / "tinyrun.nim", """
import tinygen
var v: array[16, float64]
for i in 0 ..< 16: v[i] = (if i == 0: 1e16 elif i == 8: -1e16 else: 1.0)
var naive = 0.0
for x in v: naive += x
echo "translated Polars order: ", vector_horizontal_sum(v)
echo "left to right:           ", naive
""")
  echo run(&"nim c -r --hints:off --warnings:off {work}/tinyrun.nim")

nbText: """
## The same pipeline on the whole file

`rust2nif/run.sh` translates all of `float_sum.rs` the same way: 314 lines of Rust, eight
functions with pairwise recursion, validity masks and remainders. The test compares the
bit patterns of Polars' own `col("x").sum()` with the translated Nim on the same Arrow
buffers. The arrays have lengths from 0 to 1M, nulls, sliced views, and values large
enough that a different order changes the result.

Polars only gives reproducible bits on one thread with the in-memory engine. With more
threads it splits the column and adds the pieces in whatever order they finish, so the
test pins `POLARS_MAX_THREADS=1`.
"""

nbCode:
  # rust2nif/run.sh builds this test; 200 random arrays, seed 1
  echo run(&"{tools}/test_float_sum 1 200")

nbText: """
Across all of polars-compute (111 files), syn parses every file, and 573 of 856
functions translate without hitting a construct the translator doesn't know yet. That
count is syntax only: the output isn't compiled. The main gaps are `dyn Trait`, closures
with statement bodies, macros, the `?` operator and struct literals.

## The other direction: a Nim proc inside a generated kernel

The first nanuqy experiment generates Nim kernels from Polars *queries*: Polars
describes the expression as JSON, nanuqy turns it into typed NIF, and from that into one
fused Nim loop over the Arrow buffers. Now a Nim proc can be part of that loop.
`{.nimKernel.}` keeps the proc as it is and records its source; `nimCall` puts it in a query.
"""

nbCode:
  import nanuq
  import nanuqy

  proc toFeet(m: float64): float64 {.nimKernel.} = m * 3.28084

  let peaks = newDataFrame:
    peak: ["Mont Blanc", "Monte Rosa", "Weisshorn"]
    m: [4806.0, 4634.0, 4506.0]

  let r = peaks.nimSelect(nimCall("toFeet", col("m")), nimCall("toFeet", col("m")).sum)
  echo r[0]
  echo r[1]
  echo stats.nimKernels, " Nim kernels, ", stats.polarsFallbacks, " Polars fallbacks"

nbText: """
Polars can't serialize a callback, so `nimCall` writes a placeholder it can serialize,
`as_struct(lit("__nimudf:toFeet"), col("m"))`, and nanuqy reads that back as a call. In
the typed NIF the proc's source travels next to the kernels, as a string (NIF escapes
parentheses and braces inside strings, hence `\28` and `\7B`):
"""

nbCode:
  echo excerpt(cacheDir / "last.nif", "(udf", 0, 1)

nbText: """
The code generator copies it into the module as an `{.inline.}` proc. The fused loop calls
it like any other Nim proc, so the C compiler inlines it, with no callback, no per-row
lock, and no intermediate Series. Here is the generated loop of the second kernel, the
sum:
"""

nbCode:
  var kernelSrc = ""
  for f in walkFiles(cacheDir / "k_*.nim"):
    if "toFeet(" in readFile(f) and "proc k1" in readFile(f): kernelSrc = f
  let lines = readFile(kernelSrc).splitLines
  let k1 = lines.find(lines.filterIt(it.startsWith("proc k1"))[0])
  echo excerpt(kernelSrc, "proc toFeet", 0, 1)
  echo "..."
  for i in k1 ..< lines.len:
    if "toFeet(" in lines[i]:
      echo lines[i-1 .. i+4].join("\n"); break

nbText: """
On 1M rows that is 5x faster than nanuq's `mapElements` for a light proc like this one,
and 1.2 to 1.6x for heavy ones. Haversine over four columns takes 103 ms, against 165 ms
for the same formula written as native Polars expressions. Numbers and tests are in
[nanuqy#1](https://github.com/pietroppeter/nanuqy/pull/1).

## What NIF bought us

- Every step is a separate program that reads and writes text trees, so a step can be
  inspected, diffed in CI (the committed `float_sum.core.nif` and generated Nim must be
  reproduced exactly), or swapped out.
- Rust's tree and the query's tree use the same notation. The translator, the compactor
  and the kernel generator share one small reader and writer.
- Nim source can travel inside NIF next to the kernels. A natural next step is to carry
  the proc as Nim's own NIF, from Nimony's nifler, instead of as a string.
"""

nbSave

# The theme's footer links the Nanuq repo; this page lives in nanuqy.
let page = currentSourcePath.changeFileExt("html")
if fileExists(page):
  writeFile(page, readFile(page).replace("https://github.com/pietroppeter/nanuq\"", "https://github.com/pietroppeter/nanuqy\"").replace(">pietroppeter/nanuq<", ">pietroppeter/nanuqy<"))
