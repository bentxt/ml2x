(* tools/gen_fuzz.ml — deterministic .mlj generator for fuzz.sh.

   Modes:
     gen_fuzz.exe <seed>       print a type-correct .mlj program to stdout
     gen_fuzz.exe bytes <seed> print garbage bytes to stdout

   Lane A programs are one fixed skeleton (helper functions, a record with
   a mutable field, a variant, a class type, two classes, top-level
   values, main) whose literals and record-field order are drawn from a
   seed-local Random.State.  The skeleton exercises the whole v1 surface:

     - typed expressions       `(5 : int)`, `(None : int option)`,
                                `([] : int list)`, `let c1 : itf = ...`
     - records                 literal, shuffled field order, mutable
                                field assignment, record equality
     - variants                `type shape = ...`, all-constructor matches
     - records                 literals (shuffled field order), field
                                access, mutation, record patterns in match
     - options incl. nested    `Some (Some n)` / `Some None` / `None`
     - lists                   literals, `[]`, cons recursion, for-in
     - tuples                  literals, let-tuple, tuple equality
     - classes                 ctor params, a `()` ctor param, mutable
                                val, self calls, static factory, inherit
                                of a class type, interface-typed values
     - generic functions       `'a` / `'b` signatures, concrete calls
     - statement-bearing operands in `&&`, `^`, call args, list elements,
                                record fields, tuple components, for-range
                                bounds, while conditions, match scrutinee
     - bounded loops            for-range (to and downto) / for-in / while
     - builtins                 print_int/print_float/print_endline,
                                string_of_*, List.length

   Everything stays inside the v1 subset and is bounded: no failwith, no
   division/modulo by zero (divisors are `((e % 7) + 9)` which is always
   >= 2), loops and recursion always terminate, `main` is exactly
   `let main () : unit`, and the whole program is under 120 lines.
   The output for a given seed is byte-identical on every run, so a
   counterexample is reproducible from its seed alone. *)

let lit_ints = [| 0; 1; 2; 3; 4; 5; 7; 9; 10; 13 |]
let lit_strs = [| "a"; "b"; "hi"; "x"; "y" |]

let gen_program seed =
  let st = Random.State.make [| seed land 0x7fffffff |] in
  let ri () =
    string_of_int (lit_ints.(Random.State.int st (Array.length lit_ints)))
  in
  let rs () =
    "\"" ^ lit_strs.(Random.State.int st (Array.length lit_strs)) ^ "\""
  in
  let a = ri () and c = ri () in
  let b = rs () in
  let orders =
    [| [ "fld_a = " ^ a; "fld_b = " ^ b; "fld_c = " ^ c ];
       [ "fld_a = " ^ a; "fld_c = " ^ c; "fld_b = " ^ b ];
       [ "fld_b = " ^ b; "fld_a = " ^ a; "fld_c = " ^ c ];
       [ "fld_b = " ^ b; "fld_c = " ^ c; "fld_a = " ^ a ];
       [ "fld_c = " ^ c; "fld_a = " ^ a; "fld_b = " ^ b ];
       [ "fld_c = " ^ c; "fld_b = " ^ b; "fld_a = " ^ a ] |]
  in
  let fields = orders.(Random.State.int st (Array.length orders)) in
  let main =
    String.concat "\n"
      [
        "let main () : unit =";
        "  let r0 = { " ^ String.concat "; " fields ^ " } in";
        "  let c0 = new cell " ^ ri () ^ " in";
        "  r0.fld_c <- (r0.fld_c + 1);";
        "  let u0 = [ (c0 # bump 1; " ^ ri () ^ "); " ^ ri () ^ "; " ^ ri ()
        ^ " ] in";
        "  let r1 = { fld_a = (c0 # bump 1; " ^ ri () ^ "); fld_b = r0.fld_b; \
         fld_c = " ^ ri () ^ " } in";
        "  let sc = ((c0 # bump 1; r0.fld_a > 0) && (c0 # bump 1; \
         r0.fld_a < 100)) in";
        "  print_endline (string_of_int (sum u0));";
        "  print_endline (string_of_int (List.length u0));";
        "  print_endline (string_of_int (rec_pat r0));";
        "  print_endline (string_of_bool sc);";
        "  print_endline (recolor (Some " ^ ri () ^ "));";
        "  print_endline (recolor None);";
        "  print_endline (opt3 (Some (Some " ^ ri () ^ ")));";
        "  print_endline (opt3 (Some None));";
        "  print_endline (classify " ^ ri () ^ ");";
        "  print_endline (string_of_int (char_rank 'b'));";
        "  print_endline (string_of_bool ('a' < 'b'));";
        "  print_endline (string_of_int (pair_sum (" ^ ri () ^ ", " ^ ri ()
        ^ ")));";
        "  print_endline (string_of_int (first " ^ ri () ^ " \"a\"));";
        "  print_endline (string_of_int (List.length (wrap 2)));";
        "  let (swa, swb) = swap \"x\" " ^ ri () ^ " in";
        "  print_endline (string_of_int swa);";
        "  print_endline swb;";
        "  print_float (area (Circle 1.5));";
        "  print_float (area (Rect (2.0, 3.0)));";
        "  print_float (area Dot);";
        "  print_endline \"\";";
        "  print_float (3.0 / 2.0);";
        "  print_endline \"\";";
        "  print_endline (c0 # label ());";
        "  print_endline (string_of_int (c0 # next ()));";
        "  print_endline (string_of_int ((cell.make 5) # value ()));";
        "  let c1 : itf = c0 in";
        "  print_endline (c1 # label ());";
        "  let b1 = new boxed " ^ ri () ^ " () \"hey\" in";
        "  print_endline (b1 # label ());";
        "  print_endline (string_of_int (g0 + g1));";
        "  print_endline (string_of_bool (r0 = r1));";
        "  print_endline (string_of_bool ([1; 2] = [1; 2]));";
        "  print_endline (string_of_bool (Some 1 = Some 1));";
        "  print_endline (string_of_int ((5 : int) + (3 : int)));";
        "  print_endline (string_of_int (sum ([] : int list)));";
        "  print_endline (recolor (None : int option));";
        "  print_endline (\"x\" ^ (c0 # bump 1; r0.fld_b));";
        "  for i = (c0 # bump 1; 0) to (c0 # bump 1; 2) do print_int (i + \
         r0.fld_a) done;";
        "  for i = (c0 # bump 1; 3) downto (c0 # bump 1; 1) do print_int (i \
         + r0.fld_a) done;";
        "  for x in (c0 # bump 1; [1; 2]) do print_int x done;";
        "  let mutable w = 0 in";
        "  while (c0 # bump 1; w < 2) do w <- w + 1 done;";
        "  if (c0 # bump 1; r0.fld_a > 5) then print_endline \"hi\" else \
         print_endline \"lo\";";
        "  (match (c0 # bump 1; r0.fld_a) with";
        "   | 0 -> print_endline \"z\"";
        "   | n when n > 0 -> print_endline (string_of_int n)";
        "   | _ -> print_endline \"q\");";
        "  let (p0, p1, p2) = ((c0 # bump 1; 1), \"a\", true) in (print_endline \
         (string_of_int p0); print_endline (string_of_bool p2))";
      ]
  in
  let head =
    String.concat "\n"
      [
        "let g0 = if true then " ^ ri () ^ " else 0";
        "let g1 = if g0 = 5 then 1 else 0";
        "";
        "type shape = Circle of float | Rect of float * float | Dot";
        "type box = { fld_a : int; fld_b : string; mutable fld_c : int }";
        "class type itf = object";
        "  method label () : string";
        "end";
        "";
        "class cell (start : int) =";
        "  object (self)";
        "    inherit itf";
        "    val mutable count = start";
        "    method label () : string = \"cell\" ^ string_of_int count";
        "    method bump (k : int) : unit = count <- count + k";
        "    method value () : int = count";
        "    method next () : int = self # value () + 1";
        "    method static make (s : int) : cell = new cell s";
        "  end";
        "";
        "class boxed (a : int) () (b : string) =";
        "  object (self)";
        "    method label () : string = string_of_int a ^ b";
        "  end";
      ]
  in
  let helpers =
    String.concat "\n"
      [
        "let rec sum (xs : int list) : int =";
        "  match xs with";
        "  | [] -> 0";
        "  | x :: rest -> x + sum rest";
        "let classify (n : int) : string =";
        "  match n with";
        "  | k when k < 0 -> \"neg\"";
        "  | k when k = 0 -> \"zero\"";
        "  | k when k > 10 -> \"big\"";
        "  | _ -> \"small\"";
        "let recolor (x : int option) : string =";
        "  match x with";
        "  | Some n -> \"s\" ^ string_of_int n";
        "  | None -> \"n\"";
        "let opt3 (x : int option option) : string =";
        "  match x with";
        "  | Some (Some n) -> \"ss\" ^ string_of_int n";
        "  | Some None -> \"sn\"";
        "  | None -> \"n\"";
        "let first (x : 'a) (y : 'b) : 'a = x";
        "let swap (x : 'a) (y : 'b) : 'b * 'a = (y, x)";
        "let wrap (x : 'a) : 'a list = [x]";
        "let char_rank (c : char) : int =";
        "  match c with";
        "  | 'a' -> 1";
        "  | 'b' -> 2";
        "  | _ -> 0";
        "let pair_sum (t : int * int) : int =";
        "  let (a, b) = t in";
        "  a + b";
        "let area (f : shape) : float =";
        "  match f with";
        "  | Circle r -> r * r * 3.0";
        "  | Rect (w, h) -> w * h";
        "  | Dot -> 0.0";
        "let rec_pat (b : box) : int =";
        "  match b with";
        "  | { fld_a = a; fld_b = _; fld_c = c } -> a + c";
      ]
  in
  String.concat "\n\n" [ head; helpers; main ]

let gen_bytes seed =
  let st = Random.State.make [| seed land 0x7fffffff |] in
  let n = 1 + Random.State.int st 1000 in
  let b = Buffer.create n in
  for _ = 1 to n do
    Buffer.add_char b (Char.chr (Random.State.int st 256))
  done;
  output_string stdout (Buffer.contents b)

let () =
  match Array.to_list Sys.argv with
  | [ _; "bytes"; s ] -> gen_bytes (int_of_string s)
  | [ _; s ] -> print_string (gen_program (int_of_string s))
  | _ ->
      Printf.eprintf "usage: gen_fuzz.exe <seed> | gen_fuzz.exe bytes <seed>\n";
      exit 2
