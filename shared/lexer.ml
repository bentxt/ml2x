(* ml2java lexer: hand-written scanner for the v1 subset (SPEC.md).
   Produces a token list with 1-based line/column positions, ending TEOF.
   Comments are OCaml-style and nest: (* ... (* ... *) ... *).
   Positions: line 1-based, col 1-based (ambiguity note: col base = 1).

   Float operators +. -. *. /. deliberately lex to the same tokens as
   + - * / (the AST has one binop set; the checker decides int vs float
   from operand types). `mod` and `downto` are NOT keywords per SPEC:
   `%` is Mod, and `downto` surfaces as a plain identifier (the parser
   recognizes it in for-ranges after `=`).
*)

type t =
  | TInt of int
  | TFloat of float
  | TStr of string
  | TChar of char
  | TBool of bool
  | TIdent of string               (* lowercase / _ identifiers *)
  | TUctor of string                (* Uppercase identifiers (constructors) *)
  | TTypeVar of string              (* 'a *)
  | TKey of string                  (* keywords incl. out-of-v1 markers *)
  | TPlus | TMinus | TStar | TSlash | TPercent
  | TConcat                         (* ^ *)
  | TEq | TNe | TLt | TLe | TGt | TGe
  | TAnd | TOr
  | TCons                           (* :: *)
  | TArrow                          (* -> *)
  | TAssign                         (* <- *)
  | TLParen | TRParen
  | TLBracket | TRBracket
  | TLBrace | TRBrace
  | TSemi | TColon | TComma | TDot | THash
  | TUnderscore
  | TEOF

type token = { t : t; line : int; col : int }

(* Keywords. `true`/`false` become TBool literals, not TKey.
   Out-of-v1 markers are recognized so the parser can emit a clean
   diagnostic instead of a generic "expected X" error. *)
let keywords =
  [ "let"; "mutable"; "rec"; "in"; "type"; "of"; "fun"; "match"; "with";
    "when"; "if"; "then"; "else"; "while"; "do"; "done"; "for"; "to";
    "begin"; "end"; "class"; "object"; "val"; "method"; "private"; "static";
    "inherit"; "new"; "not";
    (* Not v1 but recognized so the parser can emit a clean diagnostic. *)
    "and"; "raise"; "try"; "ref"; "open"; "module"; "exception"; "struct";
    "sig"; "include"; "external"; "assert"; "lazy"; "functor"; "mutable" ]

let lex ~file src =
  let n = String.length src in
  let i = ref 0 in
  let line = ref 1 in
  let col = ref 1 in
  let at_end () = !i >= n in
  let cur () = if at_end () then '\000' else src.[!i] in
  let cur2 () = if !i + 1 >= n then '\000' else src.[!i + 1] in
  let advance () =
    if not (at_end ()) then begin
      if src.[!i] = '\n' then begin incr line; col := 1 end
      else incr col;
      incr i
    end
  in
  let error l c msg = Ast.raise_at ~file { line = l; col = c } msg in
  let toks = ref [] in
  let tok t l c = toks := { t; line = l; col = c } :: !toks in
  let is_ident_char c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
    || (c >= '0' && c <= '9') || c = '_'
  in
  let is_digit c = c >= '0' && c <= '9' in
  let lex_ident l c =
    let b = Buffer.create 16 in
    while not (at_end ()) && is_ident_char (cur ()) do
      Buffer.add_char b (cur ()); advance ()
    done;
    let s = Buffer.contents b in
    if s = "true" then tok (TBool true) l c
    else if s = "false" then tok (TBool false) l c
    else if s = "_" then tok TUnderscore l c
    else if List.mem s keywords then tok (TKey s) l c
    else if s.[0] >= 'A' && s.[0] <= 'Z' then tok (TUctor s) l c
    else tok (TIdent s) l c
  in
  let lex_number l c =
    let b = Buffer.create 8 in
    while not (at_end ()) && is_digit (cur ()) do
      Buffer.add_char b (cur ()); advance ()
    done;
    if not (at_end ()) && cur () = '.' && is_digit (cur2 ()) then begin
      Buffer.add_char b (cur ()); advance ();
      while not (at_end ()) && is_digit (cur ()) do
        Buffer.add_char b (cur ()); advance ()
      done;
      tok (TFloat (float_of_string (Buffer.contents b))) l c
    end
    else
      try tok (TInt (int_of_string (Buffer.contents b))) l c
      with Failure _ -> error l c "integer literal out of range"
  in
  let lex_string l c =
    advance ();                     (* opening quote *)
    let b = Buffer.create 16 in
    let rec go () =
      if at_end () then error l c "unterminated string literal";
      match cur () with
      | '"' -> advance (); tok (TStr (Buffer.contents b)) l c
      | '\n' -> error l c "newline in string literal"
      | '\\' ->
          advance ();
          (match cur () with
           | 'n' -> Buffer.add_char b '\n'; advance (); go ()
           | 't' -> Buffer.add_char b '\t'; advance (); go ()
           | 'r' -> Buffer.add_char b '\r'; advance (); go ()
           | '\\' -> Buffer.add_char b '\\'; advance (); go ()
           | '"' -> Buffer.add_char b '"'; advance (); go ()
           | '\'' -> Buffer.add_char b '\''; advance (); go ()
           | ch -> error l c (Printf.sprintf "unknown escape \\%c" ch))
      | ch ->
          Buffer.add_char b ch; advance (); go ()
    in
    go ()
  in
  let lex_char_lit l c =
    (* current char is the opening quote *)
    advance ();
    if at_end () then error l c "unterminated character literal";
    let ch =
      match cur () with
      | '\\' ->
          advance ();
          let e = cur () in
          let v =
            match e with
            | 'n' -> '\n' | 't' -> '\t' | 'r' -> '\r'
            | '\\' -> '\\' | '\'' -> '\'' | '"' -> '"'
            | _ -> error l c (Printf.sprintf "unknown escape \\%c" e)
          in
          advance (); v
      | c -> advance (); c
    in
    if at_end () || cur () <> '\'' then
      error l c "unterminated character literal";
    advance ();
    tok (TChar ch) l c
  in
  let lex_typevar l c =
    (* current char is the apostrophe; not a char literal *)
    advance ();
    let b = Buffer.create 4 in
    while not (at_end ()) && is_ident_char (cur ()) do
      Buffer.add_char b (cur ()); advance ()
    done;
    let v = Buffer.contents b in
    if v = "" then error l c "expected a type variable name after '";
    tok (TTypeVar v) l c
  in
  let skip_comment l c =
    (* current chars are the comment opener; l,c is their position *)
    advance (); advance ();
    let rec go d =
      if at_end () then error l c "unterminated comment";
      match cur () with
      | '(' when cur2 () = '*' ->
          advance (); advance ();
          if d + 1 > 1000 then
            error l c "comment nested too deeply (limit 1000)";
          go (d + 1)
      | '*' when cur2 () = ')' ->
          advance (); advance ();
          if d > 1 then go (d - 1)
      | _ -> advance (); go d
    in
    go 1
  in
  while not (at_end ()) do
    let l = !line and c = !col in
    let ch = cur () in
    if ch = ' ' || ch = '\t' || ch = '\r' || ch = '\n' then advance ()
    else if ch = '(' && cur2 () = '*' then skip_comment l c
    else if ch = '*' && cur2 () = ')' then
      error l c "unmatched comment close *)"
    else
      match ch with
      | 'a' .. 'z' | 'A' .. 'Z' | '_' -> lex_ident l c
      | '0' .. '9' -> lex_number l c
      | '"' -> lex_string l c
      | '\'' ->
          (* char literal (`'a'`, `'\n'`, `'\\'`) or type variable (`'a`) *)
          if cur2 () = '\\' || (!i + 2 < n && src.[!i + 2] = '\'') then
            lex_char_lit l c
          else if !i + 1 < n && is_ident_char src.[!i + 1] then
            lex_typevar l c
          else error l c "unexpected '"
      | '(' -> advance (); tok TLParen l c
      | ')' -> advance (); tok TRParen l c
      | '[' -> advance (); tok TLBracket l c
      | ']' -> advance (); tok TRBracket l c
      | '{' -> advance (); tok TLBrace l c
      | '}' -> advance (); tok TRBrace l c
      | ';' -> advance (); tok TSemi l c
      | ',' -> advance (); tok TComma l c
      | ':' ->
          advance ();
          if not (at_end ()) && cur () = ':' then (advance (); tok TCons l c)
          else if not (at_end ()) && cur () = '=' then
            error l c "`:=` (references) is not supported in v1 (SPEC)"
          else tok TColon l c
      | '.' -> advance (); tok TDot l c
      | '#' -> advance (); tok THash l c
      | '=' -> advance (); tok TEq l c
      | '<' ->
          advance ();
          if not (at_end ()) && cur () = '-' then (advance (); tok TAssign l c)
          else if not (at_end ()) && cur () = '>' then (advance (); tok TNe l c)
          else if not (at_end ()) && cur () = '=' then (advance (); tok TLe l c)
          else tok TLt l c
      | '>' ->
          advance ();
          if not (at_end ()) && cur () = '=' then (advance (); tok TGe l c)
          else tok TGt l c
      | '|' ->
          advance ();
          if not (at_end ()) && cur () = '|' then (advance (); tok TOr l c)
          else tok (TKey "|") l c
      | '&' ->
          advance ();
          if not (at_end ()) && cur () = '&' then (advance (); tok TAnd l c)
          else error l c "unexpected `&` (v1 has no bitwise operators)"
      | '+' ->
          advance ();
          if not (at_end ()) && cur () = '.' then advance ();
          tok TPlus l c
      | '-' ->
          advance ();
          if not (at_end ()) && cur () = '>' then (advance (); tok TArrow l c)
          else begin
            if not (at_end ()) && cur () = '.' then advance ();
            tok TMinus l c
          end
      | '*' ->
          advance ();
          if not (at_end ()) && cur () = '.' then advance ();
          tok TStar l c
      | '/' ->
          advance ();
          if not (at_end ()) && cur () = '.' then advance ();
          tok TSlash l c
      | '%' -> advance (); tok TPercent l c
      | '^' -> advance (); tok TConcat l c
      | ch -> error l c (Printf.sprintf "unexpected character `%c`" ch)
  done;
  (* TEOF sits just past the last character, so errors at end of input
     report the position right after the final token. *)
  tok TEOF !line !col;
  List.rev !toks
