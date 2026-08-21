# ml2java tutorial

ml2java compiles OCaml-shaped source files (`.mlj`) into ordinary, readable
Java. It is deliberately restricted: only constructs that have a direct and
predictable Java representation are accepted. Everything else is rejected
with a one-line error. This tutorial walks through the language from a
hello-world to classes and recursion. Every example file named here lives
in `examples/` and is compiled, run, and output-checked by `sh check.sh`,
so it is guaranteed to work in the current tree.

## Setup

Requires OCaml with `dune` and a JDK (17+; records and sealed interfaces
need it).

```sh
cd ml2java
dune build
_build/default/bin/ml2java.exe examples/hello.mlj -o hello.java
javac -encoding UTF-8 -Xlint:all -Werror hello.java && java hello
```

The generated top-level class takes the input file's basename, so `-o`
must keep that basename. Errors are one line on stderr of the form
`file.mlj:line:col: error: message`; the exit code is 1, and no output
file is written on error.

## 1. Hello

```ocaml
(* examples/hello.mlj *)
let main () : unit =
  print_endline "hello, ml2x"
```

`let main () : unit` becomes Java's `public static void main`. Run it:
`java hello` prints `hello, ml2x`. The unit-typed call argument `()`
of `main` is dropped from the Java signature, so `main` has no
parameters there.

## 2. Values, functions, and `if`

```ocaml
(* examples/operators.mlj *)
```

Integer arithmetic, `bool` logic, `if/then/else` (an expression, as in
OCaml), and function definitions with `let` all work as in OCaml.
`int` is Java `long`, `float` is `double`, `bool` is `boolean`,
`string` is `String`, `char` is `char`. `mod` is not available; use `%`.

## 3. Records

```ocaml
(* examples/validate.mlj *)
type order = { item : string; qty : int; coupon : string option }
```

A record compiles to a Java `record`. A record containing any `mutable`
field instead becomes a `final class` with public fields (Java records
cannot have mutable components; `=` on records must stay structural).
Construct with `{ item = "pen"; qty = 1 }`, read with `o.item`, update
with `{ o with qty = 2 }` (not supported: copy-update is outside the v1 subset). Pattern matching on
records is restricted (see the restriction list at the bottom).

## 4. Variants and `match`

```ocaml
(* examples/shapes.mlj *)   (* a simple variant *)
(* examples/tree.mlj *)      (* a recursive variant: a search tree *)
```

A variant compiles to a Java sealed interface plus one `record` per
constructor. `match` compiles to an if/else `instanceof` chain, and the
compiler checks exhaustiveness — you cannot forget a constructor:

```ocaml
(* examples/tree.mlj *)
type btree =
  | Empty
  | Node of int * btree * btree
```

Recursive functions over recursive types are the normal way to write
programs here; `let rec` is supported. Guards (`when`) are supported,
including "guard-only" arms — but a guard does not count toward
exhaustiveness, because it can fail at runtime:

```ocaml
(* rejected: the guarded `true` arm may fail, so `true` is missing *)
let f (b : bool) : int =
  match b with
  | true when false -> 7
  | false -> 9
```

## 5. Tuples

Tuples compile to generated `Tuple2`/`Tuple3` records. Use them in
patterns, with `fst`/`snd`, and with the usual OCaml syntax. See
`examples/tuples.mlj` for field access, nesting, and equality.

## 6. Lists

```ocaml
(* examples/lists.mlj *)
```

Lists compile to `java.util.List`. Literals use `List.of`, `::` uses a
small `_cons` helper, and `for x in xs` becomes an enhanced for loop.
Recursive functions over lists (`sum`, `evens`, `take`) are the pattern.

## 7. Functions and generics

```ocaml
(* examples/generics.mlj *)
let id (x : 'a) : 'a = x
let swap (x : 'a) (y : 'b) : 'b * 'a = (y, x)
```

Type variables are real: `id` returns exactly the type it received.
One variable used twice means the same type both places. Partial
application and functions as values are **not** in the v1 subset.

## 8. Strings and printing

```ocaml
(* examples/formatting.mlj *)
```

`^` concatenates, `string_of_int`/`string_of_float`/`string_of_bool`
convert, `print_endline` prints a line, `print_int` prints without a
newline. String comparison (`<`, `<=`, ...) uses `compareTo` in Java.
Non-ASCII text in string literals passes through as UTF-8.

## 9. State: classes, mutation, loops

```ocaml
(* examples/counters.mlj *)   (* classes, mutable fields, interfaces *)
(* examples/fizzbuzz.mlj *)   (* for i = 1 to n, mutable locals *)
```

- `let mutable x = 0` is a mutable local; `x <- x + 1` updates it.
- `for i = 1 to n do ... done` is a counting loop; `for i = n downto 1`
  counts downward.
- `while cond do ... done` re-evaluates its condition each iteration,
  even when the condition contains statements.
- Classes map to nested `static final class`es: constructor parameters
  become `private final` fields plus one constructor; `val` fields stay
  private; `method private` → `private`, `method static` → `static`.
- A `class type` is a Java interface; `inherit` implements it. An
  interface method must be implemented by a public, non-static method
  with a compatible signature.
- A static method has no instance: `self` and bare field names are
  checker errors inside it.

`&&` and `||` keep short-circuit semantics even when an operand contains
statements: the right side of `false && (...)` never runs.

## 10. When ml2java says no

The v1 subset is enforced, not discovered at runtime. The full rejection
list is in SPEC.md ("Deliberate restrictions"); every one has a fixture
under `test/reject/`. Common messages and what they mean:

| Error text (abridged) | What to do |
|---|---|
| `non-exhaustive match: missing case(s) ...` | add the missing constructor/constant arm, or a wildcard `_`; a guarded arm never counts as coverage |
| `duplicate function 'f'` | top-level names are unique per file |
| `unbound function 'f'` | the name is not defined (or misspelled) |
| `instance field 'n' cannot be accessed from a static method` | move the field access out of the `method static` body |
| `method 'm' of class 'c' is private, but it must be public to implement ...` | implement interface methods with `public` (non-private) methods |
| `output basename 'X' differs from the input basename 'Y'` | `-o` must keep the input file's basename (the top-level class is named after it) |
| `error: ...` starting with `ml2java: error:` | a CLI-level problem (missing file, bad `-o`), see `--help` |

The check gate itself (`sh check.sh`) is the best spec: it compiles every
fixture, requires `javac -Werror` cleanliness, requires clean exit and
empty stderr at runtime, and diffs stdout. Add new behavior by adding a
`.mlj` + `.out` pair under `test/` and let the gate verify it.

## 11. Fuzzing

`FUZZ_N=200 sh fuzz.sh` generates deterministic type-correct programs
(lane A) and hostile garbage/mutations (lane B) and gates every one. Any
counterexample is reproducible from its seed alone. If you add features,
raise `FUZZ_N` and let the lanes probe them before you commit to the
behavior.
