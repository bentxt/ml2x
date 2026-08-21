(* Source text -> AST. See SPEC.md and ast.ml.
   Raises Ast.Front_error with a formatted "file:line:col: error: msg" line
   for any syntax error or anything out of the v1 surface. *)
val parse_program : file:string -> string -> Ast.program
