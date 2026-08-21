# ml2ts

ml2ts compiles OCaml-shaped source files (`.mlj`) into ordinary, readable
TypeScript that runs on Node. It is the second backend of the ML2X idea,
sharing the frontend with `ml2java`: the same lexer, parser, semantic
checker, and the same source files compile to either target. Only source
constructs that have a direct, predictable TypeScript representation are
accepted; everything else is rejected with a single-line error.

The language contract is [`SPEC.md`](SPEC.md). If the README and SPEC
disagree, SPEC and `shared/ast.ml` win.

## Build and run

Requires: OCaml with `dune` and `tsc` 5.9+ with Node 22+.

```sh
cd ml2ts
dune build                                  # builds ../_build/default/ml2ts/bin/ml2ts.exe
../_build/default/ml2ts/bin/ml2ts.exe input.mlj   # writes input.ts next to it
../_build/default/ml2ts/bin/ml2ts.exe input.mlj -o out.ts
```

Unlike Java there is no filename constraint: `-o` may name any output
path. Running the generated module needs nothing beyond Node:

```sh
node input.ts
```

Errors are printed as one line on stderr, `file.mlj:line:col: error: message`,
and the exit code is 1. If an error occurs, no output file is written.

## How the compiler is put together

The shared frontend (`shared/`) plus one emitter:

```text
.mlj source
  -> shared/lexer.ml / shared/parser.ml   (hand-written; parser emits ast.ml nodes)
  -> shared/check.ml                      (semantic validation + type table)
  -> src/emit_ts.ml                       (checked AST -> TS text)
  -> .ts source
```

- `shared/check.ml` fills a table mapping every expression node to its
  type, which the emitter uses for equality choice (`===` vs `_eq`),
  match lowering, and option/list representation. It enforces the v1
  profile (full application, mutability, match exhaustiveness, interface
  completeness, private/static access) plus the TS profile's two
  name-namespace rules (class members; values vs classes), both behind
  profile flags.
- `src/emit_ts.ml` follows SPEC's "TypeScript mapping" rules and emits
  plain TS: interfaces, discriminated unions, classes, `const`/`let`
  locals, and a handful of tiny generated helpers. No runtime library
  beyond Node's builtins.

## What the generated TypeScript looks like

One `.mlj` file becomes one `.ts` module; declarations sit at module top
level. The short version of the mapping:

- Records → `interface`s (`readonly` fields unless `mutable`); a
  `mutable` record field is assignable (`r.f = e`).
- Variants → discriminated unions `{ tag: "C"; v0: T; v1: U }`; `match`
  becomes an if/else chain on `tag` with pattern variables bound by
  `const`. Guarded arms live in a labeled block the arm body breaks out
  of, and each guarded arm re-copies the scrutinee so tsc's narrowing
  cannot reject a re-tested tag.
- `option` is erased to nullable: `None` is `null`, `Some x` is `x`
  (`T | null`). A nested option wraps the payload of `Some` in a
  generated `_SomeBox<T>` object, so `Some None` stays distinct from
  `None`.
- Tuples → fixed tuples `[t1, t2]`; mixed-type tuple literals are pinned
  into an annotated temp so element types survive.
- Lists → arrays `t[]`; `[]` → `[]`, `x :: xs` → `[x, ...xs]`.
- `int`/`float` → `number` (beyond ±2^53, precision is lost — documented
  in SPEC), `bool` → `boolean`, `string` → `string`, `char` → `string`
  (length 1), `type param 'a` → `A`.
- Classes → `class`es: constructor parameters become `private readonly`
  fields; `val` fields stay private; `class type` becomes an `interface`
  and `inherit` becomes `implements`.
- `let main () : unit` becomes `function main(): void` plus a trailing
  `main();` call.
- A top-level value whose initializer carries statements becomes an IIFE
  so its statements run at the declaration's position (declarations
  evaluate in source order).
- `&&`/`||` keep short-circuit semantics even when an operand carries
  statements; a statement-bearing `while` condition re-evaluates every
  iteration.
- Int division is `Math.trunc(a / b)` (OCaml truncates toward zero);
  `%` stays `%`.

Equality follows SPEC: `=`/`<>` on `int`/`float`/`bool`/`char`/`string`
uses `===`/`!==`; on records, variants, lists, options, tuples, and class
instances it uses a generated deep-structural `_eq` helper (keys compared
sorted, so record literals in any field order compare equal).
`<`/`<=`/`>`/`>=` on strings lower to the plain operators (JS string
comparison is lexicographic). `print_*`/`string_of_float` go through
`process.stdout.write`/`console.log` and a generated `_fmt_float` helper
that reproduces Java's `Double.toString` forms, so the shared `.out`
files pass unchanged.

## Deliberate restrictions (v1)

The same surface as the shared checker's v1 profile (see
`ml2java/SPEC.md`), plus the TS name rules: ECMAScript strict-mode
reserved words, `constructor`, the TS primitive type names, the ES-lib
globals (`undefined`, `NaN`, `Infinity`), and `eval`/`arguments` are
errors; `_`-prefixed names are reserved for the compiler's helpers; a
class's methods and its fields/ctor params share one member namespace; a
class and a top-level function/value share one value namespace. TS
contextual keywords like `get`, `set`, `of`, `from`, `async`, `type` are
legal in every emitted position and are NOT banned (a shared fixture uses
`method get`). Every rule has a rejection test under `test/reject/`.

## Fuzzing

`sh fuzz.sh` (also the last stage of `sh check.sh`) is the same
deterministic harness as ml2java's, reusing `ml2java/tools/gen_fuzz.exe`:

- **Lane A** — `gen_fuzz.exe <seed>` prints a type-correct program
  exercising the full v1 surface. Each generated program must compile,
  pass `tsc --strict --noEmit --target es2020 --lib es2020`, run with
  exit 0 and EMPTY stderr, and compile byte-identically a second time.
- **Lane B** — per seed, a garbage byte file and a single-byte mutation
  of a `test/*.mlj` fixture. The compiler must either reject each sample
  (exit 1, first stderr line shaped `<path>:<line>:<col>: error:` or
  `ml2ts: error:`) or accept it and pass the full Lane A gate.

Every sample is a pure function of its seed, so any counterexample is
reproducible from the seed alone. On a counterexample the run stops and
keeps the evidence in `fuzz-artifacts-<pid>/`.

```sh
FUZZ_N=200 sh fuzz.sh     # 200 seeds per lane
FUZZ_N=0 sh fuzz.sh        # skip
```

## Tests

`sh check.sh` runs the whole suite:

1. builds the compiler with `dune`;
2. compiles every `test/*.mlj` to TS, runs `tsc --strict --noEmit
   --target es2020 --lib es2020` (the `--lib es2020` excludes the DOM
   lib, whose globals would collide with source names), runs the program
   with `node`, requires exit 0 with EMPTY stderr, and diffs its stdout
   against the matching `test/*.out` file — the same `.out` files ml2java
   must match;
3. compiles every `examples/*.mlj` (copied from `ml2java/examples/`) and
   gates it exactly like a test fixture;
4. compiles every `test/reject/*.mlj` and requires it to fail: exit 1, a
   located first error line `basename.mlj:line:col: error:`, an error
   line containing the text of the matching `test/reject/*.err` file
   (matched as a fixed string), and no output file written — including a
   no-overwrite check that a pre-seeded output file survives a rejected
   run;
5. checks the CLI contract against the real executable: `--help`/`-help`
   exit 0 with `usage: ml2ts` on stdout; missing input, a directory as
   input, and `-o` into a nonexistent directory exit 1 with an
   `ml2ts: error:` line; an unknown flag, `-o` without a value, `-o`
   twice, and zero arguments exit 2 with usage on stderr;
6. checks determinism: `test/Core.mlj` compiled twice produces
   byte-identical TS;
7. runs the fuzz harness: every generated program must compile, pass
   `tsc --strict`, run with exit 0 and empty stderr, and recompile
   byte-identically; every garbage/mutation sample must be rejected with
   a located error line (or pass the same gate). `FUZZ_N` seeds per lane
   (default 60), 0 skips.

Current tests: 13 shared positive fixtures (all but `Lit`, whose 63-bit
int boundary values cannot be represented in JS) — `Core`, `Misc`,
`Objects`, `Interp`, `Edge`, `Order`, `DupItf`, `NewUnit`,
`GuardChain`, `MixedRec`, `GenPoll`, `FloatPrint`, `OptEq` — each
compiled to TS, type-checked, run, and diffed against the shared `.out`;
12 shared examples
(`hello`, `counters`, `validate`, `lists`, `options`, `shapes`,
`operators`, `tuples`, `generics`, `tree`, `formatting`, `fizzbuzz`);
57 shared reject fixtures plus 7 TS-specific ones (`ts_keyword`,
`ts_await`, `ts_constructor`, `ts_eval`, `ts_undefined`,
`class_member_collision`, `value_class_collision`).

## Layout

```text
SPEC.md            the language + mapping contract
bin/ml2ts.ml       CLI
src/emit_ts.ml     TypeScript source emitter
../shared/         shared AST, lexer, parser, checker, profiles
test/*.mlj         shared positive fixtures (compile, tsc --strict, run, diff vs *.out)
test/reject/*.mlj  fixtures that must fail (located error contains *.err text)
examples/*.mlj     shared example programs, gated exactly like test fixtures
fuzz.sh            fuzz driver (Lane A + Lane B, FUZZ_N)
check.sh           the test driver
```
