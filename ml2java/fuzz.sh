#!/bin/sh
# ml2java fuzz driver (POSIX sh):
#   Lane A - FUZZ_N deterministic .mlj programs from tools/gen_fuzz.exe
#            (typed expressions, records with shuffled field order,
#            variants, nested options, lists, tuples, classes with ctor
#            params / a `()` ctor param / mutable val / self / static
#            factory / inherit, generic functions, statement-bearing
#            operands in `&&`, `^`, call args, list elements, record
#            fields, tuple components and for-range bounds).  Each must:
#              - compile, and pass javac -encoding UTF-8 -Xlint:all -Werror
#              - run: exit 0, EMPTY stderr
#              - compile byte-identically a second time
#   Lane B - per seed, a garbage byte file and a single-byte mutation of a
#            test/*.mlj fixture.  The compiler must either reject the
#            sample (exit 1, first stderr line shaped
#            `<path>:<line>:<col>: error:` or `ml2java: error:`) or accept
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

EXE=_build/default/bin/ml2java.exe
GEN=_build/default/tools/gen_fuzz.exe
TMP="${TMPDIR:-/tmp}/ml2java-fuzz-$$"
ART="fuzz-artifacts-$$"              # counterexample evidence, kept on failure
mkdir -p "$TMP/classes" "$TMP/det2" "$ART"
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

# full gate: ml2java -> javac -Werror -> run (exit 0, empty stderr)
# -> determinism (compile again to a different dir, byte-compare).
# The generated top-level class is named after the input file, so the
# second compile uses the same input (and therefore the same class name)
# with a different -o directory; the CLI rejects an -o whose basename
# differs from the input's.
check_one() { # $1=name  $2=source
  name=$1; src=$2
  if ! timeout_run 20 "$EXE" "$src" -o "$TMP/classes/$name.java" 2>"$TMP/$name.err"; then
    echo "compile-reject"; show_err "$TMP/$name.err" >&2; return 1
  fi
  if ! timeout_run 30 javac -encoding UTF-8 -Xlint:all -Werror -d "$TMP/classes" "$TMP/classes/$name.java" 2>"$TMP/$name.javac"; then
    echo "javac-fail"; show_err "$TMP/$name.javac" >&2; return 1
  fi
  timeout_run 20 java -cp "$TMP/classes" "$name" >"$TMP/$name.run" 2>"$TMP/$name.run.err"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "run-exit-$rc"; show_err "$TMP/$name.run.err" >&2; return 1
  fi
  if [ -s "$TMP/$name.run.err" ]; then
    echo "run-stderr"; show_err "$TMP/$name.run.err" >&2; return 1
  fi
  if ! timeout_run 20 "$EXE" "$src" -o "$TMP/det2/$name.java" 2>"$TMP/${name}_2.err" ||
     ! cmp -s "$TMP/classes/$name.java" "$TMP/det2/$name.java"; then
    echo "non-deterministic"; show_err "$TMP/${name}_2.err" >&2; return 1
  fi
  return 0
}

# lane B sample: rejected (exit 1 + located/CLI error line) or accepted and
# fully gated
check_sample() { # $1=name  $2=source
  name=$1; src=$2
  if timeout_run 20 "$EXE" "$src" -o "$TMP/classes/$name.java" >"$TMP/$name.out" 2>"$TMP/$name.err"; then
    check_one "$name" "$src"
  else
    if ! sed -n '1p' "$TMP/$name.err" |
         grep -Eq "^(ml2java: error:|.*:[0-9]+:[0-9]+: error:)"; then
      echo "bad-error-shape"; show_err "$TMP/$name.err" >&2; return 1
    fi
    return 0
  fi
}

# lane A worker: generate seed-th program and gate it
lane_a() { # seed
  seed=$1
  "$GEN" "$seed" > "$TMP/a$seed.mlj" 2>"$TMP/a$seed.gen.err" || { echo "gen-failed"; return 1; }
  if check_one "a$seed" "$TMP/a$seed.mlj"; then
    echo "OK"
  else
    mkdir -p "$ART/a$seed"
    cp "$TMP/a$seed.mlj" "$ART/a$seed/program.mlj"
    echo "program generated from seed $seed (replay: $GEN $seed)" > "$ART/a$seed/seed"
    echo "lane A valid program" > "$ART/a$seed/lane"
    echo "accepted: ml2java exit 0, javac -Xlint:all -Werror clean, java exit 0 with empty stderr, second compile byte-identical" > "$ART/a$seed/expected"
    cp "$TMP/a$seed.err" "$ART/a$seed/compiler.stderr" 2>/dev/null
    cp "$TMP/a$seed.javac" "$ART/a$seed/javac.stderr" 2>/dev/null
    cp "$TMP/a$seed.run.err" "$ART/a$seed/java.stderr" 2>/dev/null
    cp "$TMP/a$seed.run" "$ART/a$seed/java.stdout" 2>/dev/null
    cp "$TMP/classes/a$seed.java" "$ART/a$seed/generated.java" 2>/dev/null
    return 1
  fi
}

# lane B worker: single-byte mutation of a fixture
lane_m() { # seed
  seed=$1
  n=$(ls test/*.mlj | wc -l | tr -d ' ')
  [ "$n" -gt 0 ] || { echo "no-fixtures"; return 1; }
  idx=$((seed % n + 1))
  src=$(ls test/*.mlj | awk -v i="$idx" 'NR == i { print; exit }')
  base=$(basename "$src" .mlj)
  cp "$src" "$TMP/m$seed.mlj"
  size=$(wc -c < "$TMP/m$seed.mlj")
  if [ "$size" -le 1 ]; then echo "empty-fixture"; return 0; fi
  pos=$((seed % size))
  byte=$(((seed / 7) % 256))
  printf '%b' "\\$(printf '%03o' "$byte")" |
    dd of="$TMP/m$seed.mlj" bs=1 seek="$pos" conv=notrunc 2>/dev/null
  if check_sample "m$seed" "$TMP/m$seed.mlj"; then
    echo "OK"
  else
    mkdir -p "$ART/m$seed"
    cp "$TMP/m$seed.mlj" "$ART/m$seed/mutation.mlj"
    cp "$src" "$ART/m$seed/original.mlj"
    echo "seed=$seed byte=$pos <- $byte on $base" > "$ART/m$seed/seed"
    echo "lane B single-byte mutation of test/$base.mlj" > "$ART/m$seed/lane"
    cp "$TMP/m$seed.err" "$ART/m$seed/compiler.stderr" 2>/dev/null
    cp "$TMP/m$seed.javac" "$ART/m$seed/javac.stderr" 2>/dev/null
    cp "$TMP/m$seed.run.err" "$ART/m$seed/java.stderr" 2>/dev/null
    cp "$TMP/m$seed.run" "$ART/m$seed/java.stdout" 2>/dev/null
    return 1
  fi
}

# lane B worker: garbage bytes
lane_g() { # seed
  seed=$1
  "$GEN" bytes "$seed" > "$TMP/g$seed.mlj" 2>"$TMP/g$seed.gen.err" || { echo "gen-failed"; return 1; }
  if check_sample "g$seed" "$TMP/g$seed.mlj"; then
    echo "OK"
  else
    mkdir -p "$ART/g$seed"
    cp "$TMP/g$seed.mlj" "$ART/g$seed/garbage.bin"
    echo "garbage bytes generated from seed $seed" > "$ART/g$seed/seed"
    echo "lane B garbage file" > "$ART/g$seed/lane"
    cp "$TMP/g$seed.err" "$ART/g$seed/compiler.stderr" 2>/dev/null
    cp "$TMP/g$seed.javac" "$ART/g$seed/javac.stderr" 2>/dev/null
    cp "$TMP/g$seed.run.err" "$ART/g$seed/java.stderr" 2>/dev/null
    cp "$TMP/g$seed.run" "$ART/g$seed/java.stdout" 2>/dev/null
    return 1
  fi
}

# ---------------- Lane A ----------------
step "fuzz lane A ($N seeds)"
i=0
while [ "$i" -lt "$N" ]; do
  out=$(lane_a "$i"); rc=$?
  if [ "$rc" -ne 0 ]; then
    bad; echo "  counterexample: seed $i"; echo "  reason: $out"
    fail=1
    break
  fi
  i=$((i+1))
done
[ "$fail" -eq 0 ] && ok

# ---------------- Lane B ----------------
if [ "$fail" -eq 0 ]; then
  step "fuzz lane B ($N mutations + $N garbage files)"
  i=0
  while [ "$i" -lt "$N" ]; do
    out=$(lane_m "$i"); rc=$?
    if [ "$rc" -ne 0 ]; then
      bad; echo "  counterexample: mutation seed $i"; echo "  reason: $out"
      fail=1
      break
    fi
    i=$((i+1))
  done
fi
if [ "$fail" -eq 0 ]; then
  i=0
  while [ "$i" -lt "$N" ]; do
    out=$(lane_g "$i"); rc=$?
    if [ "$rc" -ne 0 ]; then
      bad; echo "  counterexample: garbage seed $i"; echo "  reason: $out"
      fail=1
      break
    fi
    i=$((i+1))
  done
  [ "$fail" -eq 0 ] && ok
fi

if [ "$fail" -eq 0 ]; then
  echo "fuzz: ALL OK"
  rm -rf "$TMP"
  rmdir "$ART" 2>/dev/null    # evidence dir: only kept when a counterexample filled it
else
  echo "fuzz: FAILURES (artifacts kept in $ART)"
fi
exit "$fail"
