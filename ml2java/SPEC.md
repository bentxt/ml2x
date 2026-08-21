# ml2java v1 language spec

Source: `.mlj` files. OCaml-shaped syntax. One file = one Java compilation
unit. The Java top-level class is the file basename unchanged; everything
declared is nested `static` inside it.

This file plus `../shared/ast.ml` is the binding contract for parser, checker, and
emitter. If the spec and the AST disagree, the AST wins. Unspecified behavior:
pick the boring option and write the choice in a comment.

## Items

```ocaml
type point = { x : int; y : int }                       (* record *)
type dim = { mutable w : int; h : int }                 (* mutable field *)
type shape = Circle of int | Rect of point * point | Dot (* variant *)
type 'a tree = Leaf | Node of 'a tree * 'a * 'a tree    (* generic variant *)
type ('a, 'b) either_or = .. .                          (* NOT in v1: two type params only via 'a 'b syntax below *)
type ('a, 'b) t = .. .                                  (* NOT in v1 *)
type 'a 'b pair2 = { fst : 'a; snd : 'b }               (* generic record, 'a 'b params *)

let add (x : int) (y : int) : int = x + y               (* function; multi-arg via several parens groups *)
let rec fact (n : int) : int = if n = 0 then 1 else n * fact (n - 1)
let origin = { x = 0; y = 0 }                           (* top-level value *)

The entry point is `let main () : unit`; that is the only accepted form of
`main` (parameters or a non-unit return are checker errors).

class greeter (prefix : string) =                       (* class: ctor params become fields *)
  object (self)
    inherit printable                                   (* implements Java interface *)
    val mutable count = 0                               (* private field *)
    method greet (name : string) : string =             (* public instance method *)
      count <- count + 1;
      prefix ^ " " ^ name
    method private bump () : unit = count <- count + 1  (* private method *)
    method static make (p : string) : greeter = new greeter p
    method total () : int = count + self # bonus ()     (* self call *)
  end

class type printable = object method to_string () : string end
```

## Expressions

literals, `x`, `(a, b)`, `[a; b]`, `x :: xs`, `{ x = e }`, `r.x`,
`x <- e`, `r.f <- e`, `obj # m a`, `f a b`, `Circle e`, `Dot`, `Some e`, `None`,
`new c a`, `match e with | p when g -> rhs | ...`, `if a then b else c`,
`let x = a in b`, `let mutable x = a in b`, `let (a, b) = e in b`,
`a; b`, `while c do body done`, `for x in xs do body done`,
`for i = lo to hi do body done`, `for i = lo downto hi do body done`,
`-x`, `not x`, `(e : t)`.

Operators: `+ - * / % mod` (int), `+. -. *. /.` (float), `= <> < <= > >=`,
`&& ||`, `^` (string concat). Precedence: OCaml standard for these.
Unary minus on literals and expressions. `not` prefix.

Int literals must fit OCaml's 63-bit int: max is 4611686018427387903,
anything larger is a lexer error.  The left operand of a sequence `a; b`
must have type unit (hard error otherwise, matching OCaml's warning).

Input nesting is bounded: expressions, types, patterns, and comments nested
deeper than 1000 are errors (message carries "nested too deeply (limit
1000)").

Application: several parenthesized groups `f (x : int) (y : int)` declare
params. Calls are curried in syntax `f a b` but must be FULLY APPLIED;
partial application is a checker error in v1.

## Patterns

`_`, `x`, literals, `None`, `Some p`, `Circle p`, `Node (l, v, r)` (tuple
arg flattens to component patterns: Node of a*b*c then `Node (l,v,r)` gives
three binders), `(p1, p2)`, `[]`, `x :: xs`, `{ a = p1; b = p2 }` (record
pattern: must name exactly the record's fields, like a record literal).

## Types

`int float bool char string unit`, `'a`, `t list`, `t option`,
`t1 * t2`, user names (lowercase, like OCaml). Type params on decls:
`'a tree ` / `'a point`.  Multi-argument type applications use the
parenthesized OCaml form `(int, string) pair2` (juxtaposition `int string
pair2` is not accepted in v1).  `type t = ...` aliases expand in the
checker (generic aliases `type 'a t = 'a list` included), so generated
code never carries the alias name.

## Java mapping (emitter rules)

| Source | Java |
|---|---|
| evaluation order | strictly left-to-right: operator operands, call arguments, list/tuple/record elements, cons operands, string concatenation operands. `&&`/`\|\|` still short-circuit: the right operand never runs before the left, and is skipped when the left decides the result. |
| file `Demo.mlj` | `public final class Demo { ... }` — one file, one top-level class, named after the basename. |
| immutable record `type point = { x : int; y : int }` | `record point(long x, long y) {}` (nested static). |
| record with a `mutable` field | `final class` with public fields and a single constructor; mutable fields public non-final, others public final. |
| variant `type shape = Circle of int \| Rect of point * point \| Dot` | `sealed interface shape<T> {}` plus one nested `record` per constructor `implements shape<T>`; payload components named `v0`, `v1`, ... (`Circle of int` → `record Circle(long v0) implements shape {}`). |
| `match` | if/else `instanceof` chain with pattern variables. |
| option | erased to nullable: `None` = `null`, `Some x` = `x`; `match Some x -> ... \| None -> ...` lowers to a `v == null ? ... : ...` shape. A nested option (`t option option`) cannot be erased — `Some None` and `None` would both be `null` — so the payload of a `Some` whose element type is itself an option is wrapped in a generated `_SomeBox<T>` record, keeping the two values distinct. |
| `&&` / `\|\|` | always short-circuit. When an operand carries statements (assignment, `if`, `match`, `let`, `;`), the right operand is lowered into an `if` block that runs only when the left value demands it. A statement-bearing `while` condition is re-evaluated every iteration: `while (true) { ...; if (!cond) break; body }`. |
| match exhaustiveness | only an unguarded arm proves coverage; a guarded arm may fail at runtime, so a match whose cases are all guarded is non-exhaustive. Every emitted match chain ends in a defensive `throw new IllegalStateException(...)` so a checker hole surfaces as an exception, never as an invented value. |
| tuple | nested `record Tuple2<A,B>(A v0, B v1) {}` / `Tuple3`, emitted once per arity, only when used. |
| list | `java.util.List<T>`; literals → `List.of(...)`; `::` → helper; `[]` / `x :: xs` match → `isEmpty` / `get(0)` / `subList(1, size())`; `for x in xs` → enhanced for. |
| int literals | stay plain (`5` widens to `long`); string concat `^` → `+`. |
| equality `=` | `==` / `!=` on primitive operands (int, bool, char, float); `.equals` on string, record, variant, list, option, tuple, user objects. The checker resolves operand types; the emitter uses the checker's type table. |
| class | nested `static final class cname { ... }`: constructor parameters become `private final` fields plus a single constructor; `val` fields stay `private` (final unless mutable); methods map to methods; `method private` → `private`; `method static` → `static`; `inherit itf` → `implements itf`, and all interface methods must exist (checker error otherwise). Two inherited class types declaring the same method name: identical signatures are allowed and share the class's single implementation; incompatible signatures are a checker error. |
| static methods | have no instance: `self` and bare field/constructor-parameter names are checker errors inside them, so `this` never appears in a static context. |
| interface implementation | must be a public, non-static method with a compatible signature; private or static implementations are checker errors (javac would reject them). |
| bare field/ctor-param name inside a method | `this.name`. |
| class type | nested `interface ctname { ... }` (methods without bodies). |
| string and char literals | escaped for Java: `"`, `\`, `\n`, `\t`, `\r` use backslash forms; every other character below 0x20 and 0x7F is emitted as `\uXXXX`; all other Unicode passes through verbatim as UTF-8. Generated files compile with `javac -encoding UTF-8` and produce no warnings under `-Xlint:all -Werror`. |
| `let main () : unit` | `public static void main(String[] args)`. |
| other top-level functions / values | functions → `public static` methods; values → `public static final` fields. A value whose initializer carries statements (`if`, `match`, `let`, `;`, loops) is assigned inside a `static { }` initializer block, in declaration order, instead of an illegal class-body statement. |

## Builtins

```
print_string   s        -> System.out.print(s)
print_endline  s        -> System.out.println(s)
print_int      n        -> System.out.print(n)
print_float    x        -> System.out.print(x)
string_of_int  n        -> Long.toString(n)
string_of_float x       -> Double.toString(x)
string_of_bool b        -> Boolean.toString(b)
failwith       s        -> throw new RuntimeException(s)  (expr of any type)
fst / snd      pair     -> pair.v0 / pair.v1
List.length    xs       -> xs.size()
```

## Out of v1 (clean diagnostic, position + message)

partial application, functions as values / `fun x -> e`, modules, functors,
exceptions (`raise`, `try`), arrays, float-less `+.`-free mixes requiring
promotion (int+float is an error, not auto-coerce, except literals? no: error),
char arithmetic, named variant payload fields,
class inheritance (`inherit` only takes class type names = interfaces),
`open`, references (`ref`, `:=`, `!`), a named parameter of type `unit`
(write `()`, which is dropped from the Java signature), and `unit` inside
`list`/`option`/tuple/type-argument positions (`unit` has no Java value, so
it may appear only as a whole expression or return type).  The restriction
applies to inferred composite types too: a value, function, or expression
whose inferred type contains `unit` anywhere inside a `list`/`option`/
tuple/constructor type argument is rejected, not only explicitly written
annotations.  Comparing `unit` values with `=` is likewise rejected.

## Names

Every source name that reaches the Java output verbatim (types, constructors,
functions, values, classes, class types, fields, methods, parameters) must be
a legal Java identifier. Rejected with a located diagnostic:

- Java keywords (`final`, `static`, `null`, ...);
- names starting with `_` (the emitter owns `_`-prefixed helpers and
  temporaries);
- `TupleN` names (the emitter emits `Tuple2`/`Tuple3`/... records per arity);
- duplicate parameter names, duplicate class members (ctor params and `val`
  fields share one field namespace), duplicate method names in a class;
- a type, class, and class type sharing one name (they share the nested-type
  namespace of the generated file);
- names that collide CASE-INSENSITIVELY in the generated file's nested-type
  namespace (records, variant interfaces and constructors, classes, class
  types, and the top-level class): on a case-insensitive filesystem the two
  generated `.class` files would overwrite each other, so the checker
  rejects the pair (message carries `collides`).  This also covers exact
  duplicates across categories (a constructor reusing a record's name, ...);
- a class field or constructor parameter whose name is also an in-scope
  top-level value/function (so `val` initializers resolve names
  unambiguously);
- a file basename that is not a valid Java class name (the basename becomes
  the top-level class).

Local binders and pattern variables are exempt: the emitter renames them
(`x_b0`, ...), so source shadowing never collides with Java.

## Errors

All front-end errors: one line `file.mlj:line:col: error: message` on stderr,
exit 1. Checker runs before emission; no half-emitted file.  Declaration
errors point at the declaration's head keyword (`type`/`let`/`class`).
Genuinely file-level errors (bad file basename, `-o` basename mismatch) use
the position convention `file:0:0`.
