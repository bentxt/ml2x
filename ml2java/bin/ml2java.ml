(* ml2java <input.mlj> [-o output.java]
   Default output: <basename>.java next to the input.

   CLI contract:
   - ml2java file.mlj            -> writes file.java next to it
   - ml2java file.mlj -o out.java-> writes out.java (basename must match)
   - --help / -help              -> usage on stdout, exit 0
   - bad argument shapes         -> usage on stderr, exit 2
   - input missing/unreadable    -> one line "ml2java: error: <path>: <reason>"
                                    on stderr, exit 1, no output written
   - unwritable output           -> same one-line shape, exit 1, no partial
                                    output (output is written via a temp file
                                    in the target directory + rename)
   - no OCaml exception text ever reaches the user: all I/O is wrapped in
     Sys_error handlers and front-end errors print their single line. *)

let usage = "usage: ml2java <input.mlj> [-o output.java]"

(* Print a one-line `ml2java: error: ...` diagnostic and exit 1. *)
let die fmt = Printf.ksprintf (fun msg -> prerr_endline ("ml2java: error: " ^ msg); exit 1) fmt

(* A Sys_error message sometimes already carries the offending path (e.g.
   open_in_bin gives "<path>: No such file or directory") and sometimes does
   not (e.g. "Is a directory"). Normalize so the path is printed exactly
   once, in the contract shape "ml2java: error: <path>: <reason>". *)
let sys_error path msg =
  if String.starts_with ~prefix:(path ^ ":") msg then msg
  else path ^ ": " ^ msg

(* Read a whole file. Any Sys_error (missing file, directory, permissions,
   ...) becomes a one-line error. *)
let read_input path =
  let ic =
    try open_in_bin path
    with Sys_error m -> die "%s" (sys_error path m)
  in
  let src =
    try
      let n = in_channel_length ic in
      really_input_string ic n
    with
    | Sys_error m ->
        close_in_noerr ic;
        die "%s" (sys_error path m)
    | End_of_file ->
        close_in_noerr ic;
        die "%s: unexpected end of file" path
  in
  close_in ic;
  src

(* Atomic write: stream to a unique temp file in the output directory, then
   rename it over the destination. On ANY failure the temp file is removed
   and the destination is left untouched (never partial/truncated). *)
let write_output path contents =
  let dir = Filename.dirname path in
  (* prefix of the temp names we create (before the random part) *)
  let tmp_prefix = Filename.concat dir ".ml2java-" in
  let tmp =
    try Filename.temp_file ~temp_dir:dir ".ml2java-" ".tmp"
    with Sys_error m ->
      (* the message names the temp path; report the user's output path *)
      let m = if String.starts_with ~prefix:(tmp_prefix ^ ":") m then
        String.sub m (String.length tmp_prefix + 2) (String.length m - String.length tmp_prefix - 2)
      else m in
      die "%s" (sys_error path m)
  in
  let oc =
    try
      (* plain open_out_bin creates with 0o666 under the umask *)
      open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o666 tmp
    with Sys_error m ->
      (try Sys.remove tmp with Sys_error _ -> ());
      die "%s" (sys_error path m)
  in
  (try
     output_string oc contents;
     flush oc;
     close_out oc
   with Sys_error m ->
      (try Sys.remove tmp with Sys_error _ -> ());
      die "%s" (sys_error path m));
  (try Sys.rename tmp path
   with Sys_error m ->
     (try Sys.remove tmp with Sys_error _ -> ());
     die "%s" (sys_error path m))

let () =
  let args = Array.to_list Sys.argv |> List.tl in
  (* --help / -help: usage on stdout, exit 0, no file work *)
  let input, output =
    match args with
    | [ ("--help" | "-help") ] ->
      print_endline usage;
      exit 0
    | [ input ] ->
      let base = Filename.(remove_extension (basename input)) in
      (input, Filename.concat (Filename.dirname input) (base ^ ".java"))
    | [ input; "-o"; output ] ->
      (* the top-level class is named after the input file, so the output
         basename must match it or javac rejects the generated file *)
      let ibase = Filename.(remove_extension (basename input)) in
      let obase = Filename.(remove_extension (basename output)) in
      if ibase <> obase then begin
        Printf.eprintf
          "%s:0:0: error: output basename `%s` differs from the input basename `%s`; the top-level Java class is `%s`\n"
          input obase ibase ibase;
        exit 1
      end;
      (input, output)
    | _ ->
      prerr_endline usage;
      exit 2
  in
  let src = read_input input in
  match Pipeline.compile ~profile:Profile.java
          ~emit:Ml2java_lib.Emit_java.emit_program
          ~file:(Filename.basename input) src
  with
  | Ok java -> write_output output java
  | Error msg ->
    prerr_endline msg;
    exit 1
