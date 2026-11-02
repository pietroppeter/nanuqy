#!/usr/bin/env bash
# How much of a Rust crate does the rust -> NIF -> Nim pipeline lower without
# an UNSUPPORTED marker? Syntax coverage only: the output is not compiled.
#   rust2nif/coverage.sh <crate src dir> <work dir>
set -euo pipefail
src=$1; work=$2; here=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$work"
files=0; parsed=0
for f in $(find "$src" -name '*.rs' | sort); do
  b=$(echo "${f#$src/}" | tr / _)
  files=$((files+1))
  if "$here/rs2nif/target/release/rs2nif" "$f" > "$work/$b.dbg" 2>/dev/null &&
     "$here/dbg2nif" "$work/$b.dbg" > "$work/$b.nif" && "$here/rcompact" "$work/$b.nif" > "$work/$b.core.nif"; then
    parsed=$((parsed+1))
    "$here/rs2nim" "$work/$b.core.nif" > "$work/$b.nim" 2> "$work/$b.log" || echo "rs2nim failed on $b"
  else echo "syn could not parse $b"; fi
done
clean=$(awk '/^functions:/{c+=$2; t+=$5} END{print c" of "t}' "$work"/*.log)
echo "files: $files, parsed: $parsed, functions lowered with no UNSUPPORTED node: $clean"
echo "most frequent unsupported constructs (count = occurrences):"
grep -h '^  [0-9]*x ' "$work"/*.log | sed 's/^  //' | awk '{n=$1; sub(/x$/,"",n); $1=""; k[$0]+=n} END{for(x in k) print k[x]"\t"x}' | sort -rn | head -25
