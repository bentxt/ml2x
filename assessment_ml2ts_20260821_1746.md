# ml2ts verification assessment

Assessment time: 2026-08-21 17:46 Europe/Zurich

First formal verification record for the TypeScript backend, mirroring the
method of `assessment_20260820_175225.md` (ml2java). The ml2ts backend
shares the frontend (lexer, parser, checker, profiles) with ml2java; this
assessment verifies the TS-specific surface: the emitter, the TS profile
rules, and the documented semantic differences.

## Method

- Full suite: `sh ml2ts/check.sh` — ALL OK (build; 13 test fixtures and
  13 examples compiled to TS, type-checked with
  `tsc --strict --noEmit --target es2020 --lib es2020`, run with `node`
  requiring exit 0 and EMPTY stderr, stdout diffed against the shared
  `.out` files; 64 rejection fixtures — 57 shared + 7 TS-specific —
  each requiring exit 1, a located first error line, the `.err` text, and
  no output file written, including a no-overwrite check; CLI contract;
  determinism; fuzz at the default 60 seeds per lane).
- Deep fuzz: `FUZZ_N=500 sh ml2ts/fuzz.sh` — ALL OK (500 generated
  programs compiled → `tsc --strict` → run with exit 0 and empty stderr
  → byte-identical recompile; 500 single-byte mutations and 500 garbage
  files each rejected with a located error or accepted through the full
  gate). ~9 minutes, found nothing.
- Parity audit: every fixture present in only one backend was checked
  against `shared/profile.ml`. All are intentional profile differences,
  not missing coverage (see below).
- Targeted probes compiled through the real path (`ml2ts` → `tsc
  --strict` → `node`) or rejected, one per risk class below. Probe files
  were deleted after testing.

## Probes: accepted programs preserve meaning

| Probe | Result |
|---|---|
| `Some None : int option option` matched as `Some None` / `Some (Some n)` / `None` | prints `some none` / `some some` / `none`; nested-option meaning preserved (the `_SomeBox` wrapper) |
| `false && (touched <- 1; true)` | prints `0`; statement-bearing rhs does not execute (short-circuit preserved) |
| top-level value with statement initializer | prints `1`; initializer statements run at the declaration's position (IIFE emission) |
| `let id (x : 'a) : 'a = x` then `id 3 + 1` | compiles, passes `tsc --strict`, prints `4` |
| `let final = 42` (a Java keyword, legal in TS) | accepted, prints `42`; the reserved-name tables are profile-correct |
| `-o` to an arbitrary basename | accepted and runs (`renamed ok`); TS has no filename→class constraint, unlike Java's basename-mismatch reject — intentional profile difference (`check_basename = false`) |
| 63-bit int boundary (`4611686018427387903`) | prints `4611686018427388000`; values beyond ±2^53 lose precision at runtime — the documented semantic difference that keeps the shared `Lit.mlj` fixture Java-only |

## Probes: rejected programs

| Probe | Result |
|---|---|
| guard-only match (no unguarded arm) | rejected: `non-exhaustive match: missing case(s) true, false` at the match's position |
| static method accessing an instance field | rejected: `instance field 'n' cannot be accessed from a static method` |
| private method implementing an interface method | rejected: `method 'to_string' of class 'p' is private, but it must be public to implement method 'to_string' of interface 'itf'` |
| `let undefined = 42` | rejected: `function 'undefined' is a TypeScript keyword and cannot be emitted` |
| method colliding with a field/ctor parameter | rejected: `method 'x' of class 'c' collides with a field or constructor parameter of the same name` (TS-only rule: one member namespace) |
| class colliding with a top-level function/value | rejected: `class 'f' collides with a function or value of the same name` (TS-only rule: one value namespace) |

## Parity audit: one-sided fixtures are intentional

- Java-only rejects: `tuple_name` (Java emits generated `TupleN` records;
  TS does not — `ban_tupleN_names = false`), `case_collision`
  (case-insensitive `.class` filesystem; TS emits one module —
  `case_insensitive_type_namespace = false`), `123bad` / `final` (file
  basename becomes the top-level class; TS has no such constraint —
  `check_basename = false`).
- TS-only rejects: `ts_keyword`, `ts_await`, `ts_constructor`, `ts_eval`,
  `ts_undefined` (TS reserved names), `class_member_collision`,
  `value_class_collision` (TS member/value namespaces; Java keeps these
  separate — `class_member_namespace` / `value_class_namespace = false`
  for Java).
- `Lit.mlj` (63-bit int boundary, unary minus, float forms, escapes,
  UTF-8) is documented in `ml2ts/SPEC.md` as Java-only: TS `int` is
  `number` and cannot represent the boundary values. The probe above
  confirms the documented behavior.

## What is still true

- `check.sh`'s default fuzz depth is 60 seeds per lane; deeper runs are
  manual (`FUZZ_N=500` took ~9 minutes, found nothing).
- The language is a deliberately small v1 subset (see SPEC.md's rejection
  list). The enforced boundary holds: accepted programs pass
  `tsc --strict` and preserve meaning in the probes and lanes above;
  rejected programs fail with a located single-line error and never
  overwrite an existing output file.
- The ml2java assessment (`assessment_20260820_175225.md`) remains the
  record for the Java backend; the shared frontend it verifies is the
  same code the TS backend runs.
