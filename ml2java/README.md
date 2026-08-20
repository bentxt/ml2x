# ml2java

ml2java compiles OCaml-shaped source files (`.mlj`) into ordinary, readable
Java. It is the first working backend of the ML2X idea: only source constructs
that have a direct, predictable Java representation are accepted; everything
else is rejected with a single-line error.

The language contract is [`SPEC.md`](SPEC.md). If the README and SPEC
disagree, SPEC and `src/ast.ml` win.

## Build and run

Requires: OCaml with `dune` (no libraries beyond the standard one) and a JDK
(`javac`, `java`, Java 17 or newer for records and sealed interfaces).

```sh
cd ml2java
dune build                                  # builds _build/default/bin/ml2java.exe
_build/default/bin/ml2java.exe input.mlj    # writes input.java next to it
_build/default/bin/ml2java.exe input.mlj -o out.java
```

The generated Java file's top-level class is the input file's basename, so
`-o` must keep that basename (`Core.mlj -o Renamed.java` is rejected).
Compiling and running it needs no runtime library beyond the JDK:

```sh
javac Main.java && java Main
```

Errors are printed as one line on stderr, `file.mlj:line:col: error: message`,
and the exit code is 1. If an error occurs, no output file is written.

## How the compiler is put together

Four phases, all single-file modules under `src/`:

```text
.mlj source
  -> lexer.ml / parser.ml        (hand-written; parser emits ast.ml nodes)
  -> check.ml                    (semantic validation + type table)
  -> emit_java.ml                (checked AST -> Java text)
  -> .java source
```

- `src/ast.ml` is the contract module: every node the parser, checker, and
  emitter agree on lives here.
- `src/check.ml` fills a table mapping every expression node to its type,
  which the emitter uses for equality choice (`==` vs `.equals`), record
  field accessors, and match lowering. It also enforces the v1 profile:
  full application only, mutability rules, exhaustiveness of matches,
  interface completeness, private/static access rules.
- `src/emit_java.ml` follows SPEC's "Java mapping" rules and emits idiomatic
  modern Java: records, sealed interfaces, `var`-free but simple code with
  no runtime emulation beyond three tiny helpers.

The CLI is `bin/ml2java.ml`; `src/pipeline.ml` wires the phases and converts
front-end exceptions into the standard error line.

## What the generated Java looks like

One `.mlj` file becomes one Java file; everything is nested `static` inside
the top-level class. The short version of the mapping:

- Records → Java `record`s. A record with any `mutable` field becomes a
  `final class` with public fields plus `equals`/`hashCode` (records cannot
  have mutable components in Java, and `=` on records must stay structural).
- Variants → a sealed interface plus one `record` per constructor; `match`
  becomes an if/else `instanceof` chain with pattern variables.
- `option` is erased to nullable: `None` is `null`, `Some x` is `x`.
  A primitive element type is boxed (`int option` → `Long`) so `null` is
  representable.  A nested option (`t option option`) wraps the payload of
  `Some` in a generated `_SomeBox<T>` record, so `Some None` stays distinct
  from `None`.
- Tuples → generated `Tuple2`/`Tuple3` records, emitted once per arity used.
- Lists → `java.util.List`; literals become `List.of(...)`; `::` becomes a
  small `_cons` helper; `for x in xs` becomes an enhanced `for`.
- Fixed `int` maps to Java `long` (literals carry an `L` suffix);
  `float` → `double`, `string` → `String`, `bool` → `boolean`,
  `char` → `char`.
- Classes → nested `static final class`es: constructor parameters become
  `private final` fields plus one constructor; `val` fields stay private;
  `class type` becomes a Java `interface` and `inherit` becomes
  `implements`.
- `let main () : unit` becomes `public static void main(String[] args)`.
- `&&`/`||` keep short-circuit semantics even when an operand carries
  statements; a statement-bearing `while` condition re-evaluates every
  iteration.
- a top-level value whose initializer carries statements is assigned inside
  a `static { }` block, in declaration order.

Equality follows SPEC: `=` on `int`/`float`/`bool`/`char` uses `==`; on
strings, records, variants, lists, tuples, and objects it uses `.equals`;
on options it uses `java.util.Objects.equals` (null-safe, since `None` is
`null`). `<`/`<=`/`>`/`>=` on strings lower to `compareTo`.

## Deliberate restrictions (v1)

Raised with a clean one-line error, never silently mishandled:

partial application and functions as values, modules and functors,
exceptions, references, arrays, mixed `int`/`float` arithmetic, char
arithmetic, `downto`, record patterns, two-or-more type parameters on
variants, named variant payload fields, type aliases, real class
inheritance (`inherit` takes class types only), `open`, `mod` (use `%`),
named `unit` parameters (write `()` instead), `unit` inside
list/option/tuple/type-argument positions, and `=` on `unit` values.

Names that Java would reject are also errors: Java keywords, `_`-prefixed
names (the compiler owns them for its helpers), `TupleN` names, duplicate
parameters/members, type/class/class-type name collisions, and names that
collide case-insensitively in the generated file (they would overwrite each
other's `.class` file on a case-insensitive filesystem).  See `SPEC.md` for
the full list.

Every one of these has a rejection test under `test/reject/`.

## Fuzzing

`sh fuzz.sh` (also the last stage of `sh check.sh`) is a deterministic
fuzz harness with two lanes:

- **Lane A** — `tools/gen_fuzz.exe <seed>` prints a type-correct program
  exercising the full v1 surface: typed expressions, records (including
  shuffled field order and mutable fields), variants, nested options,
  lists, tuples, classes (ctor params, a `()` ctor param, mutable `val`,
  `self`, a static factory, `inherit`), generic functions,
  statement-bearing operands in `&&`, `^`, call arguments, list elements,
  record fields, tuple components and `for`-range bounds.  Each generated
  program must compile, pass `javac -encoding UTF-8 -Xlint:all -Werror`,
  run with exit 0 and EMPTY stderr, and compile byte-identically a second
  time.
- **Lane B** — per seed, a garbage byte file and a single-byte mutation of
  a `test/*.mlj` fixture.  The compiler must either reject each sample
  (exit 1, first stderr line shaped `<path>:<line>:<col>: error:` or
  `ml2java: error:`) or accept it and pass the full Lane A gate.

Every sample is a pure function of its seed, so any counterexample is
reproducible from the seed alone.  On a counterexample the run stops and
keeps the evidence (sample source, seed, observed vs expected) in
`fuzz-artifacts-<pid>/`.

```sh
FUZZ_N=200 sh fuzz.sh     # 200 seeds per lane
FUZZ_N=0 sh fuzz.sh        # skip
```

## Tests

`sh check.sh` runs the whole suite:

1. builds the compiler with `dune`;
2. compiles every `test/*.mlj` to Java, runs `javac -encoding UTF-8
   -Xlint:all -Werror` (warnings are failures), runs the program,
   requires `java` to exit 0 with EMPTY stderr, and diffs its stdout
   against the matching `test/*.out` file;
3. compiles every `examples/*.mlj` and gates it exactly like a test
   fixture (same javac flags, exit 0, empty stderr, stdout diff against
   `examples/*.out`);
4. compiles every `test/reject/*.mlj` and requires it to fail: exit 1, a
   located first error line `basename.mlj:line:col: error:`, an error line
   containing the text of the matching `test/reject/*.err` file (matched
   as a fixed string), and no output file written — including a
   no-overwrite check that a pre-seeded output file survives a rejected
   run;
5. checks the CLI contract against the real executable: `--help`/`-help`
   exit 0 with `usage: ml2java` on stdout; missing input, a directory as
   input, and `-o` into a nonexistent directory exit 1 with an
   `ml2java: error:` line; an unknown flag, `-o` without a value, `-o`
   twice, and zero arguments exit 2 with usage on stderr; `-o` with a
   basename different from the input is rejected;
6. checks determinism: `test/Core.mlj` compiled twice to different output
   paths produces byte-identical Java;
7. runs the fuzz harness (`tools/gen_fuzz.exe` + `fuzz.sh`): every
   generated program must compile, pass `javac -Xlint:all -Werror`, run
   with exit 0 and empty stderr, and recompile byte-identically; every
   garbage/mutation sample must be rejected with a located error line (or
   pass the same gate).  `FUZZ_N` seeds per lane (default 30), 0 skips.

Current tests cover the full v1 surface: records, variants, generics,
matches with guards, tuples (including Tuple3, nested tuple patterns,
fst/snd, tuple equality), options (including nested options), lists,
cons, mutable records, shadowing, classes, interfaces (including two
class types sharing an identical method signature), static/private
methods, loops, `while` (including statement-bearing conditions),
short-circuit `&&`/`||`, evaluation order (call args, record/list/tuple
elements, cons, `^`, unit-typed call arguments), literal edges (63-bit
max int, unary minus, floats, char ordering, string escapes, UTF-8),
statement-bearing top-level values, mutable locals, builtins
(`print_*`, `string_of_*`, `failwith`, `fst`/`snd`, `List.length`),
plus 60 rejection fixtures (including `main` shape, int overflow,
nesting limits, non-unit sequence operands, unit inside inferred
composite types, class members shadowing top-level names, incompatible
inherited signatures, generic class types, structural signature
mismatches, self in static methods, and case-insensitive name
collisions).  Twelve positive
fixtures each compile to Java, run, and match their expected output:
`Core` (portable functional surface), `Misc` (one feature per line),
`Objects` (the two OO facilities), `Interp` (a small expression
interpreter exercising everything together), `Edge` (the boundary cases
from the 2026-08 assessment: nested options, short-circuiting,
statement-bearing top-level values, generic functions, statement-bearing
`while` conditions), `Order` (strict left-to-right evaluation-order
proofs plus unit-materialization), `Lit` (literal and UTF-8 edge cases),
`DupItf` (one implementation shared by two identical interface
methods), and `NewUnit` (class constructors with `()` parameters and
unit-typed call arguments), `GuardChain` (guarded matches compile to
linear-size labeled blocks), `MixedRec` (field reads on records that
mix mutable and immutable fields), and `GenPoll` (back-to-back generic
functions keep independent type variables).  Eight examples under
`examples/` are compiled and run the
same way: `hello`, `counters`, `validate`, `lists`, `options`, `shapes`,
`operators`, and `tuples`.

## Layout

```text
SPEC.md            the language + mapping contract
bin/ml2java.ml     CLI
src/ast.ml         shared AST (contract module)
src/lexer.ml       tokenizer
src/parser.ml      recursive-descent parser
src/check.ml       semantic checker and type table
src/emit_java.ml   Java source emitter
src/pipeline.ml    phase wiring
test/*.mlj         positive fixtures (compile, javac -Werror, run, diff vs *.out)
test/reject/*.mlj  fixtures that must fail (located error contains *.err text)
examples/*.mlj     example programs, gated exactly like test fixtures
tools/gen_fuzz.ml  deterministic fuzz-program/garbage generator
fuzz.sh            fuzz driver (Lane A + Lane B, FUZZ_N)
check.sh           the test driver
```
