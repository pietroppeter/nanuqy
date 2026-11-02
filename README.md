# nanuqy

Polars expressions compiled to fused Nim kernels through NIF, with Polars (via
[Nanuq](https://github.com/pietroppeter/nanuq)) as fallback and as oracle. An experiment:
how much of Polars' Rust can Nim code generated on demand take over, step by step?
It started as a spike in Nanuq (pietroppeter/nanuq#68). It answers one question from the
[forum thread](https://forum.nim-lang.org/t/14258): Araq suggested that instead of
wrapping Rust we could "translate from your input source into a NIF model" and
"generate only the code that you actually need, on demand. In Nim." What is the
smallest piece of Nanuq where Nim code can take over from Rust that way, and can that
grow step by step without breaking the library?

## What it does

`nimSelect(df, exprs)` evaluates expressions with Nim code generated for exactly
those expressions:

```
Expr ── Polars' own JSON (e.meta.serialize) ──▶ untyped NIF        polars2nif.nim
     ── types from the frame's schema ────────▶ typed NIF (.nif)    sem.nim
     ── code generator reads the .nif file ───▶ Nim module          nif2nim.nim
     ── nim c --app:lib, cached by hash ──────▶ shared library      jit.nim
     ── run on the frame's Arrow buffers (no copy) ─▶ result Series back in Polars
        through the Arrow C Data Interface (no copy)
```

Anything outside the supported subset is evaluated by Polars, so the answer is always
complete. Supported: Int64 / Float64 columns (with or without nulls), `+ - * /`,
comparisons, `and`/`or`, negation, `abs`, `filter`, `sum`, `mean`, `min`, `max`,
`count`, `len`, arithmetic between aggregations, and the UInt32 counts. Every kernel is a
single fused loop: `(a * 2 + b).sum()` never builds the `a * 2` column.

For `col("a").filter(col("b") > lit(0)).mean()` (see `explain.nim`):

```nif
(.nif27)
(.vendor "nanuq")
(.lang "nq-query")
(kernels
  (kernel
    :k0.0.nq
    (name "a")
    (shape scalar)
    (inputs
      (input 0 "a" (i 64) nullable)
      (input 1 "b" (f 64) notnull))
    (mean
      (f 64)
      (filter
        (i 64)
        (col (i 64) 0 "a" nullable)
        (gt (bool) (col (f 64) 1 "b" notnull) (lit (f 64) 0.0))))))
```

```nim
proc k0(cols: ptr UncheckedArray[KCol], n: int, res: ptr KRes) {.exportc: "k0", dynlib, cdecl, gcsafe, raises: [].} =
  let c0 = cast[ptr UncheckedArray[int64]](cols[0].data)  # a
  ...
  for i in 0 ..< n:
    let t1 = fgt(c1[i], float64(0.0))
    let take4 = (true && true && (true && true) && t1) && isValid(v0, o0, i)
    let x5 = float64(c0[i])
    acc2 += keep(take4, x5)
    cnt3 += int(take4)
  res.isNull = not (cnt3 > 0)
  if (cnt3 > 0): res.f = (acc2 / float64(cnt3))
```

The typed NIF follows Nimony's IR conventions: the result type is the first child
(`(add T X X)`), int-to-float promotions are explicit `(conv T X)` nodes, the kernel name
is a symbol definition. The code generator only sees the `.nif` file, the way a Nimony
plugin or `{.build.}` backend would.

## Run it

```sh
nimble install https://github.com/pietroppeter/nanuq   # or a sibling ../nanuq checkout
nim c -r -d:nanuqLib=prebuilt tools/explain.nim             # every step for one expression
nim c -r -d:nanuqLib=prebuilt tools/demo.nim                # Nim result next to Polars' result
nim c -r -d:nanuqLib=prebuilt tests/difftest.nim 1 600      # seed, number of random expressions
nim c -r -d:release -d:nanuqLib=prebuilt bench/bench.nim    # 10 million rows
```

Kernels are cached in `$TMP/nanuq-nif-cache`. The `nim` compiler must be on the PATH at
run time: that is the price of generating code on demand.

## Results

### Correctness: Polars is the oracle

`difftest.nim` generates random expressions from the supported grammar (depth 3, five
columns: ints with nulls, ints without, floats with nulls and NaN, floats without, ints
near `int64` limits to force overflow), runs each through Polars and through the Nim
kernels, and compares name, type, values and nulls (floats within 1e-9 relative). It
does this on the full frame, on a slice (Arrow offsets), on an empty frame and on the
rows where one column is all null.

The first run found two real differences, both in how Polars treats NaN:

- comparisons use a total order: `NaN == NaN` is true and NaN is greater than every
  number (IEEE says false for both);
- `min`/`max` skip NaN, unless every value is NaN.

After fixing those (`kabi.nim`, `nif2nim.nim`), 8 seeds x 600 expressions x 4 frames agree.
Adding UInt32 arithmetic (the result type of `count`) took the fallbacks from 17 of 300
expressions to 1 and passed on the first run. That loop (extend the grammar, let the
oracle check it) is the process this experiment is about.

### Speed

10 million rows, `a` Int64 with 10% nulls, `b` Float64, best of 7, 4-core Linux sandbox.
"Nim kernel" includes the Arrow export and wrapping the result; "loop" is the generated
loop alone. Compiling all six kernels into one library took 1.3 s, once (then cached).

| query | Polars ms | Nim kernel ms | loop ms | Nim vs Polars |
|---|---:|---:|---:|---:|
| `(a * 2 + b).sum()` | 129.9 | 22.8 | 22.2 | 5.7x faster |
| `a.filter(b > 0).mean()` | 39.1 | 27.8 | 27.0 | 1.4x faster |
| `a.sum() / b.mean()` | 18.6 | 20.8 | 20.2 | 0.9x |
| `b.filter((a > 10) and (b < 0.5)).count()` | 36.7 | 26.1 | 25.3 | 1.4x faster |
| `a * 2 + b` (column) | 126.6 | 30.6 | 23.9 | 4.1x faster |
| `(a > 0) or (b < 0)` (boolean column) | 16.9 | 31.7 | 30.9 | 0.5x |

The kernels are one thread; Polars was as fast with `POLARS_MAX_THREADS=1`, so it does not
parallelize these single expressions either. The wins come from fusion: Polars
materializes `a * 2` and `a * 2 + b` as columns before summing. Polars wins where one
SIMD kernel per operation is already optimal (two plain aggregations, boolean output).

The first version of the generated code was 2-9x *slower* on filters and booleans.
Three code generation changes fixed most of it, and each is a lesson for any Nim engine:
Nim's `and`/`or` short-circuit, so they became a branch per row that mispredicts on random
data (now `&&`/`||` on bytes); gcc keeps a branch for a float `if` (now a bit mask,
`keep`); bits are now gathered 64 rows at a time instead of a read-modify-write per row.
Procs called in the loop also need `raises: []`, or each call checks Nim's error flag.

## Findings

**The Rust Nanuq owns is glue.** `src/rust/src/lib.rs` (about 6,100 lines) only converts
between C and Polars. Rewriting it in Nim gains nothing while Polars is the engine; the
one part that can move to Nim today is building columns: Nim can lay out Arrow buffers
itself and hand them over with `fromArrow`, as this experiment does for its results. The
real question is replacing Polars functionality, and that is what the experiment tries.

**The smallest piece is one expression.** Evaluating a numeric expression (arithmetic,
filters, aggregations) is self-contained: Polars already describes it as data (its DSL
serialized to JSON), the inputs and the output cross through Arrow without copies, and
Polars can still do everything else.

**A gradual replacement looks feasible, as a hybrid that grows.** This is the
"strangler" pattern:

- Polars stays the engine for whatever Nim does not cover yet, and the fallback is
  per expression, so coverage can grow one tag at a time with no flag day.
- Polars is also the oracle. Random differential tests found real semantic differences
  in the first minutes, and Nanuq already has more oracles: every spec requirement has
  a Nim example with Polars' output (`nimble specexamples`), and the book runs
  18+ chapters of reference Polars code against expected output. A Nim engine can run
  under all of them and be diffed against Polars release by release.
- Each Polars upgrade can change semantics (2.x changed several). Re-running the
  differential tests against the new pinned Polars catches that.

**What makes it hard, roughly in order:**

1. Breadth. Strings, temporal types, categoricals, lists and structs, group-by and joins
   (hash tables, spilling), window functions, sorting. Each has subtle semantics; the NaN
   ordering above is a small example.
2. The optimizer. Predicate and projection pushdown, common subexpressions, the streaming
   engine. The sensible split keeps Polars as the planner and takes over *execution* of
   plan nodes, which needs Polars' optimized plan as data (it serializes its DSL plan
   today; the optimized IR would need a new export from `lib.rs`).
3. I/O. CSV, Parquet, IPC, JSON and cloud readers are a large part of Polars and the last
   thing worth replacing.
4. Parallelism. These kernels use one thread. Chunked parallel loops are straightforward;
   Polars' work stealing is not. Nimony's passive procs are the natural tool later.
5. Compile latency. About 1.3 s per new set of kernels with the C backend; cached
   afterwards. For queries known at compile time a macro (or a Nimony plugin) can generate
   the same code ahead of time, with no compiler needed at run time.

Replacing Polars completely means matching a project with many person-years in it, and
following its releases. With specs, the book and a Polars oracle for every step, an
agent-driven port of the commonly used core looks plausible; all of it, I/O and the
streaming engine included, is a multi-year effort. Either way the path goes through a
hybrid where Nim first takes over the parts where it adds something.

**Where Nim adds something (so where to grow first):**

- Fusion: whole expression trees in one loop, 4-6x on arithmetic chains above.
- Nim functions inside queries. Today `mapElements` calls back into Nim per batch and
  copies strings and structs. A generated kernel can inline the user's Nim proc into the
  loop instead, which is the place where Nanuq could beat Python Polars, not just match it.
- Other targets. The same typed NIF can go to Nimony instead of `nim c`, and from there to
  its native and C backends or a GPU backend. Nimony has the seams: `{.build("nimony c",
  "backend.nim").}` routes a module's IR through an external code generator ("for example a
  GPU kernel binary"), and a `{.gpu.}` colouring plus checker plugin exists in its tests.
  There is no complete GPU code generator in the repository yet: that is the part Araq
  means by "refine Nimony's GPU codegen strategy".

## Through Nimony

`nimony/` runs the six benchmark kernels (`bench_kernels.nif`) through Nimony 0.6.3
(nim-lang/nimony at 6d55886, 2026-11-02), built with `nim c -r src/hastur/hastur build all`.
`nif2nim --nimony` emits the variant: three differences only. Nimony pointers are not-nil by
default, so the module uses `{.feature: "lenientnils".}` (validity pointers are nil for
columns without nulls); there are no `overflowChecks`-style push pragmas (`-d:danger`
turns checks off); kernels are linked into the program, not exported from a dynlib.

```sh
nim c -r src/nanuqy/nif2nim.nim --nimony nimony/bench_kernels.nif > nimony/kny.nim
nim c -r src/nanuqy/nif2nim.nim nimony/bench_kernels.nif > nimony/kn2.nim
cd nimony
nimony c -r -d:danger harness.nim   # Nimony, C backend
nim c -r -d:danger harness.nim      # Nim 2, same kernels (kn2.nim)
nimony c -r -d:danger par.nim       # one kernel as a parallel for
```

Results on 10M synthetic rows: the same values and checksums from both compilers, and
the same speed (within noise, 19-37 ms per kernel for both). The LLVM backend (`nimony l`)
needs a newer clang than this sandbox has (LLVM 19 IR syntax); the native backend
(`nimony n`) needs the separate nativenif tools; neither was tried further.

`par.nim` writes the elementwise kernel `a * 2 + b` with Nimony's parallel for
(`for i in 0 || (n - 1)`, `std/parfor`): 20.9 ms sequential, 6.9 ms on 4 cores, same
checksum. Its plugin checks statically that the loop has no data races (it rejects a write
to `x[i]` inside a nested loop), which suits generated code.

## Translating Polars' own Rust through NIF

The kernels above are written from Polars' *documented behaviour*. Another reading of
Araq's suggestion is to put the *Rust source itself* into NIF and generate Nim from it.
`rust2nif/` tries that on one real Polars kernel,
[`float_sum.rs`](https://github.com/pola-rs/polars/blob/py-2.1.0/crates/polars-compute/src/float_sum.rs)
(polars-compute at py-2.1.0, 314 lines), the pairwise float sum behind `col("x").sum()`.

```
float_sum.rs --syn (rs2nif, 6 lines of Rust)--> Debug tree
  --dbg2nif--> NIF "rust-parsed" (8.7k lines) --rcompact--> NIF "rust-core" (2.7k lines)
  --rs2nim--> float_sum_gen.nim (114 lines) + rshim.nim (hand-written std/arrow pieces)
```

- `rs2nif` is the only Rust: it prints syn's parse of the file. `dbg2nif` turns that into
  NIF and `rcompact` is a NIF-to-NIF pass that removes syntax noise (spans, punctuation,
  default enum values, single-segment paths). Both know nothing about the program.
- `rs2nim` lowers rust-core NIF to Nim. It knows Rust syntax in general (let, while, for,
  ranges, if/if let, match, tuples, casts, unsafe blocks, `&self` methods, compound
  assignment) and a few idioms by name (`iter().map(..).sum()`, `try_into().ok()`, `as_()`,
  `F::zero()`). Rust's `/` and `%` become `rdiv`/`rmod`, overloaded per type in the shim, so
  no type inference is needed. `#[cfg(feature = "simd")]` items are dropped: the non-SIMD
  impl gives the same lane order. Generics are monomorphized (`T=F=float64`); generics
  that only appear in a where clause stay Nim generics.
- `rshim.nim` is what the source cannot provide: views for `&[T]`, `as_chunks`,
  `split_at`, polars-arrow's `BitMask`, and one std fact found while testing: Rust's
  `impl Sum for f64` folds from -0.0, not 0.0.

Result (`rust2nif/run.sh`, 1300 random arrays over 4 seeds, lengths 0 to 1M, null rates 0
to 100 %, sliced views with Arrow offsets, values up to 1e16 so the summation order shows):
**the translated Nim is bit-identical to Polars' sum on every array**, while a plain
left-to-right loop matches on only about 6 % of them. 10M values on one thread: Polars
3.6 ms, translated Nim 4.4 ms (`-d:danger`, no SIMD flags), same bits.

One thing the oracle had to learn: Polars' sum is only reproducible on one thread with the
in-memory engine. With more threads, or the streaming engine (which `Engine.Auto` picks
for large frames), the column is split into pieces summed in parallel, and the last bit can
change from run to run. The test sets `POLARS_MAX_THREADS=1` and `Engine.InMemory`.

How far does this go? `rust2nif/coverage.sh` runs the pipeline over all of
polars-compute (111 files, 24.7k lines). syn parses every file, and **573 of 856
functions** lower without an unsupported node. That is syntax coverage only: the output
is not compiled, and each crate API it calls needs a shim (polars-compute calls 415
distinct method names). The biggest gaps, by occurrences: `dyn Trait` types (131), closures
with statement bodies (128), macros in expressions (104: `vec!`, `polars_bail!`,
`unreachable!`, ...; syn gives macro bodies as token streams), `?` (68), struct literals
(58), `_` types (40). Each is a design choice more than work: closures could become Nim
lambdas or inlined loops, `?` needs an error model, `dyn` needs a vtable story.

So the honest summary: on a self-contained numeric kernel, mechanical Rust → NIF → Nim
works and Polars confirms it to the bit. The cost moves into the shim (std, arrow,
polars-utils) and into lowering rules for each Rust idiom, which is the kind of work an
agent can grind through with the oracle checking every step.

## What this experiment did not do

- The host side (`jit.nim`, Nanuq itself) is Nim 2; Nimony compiles the kernels only.
  The NIF reader/writer here is a small stand-alone one written against the
  [NIF 2027 spec](https://github.com/nim-lang/nifspec), and the typed NIF goes to Nimony as
  generated Nim source, not as Nimony NIF directly.
- No strings, dates, group-by or lazy plans, no multithreading, no integration with
  `LazyFrame.collect`.

## Possible next steps, smallest first

1. Inline Nim procs into kernels (`mapElements` without callbacks or copies), and measure
   against the `benchmarks/map_elements.nim` numbers.
2. Take over plan nodes: a `select`/`with_columns`/`filter` on a scan, chunked and
   multi-threaded, still falling back per node.
3. Feed the typed NIF to Nimony and compare its C and native backends with `nim c`.
4. A GPU backend through Nimony's `{.build.}` seam, for the same kernels.

## Files

| file | step |
|---|---|
| `src/nanuqy/nif.nim` | minimal NIF 2027 reader and writer |
| `src/nanuqy/polars2nif.nim` | Polars expression JSON to untyped NIF |
| `src/nanuqy/sem.nim` | typing with Polars' rules, typed NIF |
| `src/nanuqy/nif2nim.nim` | typed NIF to a Nim module (also a stand-alone tool) |
| `src/nanuqy/kabi.nim` | ABI and helpers shared by host and kernels |
| `src/nanuqy/jit.nim` | compile, cache, load, run on Arrow buffers, `nimSelect` |
| `tests/difftest.nim` | random differential test against Polars |
| `bench/bench.nim` | timings against Polars |
| `tools/explain.nim`, `tools/demo.nim` | look at each step |
| `nimony/` | the kernels through Nimony |
| `rust2nif/` | Polars' `float_sum.rs` through NIF to Nim, bit-exact test, coverage script |

## Explainer

A walk through one query, with the NIF at each step: https://claude.ai/artifact/3pEzTXqEK9wGrDcdh3YRYQ
