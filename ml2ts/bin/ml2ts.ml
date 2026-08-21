(* ml2ts <input.mlj> [-o output.ts]
   Default output: <basename>.ts next to the input.

   CLI contract (mirrors ml2java):
   - ml2ts file.mlj            -> writes file.ts next to it
   - ml2ts file.mlj -o out.ts  -> writes out.ts (any basename: the output
                                  is a TS module, not a class)
   - --help / -help            -> usage on stdout, exit 0
   - bad argument shapes       -> usage on stderr, exit 2
   - input missing/unreadable  -> one line "ml2ts: error: <path>: <reason>"
                                  on stderr, exit 1, no output written
   - unwritable output         -> same one-line shape, exit 1, no partial
                                  output (output is written via a temp file
                                  in the target directory + rename)
   - no OCaml exception text ever reaches the user: all I/O is wrapped in
     Sys_error handlers and front-end errors print their single line. *)

let usage = "usage: ml2ts <input.mlj> [-o output.ts]"

(* Print a one-line `ml2ts: error: ...` diagnostic and exit 1. *)
let die fmt =
  Printf.ksprintf
    (fun msg -> prerr_endline ("ml2ts: error: " ^ msg); exit 1)
    fmt

(* A Sys_error message sometimes already carries the offending path (e.g.
   open_in_bin gives "<path>: No such file or directory") and sometimes does
   not (e.g. "Is a directory"). Normalize so the path is printed exactly
   once, in the contract shape "ml2ts: error: <path>: <reason>". *)
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
  let tmp_prefix = Filename.concat dir ".ml2ts-" in
  let tmp =
    try Filename.temp_file ~temp_dir:dir ".ml2ts-" ".tmp"
    with Sys_error m ->
      let m =
        if String.starts_with ~prefix:(tmp_prefix ^ ":") m then
          String.sub m (String.length tmp_prefix + 2)
            (String.length m - String.length tmp_prefix - 2)
        else m
      in
      die "%s" (sys_error path m)
  in
  let oc =
    try
      (* plain open_out_bin creates with 0o666 under the umask *)
      open_out_gen [ Open_wronly; Open_creat; Open_trunc; Open_binary ] 0o666
        tmp
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
        (input, Filename.concat (Filename.dirname input) (base ^ ".ts"))
    | [ input; "-o"; output ] -> (input, output)
    | _ ->
        prerr_endline usage;
        exit 2
  in
  let src = read_input input in
  match
    Pipeline.compile ~profile:Profile.ts ~emit:Ml2ts_lib.Emit_ts.emit_program
      ~file:(Filename.basename input) src
  with
  | Ok ts -> write_output output ts
  | Error msg ->
      prerr_endline msg;
      exit 1
