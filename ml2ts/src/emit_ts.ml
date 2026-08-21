(* emit_ts.ml — ml2ts v1 TypeScript source emitter.

   Implements the "TypeScript mapping" rules of ml2ts/SPEC.md.  One .mlj
   file becomes one .ts module; declarations sit at module top level (no
   wrapper class, unlike Java).

   Boring choices, documented per SPEC ("pick the boring option and write
   the choice in a comment"):
   - the unit expression `()` is `null`; unit-typed values are never
     materialized (no `void` locals): `()` parameters are dropped from
     signatures, unit-typed call arguments are dropped, unit-typed
     statement expressions emit nothing.
   - statement-laden expressions (let/if/match/seq/loops/assignment) in
     expression position are materialized into a fresh temp: declaration
     and statements are written to the current buffer during expression
     rendering, BEFORE the line that consumes the temp (expressions are
     always rendered to text before their consuming line is written, so
     ordering is correct).
   - match/if result temps are declared with definite assignment
     (`let _t0!: T;`) so tsc's strict definite-assignment check always
     passes; the checker's exhaustiveness proof means the value is never
     observed.  Every match chain still ends in a defensive throw, so a
     checker hole would surface as an exception instead of an invented
     value.
   - a statement-bearing while condition is re-evaluated on every
     iteration (lowered to `while (true) { ...; if (!cond) break; body }`);
     only pure conditions stay in the while head.
   - match  ->  if/else chain on the scrutinee (evaluated once into a
     fresh temp unless it is already a simple variable).  Pattern vars are
     fresh names, so OCaml shadowing maps onto TS without redeclaration
     errors.  Guards become `if (pat && g) { arm; break _mN; }` inside a
     labeled block `_mN: { ... }`; a guard failure falls through to the
     next arm exactly once, so the emitted TS is linear in the arm count.
     A GUARDED arm re-tests the scrutinee's tag after a previous arm's
     standalone `if` has narrowed it, which tsc rejects ("no overlap");
     each guarded arm therefore copies the scrutinee into a fresh const
     (`const _sN: T = scrut;`) before its condition, resetting the
     narrowing.  Unguarded arms use the else-chain form, which narrows
     progressively and needs no copy.
   - option is erased to nullable: Some e -> e, None -> null; Some/None
     patterns are `!== null` / `=== null`.  A nested option (the element
     type is itself an option) is wrapped in a generated `_SomeBox<T>`
     object `{ tag: "_Some", v0: payload }` so that `Some None` and `None`
     stay distinct.
   - tuples become fixed tuples `[t1, t2]`; construction `[a, b]`; fst/snd
     -> `v[0]` / `v[1]`.  A tuple literal whose element types are NOT all
     identical is pinned into an annotated temp (`let _t0: [T1, T2] =
     [a, b];`): an inline mixed literal would widen to a union array
     (`(string | number)[]`) and lose element types, breaking e.g.
     `fst (1, "x") + 3`.  Homogeneous literals stay inline (they widen to
     `T[]`, which is safe in every position).
   - equality: int/float/bool/char/string operands -> `===` / `!==`
     (JS string value semantics); everything else -> generated `_eq(a, b)`
     deep-structural helper (records, variants, lists, options, tuples,
     class instances).  `_eq` compares object keys SORTED, because record
     literals may be written in any field order and OCaml record equality
     is order-independent.  `NaN = NaN` is false via `_eq`'s `a === b`
     first check.
   - ordering on strings lowers to plain `< <= > >=` (JS string comparison
     is lexicographic, matching OCaml); primitive ordering stays plain.
   - int division lowers to `Math.trunc(a / b)` (OCaml int division
     truncates toward zero; JS `/` is float division); `%` stays `%` (JS
     remainder truncates like OCaml `mod`).
   - `let _ = e` binders and unit-typed binders are dropped (only the
     initializer's statements are kept).
   - local binders get unique TS names (counter-suffixed) so shadowing
     works and TS redeclaration errors never fire.
   - top-level statement-bearing values become an IIFE
     `const g0: T = (() => { ...; return _t0; })();` — top-level
     declarations evaluate in source order, so the statements must run at
     the declaration's position.
   - `failwith s` -> `throw new Error(s);` as a statement; in expression
     position `(() => { throw new Error(s); })()`.
   - `print_float` / `string_of_float` go through a generated `_fmt_float`
     helper: JS `String(1.0)` is `"1"` but the shared fixtures expect
     `"1.0"`, `"-0.0"`, `"0.3333333333333333"`.  The helper reproduces
     Java's Double.toString forms: NaN -> "NaN", +/-Infinity, -0.0, and
     appends ".0" to integral values.  This is a deliberate SPEC
     deviation (SPEC.md documents it).
   - `print_string`/`print_int`/`print_float` -> `process.stdout.write`;
     `print_endline` -> `console.log`.  A `declare const process` shim is
     emitted when a process-using builtin appears (Node provides the real
     process at runtime).
   - class instances compare structurally through `_eq` (TS `private`
     fields are ordinary enumerable own properties at runtime, so
     `Object.keys` sees them), matching OCaml's structural `=`.
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
  mutable use_eq : bool;
  mutable use_somebox : bool;
  mutable use_fmt_float : bool;
  mutable use_process : bool;
  mutable use_console : bool;
  mutable has_main : bool;
  tparams : (string, string) Hashtbl.t;  (* 'a -> A/B/... per decl *)
  mutable scope : (string * string) list;        (* ocaml name -> ts name *)
  mutable cl : cls_ctx option;
  (* TS names already taken in the current function/method body: verbatim
     parameter names plus every name handed out by fresh_binder/fresh_tmp.
     Seeded per function/method so a verbatim parameter like `x_b0` or
     `_t0` can never collide with a fresh local (TS rejects redeclaration
     in the same scope). *)
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
    use_eq = false;
    use_somebox = false;
    use_fmt_float = false;
    use_process = false;
    use_console = false;
    has_main = false;
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

(* A TS label for a match chain.  Labels live in their own namespace in
   JS (a label may share a name with a variable), but two labels in the
   same function may not share a name, so the counter is a file-global
   monotone counter like tmpc/bndc: labels are unique across the whole
   file, hence within every function.  The `_m%d` form cannot collide with
   a verbatim parameter either: parameters are emitted verbatim, and `_m0`
   is not a valid OCaml identifier, so no parameter can ever be named
   that. *)
let fresh_label st =
  let jn = Printf.sprintf "_m%d" st.lblc in
  st.lblc <- st.lblc + 1;
  jn

let push_bind st name jname = st.scope <- (name, jname) :: st.scope
let pop_bind st = st.scope <- List.tl st.scope

(* Resolve an OCaml variable name to TS text. *)
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
(* TypeScript type mapping                                            *)
(* ------------------------------------------------------------------ *)

(* 'a 'b -> "A", "B", ... *)
let letter_of_index i =
  if i < 26 then String.make 1 (Char.chr (Char.code 'A' + i))
  else "T" ^ string_of_int (i - 25)

let rec subst_typ (m : (string * typ) list) (t : typ) : typ =
  match t with
  | TParam p -> (
      match List.assoc_opt p m with Some t' -> t' | None -> t)
  | TList t -> TList (subst_typ m t)
  | TOption t -> TOption (subst_typ m t)
  | TTuple ts -> TTuple (List.map (subst_typ m) ts)
  | TCon (n, ts) -> TCon (n, List.map (subst_typ m) ts)
  | other -> other

let is_option (t : typ) : bool = match t with TOption _ -> true | _ -> false

(* Declared type params of a variant/record decl, by decl name. *)
let decl_params st name =
  match Hashtbl.find_opt st.tables.tdecls name with
  | Some (TDVariant v) -> v.vtparams
  | Some (TDRecord r) -> r.rtparams
  | _ -> []

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

let rec jtype st (t : typ) : string =
  match t with
  | TInt | TFloat -> "number"
  | TBool -> "boolean"
  | TChar | TStr -> "string"
  | TUnit -> "void"
  | TParam p -> (
      match Hashtbl.find_opt st.tparams p with
      | Some s -> s
      | None ->
          (* unconstrained type var (checker placeholder @uN): unknown is
             the safe v1 answer *)
          "unknown")
  | TList t -> jtype st t ^ "[]"
  | TOption t ->
      (* option is erased to nullable; a nested option (the element type
         is itself an option) must be wrapped in _SomeBox, otherwise
         `Some None` and `None` would both be null *)
      if is_option t then (
        st.use_somebox <- true;
        "_SomeBox<" ^ jtype st t ^ "> | null")
      else jtype st t ^ " | null"
  | TTuple ts ->
      "[" ^ String.concat ", " (List.map (jtype st) ts) ^ "]"
  | TCon (n, []) -> n
  | TCon (n, ts) -> n ^ "<" ^ String.concat ", " (List.map (jtype st) ts) ^ ">"

(* int/float/bool/char/string compare with === (JS value semantics) *)
let is_value_typed (t : typ) : bool =
  match t with
  | TInt | TFloat | TBool | TChar | TStr -> true
  | _ -> false

(* ------------------------------------------------------------------ *)
(* literals                                                           *)
(* ------------------------------------------------------------------ *)

(* Same escaping as the Java emitter: the output is valid JS.  Every
   backslash, quote, and control character is escaped (control chars as
   lowercase 4-digit hex \uXXXX); all other Unicode passes through verbatim
   as UTF-8. *)
let ts_string s =
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

let ts_char c =
  match c with
  | '\'' -> "'\\''"
  | '\\' -> "'\\\\'"
  | '\n' -> "'\\n'"
  | '\t' -> "'\\t'"
  | '\r' -> "'\\r'"
  | c when Char.code c < 0x20 || Char.code c = 0x7f ->
      Printf.sprintf "'\\u%04x'" (Char.code c)
  | c -> Printf.sprintf "'%c'" c

let jint (i : int) = Printf.sprintf "%d" i

let jfloat (f : float) =
  if f = infinity then "Infinity"
  else if f = neg_infinity then "-Infinity"
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

(* Would evaluating [e] emit TS statements into the buffer?  A call is a
   single atomic TS expression even though it may have side effects, so
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

(* returns (conditions, binds); binds are (ml name, ts name, ts type text,
   source text).  [ty] is the static type of [scrut]. *)
let rec compile_pat st ty scrut p =
  match p with
  | PWild | PUnit -> ([], [])
  | PVar x -> ([], [ (x, fresh_binder st x, jtype st ty, scrut) ])
  | PInt i -> ([ Printf.sprintf "(%s === %d)" scrut i ], [])
  | PStr s -> ([ Printf.sprintf "(%s === %s)" scrut (ts_string s) ], [])
  | PBool b ->
      ([ Printf.sprintf "(%s === %s)" scrut (if b then "true" else "false") ],
       [])
  | PChar c -> ([ Printf.sprintf "(%s === %s)" scrut (ts_char c) ], [])
  | PTuple ps -> tuple_pat st ty scrut ps
  | PCtor ("None", []) -> ([ Printf.sprintf "(%s === null)" scrut ], [])
  | PCtor ("Some", [ inner ]) ->
      let inner_t = match ty with TOption t -> t | t -> t in
      (* payload access: a nested option was wrapped by ctor_expr, so the
         inner value lives in `.v0`; a plain option payload is the value
         itself (erasure) *)
      let payload =
        if is_option inner_t then Printf.sprintf "(%s).v0" scrut else scrut
      in
      let c, b = compile_pat st inner_t payload inner in
      (Printf.sprintf "(%s !== null)" scrut :: c, b)
  | PCtor (name, ps) -> ctor_pat st ty scrut name ps
  | PNil -> ([ Printf.sprintf "(%s).length === 0" scrut ], [])
  | PCons (hp, tp) ->
      let elt_t = match ty with TList t -> t | t -> t in
      let hc, hb =
        compile_pat st elt_t (Printf.sprintf "(%s)[0]" scrut) hp
      in
      let tc, tb =
        compile_pat st ty (Printf.sprintf "(%s).slice(1)" scrut) tp
      in
      (Printf.sprintf "(%s).length > 0" scrut :: hc @ tc, hb @ tb)

and tuple_pat st ty scrut ps =
  let ts = match ty with TTuple ts -> ts | _ -> [] in
  let cs = ref [] and bs = ref [] in
  List.iteri
    (fun i child ->
      let elt = match List.nth_opt ts i with Some t -> t | None -> ty in
      let sc, sb =
        compile_pat st elt (Printf.sprintf "(%s)[%d]" scrut i) child
      in
      cs := !cs @ sc;
      bs := !bs @ sb)
    ps;
  (!cs, !bs)

and ctor_pat st ty scrut name ps =
  let targs = match ty with TCon (_, a) -> a | _ -> [] in
  let cond = Printf.sprintf "(%s).tag === \"%s\"" scrut name in
  match ps with
  | [] -> ([ cond ], [])
  | _ ->
      let cs = ref [ cond ] and bs = ref [] in
      List.iteri
        (fun i child ->
          let pt = payload_typ st name targs i in
          let sc, sb =
            compile_pat st pt (Printf.sprintf "(%s).v%d" scrut i) child
          in
          cs := !cs @ sc;
          bs := !bs @ sb)
        ps;
      (!cs, !bs)

and expr_of st (e : expr) : string =
  match e.desc with
  | EUnit -> "null"
  | EInt i -> jint i
  | EFloat f -> jfloat f
  | EBool b -> if b then "true" else "false"
  | EChar c -> ts_char c
  | EStr s -> ts_string s
  | EVar x -> lookup st x
  | ESelfField n -> "this." ^ n
  | ETyped (e, _) -> expr_of st e
  | ETuple es -> tuple_expr st es
  | EList [] -> "[]"
  | EList es ->
      (* elements evaluate strictly left-to-right *)
      "[" ^ String.concat ", " (ordered_operands st ~force:false es) ^ "]"
  | ECons (x, xs) ->
      (* head evaluates before tail, left-to-right *)
      let args = ordered_operands st ~force:false [x; xs] in
      "[" ^ List.hd args ^ ", ..." ^ List.nth args 1 ^ "]"
  | ERecord fs -> record_expr st e fs
  | EField (r, f) -> field_expr st r f
  | ECall (recv, m, args) -> call_expr st recv m args
  | ELocalCall (name, args) -> local_call st name args
  | ECtor (name, args) -> ctor_expr st e name args
  | ENew (c, args) ->
      (* arguments evaluate strictly left-to-right; unit-typed `()` ctor
         args are dropped from the TS argument list exactly like function
         call arguments (materialize_args), since the ctor declaration
         drops unit params — their statements still run at their source
         position *)
      "new " ^ c ^ "(" ^ String.concat ", " (materialize_args st args) ^ ")"
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
          line st ("let " ^ t ^ "!: " ^ jtype st ty ^ ";");
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
          line st ("let " ^ t ^ ": " ^ jtype st ty ^ " = " ^ vs ^ ";");
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
   left-to-right; otherwise all operand texts stay inline (JS already
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
   have no TS value and are dropped from the argument list, but their
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
  let ts = List.map (t_of st) es in
  let args = ordered_operands st ~force:false es in
  let lit = "[" ^ String.concat ", " args ^ "]" in
  if List.for_all (fun t -> t = List.hd ts) ts then lit
  else (
    (* mixed element types: an inline literal would widen to a union array
       and lose element types (e.g. `fst (1, "x")` -> `(string | number)[]`),
       so pin it into an annotated temp *)
    let t = fresh_tmp st in
    line st ("let " ^ t ^ ": " ^ jtype st (TTuple ts) ^ " = " ^ lit ^ ";");
    t)

and record_expr st _e fs =
  (* record fields evaluate strictly left-to-right IN SOURCE ORDER; the
     object literal keeps source order (field access is by name, so
     declaration order is irrelevant in TS) *)
  let texts = ordered_operands st ~force:false (List.map snd fs) in
  let fields = List.map2 (fun (n, _) t -> n ^ ": " ^ t) fs texts in
  "{ " ^ String.concat ", " fields ^ " }"

and field_expr st r f =
  (* the record operand evaluates before the field access *)
  let rs = materialize st r in
  "(" ^ rs ^ ")." ^ f

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
  | "print_string" ->
      st.use_process <- true;
      "process.stdout.write(" ^ String.concat ", " args ^ ")"
  | "print_endline" ->
      st.use_console <- true;
      "console.log(" ^ String.concat ", " args ^ ")"
  | "print_int" ->
      st.use_process <- true;
      "process.stdout.write(String(" ^ String.concat ", " args ^ "))"
  | "print_float" ->
      st.use_process <- true;
      st.use_fmt_float <- true;
      "process.stdout.write(_fmt_float(" ^ String.concat ", " args ^ "))"
  | "string_of_int" -> "String(" ^ String.concat ", " args ^ ")"
  | "string_of_float" ->
      st.use_fmt_float <- true;
      "_fmt_float(" ^ String.concat ", " args ^ ")"
  | "string_of_bool" -> "String(" ^ String.concat ", " args ^ ")"
  | "failwith" ->
      "(() => { throw new Error(" ^ String.concat ", " args ^ "); })()"
  | "fst" -> "(" ^ List.hd args ^ ")[0]"
  | "snd" -> "(" ^ List.hd args ^ ")[1]"
  | "List.length" -> "(" ^ List.hd args ^ ").length"
  | _ -> name ^ "(" ^ String.concat ", " args ^ ")"

and ctor_expr st _e name args =
  match name with
  | "None" -> "null"
  | "Some" -> (
      match args with
      | [ e ] ->
          let vs = materialize st e in
          if is_option (t_of st e) then (
            st.use_somebox <- true;
            (* nested option: wrap the payload so `Some None` differs from
               `None` *)
            "{ tag: \"_Some\", v0: " ^ vs ^ " }")
          else vs
      | _ -> "null")
  | _ ->
      (* variant constructor -> object literal; payloads evaluate strictly
         left-to-right *)
      let payload = ordered_operands st ~force:false args in
      (match payload with
      | [] -> "{ tag: \"" ^ name ^ "\" }"
      | _ ->
          let comps =
            List.mapi (fun i t -> "v" ^ string_of_int i ^ ": " ^ t) payload
          in
          "{ tag: \"" ^ name ^ "\", " ^ String.concat ", " comps ^ " }")

and bin_expr st op a b =
  let at = t_of st a in
  (* Operands evaluate strictly left-to-right.  When either operand needs
     ordering (statement-bearing, or a unit-typed side-effecting
     expression), the same discipline as ordered_operands applies: pin the
     LEFT operand first — committing not just its statements but also any
     inline-call side effects to a statement line — then pin the right.  A
     lazy right operand would emit its statements into the buffer before
     the consuming line that runs the left operand's inline call, violating
     source order.  When nothing needs ordering, operand texts stay inline
     in one line and JS's own left-to-right evaluation applies, so pure
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
  | Div ->
      if at = TInt then
        (* OCaml int division truncates toward zero; JS / is float *)
        "Math.trunc(" ^ as_ ^ " / " ^ bs () ^ ")"
      else s "/"
  | Mod -> s "%"
  | Concat -> s "+"
  | Eq | Ne ->
      if is_value_typed at then (
        (* TS infers LITERAL types for inline literals; comparing two
           different literals (`1 <> 2` -> `1 !== 2`) then fails with
           "no overlap".  A no-op `as T` cast on each literal operand
           widens it back to its plain type (`(1 as number) !== (2 as
           number)`). *)
        let rec is_literal e =
          match e.desc with
          | EInt _ | EFloat _ | EBool _ | EChar _ | EStr _ -> true
          | ETyped (e', _) -> is_literal e'
          | _ -> false
        in
        let widen e txt =
          if is_literal e then
            "(" ^ txt ^ " as " ^ jtype st (t_of st e) ^ ")"
          else txt
        in
        let a' = widen a as_ in
        let btxt = bs () in
        let b' = widen b btxt in
        "(" ^ a' ^ " " ^ (if op = Eq then "===" else "!==") ^ " " ^ b' ^ ")")
      else (
        st.use_eq <- true;
        let eq = "_eq(" ^ as_ ^ ", " ^ bs () ^ ")" in
        if op = Eq then eq else "!(" ^ eq ^ ")")
  | Lt | Le | Gt | Ge ->
      let o = match op with Lt -> "<" | Le -> "<=" | Gt -> ">" | _ -> ">=" in
      (* string ordering: JS < on strings is lexicographic, matching OCaml *)
      s o
  | And | Or ->
      if is_pure a && is_pure b then s (if op = And then "&&" else "||")
      else (
        (* statement-bearing operands cannot be evaluated eagerly inside the
           boolean expression: evaluate the left side first, then evaluate
           the right side only when short-circuiting demands it *)
        let t = fresh_tmp st in
        line st ("let " ^ t ^ ": boolean = " ^ as_ ^ ";");
        line st
          ("if (" ^ (if op = And then t else "!" ^ t) ^ ") {");
        with_indent st (fun () ->
            line st (t ^ " = " ^ bs () ^ ";"));
        line st "}";
        t)

(* Materialize a statement-laden expression into a fresh definite-assigned
   temp; returns the temp name.  A TUnit-typed expression carries no TS
   value: its statements are emitted in order and NO temp is produced, so a
   `void _tN = ...;` declaration can never be emitted. *)
and bind_tmp st e =
  if t_of st e = TUnit then (
    stmt_of st e;
    "")
  else (
    let t = fresh_tmp st in
    let ty = t_of st e in
    line st ("let " ^ t ^ "!: " ^ jtype st ty ^ ";");
    stmt_into st e t;
    t)

(* Emit statements that compute [e] into declared local [t]. *)
and stmt_into st e t =
  match e.desc with
  | ELet (x, v, body) ->
      stmt_bind_let st ~mut:false x v (fun () -> stmt_into st body t)
  | ELetMut (x, v, body) ->
      stmt_bind_let st ~mut:true x v (fun () -> stmt_into st body t)
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
      (* unit-typed effects: run as statement; the `!` definite-assignment
         covers the declared temp (unreachable for non-unit temps anyway) *)
      stmt_of st e
  | EUnit -> ()
  | _ ->
      let vs = expr_of st e in
      line st (t ^ " = " ^ vs ^ ";")

and stmt_bind_let st ~mut x v k =
  if x = "_" || t_of st v = TUnit then (
    stmt_of st v;
    k ())
  else (
    let jn = fresh_binder st x in
    let vs = expr_of st v in
    line st
      ((if mut then "let " else "const ") ^ jn ^ ": " ^ jtype st (t_of st v)
     ^ " = " ^ vs ^ ";");
    push_bind st x jn;
    k ();
    pop_bind st)

and stmt_bind_tuple st xs v k =
  let tv = fresh_tmp st in
  let vt = t_of st v in
  let vs = expr_of st v in
  line st ("let " ^ tv ^ ": " ^ jtype st vt ^ " = " ^ vs ^ ";");
  let comps =
    match vt with
    | TTuple ts -> ts
    | _ -> err_at st v.pos "let-tuple destructure of a non-tuple"
  in
  (* `_` components are skipped; the checker forbids unit inside tuples, so
     every component has a value *)
  let bound =
    List.filter_map
      (fun (i, x) -> if x = "_" then None else Some (i, x))
      (List.mapi (fun i x -> (i, x)) xs)
  in
  List.iter
    (fun (i, x) ->
      let jn = fresh_binder st x in
      line st
        ("const " ^ jn ^ ": " ^ jtype st (List.nth comps i) ^ " = " ^ tv
       ^ "[" ^ string_of_int i ^ "];");
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

(* Evaluate a match scrutinee once; returns (ts text, type).  A
   TUnit-typed scrutinee has no TS value: its statements run in place and
   no temp is produced. *)
and scrut_text st s =
  match s.desc with
  | EVar _ | ESelfField _ -> (expr_of st s, t_of st s)
  | _ ->
      let ty = t_of st s in
      if ty = TUnit then (
        stmt_of st s;
        ("", ty))
      else if emits_stmts s then (
        let t = fresh_tmp st in
        line st ("let " ^ t ^ "!: " ^ jtype st ty ^ ";");
        stmt_into st s t;
        (t, ty))
      else (
        let vs = expr_of st s in
        let t = fresh_tmp st in
        line st ("let " ^ t ^ ": " ^ jtype st ty ^ " = " ^ vs ^ ";");
        (t, ty))

and emit_arms st ty scrut arms mode =
  match arms with
  | [] ->
      (* unreachable in a checker-accepted program (exhaustiveness is
         checked, and guarded arms never prove coverage); fail loudly
         rather than silently exposing the definite-assigned result temp *)
      line st "throw new Error(\"non-exhaustive match\");"
  | (a : match_arm) :: rest ->
      let emit_body () =
        match mode with
        | MStmt -> stmt_of st a.rhs
        | MVal t -> stmt_into st a.rhs t
      in
      (match a.guard with
      | None ->
          let conds, binds = compile_pat st ty scrut a.pat in
          (match conds with
          | [] ->
              (* unconditional arm: remaining arms are dead *)
              emit_binds st binds;
              emit_body ();
              pop_binds st binds
          | _ ->
              line st ("if (" ^ String.concat " && " conds ^ ") {");
              with_indent st (fun () ->
                  emit_binds st binds;
                  emit_body ();
                  pop_binds st binds);
              line st "} else {";
              with_indent st (fun () -> emit_arms st ty scrut rest mode);
              line st "}")
      | Some g ->
          (* Guarded arm.  The remaining chain is emitted ONCE, as a
             labeled block the arm body breaks out of; a guard failure
             falls through to the next arm exactly once.  This keeps the
             emitted TS linear in the arm count.  The label is fresh per
             match, so nested matches never collide; labels live in their
             own JS namespace, so a label can never collide with a
             variable.  Pattern binds are emitted INSIDE the pattern
             condition block (a payload bind like `(s).v0` must not be
             evaluated when the pattern does not match), and are in scope
             for the guard and the arm body; the scope is restored for the
             fall-through path (the remaining arms must not see this
             arm's binds).  Save/restore instead of pop so the
             emission-time scope can never go negative, and the taken
             path (which ends the construct) needs no pop.
             A ctor/option pattern re-tests the scrutinee's tag after a
             previous arm's standalone `if` has narrowed it, which tsc
             rejects ("no overlap"); a fresh const copy of the scrutinee
             per guarded arm resets the narrowing. *)
          let saved = st.scope in
          let lbl = fresh_label st in
          line st (lbl ^ ": {");
          with_indent st (fun () ->
              let conds, binds = compile_pat st ty scrut a.pat in
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
                  let copy = fresh_tmp st in
                  line st
                    ("const " ^ copy ^ ": " ^ jtype st ty ^ " = " ^ scrut
                   ^ ";");
                  let conds', binds' = compile_pat st ty copy a.pat in
                  line st ("if (" ^ String.concat " && " conds' ^ ") {");
                  with_indent st (fun () ->
                      emit_binds st binds';
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
      (* a unit-typed pattern component has no TS value and can never be
         declared as a local (`void` declaration is illegal); skip it *)
      if jty <> "void" then (
        line st ("const " ^ jn ^ ": " ^ jty ^ " = " ^ src ^ ";");
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
  | ELet (x, v, body) ->
      stmt_bind_let st ~mut:false x v (fun () -> stmt_of st body)
  | ELetMut (x, v, body) ->
      stmt_bind_let st ~mut:true x v (fun () -> stmt_of st body)
  | ELetTuple (xs, v, body) ->
      stmt_bind_tuple st xs v (fun () -> stmt_of st body)
  | EIf (c, a, b) ->
      if_stmt st c (fun () -> stmt_of st a) (fun () -> stmt_of st b)
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
            line st ("let " ^ t ^ "!: boolean;");
            stmt_into st c t;
            line st ("if (!" ^ t ^ ") break;");
            stmt_of st b);
        line st "}")
  | EForIn (x, xs, body) ->
      let jx = fresh_binder st x in
      (* the list expression evaluates once, before the loop; the element
         type is inferred from the list's type (TS forbids a type
         annotation on a for-of variable) *)
      let xss = pin st xs in
      line st ("for (const " ^ jx ^ " of " ^ xss ^ ") {");
      push_bind st x jx;
      with_indent st (fun () -> stmt_of st body);
      pop_bind st;
      line st "}"
  | EForRange (x, lo, hi, b) ->
      let jx = fresh_binder st x in
      (* OCaml evaluates the bounds exactly ONCE; JS re-evaluates the for
         condition each iteration, so impure bounds are pinned into temps *)
      let los = pin st lo in
      let his = pin st hi in
      line st
        ("for (let " ^ jx ^ ": number = " ^ los ^ "; " ^ jx ^ " <= " ^ his
       ^ "; " ^ jx ^ "++) {");
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
  | ELocalCall ("failwith", [ s ]) ->
      (* statement position: a plain throw, no IIFE *)
      let vs = materialize st s in
      line st ("throw new Error(" ^ vs ^ ");")
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
  | _ ->
      "<"
      ^ String.concat ", "
          (List.mapi (fun i _ -> letter_of_index i) ps)
      ^ ">"

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
  let fields =
    String.concat "; "
      (List.map
         (fun (n, t, m) ->
           (if m then "" else "readonly ") ^ n ^ ": " ^ jtype st t)
         r.rfields)
  in
  line st ("interface " ^ r.rname ^ tps ^ " { " ^ fields ^ " }")

let emit_variant st (v : variant_decl) =
  set_tparams st v.vtparams;
  let tps = tparam_decl v.vtparams in
  let arms =
    List.map
      (fun (cname, payload) ->
        match payload with
        | [] -> "{ tag: \"" ^ cname ^ "\" }"
        | _ ->
            "{ tag: \"" ^ cname ^ "\"; "
            ^ String.concat "; "
                (List.mapi
                   (fun i t -> "v" ^ string_of_int i ^ ": " ^ jtype st t)
                   payload)
            ^ " }")
      v.vctors
  in
  line st ("type " ^ v.vname ^ tps ^ " = " ^ String.concat " | " arms ^ ";")

let emit_class_type st (ct : class_type_decl) =
  Hashtbl.reset st.tparams;
  line st ("interface " ^ ct.ctname ^ " {");
  with_indent st (fun () ->
      List.iter
        (fun (ms : method_sig) ->
          let params =
            List.filter_map
              (fun (n, t) ->
                if t = TUnit then None else Some (n ^ ": " ^ jtype st t))
              ms.msparams
          in
          line st
            (ms.msname ^ "(" ^ String.concat ", " params ^ "): "
           ^ jtype st ms.msret ^ ";"))
        ct.ctmethods);
  line st "}"

(* Fresh local names must never collide with verbatim TS parameter names:
   parameters are emitted verbatim, locals are renamed, so the used-name set
   is seeded with every emitted (non-unit) parameter name at the start of a
   function/method body. *)
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
  line st ("class " ^ c.cname ^ impl ^ " {");
  with_indent st (fun () ->
      (* fields: ctor params (private readonly) + val fields *)
      List.iter
        (fun (n, t) ->
          line st ("private readonly " ^ n ^ ": " ^ jtype st t ^ ";"))
        cparams;
      List.iter2
        (fun (f : cfield) (_, t) ->
          line st
            ("private " ^ (if f.cfmut then "" else "readonly ") ^ f.cfname
           ^ ": " ^ jtype st t ^ ";"))
        c.cfields cfields;
      (* constructor *)
      let params =
        String.concat ", "
          (List.map (fun (n, t) -> n ^ ": " ^ jtype st t) cparams)
      in
      line st ("constructor(" ^ params ^ ") {");
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
          let vis = if m.mprivate then "private " else "" in
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
                if t = TUnit then None else Some (n ^ ": " ^ jtype st t))
              m.mparams
          in
          line st
            (vis ^ stat ^ m.mname ^ tparam_decl_sp tps ^ "("
           ^ String.concat ", " params ^ "): " ^ jtype st m.mret ^ " {");
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
      (* a unit-typed value is pure side effect; no const *)
      if not (is_pure f.fbody) then stmt_of st f.fbody)
    else if is_pure f.fbody then
      let vs = expr_of st f.fbody in
      line st ("const " ^ f.fname ^ ": " ^ jtype st ty ^ " = " ^ vs ^ ";")
    else (
      (* statement-bearing initializer: an IIFE keeps the statements at the
         declaration's position (top-level declarations evaluate in source
         order) *)
      line st ("const " ^ f.fname ^ ": " ^ jtype st ty ^ " = (() => {");
      with_indent st (fun () -> bind_ret st f.fbody);
      line st "})();")
  else if f.fname = "main" && f.fret = TUnit then (
    (* the TS entry point: a trailing `main();` call is appended by
       emit_program.  Push the function's parameters exactly like the
       normal path below, so an arbitrary `main` can never emit broken
       references again (the checker's `let main () : unit` rule makes the
       push a no-op, but the emitter must not contain the hole). *)
    st.has_main <- true;
    seed_used_params st f.fparams;
    List.iter
      (fun (n, t) -> if t <> TUnit then push_bind st n n)
      f.fparams;
    line st "function main(): void {";
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
        (fun (n, t) -> if t = TUnit then None else Some (n ^ ": " ^ jtype st t))
        f.fparams
    in
    line st
      ("function " ^ f.fname ^ tparam_decl_sp tps ^ "("
     ^ String.concat ", " params ^ "): " ^ jtype st f.fret ^ " {");
    with_indent st (fun () -> bind_ret st f.fbody);
    line st "}")

let emit_decl st (d : decl) =
  match d with
  | DType (TDRecord r) -> emit_record st r
  | DType (TDVariant v) -> emit_variant st v
  | DClassType ct -> emit_class_type st ct
  | DClass c -> emit_class st c
  | DFun f -> emit_fun st f

(* ------------------------------------------------------------------ *)
(* helpers (emitted once per file, only when used)                    *)
(* ------------------------------------------------------------------ *)

let emit_eq_helper st =
  line st "function _eq(a: any, b: any): boolean {";
  with_indent st (fun () ->
      line st "if (a === b) return true;";
      line st "if (a === null || b === null) return false;";
      line st "if (Array.isArray(a) !== Array.isArray(b)) return false;";
      line st "if (Array.isArray(a) && Array.isArray(b)) {";
      with_indent st (fun () ->
          line st "if (a.length !== b.length) return false;";
          line st
            "for (let i = 0; i < a.length; i++) if (!_eq(a[i], b[i])) return false;";
          line st "return true;");
      line st "}";
      line st "if (typeof a === \"object\" && typeof b === \"object\") {";
      with_indent st (fun () ->
          (* keys are compared SORTED: record literals may be written in
             any field order and OCaml record equality is order-independent *)
          line st "const ka = Object.keys(a).sort();";
          line st "const kb = Object.keys(b).sort();";
          line st "if (ka.length !== kb.length) return false;";
          line st "for (let i = 0; i < ka.length; i++) {";
          with_indent st (fun () ->
              line st "if (ka[i] !== kb[i]) return false;";
              line st "if (!_eq(a[ka[i]], b[kb[i]])) return false;");
          line st "}";
          line st "return true;");
      line st "}";
      line st "return false;");
  line st "}"

let emit_somebox_helper st =
  (* nested options: `Some None` must differ from `None`; the payload of a
     Some whose element type is itself an option is wrapped in this object *)
  line st "type _SomeBox<T> = { tag: \"_Some\"; v0: T };"

let emit_fmt_float_helper st =
  (* JS String(1.0) is "1" but the shared fixtures expect "1.0", "-0.0",
     "0.3333333333333333"; reproduce Java's Double.toString forms *)
  line st "function _fmt_float(x: number): string {";
  with_indent st (fun () ->
      line st "if (Number.isNaN(x)) return \"NaN\";";
      line st "if (x === Infinity) return \"Infinity\";";
      line st "if (x === -Infinity) return \"-Infinity\";";
      line st "if (Object.is(x, -0)) return \"-0.0\";";
      line st "const s = String(x);";
      line st
        "if (s.indexOf(\".\") >= 0 || s.indexOf(\"e\") >= 0 || s.indexOf(\"E\") >= 0) return s;";
      line st "return s + \".0\";");
  line st "}"

let emit_process_helper st =
  (* typed shim for the Node `process` global; Node provides the real one
     at runtime *)
  line st "declare const process: { stdout: { write(s: string): void } };"

let emit_console_helper st =
  (* typed shim for the Node `console` global; Node provides the real one
     at runtime *)
  line st "declare const console: { log(s: string): void };"

(* ------------------------------------------------------------------ *)
(* program                                                             *)
(* ------------------------------------------------------------------ *)

let emit_program ((p : program), (tables : Check.tables)) : string =
  let st = mk_state tables p.file in
  List.iter (emit_decl st) p.decls;
  (* helpers, gated on flags set during emission; function declarations
     and ambient declarations hoist, so emitting them after the decls is
     fine *)
  if st.use_eq then (
    line st "";
    emit_eq_helper st);
  if st.use_somebox then (
    line st "";
    emit_somebox_helper st);
  if st.use_fmt_float then (
    line st "";
    emit_fmt_float_helper st);
  if st.use_process then (
    line st "";
    emit_process_helper st);
  if st.use_console then (
    line st "";
    emit_console_helper st);
  if st.has_main then (
    line st "";
    line st "main();");
  Buffer.contents st.buf
