(* ml2ts emitter interface: one .mlj file -> one .ts module. *)
val emit_program : Ast.program * Check.tables -> string
