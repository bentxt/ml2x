# ml2ts — TypeScript backend for ML2X

The second target of the "one frontend, multiple targets" proof: the same
`.mlj` surface language (shared lexer/parser/checker in `shared/`) compiles
to a TypeScript module that runs on Node. `ml2java/` is the reference
backend; `ml2ts/SPEC.md` is this backend's binding contract.

## Layout

- `src/emit_ts.ml` — the emitter (`.mlj` -> `.ts`).
- `bin/ml2ts.ml` — the CLI.
- `test/` — shared fixtures (copied from `ml2java/test/`, same `.out`
  files must pass) plus TS-specific rejects.
- `examples/` — shared example programs (copied from `ml2java/examples/`,
  same `.out` files), gated exactly like test fixtures.
- `check.sh` — end-to-end gate: build, compile fixtures and examples,
  `tsc --strict`, run under Node, diff stdout, reject fixtures, CLI
  contract, determinism, fuzz.
- `fuzz.sh` — deterministic fuzz (reuses `ml2java/tools/gen_fuzz.exe`).

## Usage

```
ml2ts Demo.mlj            # writes Demo.ts next to it
ml2ts Demo.mlj -o out.ts  # any output basename (no Java-style constraint)
node Demo.ts              # run the generated module
```

## Gate

```
sh check.sh               # full suite (FUZZ_N=60 by default)
FUZZ_N=10 sh check.sh     # quick pass
```

Each fixture/example: `ml2ts file.mlj -o out.ts` -> `tsc --strict --noEmit
--target es2020 --lib es2020 out.ts` -> `node out.ts` (exit 0, empty
stderr) -> stdout diff vs `.out`. Reject fixtures must fail with a located
one-line error. `tsc` 5.9+ and Node 22+ are required.

## Semantic differences from Java (documented in SPEC.md)

- `int` is `number`: values beyond ±2^53 lose precision (the shared
  `Lit.mlj` boundary fixture is Java-only).
- `print_float`/`string_of_float` go through a generated `_fmt_float`
  helper reproducing Java's `Double.toString` forms, so the shared `.out`
  files pass.
- Composite equality uses a generated deep-structural `_eq` (records,
  variants, lists, options, tuples, class instances); primitives use
  `===`/`!==`.
- Int division is `Math.trunc(a / b)`; `%` is JS remainder (same
  truncation).
- Two TS-only name-namespace rules (class member namespace, value/class
  namespace) are enforced behind profile flags; the Java profile is
  unchanged.
