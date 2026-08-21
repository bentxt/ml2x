# ML2X

ML2X is an early-stage exploration of compiling a deliberately restricted
ML/OCaml-shaped language into readable code for other platforms.

The central rule is simple: each target accepts only source constructs that
have a direct and predictable representation in that target language. ML2X is
not intended to compile every OCaml feature or reproduce the OCaml runtime on
other platforms.

## How this book is organized

The chapters are the project's own living documents, kept in sync with the
tree:

- **01 — Language spec** (`ml2java/SPEC.md`): the shared language contract
  from the Java side. If the spec and the AST disagree, `shared/ast.ml`
  wins.
- **02 — Tutorial** (`ml2java/TUTORIAL.md`): a feature-by-feature walkthrough
  grounded in the runnable `examples/` files (the same examples also
  compile with ml2ts).
- **03 — The ml2java backend** (`ml2java/README.md`): build, architecture,
  generated-Java mapping, restrictions, fuzzing, and the test suite.
- **04 — Verification** (`assessment_20260820_175225.md`): the dependability
  re-verification of the 2026-08-20 morning assessment; every finding closed.
- **05 — The ml2ts backend** (`ml2ts/README.md`): the second backend —
  `.mlj` to TypeScript over the same shared frontend, same fixtures,
  same `.out` files, same fuzz harness.

## Current status

The assessment of the existing FS2ML/ocamlsharp compiler is complete; see
`ASSESSMENT.md` in the project root. Two ML2X backends exist over one shared
frontend (`shared/`): `ml2java/` compiles OCaml-shaped `.mlj` source to
ordinary Java; `ml2ts/` compiles the same source to a TypeScript module that
runs on Node. The dependability findings from the 2026-08-20 morning
assessment were all reproduced and verified fixed the same day; the Java
suite's deterministic fuzz lanes gate every generated program through
`javac -Xlint:all -Werror`, execution with clean exit and stderr, and a
byte-identical recompile. The TS suite gates every generated program through
`tsc --strict`, `node` execution, and a byte-identical recompile, and its
fixtures diff against the same `.out` files as Java. This is the "one
frontend, multiple targets" proof: target-specific semantic decisions live
in `shared/profile.ml` and `shared/check.ml` behind profile flags, and no
per-target fork of the frontend exists.

## Building this book

Requires `pandoc`. From the project root:

```sh
make book        # book/book.html
make pdf         # book/book.pdf (needs a PDF engine, e.g. typst)
```
