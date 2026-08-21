#!/bin/sh
# ml2ts end-to-end check:
#   build -> compile fixtures -> tsc (--strict, es2020 lib only) -> run
#   -> stdout diff, stderr must be empty
#   reject fixtures must exit 1, first stderr line located, error text match
#   CLI contract (help, bad arguments, missing input, unwritable output)
#   determinism: same input compiles to byte-identical TS
set -u
cd "$(dirname "$0")"

EXE=../_build/default/ml2ts/bin/ml2ts.exe
TMP="${TMPDIR:-/tmp}/ml2ts-check-$$"
rm -rf "$TMP"
mkdir -p "$TMP"
fail=0

step() { printf '%s: ' "$1"; }
ok() { echo OK; }
bad() { echo FAIL; fail=1; }

step "build"
if dune build 2>"$TMP/build.log"; then ok; else bad; cat "$TMP/build.log"; exit 1; fi

for src in test/*.mlj; do
  name=$(basename "$src" .mlj)
  step "compile $name"
  if "$EXE" "$src" -o "$TMP/$name.ts" 2>"$TMP/$name.err"; then ok; else bad; cat "$TMP/$name.err"; continue; fi

  step "tsc $name"
  if tsc --strict --noEmit --target es2020 --lib es2020 "$TMP/$name.ts" 2>"$TMP/$name.tsc"; then ok; else bad; cat "$TMP/$name.tsc"; continue; fi

  if [ -f "test/$name.out" ]; then
    step "run $name"
    node "$TMP/$name.ts" >"$TMP/$name.run" 2>"$TMP/$name.run.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      bad; echo "  node exited with status $rc:"; sed 's/^/  /' "$TMP/$name.run.err"
    elif [ -s "$TMP/$name.run.err" ]; then
      bad; echo "  node wrote to stderr:"; sed 's/^/  /' "$TMP/$name.run.err"
    elif diff -u "test/$name.out" "$TMP/$name.run" >"$TMP/$name.diff"; then ok; else bad; cat "$TMP/$name.diff"; fi
  fi
done

for src in test/reject/*.mlj; do
  name=$(basename "$src" .mlj)
  step "reject $name"
  rm -f "$TMP/$name.ts"
  if "$EXE" "$src" -o "$TMP/$name.ts" >"$TMP/$name.out" 2>"$TMP/$name.err"; then
    bad; echo "  expected failure, compiled cleanly"
    continue
  fi
  # the first stderr line must be a located error: basename.mlj:line:col: error:
  if ! sed -n '1p' "$TMP/$name.err" | grep -Eq "^$name\.mlj:[0-9]+:[0-9]+: error:"; then
    bad; echo "  first error line is not located:"; sed -n '1p' "$TMP/$name.err" | sed 's/^/  /'
    continue
  fi
  # expected diagnostic text is matched as a fixed string, not a regex
  if ! grep -qF "$(cat "test/reject/$name.err")" "$TMP/$name.err"; then
    bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/$name.err"
    continue
  fi
  # a rejected compilation must not leave an output file behind
  if [ -e "$TMP/$name.ts" ]; then
    bad; echo "  rejected compilation still wrote $name.ts"
    continue
  fi
  ok
done

# a rejected compilation must not touch an existing output file either:
# pre-seed the output path and re-run one rejection
step "reject no-overwrite"
printf 'sentinel\n' > "$TMP/main_params.ts"
cp "$TMP/main_params.ts" "$TMP/main_params.sentinel"
if "$EXE" test/reject/main_params.mlj -o "$TMP/main_params.ts" 2>"$TMP/no_overwrite.err"; then
  bad; echo "  expected failure, compiled cleanly"
elif cmp -s "$TMP/main_params.ts" "$TMP/main_params.sentinel"; then
  ok
else
  bad; echo "  rejected compilation modified the output file"
fi

step "cli --help"
if "$EXE" --help >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  if grep -q "usage: ml2ts" "$TMP/cli.out"; then ok; else bad; echo "  stdout was:"; sed 's/^/  /' "$TMP/cli.out"; fi
else bad; echo "  expected exit 0"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli -help"
if "$EXE" -help >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  if grep -q "usage: ml2ts" "$TMP/cli.out"; then ok; else bad; echo "  stdout was:"; sed 's/^/  /' "$TMP/cli.out"; fi
else bad; echo "  expected exit 0"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli missing input"
if "$EXE" "$TMP/ghost.mlj" >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 1"
elif grep -qF "ml2ts: error:" "$TMP/cli.err"; then
  if [ -e "$TMP/ghost.ts" ]; then bad; echo "  output file created anyway"; else ok; fi
else
  bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"
fi

step "cli directory input"
if "$EXE" test/reject >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 1"
elif grep -qF "ml2ts: error:" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli -o bad directory"
if "$EXE" test/Core.mlj -o "$TMP/no-such-dir/Core.ts" >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 1"
elif grep -qF "ml2ts: error:" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli unknown flag"
if "$EXE" test/Core.mlj --bogus >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 2"
elif grep -q "usage: ml2ts" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli -o without value"
if "$EXE" test/Core.mlj -o >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 2"
elif grep -q "usage: ml2ts" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli -o twice"
if "$EXE" test/Core.mlj -o "$TMP/a.ts" -o "$TMP/b.ts" >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 2"
elif grep -q "usage: ml2ts" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli zero args"
if "$EXE" >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 2"
elif grep -q "usage: ml2ts" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "determinism (Core.mlj twice)"
mkdir -p "$TMP/det1" "$TMP/det2"
if "$EXE" test/Core.mlj -o "$TMP/det1/Core.ts" 2>"$TMP/det_a.err" && \
   "$EXE" test/Core.mlj -o "$TMP/det2/Core.ts" 2>"$TMP/det_b.err"; then
  if cmp -s "$TMP/det1/Core.ts" "$TMP/det2/Core.ts"; then ok
  else bad; echo "  generated TS differs between runs"; fi
else bad; echo "  compile failed:"; sed 's/^/  /' "$TMP/det_a.err" "$TMP/det_b.err"; fi

step "fuzz (FUZZ_N=${FUZZ_N:-60})"
if FUZZ_N="${FUZZ_N:-60}" sh fuzz.sh >"$TMP/fuzz.out" 2>"$TMP/fuzz.err"; then
  ok
  sed 's/^/  /' "$TMP/fuzz.out"
else
  bad
  sed 's/^/  /' "$TMP/fuzz.out" "$TMP/fuzz.err"
  echo "  fuzz artifacts (if any) were kept by fuzz.sh"
fi

if [ "$fail" -eq 0 ]; then
  echo "check: ALL OK"
  rm -rf "$TMP"
else
  echo "check: FAILURES (artifacts kept in $TMP)"
fi
exit "$fail"
