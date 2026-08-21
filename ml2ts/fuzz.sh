#!/bin/sh
# ml2ts fuzz driver (POSIX sh):
#   Lane A - FUZZ_N deterministic .mlj programs from tools/gen_fuzz.exe
#            (typed expressions, records with shuffled field order,
#            variants, nested options, lists, tuples, classes with ctor
#            params / a `()` ctor param / mutable val / self / static
#            factory / inherit, generic functions, statement-bearing
#            operands in `&&`, `^`, call args, list elements, record
#            fields, tuple components and for-range bounds).  Each must:
#              - compile, and pass tsc --strict (es2020 lib only)
#              - run: exit 0, EMPTY stderr
#              - compile byte-identically a second time
#   Lane B - per seed, a garbage byte file and a single-byte mutation of a
#            test/*.mlj fixture.  The compiler must either reject the
#            sample (exit 1, first stderr line shaped
#            `<path>:<line>:<col>: error:` or `ml2ts: error:`) or accept
#            it and pass the full Lane A gate.  Anything else is a
#            counterexample.
#
#   FUZZ_N  seeds per lane (default 30, minimum 10; 0 skips the lane).
#   Deterministic per seed: the same FUZZ_N reproduces the same files.
#   On a counterexample the run stops and the evidence (sample source,
#   seed, observed output vs expected contract) is kept in
#   fuzz-artifacts-<pid>/ so it can be replayed by hand.
set -u
cd "$(dirname "$0")"

N="${FUZZ_N:-30}"
case "$N" in
  ''|*[!0-9]*) echo "fuzz: FUZZ_N must be a non-negative integer (got '$N')" >&2; exit 2 ;;
esac
if [ "$N" -eq 0 ]; then echo "fuzz: skipped (FUZZ_N=0)"; exit 0; fi
if [ "$N" -lt 10 ]; then echo "fuzz: FUZZ_N must be at least 10 (got $N)" >&2; exit 2; fi

EXE=../_build/default/ml2ts/bin/ml2ts.exe
GEN=../_build/default/ml2java/tools/gen_fuzz.exe
TMP="${TMPDIR:-/tmp}/ml2ts-fuzz-$$"
ART="fuzz-artifacts-$$"              # counterexample evidence, kept on failure
mkdir -p "$TMP" "$ART"
fail=0

step() { printf '%s: ' "$1"; }
ok() { echo OK; }
bad() { echo FAIL; fail=1; }

# echo a possibly-binary stderr file, sanitized for the terminal
show_err() { LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' < "$1" | sed 's/^/    /'; }

step "fuzz build"
if dune build 2>"$TMP/build.log"; then ok; else bad; cat "$TMP/build.log"; exit 1; fi

# hard timeout via perl alarm (SIGALRM kills the timed-out process tree)
timeout_run() { perl -e 'alarm shift; exec @ARGV' "$@"; }

# full gate: ml2ts -> tsc --strict -> run (exit 0, empty stderr)
# -> determinism (compile again, byte-compare)
check_one() { # $1=name  $2=source
  name=$1; src=$2
  if ! timeout_run 20 "$EXE" "$src" -o "$TMP/$name.ts" 2>"$TMP/$name.err"; then
    echo "compile-reject"; show_err "$TMP/$name.err" >&2; return 1
  fi
  if ! timeout_run 30 tsc --strict --noEmit --target es2020 --lib es2020 "$TMP/$name.ts" 2>"$TMP/$name.tsc"; then
    echo "tsc-fail"; show_err "$TMP/$name.tsc" >&2; return 1
  fi
  timeout_run 20 node "$TMP/$name.ts" >"$TMP/$name.run" 2>"$TMP/$name.run.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "run-exit-$rc"; show_err "$TMP/$name.run.err" >&2; return 1
  fi
  if [ -s "$TMP/$name.run.err" ]; then
    echo "run-stderr"; show_err "$TMP/$name.run.err" >&2; return 1
  fi
  if ! timeout_run 20 "$EXE" "$src" -o "$TMP/${name}_2.ts" 2>"$TMP/${name}_2.err" ||
     ! cmp -s "$TMP/$name.ts" "$TMP/${name}_2.ts"; then
    echo "non-deterministic"; show_err "$TMP/${name}_2.err" >&2; return 1
  fi
  return 0
}

# lane B sample: rejected (exit 1 + located/CLI error line) or accepted and
# fully gated
check_sample() { # $1=name  $2=source
  name=$1; src=$2
  if timeout_run 20 "$EXE" "$src" -o "$TMP/$name.ts" >"$TMP/$name.out" 2>"$TMP/$name.err"; then
    check_one "$name" "$src"
  else
    if ! sed -n '1p' "$TMP/$name.err" |
         grep -Eq "^(ml2ts: error:|.*:[0-9]+:[0-9]+: error:)"; then
      echo "bad-error-shape"; show_err "$TMP/$name.err" >&2; return 1
    fi
    return 0
  fi
}

# lane A worker: generate seed-th program and gate it
lane_a() { # seed
  seed=$1
  "$GEN" "$seed" > "$TMP/a$seed.mlj"
  if ! r=$(check_one "a$seed" "$TMP/a$seed.mlj"); then
    echo "seed $seed: $r"
    cp "$TMP/a$seed.mlj" "$ART/a$seed.mlj"
    return 1
  fi
  return 0
}

# lane B worker: single-byte mutation of a fixture
lane_m() { # seed
  seed=$1
  src="test/$(ls test/*.mlj | sed -n "$((seed % 11 + 1))p" | xargs basename)"
  cp "$src" "$TMP/m$seed.mlj"
  # flip one byte at a deterministic position derived from the seed
  pos=$((seed * 7 % $(wc -c < "$TMP/m$seed.mlj")))
  byte=$(od -An -tu1 -j "$pos" -N1 "$TMP/m$seed.mlj" | tr -d ' ')
  new=$(( (byte + 1 + seed) % 256 ))
  printf "\\$(printf '%03o' "$new")" | dd of="$TMP/m$seed.mlj" bs=1 seek="$pos" conv=notrunc 2>/dev/null
  if ! r=$(check_sample "m$seed" "$TMP/m$seed.mlj"); then
    echo "seed $seed: $r"
    cp "$TMP/m$seed.mlj" "$ART/m$seed.mlj"
    return 1
  fi
  return 0
}

# lane B worker: garbage bytes
lane_g() { # seed
  seed=$1
  "$GEN" bytes "$seed" > "$TMP/g$seed.mlj"
  if ! r=$(check_sample "g$seed" "$TMP/g$seed.mlj"); then
    echo "seed $seed: $r"
    cp "$TMP/g$seed.mlj" "$ART/g$seed.mlj"
    return 1
  fi
  return 0
}

# ---------------- Lane A ----------------
step "fuzz lane A ($N seeds)"
i=0
while [ "$i" -lt "$N" ]; do
  if ! lane_a "$i"; then bad; break; fi
  i=$((i + 1))
done
[ "$fail" -eq 0 ] && ok

# ---------------- Lane B ----------------
if [ "$fail" -eq 0 ]; then
  step "fuzz lane B mutations ($N seeds)"
  i=0
  while [ "$i" -lt "$N" ]; do
    if ! lane_m "$i"; then bad; break; fi
    i=$((i + 1))
  done
  [ "$fail" -eq 0 ] && ok
fi
if [ "$fail" -eq 0 ]; then
  step "fuzz lane B garbage ($N seeds)"
  i=0
  while [ "$i" -lt "$N" ]; do
    if ! lane_g "$i"; then bad; break; fi
    i=$((i + 1))
  done
  [ "$fail" -eq 0 ] && ok
fi

if [ "$fail" -eq 0 ]; then
  echo "fuzz: ALL OK"
  rm -rf "$TMP" "$ART"
else
  echo "fuzz: FAILURES (artifacts kept in $ART)"
fi
exit "$fail"
