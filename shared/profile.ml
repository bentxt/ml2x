(* Target profiles for the checker.  Check is target-neutral apart from
   these: every target-specific semantic decision (which names may be
   emitted verbatim, the `main` entry-point rule, class-type monomorphism,
   the case-insensitive class-name registry) is parameterized here. *)

type t = {
  pname : string;
  (* target keywords: names that reach the target output verbatim
     (declaration, member, and parameter names; local binders and pattern
     variables are renamed by the emitter, so they are exempt) must not be
     any of these *)
  reserved_names : string list;
  (* additional literal names owned by the emitter (helpers, temporaries,
     generated records) that source code may not reuse *)
  extra_banned_names : string list;
  (* the emitter owns `_`-prefixed helper and temporary names *)
  ban_underscore_prefix : bool;
  (* the emitter owns the TupleN record names (Java: Tuple2, Tuple3, ...) *)
  ban_tupleN_names : bool;
  (* a top-level `main` must have exactly one `()` parameter and return
     unit, or the emitter cannot produce the target's entry point *)
  enforce_main_rule : bool;
  (* class type method signatures must be monomorphic (no free type
     variables): the emitter has no generic target for them in v1 *)
  monomorphic_class_types : bool;
  (* class names sharing one on-disk namespace must not differ only in
     case: the Java target emits one .class per class and two such names
     overwrite each other on case-insensitive filesystems *)
  case_insensitive_type_namespace : bool;
  (* the file basename becomes the top-level class in Java, so it must be
     a legal class name; TS has no such constraint (the output is a module
     and `-o` may name any path) *)
  check_basename : bool;
  (* TS: a class's methods and its fields/ctor params share one member
     namespace (Java separates them); a class and a top-level
     function/value share one value namespace (Java separates types from
     methods) *)
  class_member_namespace : bool;
  value_class_namespace : bool;
}

let java =
  {
    pname = "Java";
    reserved_names =
      [ "abstract"; "boolean"; "break"; "byte"; "case"; "catch"; "char";
        "class"; "const"; "continue"; "default"; "do"; "double"; "enum";
        "extends"; "final"; "finally"; "float"; "for"; "goto"; "if";
        "implements"; "import"; "instanceof"; "int"; "interface"; "long";
        "native"; "new"; "package"; "private"; "protected"; "public";
        "return"; "short"; "static"; "strictfp"; "super"; "switch";
        "synchronized"; "this"; "throw"; "throws"; "transient"; "try";
        "void"; "volatile"; "while"; "null" ];
    extra_banned_names = [];
    ban_underscore_prefix = true;
    ban_tupleN_names = true;
    enforce_main_rule = true;
    monomorphic_class_types = true;
    case_insensitive_type_namespace = true;
    check_basename = true;
    class_member_namespace = false;
    value_class_namespace = false;
  }

(* Profile for the TS target.  Java's semantics minus the
   case-insensitive class-name registry (TS has no per-file class files),
   with the ECMAScript strict-mode reserved words plus the names that are
   illegal in at least one emitted position as the banned names.  The
   banned set is the union over every position the checker guards (class
   name, type name, function/value name, method name, field name,
   parameter name): the strict-mode words (illegal as class names at
   minimum), `constructor` (illegal as a method/field name), the TS
   primitive type names (illegal as class/interface/type-alias names),
   and the globals `undefined`/`NaN`/`Infinity` (conflict with the ES
   lib).  TS contextual keywords like `get`, `set`, `of`, `from`,
   `async`, `type`, `namespace` are legal in every emitted position and
   are NOT banned (a shared fixture uses `method get`).  The emitter
   owns `_`-prefixed helpers (`_eq`, `_SomeBox`, `_v` temps), so source
   names may not start with `_`. *)
let ts =
  {
    pname = "TypeScript";
    reserved_names =
      [ "break"; "case"; "catch"; "class"; "const"; "continue";
        "debugger"; "default"; "delete"; "do"; "else"; "enum"; "export";
        "extends"; "false"; "finally"; "for"; "function"; "if"; "import";
        "in"; "instanceof"; "new"; "null"; "return"; "super"; "switch";
        "this"; "throw"; "true"; "try"; "typeof"; "var"; "void"; "while";
        "with"; "implements"; "interface"; "let"; "package"; "private";
        "protected"; "public"; "static"; "yield"; "await";
        (* illegal as a method/field name *)
        "constructor";
        (* TS primitive type names: illegal as class/interface/type-alias
           names *)
        "any"; "boolean"; "number"; "string"; "symbol"; "object";
        "unknown"; "never"; "bigint";
        (* globals declared by the ES lib: redeclaration is an error *)
        "undefined"; "NaN"; "Infinity";
        (* strict-mode-restricted names *)
        "eval"; "arguments" ];
    extra_banned_names = [];
    ban_underscore_prefix = true;
    ban_tupleN_names = false;
    enforce_main_rule = true;
    monomorphic_class_types = true;
    case_insensitive_type_namespace = false;
    check_basename = false;
    class_member_namespace = true;
    value_class_namespace = true;
  }
