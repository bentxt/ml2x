# ML2X

ML2X compiles a deliberately restricted ML/OCaml-shaped language (`.mlj`)
into readable code for other platforms. Each target backend shares one
frontend — lexer, parser, and semantic checker in `shared/` — and accepts
only source constructs that have a direct, predictable representation in
that target language. ML2X is not intended to compile every OCaml feature
or reproduce the OCaml runtime on other platforms.

Two backends are complete and gated by identical test harnesses:

- **ml2java** — `.mlj` → ordinary Java (`ml2java/`, the reference backend).
  Records → Java `record`s, variants → sealed interfaces, classes →
  nested `static final` classes, `option` erased to nullable.
- **ml2ts** — `.mlj` → a TypeScript module that runs on Node
  (`ml2ts/`). Records → `interface`s, variants → discriminated unions,
  classes → `class`es, `option` erased to `T | null`.

Both backends compile the **same** positive fixtures and examples (the
`.out` expected-output files are shared) and run the same deterministic
fuzz lanes. This is the "one frontend, multiple targets" proof: the shared
frontend stays shared — target-specific semantic decisions live in
`shared/profile.ml` and `shared/check.ml` behind profile flags, and each
target's emitter implements its own "what does this construct mean here".

## Layout

```text
shared/            lexer, parser, AST, semantic checker, profiles
ml2java/           Java backend (SPEC.md, README.md, TUTORIAL.md, check.sh)
ml2ts/             TypeScript backend (SPEC.md, README.md, check.sh)
book/              the ML2X book (pandoc, `make book`)
```

## Build and run

Requires: OCaml with `dune`, a JDK (`ml2java`), `tsc` 5.9+ and Node 22+
(`ml2ts`).

```sh
cd ml2java && dune build && sh check.sh     # Java suite (javac -Werror gate)
cd ml2ts   && dune build && sh check.sh     # TS suite (tsc --strict gate)
```

Each backend's CLI:

```sh
ml2java input.mlj          # writes input.java (basename-constrained -o)
ml2ts   input.mlj          # writes input.ts (any -o basename)
```

Errors are one line on stderr, `file.mlj:line:col: error: message`, exit 1,
and no output file is written on failure.

## The shared frontend

`shared/` holds the contract modules: `ast.ml` (the AST), `lexer.ml` +
`parser.ml` (hand-written), `check.ml` (semantic validation + type table),
`profile.ml` (per-target profile flags). Backends are parameterized by
`Profile.t`; a target-specific semantic decision goes into the shared
checker behind a profile flag, never into a per-target fork of the
frontend.

## Semantic differences between targets

Documented in each backend's `SPEC.md`. The deliberate ones:

- `int` is `long` in Java and `number` in TS (beyond ±2^53, JS loses
  precision; the shared `Lit.mlj` boundary fixture is Java-only).
- Equality: Java uses `==`/`.equals`/`Objects.equals`; TS uses
  `===`/`!==` plus a generated deep-structural `_eq` helper.
- Float printing: TS emits a `_fmt_float` helper reproducing Java's
  `Double.toString` forms so the shared `.out` files pass.
- Int division truncates in both targets (`Math.trunc` in TS).
- TS-only name-namespace rules (class members; values vs classes) are
  enforced behind profile flags; the Java profile is unchanged.

## Tests

`sh check.sh` in each backend builds the compiler, compiles every
fixture and example, runs it (javac/java or tsc/node), diffs stdout
against the shared `.out` file, requires rejects to fail with located
errors, checks the CLI contract, checks determinism, and runs the fuzz
harness (`FUZZ_N` seeds per lane, default 60). The fuzz generator lives in
`ml2java/tools/gen_fuzz.ml` and is reused by the TS backend.

## Project docs

- `ml2java/SPEC.md` — the shared language contract from the Java side
  (if the spec and `shared/ast.ml` disagree, the AST wins).
- `ml2ts/SPEC.md` — the TS mapping contract.
- `book/` — the ML2X book (intro, spec, tutorial, backend chapters,
  verification); `make book` regenerates `book/book.html`.
- `ASSESSMENT.md`, `assessment_*.md` — the FS2ML review and the ml2java
  verification passes that the current architecture and test gates came
  out of.
