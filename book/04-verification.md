# ml2java re-verification assessment

Assessment time: 2026-08-20 17:52 Europe/Zurich

Supersedes `assessment_20260820_010349.md` for the current tree. That
assessment found five groups of correctness holes ("not yet a dependable
source-to-source compiler"). Every finding in it was re-verified today
against the current sources: all are closed, most with regression coverage
in the suite. The 01:03 file is kept as history; do not treat its milestone
judgment as current.

## Method

- Full suite: `sh ml2java/check.sh` — ALL OK (build, 12 test fixtures and
  8 examples compiled and run with stdout/stderr/exit assertions under
  `javac -encoding UTF-8 -Xlint:all -Werror`, 60 rejection fixtures, CLI
  contract, determinism, fuzz lanes).
- Deep fuzz: `FUZZ_N=500 sh ml2java/fuzz.sh` — ALL OK (500 generated
  programs compiled → javac → executed → byte-identical recompile; 500
  single-byte mutations and 500 garbage files each rejected with a located
  error or accepted through the full gate).
- Per finding, a targeted probe program was compiled through the real path
  (`ml2java` → `javac` → `java`) or rejected, exactly as in the 01:03
  assessment. Probe files were deleted after testing.

## Verdicts on the 01:03 findings

### 1. Accepted programs computing incorrect results — CLOSED

| Finding | Probe result today |
|---|---|
| `Some None : int option option` matched `None` | prints `some none` / `some some` / `none` for the three payloads; meaning preserved |
| guard-only match accepted as exhaustive | rejected: `non-exhaustive match: missing case(s) true` at the match's position |
| `false && (touched <- 1; true)` executed its rhs | accepted, runs, prints `0`; rhs does not execute (statement-bearing operands now gate correctly; fixture `test/GuardChain.mlj` and fuzz lane A cover this family) |

### 2. Accepted programs rejected by `javac` — CLOSED

| Finding | Probe result today |
|---|---|
| top-level value with statement initializer wrote illegal class-body statements | accepted: emitter now places it in a `static { }` block (SPEC.md); probe printed `1` |
| static method could access instance field | rejected: `instance field 'n' cannot be accessed from a static method` (also fixture `test/reject/static_field_access.mlj`) |
| private method accepted as interface implementation | rejected: `method 'to_string' of class 'p' is private, but it must be public to implement ...` |

### 3. Generic functions mis-emitted — CLOSED

`let id (x : 'a) : 'a = x` then `id 3 + 1` now compiles, passes
`javac -Werror`, and prints `4` (fixture `test/GenPoll.mlj`; fuzz lane A
generates generic functions).

### 4. Arbitrary `-o` names producing unusable Java — CLOSED

`ml2java test/Objects.mlj -o Renamed.java` is rejected: `output basename
'Renamed' differs from the input basename 'Objects'; the top-level Java
class is 'Objects'` (also gated in `check.sh` "cli -o basename mismatch").

### 5. Declaration errors at `0:0` — CLOSED for the sampled classes

Duplicate-function probe now reports `2:1`. Interface and static-context
errors also carry real positions (see probes above). CLI-scope errors that
have no source position still use `file.mlj:0:0` legitimately (the `-o`
mismatch above is an example).

## Verdicts on the 01:03 "test-suite limits" — CLOSED

- Java exit status: asserted (`check.sh` run gate fails on non-zero exit).
- Java stderr: asserted empty.
- "Every accepted program also passes javac": that property is now
  systematic — fuzz lane A gates generated programs through
  `ml2java → javac -Xlint:all -Werror → run → byte-identical recompile`,
  and lane B does the accept/reject contract for mutations and garbage.
- Keyword / duplicate-name handling: covered by reject fixtures
  (`reserved_name`, `shadow_global`, `case_collision`,
  `type_class_collision`, `tuple_name`, etc.).

## What is still true

- `check.sh`'s default fuzz depth is 60 seeds per lane; deeper runs are
  manual (`FUZZ_N=500` took ~9 minutes, found nothing).
- Before today, `fuzz.sh` left an empty `fuzz-artifacts-<pid>/` directory
  behind on every successful run. Fixed today: the evidence directory is
  removed on success and kept only when a counterexample fills it. The five
  stale empty directories from earlier runs were removed.
- The milestone judgment still stands in spirit: the language is a
  deliberately small v1 subset (see SPEC.md's rejection list). What changed
  is that the *enforced* boundary now holds: accepted programs pass
  `javac -Werror` and preserve meaning in the probes and lanes above.
