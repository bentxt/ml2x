let compile ~profile ~file src =
  try
    let p = Parser.parse_program ~file src in
    let p, tables = Check.check_program ~profile p in
    Ok (Emit_java.emit_program (p, tables))
  with
  | Ast.Front_error msg -> Error msg
  | exn ->
    (* Defensive: no OCaml exception text/backtrace may reach the user.
       Unexpected internal failures become a single located error line. *)
    Error
      (Printf.sprintf "%s:0:0: error: internal compiler error (%s)" file
         (Printexc.to_string exn))
