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

The assessment of the existing FS2ML/ocamlsharp compiler is complete; see
[`ASSESSMENT.md`](ASSESSMENT.md).

A first ML2X backend now exists: [`ml2java/`](ml2java/) is a working v1
compiler (parser, semantic checker, Java emitter) from OCaml-shaped `.mlj`
source to Java. [`ml2java/README.md`](ml2java/README.md) documents usage and
the generated Java; [`ml2java/SPEC.md`](ml2java/SPEC.md) is the language
contract. `sh ml2java/check.sh` builds it, compiles the fixtures, runs them
under `javac`/`java`, and checks expected stdout, stderr, exit status, and
rejection diagnostics. The dependability findings from the 2026-08-20
morning assessment were all reproduced and verified fixed the same day;
see [`assessment_20260820_175225.md`](assessment_20260820_175225.md). The
suite's deterministic fuzz lanes (`FUZZ_N`, default 60 in `check.sh`) gate
every generated program through `javac -Xlint:all -Werror`, execution with
clean exit and stderr, and a byte-identical recompile.

The full brief for the (completed) FS2ML review is in
[`handoff.md`](handoff.md).

## Project principles

- Prefer small, explicit target subsets.
- Validate semantics, not syntax alone.
- Generate straightforward target-language code.
- Avoid substantial runtime emulation.
- Keep target-specific code outside the portable core.
- Preserve handwritten OCaml for MirageOS-specific integration.
