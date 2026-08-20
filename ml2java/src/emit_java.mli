(* Checked AST -> readable Java source text.
   Follows the "Java mapping" rules in SPEC.md. *)
val emit_program : Ast.program * Check.tables -> string
