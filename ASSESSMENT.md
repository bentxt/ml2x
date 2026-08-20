# ML2X Assessment — fs2ml / ocamlsharp

Status: source-grounded assessment pass. Read-only; nothing in `esca-frontends` was
modified. `sh check.sh` was run in the fs2ml repo and passes (see *Verification*).

**Naming.** The project renamed itself. The dune package and CLI are **`ocamlsharp`**
(`frontends/fs2ml/src/dune`, `bin/dune`). Historical names: `fs2ml`, `fsharp2ocaml`,
`eocaml`, and `JavaML`/`javaml` (its parent frontend). The handoff brief in this repo
says "FS2ML"; this document uses `ocamlsharp` for the standalone product and
`javaml`/`JavaML` for the parent frontend it was carved from.

All paths below are relative to the `esca-frontends` monorepo root
(`…/esca/esca-frontends/`).

---

## 1. Current project summary

`ocamlsharp` is a **source-to-source preprocessor**, not an F# or OCaml compiler:

> write OCaml with an F#-shaped syntax → emit readable OCaml → let `ocamlc`/`dune`
> typecheck it. (`frontends/fs2ml/README.md`; `frontends/fs2ml/src/pipeline.ml:1-3`)

The product deliberately owns no semantics: `src/pipeline.ml` documents
"Syntax-only frontend … No checker, no Java lowering — OCaml/ocamlc remains the
semantic authority."

The most important structural fact for ML2X:

**`ocamlsharp` is not a standalone compiler.** Its frontend — `src/token.ml`,
`src/lexer.ml`, `src/parser.ml`, `src/ast.ml`, `src/diagnostic.ml` — is a
**byte-identical copy** of the parent JavaML frontend's files
(`src/javaml/{token,lexer,parser,ast,diagnostic}.ml`; verified with `diff`). The
real compiler machinery lives in `src/javaml/` (semantic checker, desugar pass,
Java lowering, three emitters). The standalone repo contributes exactly two things
on top: an OCaml **text emitter** (`src/emit.ml`, 204 lines) and a **reverse tool**
(`bin/ocaml2ocamlsharp.ml`), plus the `core` fixture and `check.sh`.

What the product currently proves (verified by running `sh check.sh` in the fs2ml
repo):

```
build                    dune build ./bin/main.exe                     OK
forward                  test/core.fs -> core.ml -> ocamlc -c            OK
reverse (OCaml >= 5.2)   skipped: switch is 4.14.2 (gated by design)
```

The reverse tool is intentionally version-gated (`bin/dune`, `enabled_if >= 5.2.0`)
because it inspects compiler-libs internals with `Obj` to recover tuple payloads
(`bin/ocaml2ocamlsharp.ml:36-92`).

---

## 2. Relevant source tree

Only files that matter to the ML2X question.

### The product under assessment — `frontends/fs2ml/`

| File | Purpose |
|---|---|
| `src/ast.ml` | **Shared surface AST** (byte-identical to `src/javaml/ast.ml`). |
| `src/parser.ml` | Hand-written recursive-descent parser over the shared AST (byte-identical to javaml's). |
| `src/lexer.ml`, `src/token.ml`, `src/diagnostic.ml` | Shared frontend (byte-identical). |
| `src/pipeline.ml` | `parse` + `compile_syntax_only ~backend`; the OCaml lane stops here. |
| `src/emit.ml` | **The entire OCaml backend**: AST → OCaml text, rejecting a list of node families. |
| `bin/main.ml` | CLI `ocamlsharp input.fs output.ml`. |
| `bin/ocaml2ocamlsharp.ml` | Reverse tool (`ocamlc-libs` parsetree → F#-shaped source), OCaml ≥ 5.2. |
| `test/core.fs` / `test/core.ml` / `test/core.reverse.fs` | The checked fixture + reverse roundtrip. |
| `check.sh` | Build + forward + reverse proof. |
| `handoff-fs2ml.md`, `open-problems-plan.md` | Internal plans; `open-problems-plan.md` Phase 1/2 name the surface-vs-emit problem. |

### The parent frontend that actually implements the semantics — `src/javaml/`

| File | Purpose |
|---|---|
| `pipeline.ml` | Orchestration: `Java_checked.emit_program`, `Reason_checked.emit_program`, and the `compile_syntax_only ~backend` hook ocamlsharp reuses. |
| `desugar.ml` | Pre-check rewrites (value equality → `.equals`, array element-type inference). |
| `check.ml` | Semantic checker, 1885 lines (world/type analysis, member lookup, mutability, returns). |
| `resolve.ml`, `env.ml`, `module_context.ml`, `call_check.ml` | Name resolution + multi-file module context. |
| `java_prep.ml` | Lowering AST → Java-shaped IR (`java_expr`, `java_stmt`, `java_type_decl`, `java_program`), 1097 lines. |
| `emit_java.ml` | Java source generator (variants → sealed interface + records; DObject → class). |
| `emit_reason.ml` | Reason/OCaml-ish view (a second emitter over the same AST). |
| `emit_triplets.ml` | Normalized-triplet debug emitter (a third emitter). |
| `interop.ml` | Java interop signatures for `String`, `System.out`, etc. |

Test fixtures: `t/javaml/` (165 `.java` outputs, incl. `objects.jml`/`objects.java`),
`t/javaml-reject/` (semantic rejections), `t/javaml-multifile/`,
`t/javaml-reason/`.

---

## 3. Actual compiler pipeline

### ocamlsharp (the product): syntax → text, nothing between

```
Lexer.lex            src/lexer.ml:120
  -> Token.t list
Parser.parse_program src/parser.ml:739-768
  -> Ast.program
Emit.emit_program    src/emit.ml:201-204
  -> "module X = struct ... end" (OCaml text)
```

Wired in `bin/main.ml:32-35`:

```
read_file input
|> Ocamlsharp.Pipeline.compile_syntax_only ~backend:Ocamlsharp.Emit.emit_program
|> write_file output
```

`compile_syntax_only` is `source |> parse |> emit_syntax_only ~backend`
(`src/pipeline.ml:9`). There is **no semantic pass** — the emitter raises
`Diagnostic.Error` mid-emission for anything outside its subset.

### javaml (the parent frontend's Java lane) — the full ML2X-style recipe

`src/javaml/pipeline.ml:20-32`:

```
Desugar.rewrite_program        (semantic repairs: equality, array element types)
  -> Check.check_program       (semantic checking: worlds, members, returns, names)
  -> Java_prep.prepare_program (lower AST -> Java IR)
  -> Emit_java.emit_program    (Java source)
```

`Reason_checked.emit_program` (`pipeline.ml:68-73`) is `Check.check_program` +
`Emit_reason.emit_program` — a **second checked backend over the same AST**.

So the monorepo already contains the exact pipeline shape the handoff asks
"does this exist?" about: parser → AST → (semantic/type layer) → transformations/IR
→ target backend. It exists for Java and Reason; the standalone `ocamlsharp` product
deliberately ships only the first and last step.

---

## 4. Internal representations

### Surface AST — `ast.ml` (the shared, target-neutral front-end IR)

The AST is small and ML-flavored, with an explicit Java-only surface grafted on.

- `typ = { base : string; targs : typ list }` (`ast.ml:1`). Types are bare name
  strings with stringly-encoded specials: `TupleN` (arity ≥ 2) and the sentinel
  `"[]"` for arrays (`ast.ml:6-24`). There is **no function type, no module
  qualification, no polymorphism beyond `<T,U>` type parameters**.
- `expr` (`ast.ml:30-85`): `EUnit | EInt | EStr | EChar | EBool | EVar | EField |
  ECall | ELocalCall | EBin | ECtor | ENew | ERecord | EList | EArray | ETuple |
  EMatch | ELet | ELetTuple | ESeq | EIf | EWhile | ETry | EForeach | EForRange |
  EAssign | EUnary | EIndex | EAt`. The comments on `EArray`, `ELet`, `ETry`,
  `EAt` explicitly describe the **Java lowering** of each node ("lowers to a Java
  try/catch", "Both lower to the same reassignable Java `var`", "Java array
  creation `new t[]{...}`").
- `object_member = { member_visibility; member_static; self_name; member_name;
  member_params; member_ret; member_body }` (`ast.ml:87-97`); `decl = DVariant |
  DRecord | DObject | DFun` (`ast.ml:99-105`); `program = { module_name;
  package_name; imports; import_pos; decls; decl_pos }` (`ast.ml:107-117`).

So the AST is **backend-neutral in fact** (four emitters consume it), but its shape
is **not** a neutral ML IR — it is the ML surface plus the Java-only nodes
(`package`/`import`/`throws`/`DObject`/`ENew`/loops/`ETry`/`EAssign`/`EIndex`/
member calls `ECall`). It cannot represent modules, functors, signatures, function
types, GADTs, or polymorphism. That is the whole point of a "constrained subset".

### Java IR — `java_prep.ml` (the per-target lowering target)

`java_expr` (`JInt…JNewArray`, `JSwitch`), `java_stmt` (`JLocal`, `JReturn`,
`JReturnSwitch`, `JIf`, `JSwitchStmt`, `JWhile`, `JForeach`, `JForRange`, `JAssign`,
`JTry`), `java_type_decl` (`JVariant | JRecord | JObject`), `java_fun`, `java_program`
(`java_prep.ml:3-80`). This is a Java-specific statement/expression IR produced by
`prepare_program` (`java_prep.ml:1070`) — the "lowering middleware" the ocaml
pipeline deliberately skips.

### The OCaml lane has **no IR**

`src/emit.ml` builds OCaml **text strings** directly from the surface AST
(`emit_expr` returns `string`; `emit_program` concatenates). There is no OCaml
syntax tree, no normalization pass, no intermediate representation between the
shared AST and the emitted `.ml` text.

---

## 5. Supported language matrix

Scope: what `ocamlsharp`'s emitter (`src/emit.ml`) actually handles. The parser accepts
a *wider* surface (everything javaml parses); the emitter is the real boundary, and
it rejects whole node families at emission time with `Diagnostic.Error
("OCaml syntax emitter does not support " ^ feature)`.

Exact coverage, counted from the source: all 29 `expr` variants are handled by
one match (`emit.ml:71-123`) — 21 emitted, 8 refused (`ECall` :80, `ENew` :88,
`EWhile`/`ETry`/`EForeach`/`EForRange`/`EAssign` :115-119, `EIndex` :123). All 3
`pattern` forms are supported; 3 of 4 `decl` forms are supported (`DObject`
refused at :187).

| Construct | Status | Where |
|---|---|---|
| one `module X` per file | supported (container only) | `emit_program`, `src/emit.ml:201` |
| records (`type X = { ... }`, record values) | supported | `emit_decl`/`ERecord` |
| variants + constructor values | supported | `emit_decl`/`ECtor` |
| typed `let rec` functions | supported (always emits `let rec`) | `emit_decl:188-199` |
| local `let … in`, `let () = e in`, `do … in` | supported | `ELet`/`ESeq` |
| `match` + `when` guards | supported | `EMatch` |
| `if … then … else` | supported | `EIf` |
| field access `e.f` | supported | `EField` |
| local calls (fully applied) | supported | `ELocalCall` |
| tuples, lists `[...]`, arrays `[|...|]` | supported (emitter) | `ETuple`/`EList`/`EArray` |
| basic operators `= <> < <= > >= + - * / %` | supported | `ocaml_op`, `EBin` |
| unary `!`, `-` | supported | `EUnary` |
| `let mutable n = …` | partial — parsed, `mutable` dropped, no `<-` emitted | `ELet` `_is_mut` unused |
| currying / partial application | **not represented** (functions take one fixed param list) | `parse_params` |
| `throws E1, E2` | **parsed and dropped** | `DFun` `_throws` unused |
| `package` / `import` | **parsed and dropped** | `program.package_name`/`imports` unused by `emit_program` |
| Java-style member call `t.m(a)` (`ECall`) | unsupported → diagnostic | `src/emit.ml:80` |
| `new T(...)` (`ENew`) | unsupported | `src/emit.ml:88` |
| `while … do … done` (`EWhile`) | unsupported | `src/emit.ml:115` |
| `try … with/finally` (`ETry`) | unsupported | `src/emit.ml:116` |
| `for … in … do … done` (`EForeach`) | unsupported | `src/emit.ml:117` |
| `for i in a..b do…` (`EForRange`) | unsupported | `src/emit.ml:118` |
| `<-` assignment (`EAssign`) | unsupported | `src/emit.ml:119` |
| `e[i]` indexing (`EIndex`) | unsupported | `src/emit.ml:123` |
| object decl `type X(p) = member …` (`DObject`) | unsupported | `src/emit.ml:187` |

The fixture `test/core.fs` exercises exactly the "supported" row: one module,
`type Expr`, `type Pos = { … }`, a `match` with guards, record values, local calls,
and comparisons.

**The parse surface is wider than the emitted subset, and the boundary is a string
of runtime `unsupported` raises in the emitter, not a declared profile.** The
product's own plan documents this as Phase 2 work
(`open-problems-plan.md`: "The parser and AST still accept JavaML-era constructs …
the OCaml emitter rejects many of these later").

---

## 6. OCaml coupling analysis

*This section continues the handoff's section 4 "OCaml coupling" analysis.*

How much of the compiler is tied to OCaml? **Almost none.** The OCaml
assumptions are confined to one file: `src/emit.ml`. The AST and parser are
Java-flavored, not OCaml-flavored; the parent frontend proves it by consuming the
same AST for Java, Reason, and triplets output.

| Structure | Target independence |
|---|---|
| `src/ast.ml`, `src/parser.ml`, `src/lexer.ml`, `src/token.ml` | **Target-independent.** Byte-identical with `src/javaml/`, which runs 4 backends over the same AST. |
| `src/emit.ml` — type spelling | OCaml-specific: maps `String→string`, `bool/boolean→bool`, `int/long→int`, `void→unit`, `List<T>→T list`, `T[]→T array`, `TupleN→(a*b)`, type params → `'a` (`emit_typ`, `src/emit.ml:42-60`). |
| `src/emit.ml` — declarations | OCaml-specific: wraps everything in `module X = struct … end`, always emits `let rec`, renames types `lower_initial` (both lowercase for OCaml), drops `throws`/`package`/`import` (`emit_program`, `emit_decl`). |
| `src/emit.ml` — expression text | OCaml syntax built directly: `match … with`, `let … in`, `if … then … else`, `[| … |]`, `let () = e in`, `not` (`emit_expr`, `src/emit.ml:70-124`). |
| `src/emit.ml` — operators | `ocaml_op` (`src/emit.ml:68`) maps `&&`/`\|\|` and passes everything else through — `=`/`<>` stay `=`/`<>`, which is *correct* for OCaml's structural equality. |
| semantic/type layer | **absent** in ocamlsharp; OCaml type semantics are delegated to `ocamlc`/`dune`. |

**Where OCaml semantics would enter if the OCaml lane grew a checker:** equality is
already handled for free by OCaml (unlike JavaML, which needs `Desugar` to rewrite
`=`→`.equals()`, `src/javaml/desugar.ml:33-40`); exceptions are native; integers
overflow per the OCaml spec; tail calls are compiler-level. A future OCaml
subsetter must *declare* those as the OCaml profile's semantics, but the emitter
itself does not embed them today.

**Java is structurally a *third* case**: the AST is ML-flavored (ML semantics on
top) plus Java-shaped surface nodes. OCaml assumptions enter only in the emitter's
spelling.

---

## 7. Multi-target readiness

**Question:** could the current generator become one backend among several? Would
adding Java (or TS) require "a new backend only", "some IR cleanup", or "a
substantial compiler rewrite"?

**Answer from source: the pattern is already proven — there are four backends over
one AST today:**

| Backend | Where | Semantic layer |
|---|---|---|
| Java (checked) | `src/javaml/pipeline.ml:20-32` (`Java_checked`) | yes (desugar → check → java_prep → emit_java) |
| Reason view (checked) | `src/javaml/pipeline.ml:68-73` (`Reason_checked`) | yes (check → emit_reason) |
| Triplets (normalized) | `compiler.ml:19-20` → `Emit_triplets.emit_program` | — |
| OCaml (product) | `frontends/fs2ml/src/emit.ml` | no (syntax-only) |

(the monorepo's other `emit*.ml` files — `src/esc/`, `src/resc/`,
`generated/eml/` — emit from different AST types, so they are not evidence for
or against a shared-AST backend; javaml's entry CLIs are
`tools/javaml2java.ml` and `tools/javaml2reason.ml`.)

The frontend (lexer/parser/AST) is the shared asset; each backend implements its
own "what does this construct mean here" logic. Adding a TypeScript backend is a
*new backend over the existing AST* — the demonstrated pattern. It does **not**
require a frontend rewrite.

**But** two things keep this from being a real ML2X core:

1. **No target-profile contract.** "Supported" is whatever each emitter fails to
   reject, discovered per-expression during emission. There is no up-front,
   per-target subset definition (allowed node families + target-semantics rules)
   such as the brief's "integer representation and overflow, equality, exceptions,
   mutation, …". The Java lane gets close (its `check.ml` + `java_prep.ml` are
   that semantics for Java); the OCaml lane has *nothing*, which is exactly why it
   needs the "OCaml subset" spelled out somewhere other than a runtime raise.
2. **The shared frontend is vendored, not owned.** ocamlsharp carries a frozen copy
   of the javaml frontend. It is currently byte-identical, but it is a copy — the
   parent can drift. For a multi-target ML2X, a shared AST must be *one* artifact,
   not copies.

**Where you stand:** "new backend only" is accurate for *surface-to-text* backends
(e.g. a TS emitter over the current AST). It becomes "IR cleanup" as soon as you
want a TS *semantic subsetter* (matching/equality/overflow rules), because that is
currently Java-only logic living in `check.ml`/`java_prep.ml`. It becomes a
"substantial rewrite" only if you require a single semantics-verified core across
all targets rather than per-target profiles.

---

## 8. Java/OO feasibility

The two-facility `ml2java` model the brief proposes is **already implemented and
tested in the parent frontend**, with one spelling difference.

### Facility 1 — portable functional ML subset → Java

This is exactly `Java_checked` today: the shared AST (records, variants, match,
guards, tuples, lists, let, functions) is type-checked (`check.ml`), lowered
(`java_prep.ml`), and emitted as idiomatic modern Java — records as `record`,
variants as `sealed interface` + records, tuple generics as `Tuple2<…>` records,
`var` locals, `try/catch`, enhanced and counted `for`, `main(String[] args)`
entrypoint (`emit_java.ml`).

### Facility 2 — Java-only OO ML syntax → Java shell

The brief's `.mlj` idea is precisely the `DObject` machinery, and it works today:

- **Parsed.** `parse_decl` (`src/parser.ml:697-709`) → `DObject (name, tparams,
  ctor_params, members)`; `parse_object_member` (`parser.ml:659-683`) reads
  `[public|private] [static] member <self>.<name>(params) : ret = expr`.
- **Represented.** `object_member` carries `member_visibility`, `member_static`,
  a per-member `self_name` (`this`), `member_params`, `member_ret`
  (`ast.ml:87-97`).
- **Checked.** `check_program` builds per-member environments (ctor params +
  params + `self_name` bound to the object type), validates static-context
  (a static member may not reference instance fields), visibility, immutability,
  returns (`src/javaml/check.ml:1776-1850`). Supporting routines: member lookup
  `check.ml:157-194`, visibility `:205-213`, static/instance call checks
  `:909-968`, static-context check `:1680-1698`.
- **Lowered & emitted as a Java class.** Lowering: `JObject` IR node
  (`java_prep.ml:59-66`), `prepare_object_member` (`java_prep.ml:979-1017`),
  `DObject → JObject` dispatch (`java_prep.ml:1022-1034`). Emission:
  `emit_object` (`emit_java.ml:324-353`)
  → `public static final class X { private final …; ctor; public/private static/
  instance methods }`; `emit_object_member` (`emit_java.ml:300-322`).
- **Tested.** `t/javaml/objects.jml` → `t/javaml/objects.java`:

  ```
  type Greeter(prefix: String) =
    static member make(prefix: String) : Greeter = new Greeter(prefix)
    member this.greetTo(name: String) : String = prefix + " " + name
  ```
  → `public static final class Greeter { private final String prefix; public
  Greeter(String prefix) { this.prefix = prefix; } public String greetTo(String
  name) { return prefix + " " + name; } … }`

The surface spelling differs from the brief's `class user_service store = object
method … end` sketch (the parser uses `type Name (ctor_params) = member …`), but the
*concept* — "Java written in OCaml clothes", lowered to ordinary Java classes — is
implemented, checked, and regression-tested. It does **not** model OCaml structural
object typing, polymorphic methods, or open types, which matches the brief's
"do not attempt" list exactly.

The `.mlj` gating is the only missing piece: today the same file can mix portable
and Java-only constructs (the `objects.jml` fixture uses `member`, `new`,
`System.out.println`, `main`, and plain `let`), and only the *emitter* rejects
Java-only forms for the OCaml target. A per-file or per-extension profile
(`.ml` vs `.mlj`) is the natural structural addition. No filename or extension
check exists anywhere in the pipeline today — the CLI accepts any input path
(`frontends/fs2ml/bin/main.ml:38-42`).

---

## 9. Mirage / functor compatibility

**There is no module system in the language surface at all** — which is the
friendly answer for the Mirage story:

- `module` is only the file-level container: `parse_program` demands
  `module <name>` and then declarations; nothing else uses the word. The parser
  keyword table (`parser.ml:55-77`) has no `sig`/`struct`/`functor`/`include`/
  `open`; the lexer has no keyword table at all (`lexer.ml:1-110`, words are
  generic tokens); a grep for `functor`/`sig`/`module type`/`include` over both
  `src/javaml/` and `frontends/fs2ml/src` finds no language construct.
- The parent's `Module_context`/`resolve.ml`/`env.ml` are *multi-file* coordination
  (which files are compiled together, cross-file constructor lookup) — a Java
  "file" concept, not OCaml modules. Grounded: `module_context.ml:9-14` +
  `of_programs` `:70-118` (a compile-unit symbol table per file);
  `resolve.ml:13-110` (Java type-name and import resolution);
  `env.ml:5-58` (constructor/record tables); cross-file calls typed in
  `check.ml:373-377` and `check_module_function` `check.ml:882-903`.
- The reverse tool explicitly rejects functor application: `Longident.Lapply` →
  `"module application paths are unsupported"` (`bin/ocaml2ocamlsharp.ml:31-32`),
  catches all other structure items with a per-item rejection (`:333-339`),
  and `emit_module` handles only a single `Pstr_module` (structure), `Pstr_type`,
  `Pstr_value` (`bin/ocaml2ocamlsharp.ml:341-358`).

Consequence, all of which fit the handoff's "avoid portable abstractions at the
level of low-level device APIs" guidance:

- Portable product/domain code written in this frontend is **functor-free by
  construction** — there is no syntax to express a functor, so no accident.
- Mirage glue (real OCaml, functors, modules, PPX, attributes) stays **outside the
  tool**, as handwritten `.ml` — the tool is a text emitter, so the escape hatch is
  by construction. `ocamlc`/`dune` remain the semantic authority.
- A future "parameterized module → functor" feature is neither enabled nor
  precluded by the current code; the AST has no module node to extend, so adding
  one would be new surface, not a refactor of existing module logic.

---

## 10. Gap analysis

For each desired property: **desired / current / gap / evidence**.

### G1. Shared ML-shaped frontend across targets

- **desired:** one lexer/parser/AST that all targets consume.
- **current:** present in the monorepo — `src/javaml/` frontend is byte-identical
  to `frontends/fs2ml/src/` frontend; four emitters consume it.
- **gap:** `ocamlsharp` ships a *vendored copy* of the frontend, not the original.
  Divergence is possible. Also the AST mixes portable + Java-only surface nodes.
- **evidence:** `diff` shows `ast.ml/parser.ml/lexer.ml/token.ml/diagnostic.ml`
  identical; `src/javaml/` has `emit_java`/`emit_reason`/`emit_triplets` over the
  same AST.

### G2. Target subset checker (validate semantics, not only syntax)

| | |
|---|---|
| **desired** | per-target profile with target rules: integer overflow, equality, exceptions, mutation, ordering, tail calls, option/result, representation. |
| **current** | Java lane: `check.ml` (1885 lines) does deep checking (world/type walk, member sigs, visibility, mutability, returns, duplicates). OCaml lane: **none** — emitter raises `unsupported` mid-emit. |
| **gap** | OCaml (and any new target) needs its own subsetter/profile; JavaML's is Java-shaped. |
| **evidence** | `src/javaml/check.ml:1763` `check_program`; `frontends/fs2ml/src/pipeline.ml:1-3` "No checker". |

### G3. Target lowering + generator ("boring" readable output)

| | |
|---|---|
| **desired** | lower accepted source into target constructs; readable output. |
| **current** | Java: `java_prep.ml` (1097 lines) → Java IR → readable Java. OCaml: emits text directly from surface AST (`src/emit.ml`), readable and simple; no lowering IR. |
| **gap** | OCaml lane has no IR layer; the boundary between "portable surface" and "OCaml spelling" is not explicit. |
| **evidence** | `src/javaml/java_prep.ml:3-80` (`java_expr`/`java_stmt`); `src/emit.ml` (no IR). |

### G4. `.mlj` Java-only OO facility

| | |
|---|---|
| **desired** | Java-only OO syntax lowering to ordinary Java; never OCaml. |
| **current** | `DObject` + `emit_object` already do exactly this (see §8); OCaml emitter rejects `DObject`. |
| **gap** | no per-file/per-extension profile that *prevents* mixing Java-only surface into an OCaml-target file; surface spelling differs from the brief's sketch. |
| **evidence** | `t/javaml/objects.jml` → `objects.java`. |

### G5. Mirage escape hatch preserved

| | |
|---|---|
| **desired** | real OCaml stays the escape for Mirage glue; portable core functor-free. |
| **current** | no functor/module syntax in surface at all; ocamlc/dune are the authority; the OCaml lane emits text. |
| **gap** | none (by construction). |
| **evidence** | no `functor/sig/module type` anywhere; `ocaml2ocamlsharp.ml:31-32` rejects module application. |

### G6. Adding targets without a frontend rewrite

| | |
|---|---|
| **desired** | new target = new backend (+ its own profile). |
| **current** | proven by 4 backends over one AST; ocamlsharp exists. |
| **gap** | no TS backend; no per-target semantic contract so "new backend" is only valid for syntax-only emitters. |
| **evidence** | `pipeline.ml:20-37,68-73`. |

---

## 11. Minimal next steps (structural only — not to be implemented here)

If this repository is to become the basis of ML2X, the smallest structural moves
are:

1. **Make the shared frontend a real shared artifact.** In the monorepo, treat
   `src/javaml/{token,lexer,parser,ast,diagnostic}.ml` as the canonical ML2X frontend
   and have `frontends/fs2ml/` consume it (library dependency) instead of a copy.
   This converts "byte-identical today" into "guaranteed identical tomorrow."

2. **Introduce a per-target *profile* plus a shared *subset-checker* pass**, running
   after `parse` and before any backend. A profile = allowed node families + target
   semantic rules (equality, overflow, representation, …). The checker would be the
   single place that rejects `ECall/ENew/…` for the OCaml profile (replacing the
   per-expression `unsupported` raises in `emit.ml`), and would surface the *type
   subset* of the Java/TS profiles. The reusable base is the target-neutral parts of
   `check.ml` (duplicates, unknown names, mutability, return coverage) — its
   Java-specific rules (boxing, equality-to-`.equals`, sealed interfaces) move out
   of the base.

3. **Give the OCaml lane a lowering IR** (mirror of `java_prep.ml`'s `java_expr` /
   `java_stmt`), even a thin one, so OCaml emission stops being text-strings-from-
   surface-AST. This is where "readable OCaml" decisions (multi-line lets,
   `match` layout, tuple/record spelling, guard placement) become testable and
   where a semantic rule such as "currying is fully applied only" can be enforced
   once.

4. **Add the `.mlj`-style profile gate** to the existing object machinery: tag a
   source as `portable` (OCaml/TS) or `java-only` (`.mlj`), and have the subset
   checker refuse Java-only constructs (`DObject`, `ENew`, `ECall`, loops, `throws`,
   `package`, `import`) in a portable file. The object→Java lowering already works
   and is tested; this change only adds the *wall*.

5. **Add one new target backend (TypeScript) as a thin proof.** A TS profile over
   the shared AST + a TS lowering + a small emitter that keeps the Java/OCaml
   surface out and maps the portable subset (records, variants, match, tuples,
   option/result, modules-as-files) to readable TS. This validates the "new backend
   only" claim rather than the "rewrite" claim — or, if the profile demands more
   than the existing frontend can express (e.g. function types), it surfaces the
   exact IR gap.

---

## Bottom line

`fs2ml`/`ocamlsharp` is a **syntax-only slice** of a working, ML-shaped frontend that
already has multiple checked backends (Java, Reason) over one shared AST. It is
**already very close to the ML2X shape** — the hard parts the brief worries about
(frontend separation, per-target semantics, OO-to-Java lowering, readable boring
output, functor-free portable core) exist and are tested in the parent
`src/javaml/`. What the standalone product contributes is a clean, small OCaml
emitter. What ML2X would add on top is: a real *subset contract* (profiles +
semantic checker) instead of per-emitter rejection, an OCaml-side lowering IR,
the `.mlj` gate, and a TS backend as the generalization proof. It is closer to a
foundation than its own `open-problems-plan` suggests, provided the shared frontend
stops being a vendored copy and the semantic layer moves from "Java-only" to
"per-target".
