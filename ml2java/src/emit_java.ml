(* emit_java.ml — ml2java v1 Java source emitter.

   Implements the "Java mapping" rules of SPEC.md.  One .mlj file becomes one
   Java file; the top-level class is the file basename, everything declared is
   nested static inside it.

   Boring choices, documented per SPEC ("pick the boring option and write the
   choice in a comment"):
   - failwith  ->  private generic helper `_fail(String)` emitted once per
     file; throws RuntimeException.  Composes in both statement and expression
     positions.
   - x :: xs  ->  private generic helper `_cons(T, List<T>)` (ArrayList +
     addAll + Collections.unmodifiableList).  Only `java.util.List` is
     imported; ArrayList/Collections are fully qualified inside the helper.
   - int literals get an explicit `L` suffix so `List.of(...)` and generic
     contexts infer Long, not Integer.
   - statement-laden expressions (let/if/match/seq/loops/assignment) in
     expression position are materialized into a fresh temp: declaration and
     statements are written to the current buffer during expression
     rendering, BEFORE the line that consumes the temp (expressions are
     always rendered to text before their consuming line is written, so
     ordering is correct).
   - match/if result temps are initialized to the type's zero value up front
     so javac's definite-assignment check always passes; the checker's
     exhaustiveness proof means the zero is never observed.  Every match
     chain still ends in a defensive throw, so a checker hole would surface
     as an exception instead of an invented value.
   - a statement-bearing while condition is re-evaluated on every iteration
     (lowered to `while (true) { ...; if (!cond) break; body }`); only pure
     conditions stay in the while head.
   - match  ->  if/else instanceof chain.  The scrutinee is evaluated once
     into a fresh temp unless it is already a simple variable.  Pattern vars
     are fresh names, so OCaml shadowing maps onto Java without redeclaration
     errors.  Guards become `if (pat && g) { arm; break _mN; }` inside a
     labeled block `_mN: { ... }`; a guard failure falls through to the next
     arm exactly once, so the emitted Java is linear in the arm count (the
     old nested-else form emitted the remaining chain once per guarded arm,
     i.e. 2^(N-1) lines for N guarded arms).
   - generic ctor patterns use a raw `instanceof` plus an unchecked cast for
     payload access (javac accepts with a warning; check.sh does not use
     -Werror).
   - option is erased to nullable: Some e -> e, None -> null; Some/None
     patterns are `!= null` / `== null`.  A primitive element type is boxed
     (`int option` -> Long) so that null is representable.  Equality on
     options uses java.util.Objects.equals (null-safe, structural), since
     None == null and `.equals` on a null left operand would NPE.
   - tuples become nested records Tuple2<T,U>(T v0, U v1) ..., emitted once
     per arity used.
   - equality: primitive operand types -> == / !=, everything else ->
     (a).equals(b).  A null left operand NPEs; accepted for v1 (options are
     the exception, see above).
   - ordering on strings (the checker permits TStr for Lt/Le/Gt/Ge) lowers to
     `(a).compareTo(b) < 0` etc.; primitive ordering stays `< <= > >=`.
   - `let _ = e` binders and unit-typed binders are dropped (only the
     initializer's statements are kept).
   - unit-typed values are never materialized: `()` parameters are dropped
     from signatures, unit-typed call arguments are dropped, unit-typed
     statement expressions emit nothing.
   - local binders get unique Java names (counter-suffixed) so shadowing
     works and Java's no-shadowing rules never fire.
   - records with a `mutable` field cannot be Java records; they become
     a final class with public fields plus equals/hashCode so the SPEC
     equality rule (records compare with .equals) still holds.
*)

open Ast

type cls_ctx = {
  cparams : (string * typ) list;
  cfields : (string * typ) list;
}

type state = {
  tables : Check.tables;
  file : string;
  buf : Buffer.t;               (* body text (decls and helpers share it) *)
  mutable indent : int;
  mutable tmpc : int;
  mutable bndc : int;
  mutable lblc : int;             (* match-chain break labels (_m0, _m1, ...) *)
  mutable tup_arities : int list;     (* tuple arities used, dedup at end *)
  mutable use_list : bool;
  mutable use_cons : bool;
  mutable use_fail : bool;
  mutable use_somebox : bool;
  tparams : (string, string) Hashtbl.t;  (* 'a -> T/U/... per decl *)
  mutable scope : (string * string) list;        (* ocaml name -> java name *)
  mutable cl : cls_ctx option;
  (* Java names already taken in the current function/method body: verbatim
     parameter names plus every name handed out by fresh_binder/fresh_tmp.
     Seeded per function/method so a verbatim parameter like `x_b0` or
     `_t0` can never collide with a fresh local. *)
  mutable used : (string, unit) Hashtbl.t;
}

let mk_state tables file =
  {
    tables;
    file;
    buf = Buffer.create 8192;
    indent = 0;
    tmpc = 0;
    bndc = 0;
    lblc = 0;
    tup_arities = [];
    use_list = false;
    use_cons = false;
    use_fail = false;
    use_somebox = false;
    tparams = Hashtbl.create 8;
    scope = [];
    cl = None;
    used = Hashtbl.create 8;
  }

let err st pos msg = raise (Front_error (format_error ~file:st.file pos msg))
(* internal emitter errors: every call site passes the position of the
   expression being lowered, so the diagnostic points at real source *)
let err_at st pos msg = err st pos ("emitter: " ^ msg)

let spaces n = String.make (n * 2) ' '

let desc_tag (e : expr) =
  match e.desc with
  | EUnit -> "EUnit" | EInt _ -> "EInt" | EFloat _ -> "EFloat"
  | EBool _ -> "EBool" | EChar _ -> "EChar" | EStr _ -> "EStr"
  | EVar _ -> "EVar" | ETuple _ -> "ETuple" | EList _ -> "EList"
  | ECons _ -> "ECons" | ERecord _ -> "ERecord" | EField _ -> "EField"
  | EAssign _ -> "EAssign" | ECall _ -> "ECall" | ELocalCall _ -> "ELocalCall"
  | ECtor _ -> "ECtor" | ENew _ -> "ENew" | EMatch _ -> "EMatch"
  | EIf _ -> "EIf" | ELet _ -> "ELet" | ELetMut _ -> "ELetMut"
  | ELetTuple _ -> "ELetTuple" | ESeq _ -> "ESeq" | EWhile _ -> "EWhile"
  | EForIn _ -> "EForIn" | EForRange _ -> "EForRange" | EBin _ -> "EBin"
  | EUnary _ -> "EUnary" | ETyped _ -> "ETyped" | ESelfField _ -> "ESelfField"

let type_of_expr st (e : expr) =
  match Hashtbl.find_opt st.tables.types e.id with
  | Some t -> t
  | None ->
      err st e.pos
        (Printf.sprintf "no type annotation for %s (expr #%d)" (desc_tag e) e.id)

let t_of st (e : expr) = type_of_expr st e

(* ------------------------------------------------------------------ *)
(* Text lines                                                          *)
(* ------------------------------------------------------------------ *)

(* A fully indented code line into the body buffer.  Statements that a
   nested expression materializes are written during expression evaluation,
   which always happens before the consuming [line] call, so everything
   lands in program order. *)
let line st s =
  Buffer.add_string st.buf (spaces st.indent);
  Buffer.add_string st.buf s;
  Buffer.add_char st.buf '\n'

let with_indent st f =
  st.indent <- st.indent + 1;
  f ();
  st.indent <- st.indent - 1

(* ------------------------------------------------------------------ *)
(* Fresh names and scope                                               *)
(* ------------------------------------------------------------------ *)

(* Every name handed out here is reserved in [st.used] for the rest of the
   current function/method body.  fresh_binder's `%s_b%d` form can collide
   with a VERBATIM parameter named e.g. `x_b0` (params are emitted verbatim,
   locals are renamed), so the suffix is bumped until the name is free. *)
let fresh_binder st name =
  let n = ref st.bndc in
  let rec go () =
    let jn = Printf.sprintf "%s_b%d" name !n in
    if Hashtbl.mem st.used jn then (
      incr n;
      go ())
    else jn
  in
  let jn = go () in
  st.bndc <- !n + 1;
  Hashtbl.replace st.used jn ();
  jn

let fresh_tmp st =
  let n = ref st.tmpc in
  let rec go () =
    let jn = Printf.sprintf "_t%d" !n in
    if Hashtbl.mem st.used jn then (
      incr n;
      go ())
    else jn
  in
  let jn = go () in
  st.tmpc <- !n + 1;
  Hashtbl.replace st.used jn ();
  jn

(* A Java label for a match chain.  Labels live in their own namespace in
   Java (a label may share a name with a variable), but two labels in the
   same method may not share a name, so the counter is a file-global
   monotone counter like tmpc/bndc: labels are unique across the whole
   file, hence within every method.  The `_m%d` form cannot collide with a
   verbatim parameter either: parameters are emitted verbatim, and `_m0`
   is not a valid OCaml identifier, so no parameter can ever be named
   that. *)
let fresh_label st =
  let jn = Printf.sprintf "_m%d" st.lblc in
  st.lblc <- st.lblc + 1;
  jn

let push_bind st name jname = st.scope <- (name, jname) :: st.scope
let pop_bind st = st.scope <- List.tl st.scope

(* Resolve an OCaml variable name to Java text. *)
let lookup st name =
  match List.assoc_opt name st.scope with
  | Some jn -> jn
  | None -> (
      match st.cl with
      | Some { cparams; cfields; _ } ->
          if List.mem_assoc name cparams || List.mem_assoc name cfields
          then "this." ^ name
          else name
      | None -> name)

(* ------------------------------------------------------------------ *)
(* Java type mapping                                                  *)
(* ------------------------------------------------------------------ *)

(* 'a 'b -> "T", "U", ... *)
let letter_of_index i =
  if i < 8 then String.make 1 (Char.chr (Char.code 'T' + i))
  else "Z" ^ string_of_int (i - 7)

let rec subst_typ (m : (string * typ) list) (t : typ) : typ =
  match t with
  | TParam p -> (
      match List.assoc_opt p m with Some t' -> t' | None -> t)
  | TList t -> TList (subst_typ m t)
  | TOption t -> TOption (subst_typ m t)
  | TTuple ts -> TTuple (List.map (subst_typ m) ts)
  | TCon (n, ts) -> TCon (n, List.map (subst_typ m) ts)
  | other -> other

(* type args of a TCon, else [] *)
let con_args (t : typ) = match t with TCon (_, args) -> args | _ -> []

let is_option (t : typ) : bool = match t with TOption _ -> true | _ -> false

(* Declared type params of a variant/record decl, by decl name. *)
let decl_params st name =
  match Hashtbl.find_opt st.tables.tdecls name with
  | Some (TDVariant v) -> v.vtparams
  | Some (TDRecord r) -> r.rtparams
  | _ -> []

(* Field type of a record-typed value, with the record's declared params
   replaced by the value's type args.  The checker guarantees the field
   exists and the scrutinee is the record; the fallback is defensive. *)
let record_field_typ st ty f =
  match ty with
  | TCon (n, args) -> (
      match Hashtbl.find_opt st.tables.tdecls n with
      | Some (TDRecord r) -> (
          match List.find_opt (fun (fn, _, _) -> fn = f) r.rfields with
          | Some (_, ft, _) ->
              let params = decl_params st n in
              if List.length params = List.length args then
                subst_typ (List.combine params args) ft
              else ft
          | None -> TParam "@field")
      | _ -> TParam "@field")
  | _ -> TParam "@field"

(* Payload type i of a ctor, with the variant's declared params replaced by
   the scrutinee's type args. *)
let payload_typ st name targs i =
  match Hashtbl.find_opt st.tables.ctors name with
  | Some (parent, payloads) -> (
      match List.nth_opt payloads i with
      | None -> TParam "@payload"
      | Some t ->
          let params = decl_params st parent in
          if List.length params = List.length targs then
            subst_typ (List.combine params targs) t
          else t)
  | None -> TParam "@payload"

let add_arity st n =
  if not (List.mem n st.tup_arities) then st.tup_arities <- n :: st.tup_arities

let rec jtype st (t : typ) : string =
  match t with
  | TInt -> "long"
  | TFloat -> "double"
  | TBool -> "boolean"
  | TChar -> "char"
  | TStr -> "String"
  | TUnit -> "void"
  | TParam p -> (
      match Hashtbl.find_opt st.tparams p with
      | Some s -> s
      | None ->
          (* unconstrained type var (checker placeholder @uN): Object is the
             safe v1 answer *)
          "Object")
  | TList t ->
      st.use_list <- true;
      "List<" ^ jboxed st t ^ ">"
  | TOption t ->
      (* option is erased to nullable; a primitive element must be boxed
         so that None (null) is representable.  A nested option (the element
         type is itself an option) must be wrapped in _SomeBox, otherwise
         `Some None` and `None` would both be null. *)
      if is_option t then (
        st.use_somebox <- true;
        "_SomeBox<" ^ jboxed st t ^ ">")
      else jboxed st t
  | TTuple ts ->
      let n = List.length ts in
      add_arity st n;
      Printf.sprintf "Tuple%d<%s>" n
        (String.concat ", " (List.map (jboxed st) ts))
  | TCon (n, []) -> n
  | TCon (n, ts) -> n ^ "<" ^ String.concat ", " (List.map (jboxed st) ts) ^ ">"

(* type arguments must be reference types in Java: box primitives *)
and jboxed st (t : typ) : string =
  match t with
  | TInt -> "Long"
  | TFloat -> "Double"
  | TBool -> "Boolean"
  | TChar -> "Character"
  | _ -> jtype st t

(* zero value of a type, for match/if result temps *)
let zero_of (t : typ) : string =
  match t with
  | TInt -> "0L"
  | TFloat -> "0.0"
  | TBool -> "false"
  | TChar -> "0"
  | _ -> "null"

let is_primitive (t : typ) : bool =
  match t with TInt | TFloat | TBool | TChar -> true | _ -> false

(* ------------------------------------------------------------------ *)
(* literals                                                           *)
(* ------------------------------------------------------------------ *)

(* Java source is read in two phases: raw unicode escapes (`\uXXXX` in the
   source text) are processed BEFORE tokenization, so a literal sequence
   `\u` in emitted text would be consumed by phase 1 even inside a string.
   `\\` (two source backslashes) survives phase 1 intact and tokenizes as
   one escaped backslash, so every backslash in an emitted string literal
   must be doubled.  Non-ASCII characters pass through verbatim (files are
   UTF-8, javac runs with -encoding UTF-8); every control character,
   quote, and backslash is escaped (control chars as lowercase 4-digit
   hex \uXXXX). *)
let java_string s =
  let b = Buffer.create (String.length s + 2) in
  Buffer.add_char b '"';
  String.iter
    (fun c ->
      match c with
      | '"' -> Buffer.add_string b "\\\""
      | '\\' -> Buffer.add_string b "\\\\"
      | '\n' -> Buffer.add_string b "\\n"
      | '\t' -> Buffer.add_string b "\\t"
      | '\r' -> Buffer.add_string b "\\r"
      | c when Char.code c < 0x20 || Char.code c = 0x7f ->
          Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
      | c -> Buffer.add_char b c)
    s;
  Buffer.add_char b '"';
  Buffer.contents b

let java_char c =
  match c with
  | '\'' -> "'\\''"
  | '\\' -> "'\\\\'"
  | '\n' -> "'\\n'"
  | '\t' -> "'\\t'"
  | '\r' -> "'\\r'"
  | c when Char.code c < 0x20 || Char.code c = 0x7f ->
      Printf.sprintf "'\\u%04x'" (Char.code c)
  | c -> Printf.sprintf "'%c'" c

let jint (i : int) = Printf.sprintf "%dL" i

let jfloat (f : float) =
  if f = infinity then "Double.POSITIVE_INFINITY"
  else if f = neg_infinity then "Double.NEGATIVE_INFINITY"
  else
    let s = Printf.sprintf "%.17g" f in
    if String.contains s '.' || String.contains s 'e' || String.contains s 'E'
    then s
    else s ^ ".0"

(* ------------------------------------------------------------------ *)
(* purity / statement legality                                         *)
(* ------------------------------------------------------------------ *)

(* no side effects and no hidden statements *)
let rec is_pure (e : expr) : bool =
  match e.desc with
  | EUnit | EInt _ | EFloat _ | EBool _ | EChar _ | EStr _ | EVar _
  | ESelfField _ ->
      true
  | ETyped (e, _) -> is_pure e
  | EUnary (_, e) -> is_pure e
  | EBin (_, a, b) -> is_pure a && is_pure b
  | EField (r, _) -> is_pure r
  | ETuple es -> List.for_all is_pure es
  | EList es -> List.for_all is_pure es
  | ECons (a, b) -> is_pure a && is_pure b
  | ERecord fs -> List.for_all (fun (_, e) -> is_pure e) fs
  | ECtor (_, es) -> List.for_all is_pure es
  | ENew (_, es) -> List.for_all is_pure es
  | _ -> false

(* Would evaluating [e] emit Java statements into the buffer?  A call is a
   single atomic Java expression even though it may have side effects, so
   only operands that CONTAIN statement-bearing sub-expressions (which the
   emitter lowers to declarations/if/loops) need materializing before their
   consuming line. *)
let rec emits_stmts (e : expr) : bool =
  match e.desc with
  | EUnit | EInt _ | EFloat _ | EBool _ | EChar _ | EStr _ | EVar _
  | ESelfField _ ->
      false
  | ETyped (e, _) -> emits_stmts e
  | EUnary (_, e) -> emits_stmts e
  | EBin (_, a, b) -> emits_stmts a || emits_stmts b
  | EField (r, _) -> emits_stmts r
  | ETuple es | EList es -> List.exists emits_stmts es
  | ECons (a, b) -> emits_stmts a || emits_stmts b
  | ERecord fs -> List.exists (fun (_, e) -> emits_stmts e) fs
  | ECall (r, _, args) -> emits_stmts r || List.exists emits_stmts args
  | ELocalCall (_, args) -> List.exists emits_stmts args
  | ECtor (_, es) | ENew (_, es) -> List.exists emits_stmts es
  | ELet _ | ELetMut _ | ELetTuple _ | ESeq _ | EIf _ | EMatch _ | EWhile _
  | EForIn _ | EForRange _ | EAssign _ ->
      true

(* ------------------------------------------------------------------ *)
(* expression and statement emission (one recursion group)             *)
(* ------------------------------------------------------------------ *)

(* match arm emission mode: arms are statements, or compute into temp t *)
type arm_mode = MStmt | MVal of string

(* returns (conditions, binds); binds are (ml name, java name, jtype text,
   source text).  [ty] is the static type of [scrut]. *)
let rec compile_pat st ty scrut p =
  match p with
  | PWild | PUnit -> ([], [])
  | PVar x -> ([], [ (x, fresh_binder st x, jtype st ty, scrut) ])
  | PInt i -> ([ Printf.sprintf "(%s == %dL)" scrut i ], [])
  | PStr s -> ([ Printf.sprintf "(%s).equals(%s)" scrut (java_string s) ], [])
  | PBool b ->
      ([ Printf.sprintf "(%s == %s)" scrut (if b then "true" else "false") ], [])
  | PChar c -> ([ Printf.sprintf "(%s == %s)" scrut (java_char c) ], [])
  | PTuple ps -> tuple_pat st ty scrut ps
  | PRecord fs ->
      (* a pure record reads through accessors, a record with any mutable
         field through direct field access (same rule as field_expr) *)
      let rec_has_mutable =
        match ty with
        | TCon (n, _) -> (
            match Hashtbl.find_opt st.tables.tdecls n with
            | Some (TDRecord rd) ->
                List.exists (fun (_, _, m) -> m) rd.rfields
            | _ -> false)
        | _ -> false
      in
      let cs = ref [] and bs = ref [] in
      List.iter
        (fun (f, child) ->
          let ft = record_field_typ st ty f in
          let access =
            if rec_has_mutable then Printf.sprintf "(%s).%s" scrut f
            else Printf.sprintf "(%s).%s()" scrut f
          in
          let sc, sb = compile_pat st ft access child in
          cs := !cs @ sc;
          bs := !bs @ sb)
        fs;
      (!cs, !bs)
  | PCtor ("None", []) -> ([ Printf.sprintf "(%s == null)" scrut ], [])
  | PCtor ("Some", [ inner ]) ->
      let inner_t = match ty with TOption t -> t | t -> t in
      (* payload access: a nested option was wrapped by ctor_expr, so the
         inner value lives in `.v()`; a plain option payload is the value
         itself (erasure) *)
      let payload =
        if is_option inner_t then Printf.sprintf "(%s).v()" scrut else scrut
      in
      let c, b = compile_pat st inner_t payload inner in
      (Printf.sprintf "(%s != null)" scrut :: c, b)
  | PCtor (name, ps) -> ctor_pat st ty scrut name ps
  | PNil -> ([ Printf.sprintf "(%s).isEmpty()" scrut ], [])
  | PCons (hp, tp) ->
      let elt_t = match ty with TList t -> t | t -> t in
      let hc, hb =
        compile_pat st elt_t (Printf.sprintf "(%s).get(0)" scrut) hp
      in
      let tc, tb =
        compile_pat st ty
          (Printf.sprintf "(%s).subList(1, (%s).size())" scrut scrut)
          tp
      in
      (Printf.sprintf "!(%s).isEmpty()" scrut :: hc @ tc, hb @ tb)

and tuple_pat st ty scrut ps =
  let ts = match ty with TTuple ts -> ts | _ -> [] in
  let cs = ref [] and bs = ref [] in
  List.iteri
    (fun i child ->
      let elt = match List.nth_opt ts i with Some t -> t | None -> ty in
      let sc, sb =
        compile_pat st elt (Printf.sprintf "(%s).v%d()" scrut i) child
      in
      cs := !cs @ sc;
      bs := !bs @ sb)
    ps;
  (!cs, !bs)

and ctor_pat st ty scrut name ps =
  let targs = match ty with TCon (_, a) -> a | _ -> [] in
  let cond = Printf.sprintf "(%s instanceof %s)" scrut name in
  match ps with
  | [] -> ([ cond ], [])
  | _ ->
      let cast =
        match targs with
        | [] -> Printf.sprintf "((%s) %s)" name scrut
        | _ ->
            Printf.sprintf "((%s<%s>) %s)" name
              (String.concat ", " (List.map (jboxed st) targs))
              scrut
      in
      let cs = ref [ cond ] and bs = ref [] in
      List.iteri
        (fun i child ->
          let pt = payload_typ st name targs i in
          let sc, sb =
            compile_pat st pt (Printf.sprintf "(%s).v%d()" cast i) child
          in
          cs := !cs @ sc;
          bs := !bs @ sb)
        ps;
      (!cs, !bs)

and expr_of st (e : expr) : string =
  match e.desc with
  | EUnit -> ""
  | EInt i -> jint i
  | EFloat f -> jfloat f
  | EBool b -> if b then "true" else "false"
  | EChar c -> java_char c
  | EStr s -> java_string s
  | EVar x -> lookup st x
  | ESelfField n -> "this." ^ n
  | ETyped (e, _) -> expr_of st e
  | ETuple es -> tuple_expr st es
  | EList [] ->
      st.use_list <- true;
      "List.of()"
  | EList es ->
      st.use_list <- true;
      (* elements evaluate strictly left-to-right *)
      "List.of(" ^ String.concat ", " (ordered_operands st ~force:false es)
      ^ ")"
  | ECons (x, xs) ->
      st.use_list <- true;
      st.use_cons <- true;
      (* head evaluates before tail, left-to-right *)
      "_cons(" ^ String.concat ", " (ordered_operands st ~force:false [x; xs])
      ^ ")"
  | ERecord fs -> record_expr st e fs
  | EField (r, f) -> field_expr st r f
  | ECall (recv, m, args) -> call_expr st recv m args
  | ELocalCall (name, args) -> local_call st name args
  | ECtor (name, args) -> ctor_expr st e name args
  | ENew (c, args) ->
      (* arguments evaluate strictly left-to-right; unit-typed `()` ctor
         args are dropped from the Java argument list exactly like function
         call arguments (materialize_args), since the ctor declaration
         drops unit params — their statements still run at their source
         position *)
      "new " ^ c ^ "("
      ^ String.concat ", " (materialize_args st args) ^ ")"
  | EBin (op, a, b) -> bin_expr st op a b
  | EUnary (u, e) ->
      let op = match u with Neg -> "-" | Not -> "!" in
      (* operand evaluates before the unary application *)
      "(" ^ op ^
      (if emits_stmts e then materialize st e else expr_of st e) ^ ")"
  | EIf _ | EMatch _ | ELet _ | ELetMut _ | ELetTuple _ | ESeq _ | EWhile _
  | EForIn _ | EForRange _ | EAssign _ ->
      bind_tmp st e

(* Source evaluation order is strictly left-to-right: operator operands,
   call arguments, list/tuple/record elements, cons arguments, string-concat
   operands.  Any operand that can carry statements (assignments, if/match,
   let, sequences, loops) must be materialized into a temp BEFORE the
   consuming expression is written, and operands that are mere statements
   (unit-typed effects) must run where they sit in the source order.

   [stmt_of_expr st e] runs [e] as a statement and returns None; otherwise
   it materializes [e] into a fresh temp and returns (temp, type).

   A TUnit-typed expression is NEVER materialized (no `void _tN = ...;`
   declaration can ever be emitted): its statements are emitted in place and
   no temp is produced, so a unit-typed operand in value position simply
   contributes its effects at the right point of the evaluation order. *)
and stmt_of_expr st (e : expr) : (string * typ) option =
  if is_pure e then None
  else
    match e.desc with
    | EAssign _ | EWhile _ | EForIn _ | EForRange _ ->
        (* always unit-typed effects (checker): run as statements, no value *)
        stmt_of st e;
        None
    | ELet _ | ELetMut _ | ELetTuple _ | ESeq _ | EIf _ | EMatch _ ->
        if t_of st e = TUnit then (
          stmt_of st e;
          None)
        else (
          let t = fresh_tmp st in
          let ty = t_of st e in
          line st (jtype st ty ^ " " ^ t ^ " = " ^ zero_of ty ^ ";");
          stmt_into st e t;
          Some (t, ty))
    | _ ->
        if t_of st e = TUnit then (
          (* a statement-bearing expression with a unit type that is not one
             of the forms above: run it as a statement *)
          stmt_of st e;
          None)
        else (
          let vs = expr_of st e in
          let t = fresh_tmp st in
          let ty = t_of st e in
          line st (jtype st ty ^ " " ^ t ^ " = " ^ vs ^ ";");
          Some (t, ty))

(* Pin [e] down at its source position: statement-bearing expressions are
   materialized into a temp (statements written to the buffer in place);
   unit-typed statement-bearing expressions run as statements and contribute
   no text; pure expressions (including single-expression calls, whose side
   effects run when the consuming line executes) stay inline. *)
and pin st (e : expr) : string =
  if is_pure e then expr_of st e
  else
    match stmt_of_expr st e with
    | Some (t, _) -> t
    | None -> ""

(* Does this operand list need the ordered-materialization treatment?  Any
   statement-bearing operand forces it (an inline call would otherwise move
   after the statements emitted for a later operand), as does any unit-typed
   side-effecting operand (its statements must run at exactly its source
   position, so everything before it must be pinned down), and [force]
   (record literals whose field order differs from declaration order). *)
and needs_ordering st ~force es =
  force
  || List.exists emits_stmts es
  || List.exists
       (fun e -> not (is_pure e) && t_of st e = TUnit)
       es

(* Materialize operands left-to-right.  When [needs_ordering] holds, every
   non-pure operand is pinned in source order so evaluation is exactly
   left-to-right; otherwise all operand texts stay inline (Java already
   evaluates call arguments left-to-right, and pure operands have no
   observable order). *)
and ordered_operands st ~force es : string list =
  if needs_ordering st ~force es then List.map (pin st) es
  else List.map (expr_of st) es

(* Materialize [e] into a temp if it carries statements; otherwise return
   its inline text (single-operand sites: no interleaving hazard). *)
and materialize st (e : expr) : string =
  if emits_stmts e then pin st e else expr_of st e

(* Call arguments evaluate strictly left-to-right.  Unit-typed arguments
   have no Java value and are dropped from the argument list, but their
   statements still run where they sit in the source order. *)
and materialize_args st args : string list =
  if needs_ordering st ~force:false args then
    List.filter_map
      (fun a ->
        if t_of st a = TUnit then (
          if not (is_pure a) then ignore (pin st a);
          None)
        else if is_pure a then Some (expr_of st a)
        else
          match stmt_of_expr st a with
          | Some (t, _) -> Some t
          | None -> None)
      args
  else
    (* no statement-bearing and no side-effecting unit-typed args: pure-call
       args evaluate left-to-right in the call line; unit args are `()` *)
    List.filter_map
      (fun a -> if t_of st a = TUnit then None else Some (expr_of st a))
      args

and tuple_expr st es =
  let n = List.length es in
  add_arity st n;
  let ts = List.map (fun e -> jboxed st (t_of st e)) es in
  (* elements evaluate strictly left-to-right: order them when any element
     carries statements *)
  let args = ordered_operands st ~force:false es in
  "new Tuple" ^ string_of_int n ^ "<" ^ String.concat ", " ts ^ ">("
  ^ String.concat ", " args ^ ")"

and record_expr st e fs =
  (* record fields evaluate strictly left-to-right IN SOURCE ORDER, even
     though the constructor receives them in DECLARATION order: materialize
     every field expression in source order first, then assemble the
     declaration-order argument list from the materialized texts *)
  let ty = t_of st e in
  let rname =
    match ty with
    | TCon (n, _) -> n
    | _ -> err_at st e.pos "record expression of non-record type"
  in
  let order =
    match Hashtbl.find_opt st.tables.tdecls rname with
    | Some (TDRecord r) -> List.map (fun (n, _, _) -> n) r.rfields
    | _ -> err_at st e.pos ("unknown record type " ^ rname)
  in
  (* field evaluation must follow SOURCE order, but the constructor receives
     them in DECLARATION order: when the literal's field order differs from
     the declaration order, or any field carries statements, every field is
     pinned in source order first; otherwise everything stays inline *)
  let texts =
    ordered_operands st ~force:(List.map fst fs <> order) (List.map snd fs)
  in
  let texts = List.combine (List.map fst fs) texts in
  (* the checker guarantees every literal field exists in the record type
     ("record type '%s' has no field '%s'"), so this is unreachable in a
     checker-accepted program; fail with a real position anyway *)
  let args =
    List.map
      (fun n ->
        match List.assoc_opt n texts with
        | Some t -> t
        | None -> err_at st e.pos ("record expression missing field " ^ n))
      order
  in
  let tyargs =
    match con_args ty with
    | [] -> ""
    | ts -> "<" ^ String.concat ", " (List.map (jboxed st) ts) ^ ">"
  in
  "new " ^ rname ^ tyargs ^ "(" ^ String.concat ", " args ^ ")"

and field_expr st r f =
  (* The emission shape is decided by the RECORD's overall lowering
     (emit_record): any mutable field -> final class with public fields
     (direct field read), else a Java record (accessor call).  A mixed
     record's immutable fields are still public fields of the final class,
     so a field's own mutability must NOT drive the shape. *)
  let rec_has_mutable =
    match t_of st r with
    | TCon (n, _) -> (
        match Hashtbl.find_opt st.tables.tdecls n with
        | Some (TDRecord rd) ->
            List.exists (fun (_, _, m) -> m) rd.rfields
        | _ -> false)
    | _ -> false
  in
  (* the record operand evaluates before the field access *)
  let rs = materialize st r in
  if rec_has_mutable then "(" ^ rs ^ ")." ^ f
  else "(" ^ rs ^ ")." ^ f ^ "()"

and call_expr st recv m args =
  let static = match recv.desc with EVar n -> Some n | _ -> None in
  (* the receiver evaluates before the arguments; the arguments evaluate
     strictly left-to-right.  Only operands that carry statements need
     materializing; a pure-call chain stays inline. *)
  let rs =
    if emits_stmts recv then materialize st recv else expr_of st recv
  in
  let args = materialize_args st args in
  match static with
  | Some name when Hashtbl.mem st.tables.classes name ->
      (* static call through a class name: no receiver evaluation *)
      name ^ "." ^ m ^ "(" ^ String.concat ", " args ^ ")"
  | _ -> "(" ^ rs ^ ")." ^ m ^ "(" ^ String.concat ", " args ^ ")"

and local_call st name args =
  let args = materialize_args st args in
  match name with
  | "print_string" -> "System.out.print(" ^ String.concat ", " args ^ ")"
  | "print_endline" -> "System.out.println(" ^ String.concat ", " args ^ ")"
  | "print_int" -> "System.out.print(" ^ String.concat ", " args ^ ")"
  | "print_float" -> "System.out.print(" ^ String.concat ", " args ^ ")"
  | "string_of_int" -> "Long.toString(" ^ String.concat ", " args ^ ")"
  | "string_of_float" -> "Double.toString(" ^ String.concat ", " args ^ ")"
  | "string_of_bool" -> "Boolean.toString(" ^ String.concat ", " args ^ ")"
  | "failwith" ->
      st.use_fail <- true;
      "_fail(" ^ String.concat ", " args ^ ")"
  | "fst" -> "(" ^ List.hd args ^ ").v0()"
  | "snd" -> "(" ^ List.hd args ^ ").v1()"
  | "List.length" ->
      st.use_list <- true;
      "(" ^ List.hd args ^ ").size()"
  | _ -> name ^ "(" ^ String.concat ", " args ^ ")"

and ctor_expr st e name args =
  match name with
  | "None" -> "null"
  | "Some" -> (
      match args with
      | [ e ] ->
          let vs = materialize st e in
          if is_option (t_of st e) then (
            st.use_somebox <- true;
            (* explicit type argument: `null` payloads cannot drive the
               diamond inference *)
            "new _SomeBox<" ^ jboxed st (t_of st e) ^ ">(" ^ vs ^ ")")
          else vs
      | _ -> "null")
  | _ ->
      (* variant constructor -> record new; payloads evaluate strictly
         left-to-right *)
      let tyargs =
        match t_of st e with
        | TCon (_, ts) when ts <> [] ->
            "<" ^ String.concat ", " (List.map (jboxed st) ts) ^ ">"
        | _ -> ""
      in
      "new " ^ name ^ tyargs ^ "("
      ^ String.concat ", " (ordered_operands st ~force:false args) ^ ")"

and bin_expr st op a b =
  let at = t_of st a and bt = t_of st b in
  (* Operands evaluate strictly left-to-right.  When either operand needs
     ordering (statement-bearing, or a unit-typed side-effecting
     expression), the same discipline as ordered_operands applies: pin the
     LEFT operand first — committing not just its statements but also any
     inline-call side effects to a statement line — then pin the right.  A
     lazy right operand would emit its statements into the buffer before
     the consuming line that runs the left operand's inline call, violating
     source order.  When nothing needs ordering, operand texts stay inline
     in one line and Java's own left-to-right evaluation applies, so pure
     operands never change text.  And/Or are excluded: their right operand
     must stay lazy and is pinned only inside the short-circuit block
     below (short-circuiting is part of the checker's evaluation-order
     contract). *)
  let needs = needs_ordering st ~force:false [a; b] in
  let strict = op <> And && op <> Or in
  let as_ =
    if needs && strict then pin st a
    else if emits_stmts a then materialize st a
    else expr_of st a
  in
  let bs () =
    if needs && strict then pin st b
    else if emits_stmts b then materialize st b
    else expr_of st b
  in
  let s (o : string) = "(" ^ as_ ^ " " ^ o ^ " " ^ bs () ^ ")" in
  match op with
  | Add -> s "+"
  | Sub -> s "-"
  | Mul -> s "*"
  | Div -> s "/"
  | Mod -> s "%"
  | Concat -> s "+"
  | Eq | Ne ->
      if is_primitive at || is_primitive bt then
        s (if op = Eq then "==" else "!=")
      else
        let eq =
          match (at, bt) with
          (* option erasure makes None == null; equality must be null-safe,
             so use Objects.equals (also structural for boxed values) *)
          | TOption _, _ | _, TOption _ ->
              "java.util.Objects.equals(" ^ as_ ^ ", " ^ bs () ^ ")"
          | _ -> "(" ^ as_ ^ ").equals(" ^ bs () ^ ")"
        in
        if op = Eq then eq else "!(" ^ eq ^ ")"
  | Lt | Le | Gt | Ge ->
      let o = match op with Lt -> "<" | Le -> "<=" | Gt -> ">" | _ -> ">=" in
      if is_primitive at then s o
      else
        (* string ordering (checker permits TStr for Lt/Le/Gt/Ge): compareTo *)
        let cmp = "(" ^ as_ ^ ").compareTo(" ^ bs () ^ ")" in
        "(" ^ cmp ^ " " ^ o ^ " 0)"
  | And | Or ->
      if is_pure a && is_pure b then s (if op = And then "&&" else "||")
      else (
        (* statement-bearing operands cannot be evaluated eagerly inside the
           boolean expression: evaluate the left side first, then evaluate
           the right side only when short-circuiting demands it *)
        let t = fresh_tmp st in
        line st ("boolean " ^ t ^ " = " ^ as_ ^ ";");
        line st
          ("if (" ^ (if op = And then t else "!" ^ t) ^ ") {");
        with_indent st (fun () ->
            line st (t ^ " = " ^ bs () ^ ";"));
        line st "}";
        t)

(* Materialize a statement-laden expression into a fresh zero-initialized
   temp; returns the temp name.  A TUnit-typed expression carries no Java
   value: its statements are emitted in order and NO temp is produced, so a
   `void _tN = ...;` declaration can never be emitted. *)
and bind_tmp st e =
  if t_of st e = TUnit then (
    stmt_of st e;
    "")
  else (
    let t = fresh_tmp st in
    let ty = t_of st e in
    line st (jtype st ty ^ " " ^ t ^ " = " ^ zero_of ty ^ ";");
    stmt_into st e t;
    t)

(* Emit statements that compute [e] into declared local [t]. *)
and stmt_into st e t =
  let ty = t_of st e in
  match e.desc with
  | ELet (x, v, body) -> stmt_bind_let st x v (fun () -> stmt_into st body t)
  | ELetMut (x, v, body) -> stmt_bind_let st x v (fun () -> stmt_into st body t)
  | ELetTuple (xs, v, body) ->
      stmt_bind_tuple st xs v (fun () -> stmt_into st body t)
  | ESeq (a, b) ->
      stmt_of st a;
      stmt_into st b t
  | EIf (c, a, b) ->
      if_stmt st c (fun () -> stmt_into st a t) (fun () -> stmt_into st b t)
  | EMatch (s, arms) ->
      let scrut, sty = scrut_text st s in
      emit_arms st sty scrut arms (MVal t)
  | EAssign _ | EWhile _ | EForIn _ | EForRange _ ->
      (* unit-typed effects: run as statement, leave the zero *)
      stmt_of st e;
      line st (t ^ " = " ^ zero_of ty ^ ";")
  | EUnit -> ()
  | _ ->
      let vs = expr_of st e in
      line st (t ^ " = " ^ vs ^ ";")

and stmt_bind_let st x v k =
  if x = "_" || t_of st v = TUnit then (
    stmt_of st v;
    k ())
  else (
    let jn = fresh_binder st x in
    let vs = expr_of st v in
    line st (jtype st (t_of st v) ^ " " ^ jn ^ " = " ^ vs ^ ";");
    push_bind st x jn;
    k ();
    pop_bind st)
and stmt_bind_tuple st xs v k =
  let tv = fresh_tmp st in
  let vt = t_of st v in
  let vs = expr_of st v in
  line st (jtype st vt ^ " " ^ tv ^ " = " ^ vs ^ ";");
  let comps =
    match vt with
    | TTuple ts -> ts
    | _ -> err_at st v.pos "let-tuple destructure of a non-tuple"
  in
  (* a unit-typed component has no Java value: it can never be bound as a
     local (no `void` declaration), so it is skipped *)
  let bound =
    List.filter_map
      (fun (i, x) ->
        if x = "_" then None
        else
          match List.nth_opt comps i with
          | Some TUnit -> None
          | _ -> Some (i, x))
      (List.mapi (fun i x -> (i, x)) xs)
  in
  List.iter
    (fun (i, x) ->
      let jn = fresh_binder st x in
      line st
        (jtype st (List.nth comps i) ^ " " ^ jn ^ " = " ^ tv ^ ".v"
       ^ string_of_int i ^ "();");
      push_bind st x jn)
    bound;
  k ();
  List.iter (fun _ -> pop_bind st) bound

and if_stmt st c a b =
  let cs = expr_of st c in
  line st ("if (" ^ cs ^ ") {");
  with_indent st a;
  line st "} else {";
  with_indent st b;
  line st "}"

(* Evaluate a match scrutinee once; returns (java text, type).  A
   TUnit-typed scrutinee has no Java value: its statements run in place and
   no temp is produced. *)
and scrut_text st s =
  match s.desc with
  | EVar _ | ESelfField _ -> (expr_of st s, t_of st s)
  | _ ->
      let ty = t_of st s in
      if ty = TUnit then (
        stmt_of st s;
        ("", ty))
      else (
        let vs = expr_of st s in
        let t = fresh_tmp st in
        line st (jtype st ty ^ " " ^ t ^ " = " ^ vs ^ ";");
        (t, ty))

and emit_arms st ty scrut arms mode =
  match arms with
  | [] ->
      (* unreachable in a checker-accepted program (exhaustiveness is
         checked, and guarded arms never prove coverage); fail loudly rather
         than silently exposing the zero-initialized result temp *)
      line st "throw new IllegalStateException(\"non-exhaustive match\");"
  | (a : match_arm) :: rest ->
      let conds, binds = compile_pat st ty scrut a.pat in
      let emit_body () =
        match mode with
        | MStmt -> stmt_of st a.rhs
        | MVal t -> stmt_into st a.rhs t
      in
      (match (conds, a.guard) with
      | [], None ->
          (* unconditional arm: remaining arms are dead *)
          emit_binds st binds;
          emit_body ();
          pop_binds st binds
      | _, None ->
          line st ("if (" ^ String.concat " && " conds ^ ") {");
          with_indent st (fun () ->
              emit_binds st binds;
              emit_body ();
              pop_binds st binds);
          line st "} else {";
          with_indent st (fun () -> emit_arms st ty scrut rest mode);
          line st "}"
      | _, Some g ->
          (* Guarded arm.  The remaining chain is emitted ONCE, as a
             labeled block the arm body breaks out of; a guard failure
             falls through to the next arm exactly once.  This keeps the
             emitted Java linear in the arm count (the old nested-else
             form emitted the remaining chain once per guarded arm, i.e.
             2^(N-1) lines for N guarded arms).  The label is fresh per
             match, so nested matches never collide; labels live in their
             own Java namespace, so a label can never collide with a
             variable.  Pattern binds are emitted INSIDE the pattern
             condition block (a payload bind like `((Circle) s).v0()`
             must not be evaluated when the pattern does not match), and
             are in scope for the guard and the arm body; the scope is
             restored for the fall-through path (the remaining arms must
             not see this arm's binds).  Save/restore instead of pop so
             the emission-time scope can never go negative, and the taken
             path (which ends the construct) needs no pop. *)
          let saved = st.scope in
          let lbl = fresh_label st in
          line st (lbl ^ ": {");
          with_indent st (fun () ->
              (match conds with
              | [] ->
                  (* var/wildcard pattern: always matches, no condition *)
                  emit_binds st binds;
                  let gs = expr_of st g in
                  line st ("if (" ^ gs ^ ") {");
                  with_indent st (fun () ->
                      emit_body ();
                      line st ("break " ^ lbl ^ ";"));
                  line st "}"
              | _ ->
                  line st ("if (" ^ String.concat " && " conds ^ ") {");
                  with_indent st (fun () ->
                      emit_binds st binds;
                      let gs = expr_of st g in
                      line st ("if (" ^ gs ^ ") {");
                      with_indent st (fun () ->
                          emit_body ();
                          line st ("break " ^ lbl ^ ";"));
                      line st "}");
                  line st "}"));
          st.scope <- saved;
          with_indent st (fun () -> emit_arms st ty scrut rest mode);
          line st "}")

and emit_binds st binds =
  List.iter
    (fun (ml, jn, jty, src) ->
      (* a unit-typed pattern component has no Java value and can never be
         declared as a local (`void` declaration is illegal); skip it *)
      if jty <> "void" then (
        line st (jty ^ " " ^ jn ^ " = " ^ src ^ ";");
        push_bind st ml jn))
    binds

and pop_binds st binds =
  List.iter (fun (_, _, jty, _) -> if jty <> "void" then pop_bind st) binds

and stmt_of st (e : expr) : unit =
  match e.desc with
  | EUnit -> ()
  | ESeq (a, b) ->
      stmt_of st a;
      stmt_of st b
  | ELet (x, v, body) -> stmt_bind_let st x v (fun () -> stmt_of st body)
  | ELetMut (x, v, body) -> stmt_bind_let st x v (fun () -> stmt_of st body)
  | ELetTuple (xs, v, body) ->
      stmt_bind_tuple st xs v (fun () -> stmt_of st body)
  | EIf (c, a, b) -> if_stmt st c (fun () -> stmt_of st a) (fun () -> stmt_of st b)
  | EWhile (c, b) ->
      if is_pure c then (
        let cs = expr_of st c in
        line st ("while (" ^ cs ^ ") {");
        with_indent st (fun () -> stmt_of st b);
        line st "}")
      else (
        (* a statement-bearing condition must re-evaluate on every iteration;
           only a pure operand can stay in the while head *)
        line st "while (true) {";
        with_indent st (fun () ->
            let t = fresh_tmp st in
            line st ("boolean " ^ t ^ " = false;");
            stmt_into st c t;
            line st ("if (!" ^ t ^ ") break;");
            stmt_of st b);
        line st "}")
  | EForIn (x, xs, body) ->
      let jx = fresh_binder st x in
      let elt = match t_of st xs with TList t -> t | t -> t in
      (* a unit element has no Java value and can never be referenced in
         the body; bind it as Object so no `void` declaration is emitted *)
      let elt_jt = if elt = TUnit then "Object" else jtype st elt in
      (* the list expression evaluates once, before the loop *)
      let xss = pin st xs in
      line st ("for (" ^ elt_jt ^ " " ^ jx ^ " : " ^ xss ^ ") {");
      push_bind st x jx;
      with_indent st (fun () -> stmt_of st body);
      pop_bind st;
      line st "}"
  | EForRange (x, up, lo, hi, b) ->
      let jx = fresh_binder st x in
      (* OCaml evaluates the bounds exactly ONCE; Java re-evaluates the for
         condition each iteration, so impure bounds are pinned into temps *)
      let los = pin st lo in
      let his = pin st hi in
      let (cmp, step) = if up then (" <= ", "++") else (" >= ", "--") in
      line st
        ("for (long " ^ jx ^ " = " ^ los ^ "; " ^ jx ^ cmp ^ his ^ "; " ^ jx
       ^ step ^ ") {");
      push_bind st x jx;
      with_indent st (fun () -> stmt_of st b);
      pop_bind st;
      line st "}"
  | EMatch (s, arms) ->
      let scrut, sty = scrut_text st s in
      emit_arms st sty scrut arms MStmt
  | EAssign (AVar x, v) ->
      let vs = materialize st v in
      line st (lookup st x ^ " = " ^ vs ^ ";")
  | EAssign (AField (r, f), v) ->
      (* the record expression evaluates before the assigned value *)
      let rs = materialize st r in
      let vs = materialize st v in
      line st ("(" ^ rs ^ ")." ^ f ^ " = " ^ vs ^ ";")
  | EBin ((And | Or), _, _) when not (is_pure e) ->
      (* the short-circuit lowering writes its own declaration and if
         statements; there is no value line to emit *)
      ignore (expr_of st e)
  | _ ->
      if not (is_pure e) then
        let vs = expr_of st e in
        (* a unit-typed statement-bearing expression renders to "" (its
           statements were emitted in place); nothing more to write *)
        if vs <> "" then line st (vs ^ ";")

(* tail of a function/method body *)
and bind_ret st (e : expr) : unit =
  match e.desc with
  | ESeq (a, b) ->
      stmt_of st a;
      bind_ret st b
  | _ ->
      if t_of st e = TUnit then stmt_of st e
      else
        let vs = expr_of st e in
        line st ("return " ^ vs ^ ";")

(* ------------------------------------------------------------------ *)
(* declarations                                                        *)
(* ------------------------------------------------------------------ *)

let set_tparams st ps =
  Hashtbl.reset st.tparams;
  List.iteri (fun i p -> Hashtbl.replace st.tparams p (letter_of_index i)) ps

let tparam_decl ps =
  match ps with
  | [] -> ""
  | _ -> "<" ^ String.concat ", " (List.mapi (fun i _ -> letter_of_index i) ps) ^ ">"

(* tparam_decl plus its separating space, or nothing for a monomorphic decl *)
let tparam_decl_sp ps =
  match tparam_decl ps with "" -> "" | s -> s ^ " "

(* distinct free type variables of a signature (params then return type),
   in first-appearance order *)
let sig_tparams params ret =
  let seen = ref [] in
  let rec go t =
    match t with
    | TParam p -> if not (List.mem p !seen) then seen := !seen @ [ p ]
    | TList t -> go t
    | TOption t -> go t
    | TTuple ts -> List.iter go ts
    | TCon (_, ts) -> List.iter go ts
    | _ -> ()
  in
  List.iter (fun (_, t) -> go t) params;
  go ret;
  !seen

let emit_record st (r : record_decl) =
  set_tparams st r.rtparams;
  let tps = tparam_decl r.rtparams in
  let has_mut = List.exists (fun (_, _, m) -> m) r.rfields in
  if not has_mut then
    let comps =
      String.concat ", "
        (List.map (fun (n, t, _) -> jtype st t ^ " " ^ n) r.rfields)
    in
    line st ("public record " ^ r.rname ^ tps ^ "(" ^ comps ^ ") {}")
  else (
    (* mutable field -> final class with public fields, ctor, equals, hashCode *)
    line st ("public static final class " ^ r.rname ^ tps ^ " {");
    with_indent st (fun () ->
        List.iter
          (fun (n, t, m) ->
            line st
              ("public " ^ (if m then "" else "final ") ^ jtype st t ^ " " ^ n
             ^ ";"))
          r.rfields;
        let params =
          String.concat ", "
            (List.map (fun (n, t, _) -> jtype st t ^ " " ^ n) r.rfields)
        in
        line st ("public " ^ r.rname ^ "(" ^ params ^ ") {");
        with_indent st (fun () ->
            List.iter
              (fun (n, _, _) -> line st ("this." ^ n ^ " = " ^ n ^ ";"))
              r.rfields);
        line st "}";
        (* equals: primitive fields with ==, reference fields with
           Objects.equals, matching the SPEC equality rule for records *)
        line st "@Override public boolean equals(Object o) {";
        with_indent st (fun () ->
            line st "if (this == o) return true;";
            line st ("if (!(o instanceof " ^ r.rname ^ ")) return false;");
            line st (r.rname ^ " that = (" ^ r.rname ^ ") o;");
            let cmp (n, t, _) =
              if is_primitive t then "this." ^ n ^ " == that." ^ n
              else "java.util.Objects.equals(this." ^ n ^ ", that." ^ n ^ ")"
            in
            let all = String.concat " && " (List.map cmp r.rfields) in
            line st ("return " ^ (if all = "" then "true" else all) ^ ";"));
        line st "}";
        line st "@Override public int hashCode() {";
        with_indent st (fun () ->
            let args =
              String.concat ", " (List.map (fun (n, _, _) -> "this." ^ n) r.rfields)
            in
            line st ("return java.util.Objects.hash(" ^ args ^ ");"));
        line st "}");
    line st "}")

let emit_variant st (v : variant_decl) =
  set_tparams st v.vtparams;
  let tps = tparam_decl v.vtparams in
  let cnames = List.map fst v.vctors in
  line st
    ("public sealed interface " ^ v.vname ^ tps ^ " permits "
   ^ String.concat ", " cnames ^ " {}");
  List.iter
    (fun (cname, payload) ->
      let comp (i, t) = jtype st t ^ " v" ^ string_of_int i in
      let comps =
        String.concat ", " (List.mapi (fun i t -> comp (i, t)) payload)
      in
      let impl =
        match v.vtparams with
        | [] -> v.vname
        | _ ->
            v.vname ^ "<"
            ^ String.concat ", " (List.mapi (fun i _ -> letter_of_index i) v.vtparams)
            ^ ">"
      in
      line st
        ("public record " ^ cname ^ tps ^ "(" ^ comps ^ ") implements " ^ impl
       ^ " {}"))
    v.vctors

let emit_class_type st (ct : class_type_decl) =
  Hashtbl.reset st.tparams;
  line st ("public interface " ^ ct.ctname ^ " {");
  with_indent st (fun () ->
      List.iter
        (fun (ms : method_sig) ->
          let params =
            List.filter_map
              (fun (n, t) ->
                if t = TUnit then None else Some (jtype st t ^ " " ^ n))
              ms.msparams
          in
          line st
            (jtype st ms.msret ^ " " ^ ms.msname ^ "("
           ^ String.concat ", " params ^ ");"))
        ct.ctmethods);
  line st "}"

(* Fresh local names must never collide with verbatim Java parameter names:
   parameters are emitted verbatim, locals are renamed, so the used-name set
   is seeded with every emitted (non-unit) parameter name at the start of a
   function/method body.  `args` is the verbatim parameter of the Java
   entry point `main(String[] args)`. *)
let seed_used_params st params =
  List.iter
    (fun (n, t) -> if t <> TUnit then Hashtbl.replace st.used n ())
    params

let emit_class st (c : class_decl) =
  Hashtbl.reset st.tparams;
  st.scope <- [];
  let cfields =
    List.map
      (fun (f : cfield) ->
        let t =
          match f.cftyp with Some t -> t | None -> t_of st f.cfinit
        in
        (f.cfname, t))
      c.cfields
  in
  (* unit `()` ctor params are dropped, like unit function params *)
  let cparams = List.filter (fun (_, t) -> t <> TUnit) c.cparams in
  st.cl <- Some { cparams; cfields };
  push_bind st c.cself "this";
  let impl =
    match c.cinherits with
    | [] -> ""
    | is -> " implements " ^ String.concat ", " is
  in
  line st ("public static final class " ^ c.cname ^ impl ^ " {");
  with_indent st (fun () ->
      (* fields: ctor params (private final) + val fields *)
      List.iter
        (fun (n, t) -> line st ("private final " ^ jtype st t ^ " " ^ n ^ ";"))
        cparams;
      List.iter2
        (fun (f : cfield) (_, t) ->
          line st
            ("private " ^ (if f.cfmut then "" else "final ") ^ jtype st t ^ " "
           ^ f.cfname ^ ";"))
        c.cfields cfields;
      (* constructor *)
      let params =
        String.concat ", "
          (List.map (fun (n, t) -> jtype st t ^ " " ^ n) cparams)
      in
      line st ("public " ^ c.cname ^ "(" ^ params ^ ") {");
      with_indent st (fun () ->
          List.iter
            (fun (n, _) -> line st ("this." ^ n ^ " = " ^ n ^ ";"))
            cparams;
          List.iter
            (fun (f : cfield) ->
              let vs = expr_of st f.cfinit in
              line st ("this." ^ f.cfname ^ " = " ^ vs ^ ";"))
            c.cfields);
      line st "}";
      (* methods *)
      List.iter
        (fun (m : method_decl) ->
          let vis = if m.mprivate then "private " else "public " in
          let stat = if m.mstatic then "static " else "" in
          let saved_scope = st.scope in
          let saved_used = Hashtbl.copy st.used in
          let tps = sig_tparams m.mparams m.mret in
          set_tparams st tps;
          seed_used_params st m.mparams;
          List.iter
            (fun (n, t) -> if t <> TUnit then push_bind st n n)
            m.mparams;
          let params =
            List.filter_map
              (fun (n, t) ->
                if t = TUnit then None else Some (jtype st t ^ " " ^ n))
              m.mparams
          in
          line st
            (vis ^ stat ^ tparam_decl_sp tps ^ jtype st m.mret ^ " "
           ^ m.mname ^ "(" ^ String.concat ", " params ^ ") {");
          with_indent st (fun () -> bind_ret st m.mbody);
          line st "}";
          st.scope <- saved_scope;
          st.used <- saved_used)
        c.cmethods);
  line st "}";
  st.cl <- None;
  st.scope <- []

let emit_fun st (f : fun_decl) =
  Hashtbl.reset st.tparams;
  st.scope <- [];
  Hashtbl.reset st.used;
  if f.fparams = [] then
    (* top-level value *)
    let ty = f.fret in
    if ty = TUnit then (
      (* a unit-typed value is pure side effect; no field *)
      if not (is_pure f.fbody) then (
        line st "static {";
        with_indent st (fun () -> stmt_of st f.fbody);
        line st "}"))
    else if is_pure f.fbody then
      let vs = expr_of st f.fbody in
      line st
        ("public static final " ^ jtype st ty ^ " " ^ f.fname ^ " = " ^ vs
       ^ ";")
    else (
      (* statement-bearing initializer: a statement is illegal in the class
         body, so assign the value inside a static initializer block *)
      line st ("public static final " ^ jtype st ty ^ " " ^ f.fname ^ ";");
      line st "static {";
      with_indent st (fun () ->
          let vs = expr_of st f.fbody in
          line st (f.fname ^ " = " ^ vs ^ ";"));
      line st "}")
  else if f.fname = "main" && f.fret = TUnit then (
    (* the Java entry point: `args` is a verbatim parameter name.  Push the
       function's parameters exactly like the normal path below, so an
       arbitrary `main` can never emit broken references again (the
       checker's `let main () : unit` rule makes the push a no-op, but the
       emitter must not contain the hole). *)
    Hashtbl.replace st.used "args" ();
    List.iter
      (fun (n, t) -> if t <> TUnit then push_bind st n n)
      f.fparams;
    line st "public static void main(String[] args) {";
    with_indent st (fun () -> bind_ret st f.fbody);
    line st "}")
  else (
    let tps = sig_tparams f.fparams f.fret in
    set_tparams st tps;
    seed_used_params st f.fparams;
    List.iter
      (fun (n, t) -> if t <> TUnit then push_bind st n n)
      f.fparams;
    let params =
      List.filter_map
        (fun (n, t) -> if t = TUnit then None else Some (jtype st t ^ " " ^ n))
        f.fparams
    in
    line st
      ("public static " ^ tparam_decl_sp tps ^ jtype st f.fret ^ " "
     ^ f.fname ^ "(" ^ String.concat ", " params ^ ") {");
    with_indent st (fun () -> bind_ret st f.fbody);
    line st "}")

let emit_decl st (d : decl) =
  match d with
  | DType (TDRecord r) -> emit_record st r
  | DType (TDVariant v) -> emit_variant st v
  | DType (TDTypeAlias _) ->
      (* aliases expand in the checker; nothing to emit *)
      ()
  | DClassType ct -> emit_class_type st ct
  | DClass c -> emit_class st c
  | DFun f -> emit_fun st f

(* ------------------------------------------------------------------ *)
(* helpers (emitted once per file, only when used)                    *)
(* ------------------------------------------------------------------ *)

let emit_cons_helper st =
  line st "private static <T> List<T> _cons(T x, List<T> xs) {";
  with_indent st (fun () ->
      line st "List<T> r = new java.util.ArrayList<T>();";
      line st "r.add(x);";
      line st "r.addAll(xs);";
      line st "return java.util.Collections.unmodifiableList(r);");
  line st "}"

let emit_fail_helper st =
  line st
    "private static <T> T _fail(String msg) { throw new RuntimeException(msg); }"

let emit_somebox_helper st =
  (* nested options: `Some None` must differ from `None`; the payload of a
     Some whose element type is itself an option is wrapped in this record *)
  line st "public record _SomeBox<T>(T v) {}"

let emit_tuple_record st n =
  let tps = List.init n letter_of_index in
  let decl = "<" ^ String.concat ", " tps ^ ">" in
  let comps =
    String.concat ", "
      (List.mapi (fun i tp -> tp ^ " v" ^ string_of_int i) tps)
  in
  line st
    ("public record Tuple" ^ string_of_int n ^ decl ^ "(" ^ comps ^ ") {}")

(* ------------------------------------------------------------------ *)
(* program                                                             *)
(* ------------------------------------------------------------------ *)

let emit_program ((p : program), (tables : Check.tables)) : string =
  let st = mk_state tables p.file in
  let top =
    Filename.remove_extension (Filename.basename p.file)
  in
  st.indent <- 1;
  List.iter (emit_decl st) p.decls;
  (* helpers, gated on flags set during emission *)
  if st.use_cons then (
    line st "";
    emit_cons_helper st);
  if st.use_fail then (
    line st "";
    emit_fail_helper st);
  if st.use_somebox then (
    line st "";
    emit_somebox_helper st);
  List.iter
    (fun n ->
      line st "";
      emit_tuple_record st n)
    (List.sort compare st.tup_arities);
  let b = Buffer.create 8192 in
  if st.use_list || st.use_cons then
    Buffer.add_string b "import java.util.List;\n\n";
  Buffer.add_string b ("public final class " ^ top ^ " {\n");
  Buffer.add_buffer b st.buf;
  Buffer.add_string b "}\n";
  Buffer.contents b
