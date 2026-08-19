# Handoff: FS2ML → ML2X Assessment

## Purpose

This repository contains an existing, somewhat working `fs2ml` compiler/transpiler.

Before changing the project, inspect what is already implemented and compare it with the direction described below.

The immediate goal is **not to redesign or rewrite the compiler**.

The immediate goal is:

> Understand what FS2ML already is, how it is structured, and how close it is to becoming the basis of a more general `ML2X` project.

Produce a source-grounded assessment.

---

## Background

The original motivation for FS2ML was roughly:

- OCaml is the preferred implementation language for efficient native software and MirageOS infrastructure.
- F# syntax is personally preferable to OCaml syntax.
- F# also has a pleasant object-oriented surface and is closer to JVM/enterprise languages.
- Small coding models tend to know TypeScript, Python, Java, and F#-like syntax much better than OCaml, and MirageOS knowledge is rarer still.
- A constrained familiar frontend could therefore make it easier for humans and smaller models to produce code that ultimately becomes OCaml.

The thinking has now evolved.

Rather than making "F# compiled to OCaml" the central idea, the possible generalization is:

# ML2X

`ML2X` means:

> Write target-language programs using an ML/OCaml-shaped source language, while restricting the source to constructs that have a direct, unsurprising representation on the selected target.

Possible target tools:

- `ml2java`
- `ml2ts`
- possibly more later

The project should **not** attempt to compile all of OCaml to every target.

Each target instead defines a supported subset/profile.

---

## Core ML2X Model

For each backend there are two main facilities:

### 1. Target subset checker

Given OCaml/ML-shaped source, verify that every construct can be translated cleanly to the target.

Examples of likely portable constructs:

- `let` bindings
- ordinary functions
- records
- algebraic data types / variants
- pattern matching
- tuples where appropriate
- option/result
- parametric types/generics
- immutable data
- simple modules/namespaces
- explicit mutation where semantics are well defined

Examples of constructs that may need restriction or rejection depending on target:

- pervasive currying / partial application
- functors
- first-class modules
- GADTs
- polymorphic variants
- advanced object typing
- target-specific runtime behavior
- constructs requiring substantial OCaml-runtime emulation

The governing rule is:

> If an allowed construct cannot be translated into straightforward target-language code with predictable semantics, it probably does not belong in that target profile.

The subsetter must validate semantics, not only syntax.

Examples that need explicit target rules include:

- integer representation and overflow
- equality
- exceptions
- mutation
- initialization order
- strings/Unicode
- recursion/tail calls
- generic representation
- option/result representation

### 2. Target lowering + generator

After validation, lower the accepted source into target-specific constructs and emit readable target code.

Desired property:

> Translation should be boring.

Avoid heroic runtime emulation.

---

# ml2java

`ml2java` would have two source facilities.

## A. Portable functional ML/OCaml subset

Normal functional OCaml-style code:

- records
- variants
- pattern matching
- functions
- modules
- option/result
- domain logic
- validation
- workflows
- sync logic
- etc.

This code should ideally remain useful as ordinary OCaml source where possible.

The same logical core could then participate in:

```text
OCaml source
    ├── ocamlopt → native binary
    ├── Mirage   → unikernel/provider infrastructure
    └── ml2java  → JVM/Java deployment
```

The goal is not perfect semantic coverage of OCaml.

It is a deliberately portable OCaml subset.

## B. Java-facing OO ML syntax

There is a separate Java-only source facility using OCaml-like OO syntax.

Important clarification:

> This OO syntax is NOT intended to preserve OCaml object semantics and is NOT intended to run as OCaml.

It is simply **Java written in OCaml clothes**.

For example, an ML-shaped class/method syntax may lower directly to ordinary Java classes, fields, constructors, methods, interfaces, annotations, imports, etc.

Conceptually:

```ocaml
class user_service store =
  object
    method get_user id = ...
    method save_user user = ...
  end
```

may simply mean:

```java
final class UserService {
    private final Store store;

    UserService(Store store) {
        this.store = store;
    }

    User getUser(Id id) { ... }

    void saveUser(User user) { ... }
}
```

Do NOT attempt to implement:

- OCaml structural object typing
- polymorphic methods
- open object types
- complex self types
- other OCaml OO semantics that do not map naturally to Java

This Java-facing syntax may deserve a separate extension such as `.mlj` so its semantics are unambiguous:

```text
.ml   = ordinary/portable OCaml-oriented source
.mlj  = ML-shaped Java DSL consumed by ml2java
```

This is only a possible design; inspect the existing project before recommending it.

---

# ml2ts

The same general model could apply to TypeScript.

```text
portable ML subset
    ↓
ml2ts
    ↓
TypeScript
```

Again:

- only accept constructs with direct TypeScript representations;
- define explicit target semantics;
- keep the generated TypeScript readable;
- target-specific JS/TS/browser constructs should live in a target layer rather than contaminating the portable core.

Historically there was also an idea of allowing small models to write TypeScript-like code that actually follows ML/OCaml semantics.

The broader insight is:

> Familiar syntax for humans/models can be useful, but the semantic core must remain small and controlled.

Do not create several full languages with different semantics.

---

# Relationship to F# / FS2ML

F# was originally attractive because:

- syntax is preferable to OCaml syntax;
- it is ML-family and maps reasonably to many OCaml constructs;
- its OO-facing side looks comfortable for JVM-style development;
- models may know F# better than OCaml.

However, there is a serious drawback:

- OCaml code is already less common than Java/TypeScript/Python;
- MirageOS code is much rarer;
- "F#-shaped Mirage" examples essentially do not exist;
- translating Mirage concepts into a private F# dialect makes AI assistance harder.

Therefore the current question is whether FS2ML should:

1. remain useful as a constrained F#-like frontend;
2. evolve into one optional frontend for a more general ML2X core;
3. or provide architectural pieces (parser/IR/backend separation) that are more valuable than the F# frontend itself.

Do not assume one answer.

Inspect the actual implementation.

---

# MirageOS Constraint

MirageOS makes heavy use of OCaml modules/functors for composition and device injection.

The portable product/domain code does **not** necessarily need to use functors.

A desired architectural split is roughly:

```text
portable product/domain code
    mostly functor-free
    ↓
high-level capability boundary
    ↓
Mirage-specific adapter/composition layer
    real OCaml
    functors allowed
```

Examples of portable/high-level capabilities:

- load/store document
- authenticate
- publish event
- enqueue job
- send notification

Avoid creating portable abstractions at the level of:

- TCP packets
- Ethernet frames
- block sectors
- low-level Mirage device APIs

It may be completely acceptable for Mirage glue to remain handwritten real OCaml rather than forcing Mirage functors through FS2ML/ML2X.

A possible future enhancement would be an F#-like/ML-shaped parameterized-module syntax that lowers to OCaml functors, but this should not be assumed necessary.

---

# Larger Product/Infrastructure Context

This compiler work sits inside a possible software-company architecture.

Two central infrastructure principles are:

## 1. "SaaS for me, monolith for thee"

The provider may decompose a backend aggressively into small elastic services/actors.

A self-hosting customer should get a simple consolidated backend.

Conceptually:

```text
provider:
    auth actor
    sync actor
    jobs actor
    workers
    etc.

self-hosted:
    one understandable backend deployment
    possibly plus PostgreSQL/storage
```

The same logical software should ideally support both forms.

## 2. SaaS actors compete for resources instead of reserving idle capacity

The provider infrastructure may eventually use tiny, mobile, isolated services — possibly Mirage unikernels — and allocate limited hardware dynamically.

High-value/latency-sensitive work should win resources over:

- indexing
- compression
- free-tier exports
- maintenance
- other delayable work

The goal is unusually high utilization of limited hardware and very low hosting cost.

MirageOS/unikernels are interesting only if they provide measurable economic advantages such as:

- cheap isolation
- tiny idle footprint
- fast startup/restart
- high density
- mobility/recreation
- low cost per isolated customer/service

They are not assumed superior to boring Linux/Go/process/container alternatives.

---

# Why Java Matters

Enterprise/government customers often value the JVM deployment story:

- familiar runtime
- mature operations
- standard monitoring
- known security tooling
- large supplier/developer ecosystem
- long support expectations
- organizational/procurement familiarity

The idea behind `ml2java` is therefore stronger than merely "run OCaml on the JVM".

The desired outcome is:

> Generate ordinary Java/JVM software that can integrate naturally with Java infrastructure.

A generated enterprise build could use normal Java facilities such as:

- JDBC
- OIDC/SAML integrations
- SLF4J/logging
- OpenTelemetry
- Java libraries
- Spring integration where useful
- standard JAR/container/systemd deployment

This may be more attractive than embedding an OCaml-generated Wasm island inside Java.

---

# Open Source Context

Possible product strategy:

Open source:

- customer-facing products
- self-hosted backend
- web/mobile clients
- protocols/formats
- import/export tooling
- reusable libraries

Private/internal:

- hosted control plane
- unikernel fleet orchestration
- resource allocator/market
- capacity optimization
- billing/operations machinery

Principle:

> Open-source the software the customer depends on; keep private the machinery that gives the hosted provider an operational/cost advantage.

---

# What To Inspect In This Repository

Perform a source-grounded archaeology pass.

Determine:

## 1. What FS2ML actually does today

Is it mainly:

```text
F# syntax → OCaml syntax
```

or is there already a pipeline more like:

```text
parser
  ↓
AST
  ↓
semantic/type representation
  ↓
transformations / IR
  ↓
OCaml backend
```

This distinction is critical.

## 2. Compiler structure

Identify:

- lexer/parser
- AST definitions
- type information / type checking
- semantic analysis
- normalization/transformation passes
- OCaml emitter/generator
- tests
- representative examples

For each important component, cite concrete files, types, and functions.

## 3. Supported language

Classify constructs as:

- supported
- partially supported
- unsupported
- custom/non-F#

Pay special attention to:

- let/functions
- currying
- records
- discriminated unions
- pattern matching
- generics
- modules
- interfaces
- OO syntax
- mutable state
- exceptions
- async/computation expressions
- target-specific features

## 4. OCaml coupling

Determine how much of the compiler is inherently tied to OCaml.

Classify important structures as:

- target-independent
- OCaml-specific
- F#-specific

Look especially for:

- OCaml AST types
- OCaml module assumptions
- direct construction of OCaml syntax
- OCaml type semantics embedded above the backend
- runtime/library assumptions

## 5. IR/backend separation

Does a target-neutral or mostly target-neutral IR already exist?

Could the current OCaml generator plausibly become one backend among several?

Would adding Java require:

- a new backend only;
- some IR cleanup;
- or a substantial compiler rewrite?

Do not guess. Ground the answer in source.

## 6. Existing OO handling

This is especially important for the Java DSL idea.

Determine:

- whether F# class/interface/object constructs are parsed;
- how they are represented internally;
- whether anything currently maps to OCaml objects/classes;
- whether this machinery could be repurposed into a Java-only `.mlj`-style frontend/backend path;
- how much of it assumes F#/.NET semantics.

## 7. Mirage/functor implications

Search for any existing support or assumptions concerning:

- modules
- module signatures
- parameterized modules
- functors
- first-class modules

Assess whether:

- the portable core can remain functor-free;
- Mirage glue could simply stay outside FS2ML;
- or the existing architecture naturally supports an optional functor-lowering feature.

Do not redesign around functors unless the existing code makes this compelling.

---

# Desired Assessment Output

Create `PROJECT_CAPTURE.md` or `ASSESSMENT.md`.

It should contain:

## Current project summary

A short factual description of what FS2ML currently is.

## Relevant source tree

Only relevant files/directories, with one-line purposes.

## Actual compiler pipeline

Show the real current flow with file/function references.

## Internal representations

Describe the important AST/IR/type structures.

## Supported language matrix

Supported / partial / unsupported / custom.

## OCaml coupling analysis

Where target assumptions enter the compiler.

## Multi-target readiness

Assess specifically:

```text
current FS2ML
      ↓
possible ML2X
      ├── ml2java
      └── ml2ts
```

## Java/OO feasibility

Assess the two-facility `ml2java` model:

1. portable functional subset → Java
2. Java-only OO ML syntax → idiomatic Java shell

## Mirage compatibility

Assess whether real Mirage OCaml can remain a target-specific shell while portable code remains simple.

## Gap analysis

For each desired property:

```text
desired:
current:
gap:
evidence:
```

## Minimal next steps

Give only the smallest 3–5 structural changes that would make sense **if** the repository is a viable basis for ML2X.

Do not start implementing them.

---

# Evidence Standard

Avoid vague statements such as:

> "The compiler has a modular architecture."

Prefer statements like:

> "`ModuleDecl` is defined in `src/...` and consumed by `translate_module` in `src/...`. `translate_module` directly constructs OCaml-specific nodes, so module handling is currently coupled to the OCaml backend."

Use file paths and symbols.

Include short source excerpts only where they materially clarify the architecture.

---

# Important Constraints

- Do not modify the repository in this first pass.
- Do not redesign the compiler before understanding the existing implementation.
- Do not assume FS2ML should be preserved unchanged.
- Do not assume F# must remain the canonical source language.
- Do not assume Java/Scala/Wasm is the correct enterprise solution.
- Do not attempt to support all OCaml features on all targets.
- Prefer small, explicit target subsets over runtime emulation.
- Preserve real OCaml as the escape hatch, especially for Mirage-specific code.
- Treat ML2X as a hypothesis to evaluate against the existing source.

The central question is:

> Is the existing FS2ML implementation already close to a useful foundation for ML2X, and if not, which parts of it are reusable?
::: ​​