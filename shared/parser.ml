(* ml2java recursive-descent parser for the v1 subset (SPEC.md).
   Produces the Ast.program tree; every expression gets a fresh unique id
   and a 1-based (line, col) position (the first token of the expression).

   Operator precedence (loose -> tight):
     ;  <-  ||  &&  = <> < <= > >=  :: (right)  ^ (right)
     + -  * / %  unary - not  application  postfix . #

   Grammar decisions (all verified against the OCaml parser):
     - `begin e end` is a parenthesizing expression (no AST node).
     - if-condition, while-condition, match guard, for-range bounds and
       the match scrutinee are full expressions (they absorb `;`).
     - if then/else branches, record field RHS, list elements and tuple
       components are no-`;` expressions (`;` inside needs parens).
     - the `in`-body of a let absorbs a following `;` (sequence), and a
       `let` after `;` inside a sequence is a `let ... in` expression.
     - application operands are atoms followed by postfix `.` / `#` chains;
       `f a b` is a single flat call. A bare constructor in argument
       position stays bare (`f Circle 3` is two arguments); when a
       constructor is the application head, its parenthesized tuple
       argument flattens (`Node (l, v, r)` -> three arguments).
     - `f -x` is subtraction; use `f (-x)` (OCaml rule).
     - `not` in argument position is a plain identifier (OCaml rule).
     - match arms allow an optional leading `|`; an arm RHS is a full
       expression, so a nested `match` in an arm absorbs later `|` arms.
   *)

(* Nesting-depth guard shared by parse_type / parse_assign / parse_pattern.
   Reset at the start of every parse_program call; exceeding 1000 raises a
   located error instead of overflowing the OCaml stack. *)
let depth = ref 0

let parse_program ~file src =
  let toks = Lexer.lex ~file src in
  let arr = Array.of_list toks in
  let pos = ref 0 in
  let uid = ref 0 in
  let in_for_low = ref false in
  depth := 0;
  let peek () = (arr.(!pos)).t in
  let peek_pos () = { Ast.line = (arr.(!pos)).line; col = (arr.(!pos)).col } in
  let is_downto () =
    match peek () with Lexer.TIdent "downto" -> true | _ -> false
  in
  let advance () = incr pos in
  let error msg = Ast.raise_at ~file (peek_pos ()) msg in
  let mk p desc = incr uid; { Ast.id = !uid; desc; pos = p } in
  let expect_tok tok msg =
    if peek () = tok then advance () else error msg
  in
  let expect_ident msg =
    match peek () with
    | Lexer.TIdent s -> advance (); s
    | _ -> error msg
  in
  let is_keyword s = match peek () with Lexer.TKey k -> k = s | _ -> false in

  (* ---------------- types ---------------- *)

  let rec parse_type () =
    if !depth >= 1000 then error "type nested too deeply (limit 1000)";
    incr depth;
    let t =
      let t = parse_type_component () in
      if peek () = Lexer.TStar then begin
        let ts = ref [ t ] in
        while peek () = Lexer.TStar do
          advance ();
          ts := parse_type_component () :: !ts
        done;
        Ast.TTuple (List.rev !ts)
      end
      else t
    in
    decr depth;
    t

  and parse_type_component () =
    (* returns (multi-arg group, single starting type); exactly one is set *)
    let group, t0 =
      match peek () with
      | Lexer.TLParen ->
          (* `(t1, t2, ...) name` is a multi-argument type application
             (OCaml's parenthesized form for arity >= 2); a parenthesized
             `*` tuple is a single argument *)
          advance ();
          let t1 = parse_type () in
          if peek () = Lexer.TComma then begin
            let ts = ref [ t1 ] in
            while peek () = Lexer.TComma do
              advance ();
              ts := parse_type () :: !ts
            done;
            expect_tok Lexer.TRParen
              "expected `)` after the type argument list";
            (List.rev !ts, None)
          end
          else begin
            expect_tok Lexer.TRParen
              "expected `)` after the parenthesized type";
            ([], Some t1)
          end
      | _ -> ([], Some (parse_type_atom ()))
    in
    let rec post t =
      match peek () with
      | Lexer.TIdent "list" ->
          if group <> [] then
            error "expected a type constructor name after `(...)`";
          advance ();
          post (Ast.TList t)
      | Lexer.TIdent "option" ->
          if group <> [] then
            error "expected a type constructor name after `(...)`";
          advance ();
          post (Ast.TOption t)
      | Lexer.TIdent s ->
          advance ();
          let args = if group <> [] then group else [ t ] in
          post (Ast.TCon (s, args))
      | _ -> t
    in
    match t0 with
    | Some t -> post t
    | None -> (
        (* a multi-argument group must be followed by a constructor name *)
        match peek () with
        | Lexer.TIdent s ->
            advance ();
            post (Ast.TCon (s, group))
        | _ -> error "expected a type constructor name after `(...)`")

  and parse_type_atom () =
    match peek () with
    | Lexer.TIdent "int" -> advance (); Ast.TInt
    | Lexer.TIdent "float" -> advance (); Ast.TFloat
    | Lexer.TIdent "bool" -> advance (); Ast.TBool
    | Lexer.TIdent "char" -> advance (); Ast.TChar
    | Lexer.TIdent "string" -> advance (); Ast.TStr
    | Lexer.TIdent "unit" -> advance (); Ast.TUnit
    | Lexer.TTypeVar v -> advance (); Ast.TParam v
    | Lexer.TIdent s -> advance (); Ast.TCon (s, [])
    | Lexer.TLParen ->
        advance ();
        let t = parse_type () in
        expect_tok Lexer.TRParen "expected `)` after the parenthesized type";
        t
    | _ -> error "expected a type"

  (* ---------------- patterns ---------------- *)

  and parse_pattern () =
    if !depth >= 1000 then error "pattern nested too deeply (limit 1000)";
    incr depth;
    let p =
      let p = parse_pattern_atom () in
      if peek () = Lexer.TCons then begin
        advance ();
        Ast.PCons (p, parse_pattern ())
      end
      else p
    in
    decr depth;
    p

  and pattern_arg_start () =
    match peek () with
    | Lexer.TIdent _ | Lexer.TUnderscore | Lexer.TInt _ | Lexer.TStr _
    | Lexer.TBool _ | Lexer.TChar _ | Lexer.TUctor _ | Lexer.TLParen
    | Lexer.TLBracket ->
        true
    | _ -> false

  and parse_pattern_atom () =
    match peek () with
    | Lexer.TUnderscore -> advance (); Ast.PWild
    | Lexer.TIdent s -> advance (); Ast.PVar s
    | Lexer.TInt i -> advance (); Ast.PInt i
    | Lexer.TStr s -> advance (); Ast.PStr s
    | Lexer.TBool b -> advance (); Ast.PBool b
    | Lexer.TChar c -> advance (); Ast.PChar c
    | Lexer.TUctor c ->
        advance ();
        let args =
          if peek () = Lexer.TLParen then begin
            advance ();
            if peek () = Lexer.TRParen then (advance (); [])
            else begin
              let ps = ref [ parse_pattern () ] in
              while peek () = Lexer.TComma do
                advance ();
                ps := parse_pattern () :: !ps
              done;
              expect_tok Lexer.TRParen
                "expected `)` after constructor pattern arguments";
              List.rev !ps
            end
          end
          else if pattern_arg_start () then [ parse_pattern_atom () ]
          else []
        in
        Ast.PCtor (c, args)
    | Lexer.TLParen ->
        advance ();
        if peek () = Lexer.TRParen then (advance (); Ast.PUnit)
        else begin
          let p1 = parse_pattern () in
          if peek () = Lexer.TComma then begin
            let ps = ref [ p1 ] in
            while peek () = Lexer.TComma do
              advance ();
              ps := parse_pattern () :: !ps
            done;
            expect_tok Lexer.TRParen "expected `)` after tuple pattern";
            Ast.PTuple (List.rev !ps)
          end
          else begin
            expect_tok Lexer.TRParen "expected `)` after pattern";
            p1
          end
        end
    | Lexer.TLBracket ->
        advance ();
        if peek () = Lexer.TRBracket then (advance (); Ast.PNil)
        else
          error
            "list patterns other than `[]` are not supported in v1 (use `x :: xs`)"
    | _ -> error "invalid pattern"

  (* ---------------- expressions ---------------- *)

  and arg_start () =
    match peek () with
    | Lexer.TInt _ | Lexer.TFloat _ | Lexer.TStr _ | Lexer.TChar _
    | Lexer.TBool _ | Lexer.TIdent _ | Lexer.TUctor _ | Lexer.TLParen
    | Lexer.TLBracket | Lexer.TLBrace | Lexer.TKey "begin" | Lexer.TKey "new"
    | Lexer.TKey "not" ->
        true
    | _ -> false

  and parse_noseq () = parse_assign ()

  and parse_expr () =
    let e = parse_assign () in
    let rec go e =
      if peek () = Lexer.TSemi then begin
        advance ();
        let e2 = parse_assign () in
        go (mk e.Ast.pos (Ast.ESeq (e, e2)))
      end
      else e
    in
    go e

  and parse_assign () =
    if !depth >= 1000 then error "expression nested too deeply (limit 1000)";
    incr depth;
    let e =
      let e = parse_or () in
      if peek () = Lexer.TAssign then begin
        advance ();
        let target =
          match e.Ast.desc with
          | Ast.EVar n -> Ast.AVar n
          | Ast.EField (r, f) -> Ast.AField (r, f)
          | _ ->
              Ast.raise_at ~file e.Ast.pos
                "invalid assignment target (expected a variable or a record field)"
        in
        let v = parse_assign () in
        mk e.Ast.pos (Ast.EAssign (target, v))
      end
      else e
    in
    decr depth;
    e

  and parse_or () =
    let e = parse_and () in
    let rec go e =
      if peek () = Lexer.TOr then begin
        advance ();
        let r = parse_and () in
        go (mk e.Ast.pos (Ast.EBin (Ast.Or, e, r)))
      end
      else e
    in
    go e

  and parse_and () =
    let e = parse_cmp () in
    let rec go e =
      if peek () = Lexer.TAnd then begin
        advance ();
        let r = parse_cmp () in
        go (mk e.Ast.pos (Ast.EBin (Ast.And, e, r)))
      end
      else e
    in
    go e

  and parse_cmp () =
    let e = parse_cons () in
    let rec go e =
      let op =
        match peek () with
        | Lexer.TEq -> Some Ast.Eq
        | Lexer.TNe -> Some Ast.Ne
        | Lexer.TLt -> Some Ast.Lt
        | Lexer.TLe -> Some Ast.Le
        | Lexer.TGt -> Some Ast.Gt
        | Lexer.TGe -> Some Ast.Ge
        | _ -> None
      in
      match op with
      | Some op ->
          advance ();
          let r = parse_cons () in
          go (mk e.Ast.pos (Ast.EBin (op, e, r)))
      | None -> e
    in
    go e

  and parse_cons () =
    let e = parse_concat () in
    if peek () = Lexer.TCons then begin
      advance ();
      let r = parse_cons () in
      mk e.Ast.pos (Ast.ECons (e, r))
    end
    else e

  and parse_concat () =
    let e = parse_add () in
    if peek () = Lexer.TConcat then begin
      advance ();
      let r = parse_concat () in
      mk e.Ast.pos (Ast.EBin (Ast.Concat, e, r))
    end
    else e

  and parse_add () =
    let e = parse_mul () in
    let rec go e =
      let op =
        match peek () with
        | Lexer.TPlus -> Some Ast.Add
        | Lexer.TMinus -> Some Ast.Sub
        | _ -> None
      in
      match op with
      | Some op ->
          advance ();
          let r = parse_mul () in
          go (mk e.Ast.pos (Ast.EBin (op, e, r)))
      | None -> e
    in
    go e

  and parse_mul () =
    let e = parse_unary () in
    let rec go e =
      let op =
        match peek () with
        | Lexer.TStar -> Some Ast.Mul
        | Lexer.TSlash -> Some Ast.Div
        | Lexer.TPercent -> Some Ast.Mod
        | _ -> None
      in
      match op with
      | Some op ->
          advance ();
          let r = parse_unary () in
          go (mk e.Ast.pos (Ast.EBin (op, e, r)))
      | None -> e
    in
    go e

  and parse_unary () =
    match peek () with
    | Lexer.TMinus ->
        let p = peek_pos () in
        advance ();
        mk p (Ast.EUnary (Ast.Neg, parse_unary ()))
    | Lexer.TKey "not" ->
        let p = peek_pos () in
        advance ();
        mk p (Ast.EUnary (Ast.Not, parse_unary ()))
    | _ -> parse_operand ()

  and parse_operand () =
    match peek () with
    | Lexer.TKey "if" -> parse_if ()
    | Lexer.TKey "let" -> parse_let ()
    | Lexer.TKey "match" -> parse_match ()
    | Lexer.TKey "while" -> parse_while ()
    | Lexer.TKey "for" -> parse_for ()
    | Lexer.TKey "fun" ->
        error "`fun` (functions as values) is not supported in v1"
    | Lexer.TKey "try" ->
        error "exceptions (`try`/`raise`) are not supported in v1 (SPEC)"
    | Lexer.TKey "raise" ->
        error "exceptions (`try`/`raise`) are not supported in v1 (SPEC)"
    | Lexer.TKey "ref" ->
        error "references (`ref`) are not supported in v1 (SPEC)"
    | Lexer.TKey "open" ->
        error "`open` is not supported in v1 (SPEC)"
    | Lexer.TKey "assert" ->
        error "`assert` is not supported in v1 (SPEC)"
    | _ -> parse_apply ()

  and flatten_tuple_arg e =
    match e.Ast.desc with Ast.ETuple es -> es | _ -> [ e ]

  and collect_args () =
    if !in_for_low && is_downto () then []
    else begin
      let a = parse_postfixed_atom () in
      if arg_start () then a :: collect_args () else [ a ]
    end

  and parse_postfixed_atom () =
    let e = parse_atom () in
    let rec postfix e =
      match peek () with
      | Lexer.TDot ->
          advance ();
          let name = expect_ident "expected a field or method name after `.`" in
          if arg_start () then begin
            let args = collect_args () in
            postfix (mk e.Ast.pos (Ast.ECall (e, name, args)))
          end
          else postfix (mk e.Ast.pos (Ast.EField (e, name)))
      | Lexer.THash ->
          advance ();
          let name = expect_ident "expected a method name after `#`" in
          let args = if arg_start () then collect_args () else [] in
          postfix (mk e.Ast.pos (Ast.ECall (e, name, args)))
      | _ -> e
    in
    postfix e

  and parse_apply () =
    let head = parse_postfixed_atom () in
    if arg_start () then begin
      let args = collect_args () in
      if args = [] then head
      else
        match head.Ast.desc with
        | Ast.EVar n -> mk head.Ast.pos (Ast.ELocalCall (n, args))
        | Ast.ECtor (c, []) ->
            mk head.Ast.pos
              (Ast.ECtor (c, List.concat_map flatten_tuple_arg args))
        | Ast.ECall (r, n, prev) ->
            mk head.Ast.pos (Ast.ECall (r, n, prev @ args))
        | _ ->
            Ast.raise_at ~file head.Ast.pos
              "unexpected argument (v1 requires fully applied calls)"
    end
    else head

  and parse_atom () =
    let p = peek_pos () in
    match peek () with
    | Lexer.TInt i -> advance (); mk p (Ast.EInt i)
    | Lexer.TFloat f -> advance (); mk p (Ast.EFloat f)
    | Lexer.TStr s -> advance (); mk p (Ast.EStr s)
    | Lexer.TChar c -> advance (); mk p (Ast.EChar c)
    | Lexer.TBool b -> advance (); mk p (Ast.EBool b)
    | Lexer.TIdent "mod" ->
        error "`mod` is not supported in v1 (SPEC); use `%`"
    | Lexer.TIdent s -> advance (); mk p (Ast.EVar s)
    | Lexer.TUnderscore ->
        error "`_` is not a value expression (it is only a pattern)"
    | Lexer.TUctor s -> advance (); mk p (Ast.ECtor (s, []))
    | Lexer.TKey "not" -> advance (); mk p (Ast.EVar "not")
    | Lexer.TKey "new" ->
        advance ();
        let cname = expect_ident "expected a class name after `new`" in
        let args = if arg_start () then collect_args () else [] in
        mk p (Ast.ENew (cname, args))
    | Lexer.TKey "begin" ->
        advance ();
        let e = parse_expr () in
        expect_tok (Lexer.TKey "end") "expected `end` after `begin`";
        e
    | Lexer.TLParen ->
        advance ();
        if peek () = Lexer.TRParen then (advance (); mk p Ast.EUnit)
        else begin
          let rec components acc =
            let e = parse_noseq () in
            if peek () = Lexer.TComma then begin
              advance ();
              components (e :: acc)
            end
            else List.rev (e :: acc)
          in
          let rec chunks acc =
            let comps = components [] in
            let ce =
              match comps with
              | [ e ] -> e
              | es -> mk p (Ast.ETuple es)
            in
            if peek () = Lexer.TSemi then begin
              advance ();
              chunks (ce :: acc)
            end
            else List.rev (ce :: acc)
          in
          let cs = chunks [] in
          let g =
            match cs with
            | [ e ] -> e
            | e :: rest ->
                List.fold_left (fun a b -> mk a.Ast.pos (Ast.ESeq (a, b))) e rest
            | [] -> assert false
          in
          if peek () = Lexer.TColon then begin
            advance ();
            let t = parse_type () in
            expect_tok Lexer.TRParen "expected `)` after type annotation";
            mk p (Ast.ETyped (g, t))
          end
          else begin
            expect_tok Lexer.TRParen "expected `)`";
            g
          end
        end
    | Lexer.TLBracket ->
        advance ();
        if peek () = Lexer.TRBracket then (advance (); mk p (Ast.EList []))
        else begin
          let es = ref [ parse_noseq () ] in
          while peek () = Lexer.TSemi do
            advance ();
            es := parse_noseq () :: !es
          done;
          expect_tok Lexer.TRBracket "expected `]` after list elements";
          mk p (Ast.EList (List.rev !es))
        end
    | Lexer.TLBrace ->
        advance ();
        if peek () = Lexer.TRBrace then
          error "empty record literal"
        else begin
          let fields = ref [] in
          let rec go () =
            let fname = expect_ident "expected a record field name" in
            expect_tok Lexer.TEq "expected `=` after record field name";
            let e = parse_noseq () in
            fields := (fname, e) :: !fields;
            match peek () with
            | Lexer.TSemi ->
                advance ();
                if peek () = Lexer.TRBrace then ()
                else go ()
            | Lexer.TRBrace -> ()
            | _ -> error "expected `;` or `}` in record literal"
          in
          go ();
          expect_tok Lexer.TRBrace "expected `}` after record fields";
          mk p (Ast.ERecord (List.rev !fields))
        end
    | _ -> error "expected an expression"

  and parse_if () =
    let p = peek_pos () in
    advance ();                        (* `if` *)
    let cond = parse_expr () in
    expect_tok (Lexer.TKey "then") "expected `then` after the if condition";
    let b1 = parse_noseq () in
    expect_tok (Lexer.TKey "else")
      "`if` without `else` is not supported in v1 (SPEC requires \
       `if a then b else c`)";
    let b2 = parse_noseq () in
    mk p (Ast.EIf (cond, b1, b2))

  and parse_while () =
    let p = peek_pos () in
    advance ();                        (* `while` *)
    let cond = parse_expr () in
    expect_tok (Lexer.TKey "do") "expected `do` after the while condition";
    let body = parse_expr () in
    expect_tok (Lexer.TKey "done") "expected `done` after the while body";
    mk p (Ast.EWhile (cond, body))

  and parse_for () =
    let p = peek_pos () in
    advance ();                        (* `for` *)
    let name =
      match peek () with
      | Lexer.TIdent s -> advance (); s
      | _ -> error "expected a variable name after `for`"
    in
    match peek () with
    | Lexer.TKey "in" ->
        advance ();
        let xs = parse_expr () in
        expect_tok (Lexer.TKey "do") "expected `do` in the for loop";
        let body = parse_expr () in
        expect_tok (Lexer.TKey "done") "expected `done` after the for body";
        mk p (Ast.EForIn (name, xs, body))
    | Lexer.TEq ->
        advance ();
        in_for_low := true;
        let lo = parse_expr () in
        in_for_low := false;
        let up =
          match peek () with
          | Lexer.TKey "to" -> advance (); true
          | Lexer.TIdent "downto" -> advance (); false
          | _ -> error "expected `to` or `downto` in the for range"
        in
        let hi = parse_expr () in
        expect_tok (Lexer.TKey "do") "expected `do` in the for range";
        let body = parse_expr () in
        expect_tok (Lexer.TKey "done") "expected `done` after the for body";
        mk p (Ast.EForRange (name, up, lo, hi, body))
    | _ -> error "expected `in` or `=` after the for-loop variable"

  and parse_match () =
    let p = peek_pos () in
    advance ();                        (* `match` *)
    let scrut = parse_expr () in
    expect_tok (Lexer.TKey "with") "expected `with` after the match expression";
    if peek () = Lexer.TKey "|" then advance ();
    let arms = ref [] in
    let rec go () =
      let pat = parse_pattern () in
      let guard =
        if is_keyword "when" then begin
          advance ();
          Some (parse_expr ())
        end
        else None
      in
      expect_tok Lexer.TArrow "expected `->` after the match pattern";
      let rhs = parse_expr () in
      arms := { Ast.pat; guard; rhs } :: !arms;
      if peek () = Lexer.TKey "|" then begin
        advance ();
        go ()
      end
    in
    go ();
    mk p (Ast.EMatch (scrut, List.rev !arms))

  and parse_let () =
    let p = peek_pos () in
    advance ();                        (* `let` *)
    if is_keyword "rec" then
      error "nested `let rec` is not supported in v1 (only top-level)";
    let mut = if is_keyword "mutable" then (advance (); true) else false in
    match peek () with
    | Lexer.TIdent name ->
        advance ();
        let ann =
          if peek () = Lexer.TColon then begin
            advance ();
            Some (parse_type ())
          end
          else None
        in
        expect_tok Lexer.TEq "expected `=` in the let binding";
        let v = parse_expr () in
        let v =
          match ann with Some t -> mk v.Ast.pos (Ast.ETyped (v, t)) | None -> v
        in
        expect_tok (Lexer.TKey "in") "expected `in` after the let binding";
        let body = parse_expr () in
        if mut then mk p (Ast.ELetMut (name, v, body))
        else mk p (Ast.ELet (name, v, body))
    | Lexer.TLParen ->
        advance ();
        if peek () = Lexer.TRParen then begin
          (* let () = e in body  -- discard, unit pattern *)
          advance ();
          expect_tok Lexer.TEq "expected `=` in the let binding";
          let v = parse_expr () in
          expect_tok (Lexer.TKey "in") "expected `in` after the let binding";
          let body = parse_expr () in
          mk p (Ast.ESeq (v, body))
        end
        else begin
          (* let (a, b) = e in body *)
          let names = ref [] in
          let rec more () =
            let n =
              match peek () with
              | Lexer.TIdent s -> advance (); s
              | _ -> error "expected a variable name in the tuple pattern"
            in
            names := n :: !names;
            if peek () = Lexer.TComma then begin
              advance ();
              more ()
            end
          in
          more ();
          expect_tok Lexer.TRParen "expected `)` after the tuple pattern";
          expect_tok Lexer.TEq "expected `=` in the let binding";
          let v = parse_expr () in
          expect_tok (Lexer.TKey "in") "expected `in` after the let binding";
          let body = parse_expr () in
          mk p (Ast.ELetTuple (List.rev !names, v, body))
        end
    | Lexer.TUnderscore ->
        advance ();
        expect_tok Lexer.TEq "expected `=` in the let binding";
        let v = parse_expr () in
        expect_tok (Lexer.TKey "in") "expected `in` after the let binding";
        let body = parse_expr () in
        mk p (Ast.ESeq (v, body))
    | _ -> error "expected a name after `let`"

  (* ---------------- declarations ---------------- *)

  and parse_groups () =
    let ps = ref [] in
    while peek () = Lexer.TLParen do
      advance ();
      if peek () = Lexer.TRParen then begin
        advance ();
        ps := ("()", Ast.TUnit) :: !ps
      end
      else begin
        let nm = expect_ident "expected a parameter name" in
        expect_tok Lexer.TColon "expected `:` after the parameter name";
        let t = parse_type () in
        expect_tok Lexer.TRParen "expected `)` after the parameter type";
        ps := (nm, t) :: !ps
      end
    done;
    List.rev !ps

  and parse_type_decl () =
    let dpos = peek_pos () in
    advance ();                        (* `type` *)
    let tparams = ref [] in
    let rec collect_tparams () =
      match peek () with
      | Lexer.TTypeVar v -> advance (); tparams := v :: !tparams; collect_tparams ()
      | _ -> ()
    in
    collect_tparams ();
    let name = expect_ident "expected a type name" in
    expect_tok Lexer.TEq "expected `=` after the type name";
    if peek () = Lexer.TLBrace then begin
      advance ();                     (* `{` *)
      let fields = ref [] in
      let rec go () =
        let mut = if is_keyword "mutable" then (advance (); true) else false in
        let fname = expect_ident "expected a record field name" in
        expect_tok Lexer.TColon "expected `:` after the field name";
        let ft = parse_type () in
        fields := (fname, ft, mut) :: !fields;
        match peek () with
        | Lexer.TSemi -> advance (); go ()
        | Lexer.TRBrace -> ()
        | _ -> error "expected `;` or `}` in the record type"
      in
      go ();
      expect_tok Lexer.TRBrace "expected `}` after the record fields";
      Ast.DType
        (Ast.TDRecord
           { Ast.rname = name; rtparams = List.rev !tparams;
             rfields = List.rev !fields; rpos = dpos })
    end
    else begin
      if List.length !tparams >= 2 then
        error
          "variants with two or more type parameters are not supported in \
           v1 (SPEC)";
      (* a lower-case type name after `=` reads as an alias attempt *)
      (match peek () with
       | Lexer.TIdent s ->
           error
             (Printf.sprintf
                "type aliases are not supported in v1; `%s` must be a \
                 variant (uppercase constructors) or a record" s)
       | _ -> ());
      if peek () = Lexer.TKey "|" then advance ();
      let ctors = ref [] in
      let rec go () =
        let cname =
          match peek () with
          | Lexer.TUctor s -> advance (); s
          | _ -> error "expected a constructor name (uppercase) in the variant"
        in
        let payload =
          if is_keyword "of" then begin
            advance ();
            let reject_named () =
              if peek () = Lexer.TColon then
                error
                  "named variant payload fields are not supported in v1 \
                   (SPEC)"
            in
            let comps = ref [ parse_type_component () ] in
            reject_named ();
            while peek () = Lexer.TStar do
              advance ();
              comps := parse_type_component () :: !comps;
              reject_named ()
            done;
            List.rev !comps
          end
          else []
        in
        ctors := (cname, payload) :: !ctors;
        if peek () = Lexer.TKey "|" then begin
          advance ();
          go ()
        end
      in
      go ();
      Ast.DType
        (Ast.TDVariant
           { Ast.vname = name; vtparams = List.rev !tparams;
             vctors = List.rev !ctors; vpos = dpos })
    end

  and parse_let_decl () =
    let dpos = peek_pos () in
    advance ();                        (* `let` *)
    let rec_ = if is_keyword "rec" then (advance (); true) else false in
    if is_keyword "mutable" then
      error
        "top-level `let mutable` is not supported in v1 (only local mutable \
         values)";
    let name =
      match peek () with
      | Lexer.TIdent s -> advance (); s
      | _ ->
          error
            "expected a name after `let` (top-level tuple patterns and \
             `let _` are not supported in v1)"
    in
    let params = parse_groups () in
    let ann =
      if peek () = Lexer.TColon then begin
        advance ();
        Some (parse_type ())
      end
      else None
    in
    expect_tok Lexer.TEq "expected `=` in the let declaration";
    let body = parse_expr () in
    if params <> [] then begin
      let fret =
        match ann with
        | Some t -> t
        | None ->
            error
              "missing return type annotation (SPEC: function return \
               annotation is required)"
      in
      Ast.DFun { Ast.fname = name; frec = rec_; fparams = params; fret;
                 fbody = body; fpos = dpos }
    end
    else begin
      if rec_ then
        error "`rec` is not meaningful on a parameterless top-level value";
      let fret = match ann with Some t -> t | None -> Ast.TUnit in
      let fbody =
        match ann with Some t -> mk body.Ast.pos (Ast.ETyped (body, t))
        | None -> body
      in
      Ast.DFun { Ast.fname = name; frec = false; fparams = []; fret; fbody;
                 fpos = dpos }
    end

  and parse_class_decl () =
    let dpos = peek_pos () in
    advance ();                        (* `class` *)
    if is_keyword "type" then parse_class_type_decl dpos
    else begin
      let name = expect_ident "expected a class name" in
      let cparams = parse_groups () in
      expect_tok Lexer.TEq "expected `=` after the class declaration";
      expect_tok (Lexer.TKey "object")
        "expected `object` in the class body";
      let cself =
        if peek () = Lexer.TLParen then begin
          advance ();
          let s = expect_ident "expected the self name in `object (self)`" in
          expect_tok Lexer.TRParen "expected `)` after the self name";
          s
        end
        else "self"
      in
      let cinherits = ref [] and cfields = ref [] and cmethods = ref [] in
      let rec go () =
        match peek () with
        | Lexer.TKey "end" -> ()
        | Lexer.TKey "inherit" ->
            advance ();
            let n =
              expect_ident "expected a class type name after `inherit`"
            in
            cinherits := n :: !cinherits;
            go ()
        | Lexer.TKey "val" ->
            let vpos = peek_pos () in
            advance ();
            let mut = if is_keyword "mutable" then (advance (); true) else false in
            let fname = expect_ident "expected a field name after `val`" in
            let ft =
              if peek () = Lexer.TColon then begin
                advance ();
                Some (parse_type ())
              end
              else None
            in
            expect_tok Lexer.TEq "expected `=` in the field initializer";
            let init = parse_noseq () in
            cfields :=
              { Ast.cfname = fname; cfmut = mut; cfinit = init; cftyp = ft;
                cfpos = vpos }
              :: !cfields;
            go ()
        | Lexer.TKey "method" ->
            let mpos = peek_pos () in
            advance ();
            let mprivate =
              if is_keyword "private" then (advance (); true) else false
            in
            let mstatic =
              if is_keyword "static" then (advance (); true) else false
            in
            let mname = expect_ident "expected a method name" in
            if peek () <> Lexer.TLParen then
              error "expected a parameter list `(...)` for the method";
            let mparams = parse_groups () in
            expect_tok Lexer.TColon "expected `:` before the method return type";
            let mret = parse_type () in
            expect_tok Lexer.TEq "expected `=` before the method body";
            let mbody = parse_expr () in
            cmethods :=
              { Ast.mname; mstatic; mprivate; mparams; mret; mbody; mpos }
              :: !cmethods;
            go ()
        | _ ->
            error "expected `val`, `method`, `inherit`, or `end` in the class body"
      in
      go ();
      expect_tok (Lexer.TKey "end") "expected `end` at the end of the class body";
      Ast.DClass
        {
          Ast.cname = name;
          cparams;
          cself;
          cinherits = List.rev !cinherits;
          cfields = List.rev !cfields;
          cmethods = List.rev !cmethods;
          cpos = dpos;
        }
    end

  and parse_class_type_decl dpos =
    (* current token is the `type` keyword *)
    advance ();
    let name = expect_ident "expected a class type name" in
    expect_tok Lexer.TEq "expected `=` after the class type name";
    expect_tok (Lexer.TKey "object") "expected `object` in the class type";
    let ms = ref [] in
    let rec go () =
      match peek () with
      | Lexer.TKey "end" -> ()
      | Lexer.TKey "method" ->
          advance ();
          let mn = expect_ident "expected a method name" in
          if peek () <> Lexer.TLParen then
            error "expected a parameter list `(...)` for the interface method";
          let mparams = parse_groups () in
          expect_tok Lexer.TColon "expected `:` before the method return type";
          let mret = parse_type () in
          ms := { Ast.msname = mn; msparams = mparams; msret = mret } :: !ms;
          go ()
      | _ -> error "expected `method` or `end` in the class type"
    in
    go ();
    expect_tok (Lexer.TKey "end") "expected `end` at the end of the class type";
    Ast.DClassType { Ast.ctname = name; ctmethods = List.rev !ms; ctpos = dpos }
  in

  (* ---------------- program ---------------- *)

  let rec decls acc =
    match peek () with
    | Lexer.TEOF -> List.rev acc
    | Lexer.TKey "type" -> decls (parse_type_decl () :: acc)
    | Lexer.TKey "let" -> decls (parse_let_decl () :: acc)
    | Lexer.TKey "class" -> decls (parse_class_decl () :: acc)
    | Lexer.TKey "open" ->
        error "`open` is not supported in v1 (SPEC)"
    | Lexer.TKey "module" ->
        error "modules and functors are not supported in v1 (SPEC)"
    | _ ->
        error
          "expected a top-level declaration (`type`, `let`, or `class`)"
  in
  { Ast.file; decls = decls [] }
