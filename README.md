# ML2X

ML2X is an early-stage exploration of compiling a deliberately restricted
ML/OCaml-shaped language into readable code for other platforms.

The central rule is simple: each target accepts only source constructs that
have a direct and predictable representation in that target language. ML2X is
not intended to compile every OCaml feature or reproduce the OCaml runtime on
other platforms.

## Proposed model

Each target backend would provide two parts:

1. A subset checker that validates syntax and target-specific semantics.
2. A lowering and code-generation pipeline that emits ordinary, readable
   target-language code.

Likely portable constructs include:

- `let` bindings and ordinary functions
- records and algebraic data types
- pattern matching
- tuples, options, and results
- parametric types
- immutable data
- simple modules or namespaces
- explicit mutation where its behavior is well defined

Features such as functors, first-class modules, GADTs, polymorphic variants,
advanced object typing, and pervasive partial application may be restricted or
rejected by individual targets.

## Possible targets

### `ml2java`

The proposed Java target has two possible source facilities:

- a portable functional subset for domain logic, records, variants, matching,
  validation, and workflows;
- an optional Java-only ML-shaped object syntax that maps directly to normal
  Java classes, fields, constructors, methods, interfaces, and annotations.

The intended output is ordinary Java that integrates with normal JVM tools and
libraries, rather than an emulated OCaml environment.

### `ml2ts`

The proposed TypeScript target follows the same subset-checking model and aims
to produce readable TypeScript. Browser, JavaScript, and TypeScript-specific
features would remain in a target-specific layer instead of entering the
portable core.

## OCaml and MirageOS

Portable product and domain code may remain mostly free of OCaml functors.
MirageOS composition, device injection, and other target-specific integration
can stay in handwritten OCaml around a higher-level capability boundary.

Real OCaml remains the escape hatch when a feature does not translate cleanly.

## Current status

This repository is at the assessment stage. It does not yet contain an ML2X
compiler implementation.

The immediate work is to examine the existing FS2ML compiler and determine:

- which parser, AST, semantic, transformation, and generator components exist;
- which parts are F#-specific, OCaml-specific, or target-independent;
- whether its internal representation can support multiple backends;
- whether its object-oriented syntax can support an idiomatic Java target;
- which pieces are reusable without redesigning the compiler prematurely.

The full assessment brief is in [`handoff.md`](handoff.md).

## Project principles

- Prefer small, explicit target subsets.
- Validate semantics, not syntax alone.
- Generate straightforward target-language code.
- Avoid substantial runtime emulation.
- Keep target-specific code outside the portable core.
- Preserve handwritten OCaml for MirageOS-specific integration.
