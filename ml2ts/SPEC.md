# ml2ts v1 language spec

Source: `.mlj` files — the SAME surface language as ml2java (shared lexer,
parser, and checker). One file = one TypeScript module. The generated file
is named after the input basename (`Demo.mlj` -> `Demo.ts`), but unlike
Java there is no filename constraint: `-o` may name any output path.

This file plus `shared/ast.ml` is the binding contract for the TS emitter.
If the spec and the AST disagree, the AST wins. Unspecified behavior: pick
the boring option and write the choice in a comment.

The checker is shared with ml2java and runs with `Profile.ts`. Everything
the checker accepts for the Java profile is accepted here — the TS backend
is the proof that one frontend serves multiple targets. The checker's
diagnostics are parameterized by the profile name, so messages say
"TypeScript" where the Java profile says "Java".

## Items

The surface language is identical to ml2java v1 (see `ml2java/SPEC.md`
"Items", "Expressions", "Patterns", "Types"): records, variants, functions,
`let main () : unit` entry point, classes, class types, options, lists,
tuples, match, if/while/for, mutation, and the same builtins. The TS
profile keeps the same restrictions (no partial application, no `fun x ->
e`, no modules/functors/exceptions/arrays/refs, `unit` only as a whole
expression or return type, ...).

## TypeScript mapping (emitter rules)

| Source | TypeScript |
|---|---|
| file `Demo.mlj` | `Demo.ts` — declarations at module top level, no wrapper class. `-o` may use any basename. |
| `int` | `number`. Runtime range is the IEEE-754 double safe-integer range (±2^53); literals are still lexed with OCaml's 63-bit limit, but values beyond 2^53 lose precision at runtime. Documented semantic difference. The shared `Lit.mlj` fixture's 63-bit boundary tests are therefore Java-only (excluded from the TS corpus). |
| `float` | `number`. |
| `bool` | `boolean`. |
| `char` | `string` (length 1). |
| `string` | `string`. |
| `unit` | `void` as a return type; the unit expression `()` is `null`. A `unit` parameter is dropped from the emitted signature (checker rule, same as Java). |
| type param `'a` | `A` (uppercased: `'a` -> `A`, `'b` -> `B`, ...). Only type declarations are generic in v1; functions are monomorphic. |
| `t list` | `t[]`. Generated code never mutates arrays. |
| `t option` | `t \| null`; `None` = `null`, `Some x` = `x`. A nested option (`t option option`) cannot be erased — `Some None` and `None` would both be `null` — so when the element type is itself an option, the payload of `Some` is wrapped in a generated `_SomeBox<T>` object `{ tag: "_Some", v0: payload }` and the option type renders as `_SomeBox<render(t)> \| null`. |
| tuple `t1 * t2` | fixed tuple `[t1, t2]`; construction `[a, b]`; `fst`/`snd` -> `v[0]` / `v[1]`. A tuple literal whose element types are NOT all identical is pinned into an annotated temp (`let _t0: [T1, T2] = [a, b];`): an inline mixed literal would widen to a union array (`(string \| number)[]`) and lose element types, breaking e.g. `fst (1, "x") + 3`. Homogeneous literals stay inline (they widen to `T[]`, which is safe in every position). |
| user type `name<args>` | `name<A, B>` (no args -> `name`). |
| immutable record `type point = { x : int; y : int }` | `interface point { readonly x: number; readonly y: number }`; construction `{ x: e, y: e }`; field access `r.x`. |
| record with a `mutable` field | `interface` with that field NOT `readonly`; `r.f <- e` -> `r.f = e`. |
| variant `type shape = Circle of int \| Rect of point * point \| Dot` | discriminated union `type shape = { tag: "Circle"; v0: number } \| { tag: "Rect"; v0: point; v1: point } \| { tag: "Dot" }`; payload components named `v0`, `v1`, ...; no payload -> tag only. |
| constructor `Circle e` / `Dot` | `{ tag: "Circle", v0: e }` / `{ tag: "Dot" }`. |
| `match` | if/else chain on the scrutinee (evaluated once into a temp): tag checks for variants, `=== null` / `!== null` for options, `length === 0` / `length > 0` for lists, `===` for literal patterns, `else` for wildcard/var patterns. Pattern variables are bound with `const` inside the arm. |
| match guards | a guarded arm may fail at runtime, so only an UNGUARDED arm proves coverage (checker rule, same as Java). Guard failure falls through to the next arm. Every emitted match chain ends in a defensive `throw new Error("non-exhaustive match")` so a checker hole surfaces as an exception, never as an invented value. A guarded arm re-tests the scrutinee's tag after a previous arm's standalone `if` has narrowed it, which tsc rejects ("no overlap"); each guarded arm therefore copies the scrutinee into a fresh const (`const _sN: T = scrut;`) before its condition, resetting the narrowing. |
| `Some x` / `None` match | `if (v === null) { None arm } else { Some arm }`; the bound `x` is `v` (or `v.v0` when the payload is boxed). |
| `[]` / `x :: xs` match | `if (v.length === 0) { ... } else { const x = v[0]; const xs = v.slice(1); ... }`. |
| tuple pattern `(a, b)` | `const [a, b] = v;` inside the arm. |
| `=` / `<>` | `===` / `!==` on int, bool, char, float, string operands; `_eq(a, b)` / `!_eq(a, b)` on record, variant, list, option, tuple, user objects. `_eq` is a generated deep-structural helper, emitted once, only when used; it compares object keys SORTED, because record literals may be written in any field order and OCaml record equality is order-independent. `NaN = NaN` is false, matching OCaml. TS infers LITERAL types for inline literals, so comparing two different literals (`1 <> 2` -> `1 !== 2`) would fail tsc's "no overlap" check; each literal operand is therefore widened with a no-op `as T` cast (`(1 as number) !== (2 as number)`). |
| `+ - *` (int/float) | same operators. |
| `/` (int) | `Math.trunc(a / b)` — OCaml int division truncates toward zero; JS `/` is float division. |
| `%` (int) | `%` (JS remainder truncates like OCaml `mod`). |
| `+. -. *. /.` | `+ - * /`. |
| `< <= > >=` | same (int, float, char, string). |
| `&&` / `\|\|` | always short-circuit. When an operand carries statements (assignment, `if`, `match`, `let`, `;`), the right operand is lowered into an `if` block that runs only when the left value demands it. A statement-bearing `while` condition is re-evaluated every iteration: `while (true) { ...; if (!cond) break; body }`. |
| `^` (string concat) | `+`. |
| `not x` / `-x` | `!x` / `-x`. |
| evaluation order | strictly left-to-right: operator operands, call arguments, list/tuple/record elements, cons operands, string concatenation operands. Statement-bearing subexpressions in expression position are hoisted into statements with fresh `_`-prefixed temps, preserving order. |
| `let f (x : int) (y : int) : int = e` | `function f(x: number, y: number): number { ... }` (return annotation required by the checker). `let rec` is the same (function declarations hoist). |
| top-level value `let origin = e` | `const origin: T = e;` (type from the checker table). A value whose initializer carries statements is emitted as an IIFE: `const origin: T = (() => { ...statements...; return value; })();` — top-level declarations evaluate in source order. |
| `let main () : unit` | `function main(): void { ... }` plus a trailing `main();` call at the end of the file. |
| `let x = e1 in e2` / `let mutable` / `let (a, b) = e1 in e2` | `const x = e1;` / `let x = e1;` / `const [a, b] = e1;` followed by the body. |
| `x <- e` (local mutable) | `x = e`. |
| `if a then b else c` | `if (a) { b } else { c }` (statement form) or `a ? b : c` (expression form, when neither branch carries statements). |
| `a; b` | `a; b` (left operand must be `unit` — checker rule). |
| `while c do body done` | `while (c) { body }` (or the re-evaluated form above when the condition carries statements). |
| `for x in xs do body done` | `for (const x of xs) { body }` (TS forbids a type annotation on a for-of variable; the element type is inferred from the list's type). |
| `for i = lo to hi do body done` | `for (let i = lo; i <= hi; i++) { body }`. |
| class `class c (p : t) = object (self) ... end` | `class c implements itf { private readonly p: t; ... constructor(p: t) { this.p = p; } ... }`. Constructor parameters become `private readonly` fields (non-readonly when mutable); `val` fields stay `private` (readonly unless mutable); methods map to methods; `method private` -> `private`; `method static` -> `static`; `inherit itf` -> `implements itf` (all interface methods must exist — checker rule). |
| `self` / bare field name inside a method | `this` / `this.f` (the checker rewrites bare field references to `ESelfField`). |
| static methods | have no instance: `self` and bare field/constructor-parameter names are checker errors inside them, so `this` never appears in a static context. |
| class type `class type itf = object method m (x : t) : r end` | `interface itf { m(x: t): r; }`. |
| `new c args` / `obj # m a` | `new c(args)` / `obj.m(a)`. |
| string and char literals | escaped for JS: `"`, `\`, `\n`, `\t`, `\r` use backslash forms; every other character below 0x20 and 0x7F is emitted as `\uXXXX`; all other Unicode passes through verbatim as UTF-8. |
| `print_string s` | `process.stdout.write(s)`. |
| `print_endline s` | `console.log(s)`. |
| `print_int n` | `process.stdout.write(String(n))`. |
| `print_float x` | `process.stdout.write(_fmt_float(x))` — see `_fmt_float` below. |
| `string_of_int n` / `string_of_bool b` | `String(n)` / `String(b)`. |
| `string_of_float x` | `_fmt_float(x)` — see `_fmt_float` below. |
| `failwith s` | `throw new Error(s)` as a statement; in expression position `(() => { throw new Error(s); })()`. |
| `fst` / `snd` | `v[0]` / `v[1]`. |
| `List.length xs` | `xs.length`. |

## Generated helpers

Emitted once at the top of the file, only when used:

- `_eq(a, b)` — deep structural equality for composite values (see above).
- `_SomeBox<T>` — `type _SomeBox<T> = { tag: "_Some"; v0: T };` for nested
  options.
- `_fmt_float(x)` — float-to-string formatting that reproduces Java's
  `Double.toString` forms, because JS `String(1.0)` is `"1"` but the
  shared fixtures expect `"1.0"`, `"-0.0"`, `"0.3333333333333333"`.
  `NaN` -> `"NaN"`, `Infinity` -> `"Infinity"`, `-Infinity` ->
  `"-Infinity"`, `-0.0` -> `"-0.0"` (via `Object.is`).  For
  10^-3 <= |x| < 10^7: `String(x)` with `".0"` appended when the text has
  no `.`/`e`/`E`.  Outside that range Java prints scientific notation and
  JS switches at different thresholds with different exponent spelling
  (`1e+21` vs `1.0E21`), so the exponent form is rebuilt from
  `toExponential()` (same shortest digits as `String`) into
  `mantissaEexp` (`1.0E7`, `3.14E-5`, `1.5E21`, `-1.5E21`).  Verified
  against Java's actual output by the shared `FloatPrint` fixture.
  This is a deliberate deviation from the naive `String(x)` mapping.
- `declare const process: { stdout: { write(s: string): void } };` — typed
  shim for the Node `process` global, emitted when a process-using print
  builtin is used. At runtime Node provides the real `process`.
- `declare const console: { log(s: string): void };` — typed shim for the
  Node `console` global, emitted when `print_endline` is used. At runtime
  Node provides the real `console`.

The gate runs `tsc --strict --noEmit --target es2020 --lib es2020` (the
`--lib es2020` excludes the DOM lib, whose globals like `origin` would
collide with source names).

## Names

The checker enforces the profile's name rules (see `shared/profile.ml`):
source names reaching the output verbatim must not be ECMAScript strict-mode
reserved words, `constructor` (illegal as a method/field name), the TS
primitive type names (`any boolean number string symbol object unknown
never bigint` — illegal as class/interface/type-alias names), the ES-lib
globals (`undefined NaN Infinity`), or `eval`/`arguments` (strict-mode
restricted); must not start with `_` (the emitter owns `_`-prefixed
helpers and temps); no duplicate parameters/members; a type, class, and
class type may not share one name. TS contextual keywords like `get`,
`set`, `of`, `from`, `async`, `type`, `namespace` are legal in every
emitted position and are NOT banned (a shared fixture uses `method get`).
Local binders and pattern variables are exempt: the emitter renames them
(`x_b0`, ...), so source shadowing never collides.

Two name-namespace rules are TS-only (behind profile flags, off for Java):
a class's methods and its fields/ctor params share one member namespace
(`method x` colliding with `val x` or a ctor param `x` is an error), and a
class and a top-level function/value share one value namespace (a class
named like a function is an error).

## Errors

All front-end errors: one line `file.mlj:line:col: error: message` on
stderr, exit 1. Checker runs before emission; no half-emitted file.

## Out of v1

Identical to ml2java v1's out-of-v1 list (partial application, functions as
values, modules, functors, exceptions, arrays, char arithmetic, `downto`,
record patterns, two-or-more type params on variants, named variant payload
fields, type aliases, class inheritance beyond interfaces, `open`,
references, `unit` inside composite types). The TS backend accepts exactly
the surface the shared checker accepts for `Profile.ts` — nothing more,
nothing less.
