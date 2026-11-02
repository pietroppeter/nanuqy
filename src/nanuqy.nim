## nanuqy: Polars expressions compiled to Nim kernels through NIF.
##
## `nimSelect(df, exprs)` evaluates each expression with a fused Nim loop
## generated for it (see README.md), falling back to Polars (through Nanuq)
## for anything outside the supported subset.

import nanuqy/jit
export jit
