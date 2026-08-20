(* Semantic checker for the v1 profile. Runs after parse, before emission.
   Validates: unknown names/types/ctors, arity (no partial application),
   operand types for operators incl. primitive-vs-object equality, mutability
   errors, assignment targets, private/static member access, match
   exhaustiveness for variants (or a wildcard), declared-vs-inferred return
   types where inferable, interface completeness for `inherit`, and rewrites
   bare field/ctor-param EVar references inside methods to ESelfField.
   Raises Ast.Front_error with one formatted line per error found first. *)

type tables = {
  types : (int, Ast.typ) Hashtbl.t;        (* expr id -> its type *)
  tdecls : (string, Ast.type_decl) Hashtbl.t;
  ctors : (string, string * Ast.typ list) Hashtbl.t;  (* ctor -> (parent, payload) *)
  classes : (string, Ast.class_decl) Hashtbl.t;
  funcs : (string, Ast.fun_decl) Hashtbl.t;
  class_types : (string, Ast.class_type_decl) Hashtbl.t;
}

val check_program : profile:Profile.t -> Ast.program -> Ast.program * tables
