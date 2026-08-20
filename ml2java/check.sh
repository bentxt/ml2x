#!/bin/sh
# ml2java end-to-end check:
#   build -> compile fixtures -> javac (UTF-8, -Xlint:all -Werror) -> run
#   -> stdout diff, stderr must be empty
#   reject fixtures must exit 1, first stderr line located, error text match
#   examples compile/run/diff exactly like test fixtures
#   CLI contract (help, bad arguments, missing input, unwritable output)
#   determinism: same input compiles to byte-identical Java
set -u
cd "$(dirname "$0")"

EXE=_build/default/bin/ml2java.exe
TMP="${TMPDIR:-/tmp}/ml2java-check-$$"
rm -rf "$TMP"
mkdir -p "$TMP/classes"
fail=0

step() { printf '%s: ' "$1"; }
ok() { echo OK; }
bad() { echo FAIL; fail=1; }

step "build"
if dune build 2>"$TMP/build.log"; then ok; else bad; cat "$TMP/build.log"; exit 1; fi

for src in test/*.mlj; do
  name=$(basename "$src" .mlj)
  step "compile $name"
  if "$EXE" "$src" -o "$TMP/$name.java" 2>"$TMP/$name.err"; then ok; else bad; cat "$TMP/$name.err"; continue; fi

  step "javac $name"
  if javac -encoding UTF-8 -Xlint:all -Werror -d "$TMP/classes" "$TMP/$name.java" 2>"$TMP/$name.javac"; then ok; else bad; cat "$TMP/$name.javac"; continue; fi

  if [ -f "test/$name.out" ]; then
    step "run $name"
    java -cp "$TMP/classes" "$name" >"$TMP/$name.run" 2>"$TMP/$name.run.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      bad; echo "  java exited with status $rc:"; sed 's/^/  /' "$TMP/$name.run.err"
    elif [ -s "$TMP/$name.run.err" ]; then
      bad; echo "  java wrote to stderr:"; sed 's/^/  /' "$TMP/$name.run.err"
    elif diff -u "test/$name.out" "$TMP/$name.run" >"$TMP/$name.diff"; then ok; else bad; cat "$TMP/$name.diff"; fi
  fi
done

for src in examples/*.mlj; do
  name=$(basename "$src" .mlj)
  step "compile example $name"
  if "$EXE" "$src" -o "$TMP/$name.java" 2>"$TMP/$name.err"; then ok; else bad; cat "$TMP/$name.err"; continue; fi

  step "javac example $name"
  if javac -encoding UTF-8 -Xlint:all -Werror -d "$TMP/classes" "$TMP/$name.java" 2>"$TMP/$name.javac"; then ok; else bad; cat "$TMP/$name.javac"; continue; fi

  if [ -f "examples/$name.out" ]; then
    step "run example $name"
    java -cp "$TMP/classes" "$name" >"$TMP/$name.run" 2>"$TMP/$name.run.err"
    rc=$?
    if [ "$rc" -ne 0 ]; then
      bad; echo "  java exited with status $rc:"; sed 's/^/  /' "$TMP/$name.run.err"
    elif [ -s "$TMP/$name.run.err" ]; then
      bad; echo "  java wrote to stderr:"; sed 's/^/  /' "$TMP/$name.run.err"
    elif diff -u "examples/$name.out" "$TMP/$name.run" >"$TMP/$name.diff"; then ok; else bad; cat "$TMP/$name.diff"; fi
  fi
done

for src in test/reject/*.mlj; do
  name=$(basename "$src" .mlj)
  step "reject $name"
  rm -f "$TMP/$name.java"
  if "$EXE" "$src" -o "$TMP/$name.java" >"$TMP/$name.out" 2>"$TMP/$name.err"; then
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
  if [ -e "$TMP/$name.java" ]; then
    bad; echo "  rejected compilation still wrote $name.java"
    continue
  fi
  ok
done

# a rejected compilation must not touch an existing output file either:
# pre-seed the (matching-basename) output path and re-run one rejection
step "reject no-overwrite"
printf 'sentinel\n' > "$TMP/main_params.java"
cp "$TMP/main_params.java" "$TMP/main_params.sentinel"
if "$EXE" test/reject/main_params.mlj -o "$TMP/main_params.java" 2>"$TMP/no_overwrite.err"; then
  bad; echo "  expected failure, compiled cleanly"
elif cmp -s "$TMP/main_params.java" "$TMP/main_params.sentinel"; then
  ok
else
  bad; echo "  rejected compilation modified the output file"
fi

step "cli -o basename mismatch"
cp test/Core.mlj "$TMP/Core.mlj"
if "$EXE" "$TMP/Core.mlj" -o "$TMP/Renamed.java" 2>"$TMP/miso.err"; then
  bad; echo "  expected failure, compiled cleanly"
elif grep -qF "output basename" "$TMP/miso.err"; then
  ok
else
  bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/miso.err"
fi

step "cli --help"
if "$EXE" --help >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  if grep -q "usage: ml2java" "$TMP/cli.out"; then ok; else bad; echo "  stdout was:"; sed 's/^/  /' "$TMP/cli.out"; fi
else bad; echo "  expected exit 0"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli -help"
if "$EXE" -help >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  if grep -q "usage: ml2java" "$TMP/cli.out"; then ok; else bad; echo "  stdout was:"; sed 's/^/  /' "$TMP/cli.out"; fi
else bad; echo "  expected exit 0"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli missing input"
if "$EXE" "$TMP/ghost.mlj" >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 1"
elif grep -qF "ml2java: error:" "$TMP/cli.err"; then
  if [ -e "$TMP/ghost.java" ]; then bad; echo "  output file created anyway"; else ok; fi
else
  bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"
fi

step "cli directory input"
if "$EXE" test/reject >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 1"
elif grep -qF "ml2java: error:" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli -o bad directory"
if "$EXE" test/Core.mlj -o "$TMP/no-such-dir/Core.java" >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 1"
elif grep -qF "ml2java: error:" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli unknown flag"
if "$EXE" test/Core.mlj --bogus >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 2"
elif grep -q "usage: ml2java" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli -o without value"
if "$EXE" test/Core.mlj -o >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 2"
elif grep -q "usage: ml2java" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli -o twice"
if "$EXE" test/Core.mlj -o "$TMP/a.java" -o "$TMP/b.java" >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 2"
elif grep -q "usage: ml2java" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "cli zero args"
if "$EXE" >"$TMP/cli.out" 2>"$TMP/cli.err"; then
  bad; echo "  expected exit 2"
elif grep -q "usage: ml2java" "$TMP/cli.err"; then ok
else bad; echo "  stderr was:"; sed 's/^/  /' "$TMP/cli.err"; fi

step "determinism (Core.mlj twice)"
mkdir -p "$TMP/det1" "$TMP/det2"
if "$EXE" test/Core.mlj -o "$TMP/det1/Core.java" 2>"$TMP/det_a.err" && \
   "$EXE" test/Core.mlj -o "$TMP/det2/Core.java" 2>"$TMP/det_b.err"; then
  if cmp -s "$TMP/det1/Core.java" "$TMP/det2/Core.java"; then ok
  else bad; echo "  generated Java differs between runs"; fi
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
