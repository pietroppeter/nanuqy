#!/usr/bin/env bash
# Polars' float_sum.rs (tag py-2.1.0) -> NIF -> Nim, then the bit-exactness
# test against Polars. Needs cargo and Nim; a sibling ../nanuq checkout.
#   rust2nif/run.sh [path/to/float_sum.rs]
set -euo pipefail
cd "$(dirname "$0")"
src=${1:-float_sum.rs}
if [ ! -f "$src" ]; then
  curl -sSfL -o float_sum.rs \
    https://raw.githubusercontent.com/pola-rs/polars/py-2.1.0/crates/polars-compute/src/float_sum.rs
  src=float_sum.rs
fi
(cd rs2nif && cargo build --release -q)
for t in dbg2nif rcompact rs2nim; do nim c -d:release --hints:off --warnings:off -o:$t $t.nim; done
rs2nif/target/release/rs2nif "$src" > float_sum.dbg     # syn's view of the file
./dbg2nif float_sum.dbg > float_sum.nif                 # the same tree as NIF ("rust-parsed")
./rcompact float_sum.nif > float_sum.core.nif           # compacted ("rust-core")
./rs2nim float_sum.core.nif --mono T=float64,F=float64 --skip sum_arr_as_f32 > float_sum_gen.nim
cd ..
nim c -r -d:danger -d:nanuqLib=prebuilt --hints:off --warnings:off rust2nif/test_float_sum.nim
