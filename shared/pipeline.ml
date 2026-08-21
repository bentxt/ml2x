(* Shared front-end driver. Each backend passes its profile and emitter. *)
let compile ~profile ~emit ~file src =
  try
    let p = Parser.parse_program ~file src in
    let p, tables = Check.check_program ~profile p in
    Ok (emit (p, tables))
  with
  | Ast.Front_error msg -> Error msg
  | exn ->
    (* Defensive: no OCaml exception text/backtrace may reach the user.
       Unexpected internal failures become a single located error line. *)
    Error
      (Printf.sprintf "%s:0:0: error: internal compiler error (%s)" file
         (Printexc.to_string exn))
