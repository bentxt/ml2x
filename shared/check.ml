(* check.ml — semantic checker for the v1 ml2java profile.

   Runs after parse, before emission.  Two passes over the declaration list:
   1. register every declaration into the tables (tdecls, ctors, classes,
      funcs, class_types), detecting duplicate names;
   2. type-check every declaration body, validating:
        - unknown names / types / constructors / methods / classes,
        - arity (partial application is an error; too many args is an error),
        - operand types of operators (including primitive-vs-object equality:
          both operands must unify),
        - mutability rules (immutable bindings, non-mutable fields),
        - assignment targets (local variable vs record field),
        - private / static member access,
        - match exhaustiveness for variants / options / lists (or wildcard),
        - declared vs inferred return types,
        - interface completeness for `inherit`,
      rewriting bare field/ctor-parameter EVar references inside methods to
      ESelfField, and filling tables.types for every expression id.

   Boring choices where SPEC.md is silent:
   - Unification variables are fresh TParam("u<k>") names bound in a side
     table; free TParams from annotations unify with anything.
   - Subsumption: a class value unifies with a class type it inherits, so a
     `greeter` value can be annotated `printable`.
   - Top-level `let x = e` values (fparams = []) get their inferred type
     written back into fun_decl.fret; an annotated value arrives with an
     ETyped body (parser convention) and no type may remain unresolved.
   - Exhaustiveness: variant scrutinees need every constructor (or a wildcard
     arm); option scrutinees need Some + None; lists need [] + x :: xs;
     everything else needs a wildcard/var/tuple arm.  Guarded arms never
     count toward coverage (a guard can fail at runtime), so an unguarded
     arm must cover every case.
   - Declarations carry the position of their head keyword; declaration-level
     errors point at it.
*)

open Ast

type tables = {
  types : (int, Ast.typ) Hashtbl.t;
  tdecls : (string, Ast.type_decl) Hashtbl.t;
  ctors : (string, string * Ast.typ list) Hashtbl.t;
  classes : (string, Ast.class_decl) Hashtbl.t;
  funcs : (string, Ast.fun_decl) Hashtbl.t;
  class_types : (string, Ast.class_type_decl) Hashtbl.t;
}

type st = {
  file : string;
  profile : Profile.t;
  types : (int, typ) Hashtbl.t;
  (* expr id -> source position, for the end-of-check no-unit sweep *)
  poss : (int, Ast.pos) Hashtbl.t;
  tdecls : (string, type_decl) Hashtbl.t;
  ctors : (string, string * typ list) Hashtbl.t;
  classes : (string, class_decl) Hashtbl.t;
  funcs : (string, fun_decl) Hashtbl.t;
  class_types : (string, class_type_decl) Hashtbl.t;
  subst : (string, typ) Hashtbl.t;
  mutable uvarc : int;
  (* names of unification variables created by the checker (TParam "u<k>") *)
  uvars : (string, unit) Hashtbl.t;
  (* expression ids recorded since the start of the current declaration,
     reified (resolved + uvar-renamed) when the declaration finishes *)
  mutable pending : int list;
  (* functions and values whose bodies have been checked (no forward refs) *)
  defined : (string, unit) Hashtbl.t;
}

(* unification failure; converted into a located error at the call site *)
exception Type_mismatch of typ * typ

let errp st pos msg =
  raise (Front_error (format_error ~file:st.file pos msg))

let err st (e : expr) msg = errp st e.pos msg

(* ---------------- unification ---------------- *)

let fresh st =
  let n = st.uvarc in
  st.uvarc <- n + 1;
  let p = "u" ^ string_of_int n in
  Hashtbl.replace st.uvars p ();
  TParam p

let rec resolve st (t : typ) : typ =
  match t with
  | TParam p -> (
      match Hashtbl.find_opt st.subst p with
      | Some t -> resolve st t
      | None -> t)
  | TList t -> TList (resolve st t)
  | TOption t -> TOption (resolve st t)
  | TTuple ts -> TTuple (List.map (resolve st) ts)
  | TCon (n, ts) -> TCon (n, List.map (resolve st) ts)
  | _ -> t

let rec occurs st p (t : typ) : bool =
  match t with
  | TParam q -> String.equal p q
  | TList t | TOption t -> occurs st p t
  | TTuple ts -> List.exists (occurs st p) ts
  | TCon (_, ts) -> List.exists (occurs st p) ts
  | _ -> false

let bind_var st p (t : typ) =
  if occurs st p t then raise (Type_mismatch (TParam p, t))
  else Hashtbl.replace st.subst p t

let rec unify st (a : typ) (b : typ) : unit =
  let a = resolve st a and b = resolve st b in
  match (a, b) with
  | TParam p, TParam q when String.equal p q -> ()
  | TParam p, _ -> bind_var st p b
  | _, TParam p -> bind_var st p a
  | TInt, TInt | TFloat, TFloat | TBool, TBool | TChar, TChar
  | TStr, TStr | TUnit, TUnit ->
      ()
  | TList x, TList y | TOption x, TOption y -> unify st x y
  | TTuple xs, TTuple ys ->
      if List.length xs <> List.length ys then raise (Type_mismatch (a, b));
      List.iter2 (unify st) xs ys
  | TCon (n, xs), TCon (m, ys) when String.equal n m ->
      if List.length xs <> List.length ys then raise (Type_mismatch (a, b));
      List.iter2 (unify st) xs ys
  | TCon (n, _), TCon (m, _) -> (
      (* a class value stands where a class type it inherits is expected *)
      let inherits_of cname =
        match Hashtbl.find_opt st.classes cname with
        | Some c -> c.cinherits
        | None -> []
      in
      if List.mem m (inherits_of n) || List.mem n (inherits_of m) then ()
      else raise (Type_mismatch (a, b)))
  | _ -> raise (Type_mismatch (a, b))

(* ---------------- printing / annotation validation ---------------- *)

let rec show st (t : typ) : string =
  match resolve st t with
  | TInt -> "int"
  | TFloat -> "float"
  | TBool -> "bool"
  | TChar -> "char"
  | TStr -> "string"
  | TUnit -> "unit"
  | TParam p -> "'" ^ p
  | TList t -> "(" ^ show st t ^ ") list"
  | TOption t -> "(" ^ show st t ^ ") option"
  | TTuple ts -> String.concat " * " (List.map (show st) ts)
  | TCon (n, []) -> n
  | TCon (n, ts) -> n ^ "<" ^ String.concat ", " (List.map (show st) ts) ^ ">"

(* located wrappers around unify *)
let unify_at st (e : expr) (a : typ) (b : typ) =
  try unify st a b
  with Type_mismatch (x, y) ->
    err st e
      (Printf.sprintf "type mismatch: expected %s, found %s" (show st x)
         (show st y))

let unify_at_pos st pos (a : typ) (b : typ) =
  try unify st a b
  with Type_mismatch (x, y) ->
    errp st pos
      (Printf.sprintf "type mismatch: expected %s, found %s" (show st x)
         (show st y))

(* unit has no Java value: it may appear only as a whole expression/type,
   never inside a list, option, tuple, or type argument *)
let rec has_unit_inside (t : typ) : bool =
  match t with
  | TList t | TOption t -> t = TUnit || has_unit_inside t
  | TTuple ts -> List.exists (fun t -> t = TUnit || has_unit_inside t) ts
  | TCon (_, ts) -> List.exists (fun t -> t = TUnit || has_unit_inside t) ts
  | _ -> false

let check_no_unit st ~at (t : typ) =
  if has_unit_inside t then
    errp st at
      "type unit is not allowed inside list, option, tuple, or type-argument \
       positions (Java has no void value)"

(* substitute declaration type parameters with concrete types *)
let rec subst_params (env : (string * typ) list) (t : typ) : typ =
  match t with
  | TParam p -> (
      match List.assoc_opt p env with Some t -> t | None -> t)
  | TList t -> TList (subst_params env t)
  | TOption t -> TOption (subst_params env t)
  | TTuple ts -> TTuple (List.map (subst_params env) ts)
  | TCon (n, ts) -> TCon (n, List.map (subst_params env) ts)
  | _ -> t

(* Validate a type annotation: every user type name must exist and receive
   the number of type arguments its declaration carries. *)
let rec check_ty st ~at (t : typ) : typ =
  check_no_unit st ~at t;
  match t with
  | TInt | TFloat | TBool | TChar | TStr | TUnit | TParam _ -> t
  | TList t -> TList (check_ty st ~at t)
  | TOption t -> TOption (check_ty st ~at t)
  | TTuple ts -> TTuple (List.map (check_ty st ~at) ts)
  | TCon (n, ts) ->
      let arity =
        match Hashtbl.find_opt st.tdecls n with
        | Some (TDRecord r) -> List.length r.rtparams
        | Some (TDVariant v) -> List.length v.vtparams
        | Some (TDTypeAlias a) -> List.length a.atparams
        | None -> (
            match Hashtbl.find_opt st.classes n with
            | Some _ -> 0
            | None -> (
                match Hashtbl.find_opt st.class_types n with
                | Some _ -> 0
                | None ->
                    errp st at (Printf.sprintf "unknown type name '%s'" n)))
      in
      if List.length ts <> arity then
        errp st at
          (Printf.sprintf "type '%s' expects %d type argument(s)" n arity);
      (* a type alias expands to its target; the expansion is checked
         (recursively, so alias chains resolve) and substituted *)
      (match Hashtbl.find_opt st.tdecls n with
      | Some (TDTypeAlias a) ->
          let env = List.combine a.atparams ts in
          check_ty st ~at (subst_params env a.aexpands)
      | _ -> TCon (n, List.map (check_ty st ~at) ts))

(* ---------------- target name validation ---------------- *)

(* Names that reach the target output verbatim (declaration, member, and
   parameter names; local binders and pattern variables are renamed by the
   emitter, so they are exempt) must be legal in the target: no target
   keywords, no `_` prefix, no emitter-owned TupleN names.  The emitter
   owns `_`-prefixed helpers and temporaries and the TupleN records. *)
let is_tuple_record_name n =
  let l = String.length n in
  l > 5
  && String.sub n 0 5 = "Tuple"
  &&
  let rec digits i =
    i = l || (n.[i] >= '0' && n.[i] <= '9' && digits (i + 1))
  in
  digits 5

(* reject a source name the target would not accept; [what] is the
   declaration kind used in the diagnostic.  The message texts are the
   Java-era diagnostics, parameterized by the profile's pname. *)
let check_target_name st ~at ~what n =
  if List.mem n st.profile.reserved_names then
    errp st at
      (Printf.sprintf "%s '%s' is a %s keyword and cannot be emitted" what n
         st.profile.pname)
  else if
    st.profile.ban_underscore_prefix && String.length n > 0 && n.[0] = '_'
  then
    errp st at
      (Printf.sprintf
         "%s '%s' starts with '_', which is reserved for generated %s names"
         what n st.profile.pname)
  else if st.profile.ban_tupleN_names && is_tuple_record_name n then
    errp st at
      (Printf.sprintf
         "%s '%s' collides with the compiler's generated TupleN records" what
         n)

(* the top-level class name comes from the file basename, so the basename
   itself must name a class the target would accept *)
let check_top_class_name st top =
  let start_ok c =
    (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c = '_'
  in
  let char_ok c = start_ok c || (c >= '0' && c <= '9') in
  let ok =
    String.length top > 0
    && start_ok top.[0]
    && String.for_all char_ok top
    && not (List.mem top st.profile.reserved_names)
  in
  if not ok then
    errp st
      { line = 0; col = 0 }
      (Printf.sprintf
         "file basename '%s' is not a valid %s class name (it becomes the \
          top-level class)"
         top st.profile.pname)

let find_dup xs =
  let rec go seen = function
    | [] -> None
    | x :: tl -> if List.mem x seen then Some x else go (x :: seen) tl
  in
  go [] xs

(* parameter names are emitted verbatim; unit `()` params are dropped by the
   emitter and exempt.  A NAMED unit parameter is rejected: it would be
   dropped from the Java signature while the body may still reference it. *)
let check_params st ~at (params : (string * typ) list) =
  List.iter
    (fun (n, t) ->
      if t = TUnit && n <> "()" then
        errp st at
          (Printf.sprintf "unit parameter '%s' must be written `()`" n);
      check_target_name st ~at ~what:"parameter" n)
    params;
  let named = List.filter (fun (_, t) -> t <> TUnit) params in
  match find_dup (List.map fst named) with
  | Some n ->
      errp st at (Printf.sprintf "duplicate parameter '%s'" n)
  | None -> ()

(* Fresh-copy the free type parameters of a WHOLE signature with one shared
   mapping: each occurrence of the same source type variable (in parameters
   and the return type) becomes the SAME fresh unification variable at this
   call site, so `id : 'a -> 'a` keeps its argument/result link. *)
let instantiate_shared st (ts : typ list) : typ list =
  let map = Hashtbl.create 8 in
  let rec go (t : typ) : typ =
    match t with
    | TParam p ->
        if Hashtbl.mem st.uvars p then t
        else (
          match Hashtbl.find_opt map p with
          | Some u -> u
          | None ->
              let u = fresh st in
              Hashtbl.replace map p u;
              u)
    | TList t -> TList (go t)
    | TOption t -> TOption (go t)
    | TTuple ts -> TTuple (List.map go ts)
    | TCon (n, ts) -> TCon (n, List.map go ts)
    | _ -> t
  in
  List.map go ts

let rec split_at n xs =
  if n = 0 then ([], xs)
  else
    match xs with
    | [] -> ([], [])
    | x :: tl ->
        let a, b = split_at (n - 1) tl in
        (x :: a, b)

(* instantiate parameters and return type of a callable together *)
let instantiate_sig st (params : (string * typ) list) (ret : typ)
    : (string * typ) list * typ =
  let inst = instantiate_shared st (List.map snd params @ [ ret ]) in
  let ps, rs = split_at (List.length params) inst in
  (List.map2 (fun (n, _) t -> (n, t)) params ps, List.hd rs)

(* Reify a type for storage: resolve it through the CURRENT declaration's
   substitution, then rename any remaining unification variable `u<k>` to
   a stable name so the stored type no longer aliases the mutable unifier
   state:
   - the substitution is global and keyed by SOURCE type-variable names
     (`TParam "a"`), so a later declaration's body could bind the same key
     and change what an earlier stored type resolves to;
   - unification variables are numbered globally, and an unbound uvar
     stored by name would alias any later unification that touches that
     name (instantiate_shared passes uvars through untouched).
   Renaming: a uvar that the declaration's ANNOTATIONS resolve to is
   renamed back to its source type-variable name (first parameter, then
   return, in declaration order), which keeps the stored signature exactly
   as the source wrote it — the emitter maps source names to Java type
   parameters positionally.  A uvar with no source name (purely inferred)
   becomes the stable checker placeholder `@u<k>`.  `@` cannot begin a
   source type variable (lexer ident chars are [a-zA-Z0-9_]), so the
   placeholder name can never collide. *)
let rec reify_typ st (rename : (string, string) Hashtbl.t) (t : typ) : typ =
  let t = resolve st t in
  match t with
  | TParam p ->
      if String.length p > 0 && p.[0] = '@' then t
      else (
        match Hashtbl.find_opt rename p with
        | Some n -> TParam n
        | None -> if Hashtbl.mem st.uvars p then TParam ("@" ^ p) else t)
  | TList t -> TList (reify_typ st rename t)
  | TOption t -> TOption (reify_typ st rename t)
  | TTuple ts -> TTuple (List.map (reify_typ st rename) ts)
  | TCon (n, ts) -> TCon (n, List.map (reify_typ st rename) ts)
  | _ -> t

(* Reify a whole signature (parameter types + return type) together with
   one annotation-derived rename map, as instantiate_sig does for call
   sites: a type variable is one name across the whole signature.  A
   unification variable that the declaration's raw ANNOTATIONS resolve to
   is renamed back to its source type-variable name (`'a`), so the stored
   signature reads exactly as the source wrote it — the emitter maps
   source names to Java type parameters positionally.  A uvar with no
   source name (purely inferred) is renamed to the stable placeholder
   `@u<k>` instead (see reify_typ). *)
let reify_sig st (params : (string * typ) list) (ret : typ)
    : (string, string) Hashtbl.t * (string * typ) list * typ =
  let rename = Hashtbl.create 8 in
  let rec collect_raw (t : typ) : unit =
    (* walk the RAW annotation: a source type var that now resolves to a
       unification variable gets that uvar renamed back to its source name *)
    match t with
    | TParam q -> (
        match resolve st (TParam q) with
        | TParam u ->
            if
              Hashtbl.mem st.uvars u
              && not (Hashtbl.mem rename u)
              && not (String.length q > 0 && q.[0] = '@')
            then Hashtbl.replace rename u q
        | _ -> ())
    | TList t | TOption t -> collect_raw t
    | TTuple ts | TCon (_, ts) -> List.iter collect_raw ts
    | _ -> ()
  in
  List.iter (fun (_, t) -> collect_raw t) params;
  collect_raw ret;
  ( rename,
    List.map (fun (n, t) -> (n, reify_typ st rename t)) params,
    reify_typ st rename ret )

(* Reify every expression type recorded since the current declaration
   started, then clear the pending list.  Called when the declaration's
   body has been fully checked, so later declarations can never mutate
   stored types through the shared substitution / uvar namespace.  The
   rename map is the declaration's annotation-derived uvar rename (see
   reify_sig), so expression types keep the source type-variable names
   the emitter maps to Java type parameters. *)
let drain_pending st (rename : (string, string) Hashtbl.t) =
  List.iter
    (fun id ->
      match Hashtbl.find_opt st.types id with
      | Some t -> Hashtbl.replace st.types id (reify_typ st rename t)
      | None -> ())
    st.pending;
  st.pending <- []

(* ---------------- environments ---------------- *)

type binding = { btyp : typ; bmut : bool }

type env = (string * binding) list

(* class context for a method body: enables ESelfField rewrites, private
   access checks, and field mutability checks *)
type cls_ctx = {
  cname : string;
  cself : string;                    (* self name from `object (self)` *)
  ccfields : (string * typ * bool) list; (* name, type, mutable *)
  cstatic : bool; (* static method: no `self`, no instance field access *)
}

(* ---------------- pattern checking ---------------- *)

type cover = {
  cov_all : bool; (* wildcard / var / tuple: covers everything *)
  c_ctors : string list;
  c_some : bool;
  c_none : bool;
  c_nil : bool;
  c_cons : bool;
  c_true : bool;
  c_false : bool;
}

let cover_all =
  { cov_all = true; c_ctors = []; c_some = false; c_none = false;
    c_nil = false; c_cons = false; c_true = false; c_false = false }

let cover_ctor name =
  { cov_all = false; c_ctors = [ name ]; c_some = false; c_none = false;
    c_nil = false; c_cons = false; c_true = false; c_false = false }

let cover_none =
  { cov_all = false; c_ctors = []; c_some = false; c_none = true;
    c_nil = false; c_cons = false; c_true = false; c_false = false }

let cover_nil =
  { cov_all = false; c_ctors = []; c_some = false; c_none = false;
    c_nil = true; c_cons = false; c_true = false; c_false = false }

let cover_cons =
  { cov_all = false; c_ctors = []; c_some = false; c_none = false;
    c_nil = false; c_cons = true; c_true = false; c_false = false }

let cover_bool b =
  { cov_all = false; c_ctors = []; c_some = false; c_none = false;
    c_nil = false; c_cons = false; c_true = b; c_false = not b }

(* Check a pattern against the scrutinee type; returns bindings and the
   coverage contribution of the pattern. *)
let rec check_pat st ~at (p : pattern) (scrut : typ) : env * cover =
  match p with
  | PWild -> ([], cover_all)
  | PVar x -> ([ (x, { btyp = scrut; bmut = false }) ], cover_all)
  | PUnit ->
      unify_at_pos st at TUnit scrut;
      ([], cover_all)
  | PInt _ ->
      unify_at_pos st at TInt scrut;
      ([], cover_none)
  | PStr _ ->
      unify_at_pos st at TStr scrut;
      ([], cover_none)
  | PBool b ->
      unify_at_pos st at TBool scrut;
      ([], cover_bool b)
  | PChar _ ->
      unify_at_pos st at TChar scrut;
      ([], cover_none)
  | PCtor ("None", []) ->
      unify_at_pos st at (TOption (fresh st)) scrut;
      ([], cover_none)
  | PCtor ("Some", [ inner ]) ->
      let u = fresh st in
      unify_at_pos st at (TOption u) scrut;
      let binds, _ = check_pat st ~at inner u in
      (* `Some x` covers only the Some case: keep only c_some set
         (the inner pattern's cover_all must not abort the None check) *)
      (binds,
       { cov_all = false; c_ctors = []; c_some = true; c_none = false;
         c_nil = false; c_cons = false; c_true = false; c_false = false })
  | PCtor ("Some", _) ->
      errp st at "constructor 'Some' expects exactly 1 pattern argument"
  | PCtor (name, ps) -> (
      match Hashtbl.find_opt st.ctors name with
      | None ->
          errp st at (Printf.sprintf "unknown constructor '%s' in pattern" name)
      | Some (vname, payload) ->
          let tparams =
            match Hashtbl.find_opt st.tdecls vname with
            | Some (TDVariant v) -> v.vtparams
            | _ -> []
          in
          let args = List.map (fun _ -> fresh st) tparams in
          unify_at_pos st at (TCon (vname, args)) scrut;
          (* a single wildcard child absorbs any payload arity (`Rect _`) *)
          (match ps with
          | [ PWild ] -> ([], cover_ctor name)
          | _ ->
              if List.length ps <> List.length payload then
                errp st at
                  (Printf.sprintf
                     "constructor '%s' expects %d pattern argument(s), got %d"
                     name (List.length payload) (List.length ps));
              let env =
                List.combine tparams (List.map (resolve st) args)
              in
              let binds =
                List.fold_left2
                  (fun acc child pt ->
                    let b, _ = check_pat st ~at child (subst_params env pt) in
                    acc @ b)
                  [] ps payload
              in
              (binds, cover_ctor name)))
  | PTuple ps ->
      let us = List.map (fun _ -> fresh st) ps in
      unify_at_pos st at (TTuple us) scrut;
      let binds =
        List.fold_left2
          (fun acc child u -> let b, _ = check_pat st ~at child u in b @ acc)
          [] ps us
      in
      (binds, cover_all)
  | PRecord fs ->
      (* a record pattern must name exactly the record's fields, like a
         record literal (OCaml rule) *)
      let names = List.sort compare (List.map fst fs) in
      let cands =
        Hashtbl.fold
          (fun _ td acc ->
            match td with
            | TDRecord r ->
                let rn =
                  List.sort compare
                    (List.map (fun (n, _, _) -> n) r.rfields)
                in
                if rn = names then r :: acc else acc
            | _ -> acc)
          st.tdecls []
      in
      (match cands with
      | [] ->
          errp st at
            (Printf.sprintf "no record type has exactly the fields {%s}"
               (String.concat ", " names))
      | _ :: _ :: _ ->
          errp st at
            (Printf.sprintf
               "ambiguous record pattern {%s}: more than one record type matches"
               (String.concat ", " names))
      | [ r ] ->
          let args = List.map (fun _ -> fresh st) r.rtparams in
          let env' = List.combine r.rtparams (List.map (resolve st) args) in
          unify_at_pos st at (TCon (r.rname, List.map (resolve st) args))
            scrut;
          let binds =
            List.fold_left
              (fun acc (n, child) ->
                match List.find_opt (fun (fn, _, _) -> fn = n) r.rfields with
                | None ->
                    errp st at
                      (Printf.sprintf "record type '%s' has no field '%s'"
                         r.rname n)
                | Some (_, ft, _) ->
                    let b, _ = check_pat st ~at child (subst_params env' ft) in
                    acc @ b)
              [] fs
          in
          (binds, cover_all))
  | PNil ->
      unify_at_pos st at (TList (fresh st)) scrut;
      ([], cover_nil)
  | PCons (hp, tp) ->
      let u = fresh st in
      unify_at_pos st at (TList u) scrut;
      let hb, _ = check_pat st ~at hp u in
      let tb, _ = check_pat st ~at tp (TList u) in
      (hb @ tb, cover_cons)

(* Check match exhaustiveness for the scrutinee type. *)
let check_exhaustive st (e : expr) (covers : cover list) (scrut : typ) =
  let any_all = List.exists (fun c -> c.cov_all) covers in
  if not any_all then
    match resolve st scrut with
    | TCon (vn, _) -> (
        match Hashtbl.find_opt st.tdecls vn with
        | Some (TDVariant v) ->
            let covered =
              List.fold_left (fun acc c -> c.c_ctors @ acc) [] covers
            in
            let missing =
              List.filter (fun (cn, _) -> not (List.mem cn covered)) v.vctors
            in
            if missing <> [] then
              err st e
                (Printf.sprintf "non-exhaustive match: missing constructor(s) %s"
                   (String.concat ", " (List.map fst missing)))
        | _ -> ())
    | TOption _ ->
        let missing =
          (if List.exists (fun c -> c.c_some) covers then [] else [ "Some" ])
          @ if List.exists (fun c -> c.c_none) covers then [] else [ "None" ]
        in
        if missing <> [] then
          err st e
            (Printf.sprintf "non-exhaustive match: missing case(s) %s"
               (String.concat ", " missing))
    | TList _ ->
        let missing =
          (if List.exists (fun c -> c.c_nil) covers then [] else [ "[]" ])
          @ if List.exists (fun c -> c.c_cons) covers then [] else [ "x :: xs" ]
        in
        if missing <> [] then
          err st e
            (Printf.sprintf "non-exhaustive match: missing case(s) %s"
               (String.concat ", " missing))
    | TBool ->
        let missing =
          (if List.exists (fun c -> c.c_true) covers then [] else [ "true" ])
          @ if List.exists (fun c -> c.c_false) covers then [] else [ "false" ]
        in
        if missing <> [] then
          err st e
            (Printf.sprintf "non-exhaustive match: missing case(s) %s"
               (String.concat ", " missing))
    | _ -> err st e "non-exhaustive match: a wildcard case is required"

(* ---------------- builtins ---------------- *)

let builtin st (name : string) : (typ list * (typ list -> typ)) option =
  match name with
  | "print_int" -> Some ([ TInt ], fun _ -> TUnit)
  | "print_string" | "print_endline" -> Some ([ TStr ], fun _ -> TUnit)
  | "print_float" -> Some ([ TFloat ], fun _ -> TUnit)
  | "string_of_int" -> Some ([ TInt ], fun _ -> TStr)
  | "string_of_float" -> Some ([ TFloat ], fun _ -> TStr)
  | "string_of_bool" -> Some ([ TBool ], fun _ -> TStr)
  | "failwith" -> Some ([ TStr ], fun _ -> fresh st)
  | "fst" | "snd" ->
      let u1 = fresh st and u2 = fresh st in
      let mk (ats : typ list) =
        match resolve st (List.hd ats) with
        | TTuple (a :: b :: _) -> if name = "fst" then a else b
        | t -> raise (Type_mismatch (TTuple [ u1; u2 ], t))
      in
      Some ([ TTuple [ u1; u2 ] ], mk)
  | "List.length" -> Some ([ TList (fresh st) ], fun _ -> TInt)
  | _ -> None

let binop_str (op : binop) : string =
  match op with
  | Add -> "+" | Sub -> "-" | Mul -> "*" | Div -> "/" | Mod -> "%"
  | Eq -> "=" | Ne -> "<>" | Lt -> "<" | Le -> "<=" | Gt -> ">" | Ge -> ">="
  | And -> "&&" | Or -> "||" | Concat -> "^"

(* enforce full application and unify each argument with its parameter type *)
let check_app st ~at what (args : (expr * typ) list) (params : (string * typ) list) =
  let n = List.length args and np = List.length params in
  if n < np then
    errp st at
      (Printf.sprintf "partial application of %s: expected %d argument(s), got %d"
         what np n);
  if n > np then
    errp st at
      (Printf.sprintf "too many arguments to %s: expected %d, got %d" what np n);
  List.iter2
    (fun (a, t) (_, pt) -> unify_at st a t pt)
    args params

(* ---------------- expression checking ---------------- *)

let rec check_expr st env cls (e : expr) : expr * typ =
  let memo t =
    (* store raw; the type is reified when the enclosing declaration
       finishes (a var may be bound by a later unification inside the
       same body) *)
    Hashtbl.replace st.types e.id t;
    Hashtbl.replace st.poss e.id e.pos;
    st.pending <- e.id :: st.pending;
    t
  in
  match e.desc with
  | EUnit -> (e, memo TUnit)
  | EInt _ -> (e, memo TInt)
  | EFloat _ -> (e, memo TFloat)
  | EBool _ -> (e, memo TBool)
  | EChar _ -> (e, memo TChar)
  | EStr _ -> (e, memo TStr)
  | ETyped (x, t) ->
      let t' = check_ty st ~at:e.pos t in
      let x', xt = check_expr st env cls x in
      unify_at st e t' xt;
      ({ e with desc = ETyped (x', t') }, memo t')
  | EVar name -> (
      match List.assoc_opt name env with
      | Some b -> (e, memo b.btyp)
      | None -> (
          match cls with
          | Some cl when String.equal cl.cself name ->
              (* `self` inside a method denotes the object itself, but a
                 static method has none *)
              if cl.cstatic then
                err st e
                  (Printf.sprintf "self ('%s') is not available in a static method"
                     name)
              else (e, memo (TCon (cl.cname, [])))
          | Some cl -> (
              match
                List.find_opt (fun (n, _, _) -> String.equal n name) cl.ccfields
              with
              | Some (_, t, _) ->
                  if cl.cstatic then
                    err st e
                      (Printf.sprintf
                         "instance field '%s' cannot be accessed from a static \
                          method"
                         name)
                  else ({ e with desc = ESelfField name }, memo t)
              | None ->
                  let e', t = global_value st e name in
                  (e', memo t))
          | None ->
              let e', t = global_value st e name in
              (e', memo t)))
  | ETuple es ->
      let es', ts = List.split (List.map (fun x -> check_expr st env cls x) es) in
      ({ e with desc = ETuple es' }, memo (TTuple ts))
  | EList es ->
      let es', ts = List.split (List.map (fun x -> check_expr st env cls x) es) in
      let u = fresh st in
      List.iter (fun t -> unify_at st e t u) ts;
      ({ e with desc = EList es' }, memo (TList (resolve st u)))
  | ECons (hd, tl) ->
      let hd', ht = check_expr st env cls hd in
      let tl', tt = check_expr st env cls tl in
      let u = fresh st in
      unify_at st hd ht u;
      unify_at st tl tt (TList u);
      ({ e with desc = ECons (hd', tl') }, memo (TList (resolve st u)))
  | ERecord fs ->
      let names = List.sort compare (List.map fst fs) in
      let cands =
        Hashtbl.fold
          (fun _ td acc ->
            match td with
            | TDRecord r ->
                let rn =
                  List.sort compare
                    (List.map (fun (n, _, _) -> n) r.rfields)
                in
                if rn = names then r :: acc else acc
            | _ -> acc)
          st.tdecls []
      in
      (match cands with
      | [] ->
          err st e
            (Printf.sprintf "no record type has exactly the fields {%s}"
               (String.concat ", " names))
      | _ :: _ :: _ ->
          err st e
            (Printf.sprintf
               "ambiguous record literal {%s}: more than one record type matches"
               (String.concat ", " names))
      | [ r ] ->
          let args = List.map (fun _ -> fresh st) r.rtparams in
          let env' = List.combine r.rtparams (List.map (resolve st) args) in
          let fs' =
            List.map
              (fun (n, fe) ->
                match List.find_opt (fun (fn, _, _) -> fn = n) r.rfields with
                | None ->
                    err st e
                      (Printf.sprintf "record type '%s' has no field '%s'"
                         r.rname n)
                | Some (_, ft, _) ->
                    let fe', ft' = check_expr st env cls fe in
                    unify_at st fe ft' (subst_params env' ft);
                    (n, fe'))
              fs
          in
          ({ e with desc = ERecord fs' },
           memo (TCon (r.rname, List.map (resolve st) args))))
  | EField (r, f) ->
      let r', rt = check_expr st env cls r in
      (match resolve st rt with
      | TCon (recn, args) -> (
          match Hashtbl.find_opt st.tdecls recn with
          | Some (TDRecord rd) -> (
              match List.find_opt (fun (n, _, _) -> n = f) rd.rfields with
              | Some (_, ft, _) ->
                  let env = List.combine rd.rtparams (List.map (resolve st) args) in
                  let t = subst_params env ft in
                  ({ e with desc = EField (r', f) }, memo (resolve st t))
              | None ->
                  err st e
                    (Printf.sprintf "record type '%s' has no field '%s'" recn f))
          | _ ->
              err st e
                (Printf.sprintf "cannot access field '%s' of a non-record value"
                   f))
      | _ ->
          err st e
            (Printf.sprintf "cannot access field '%s' of a non-record value" f))
  | EAssign (target, v) ->
      let v', vt = check_expr st env cls v in
      let target' =
        match target with
        | AVar name -> (
            match List.assoc_opt name env with
            | Some b ->
                if not b.bmut then
                  err st e
                    (Printf.sprintf "cannot assign to immutable variable '%s'"
                       name);
                unify_at st v vt b.btyp;
                target
            | None -> (
                match cls with
                | Some cl -> (
                    match
                      List.find_opt (fun (n, _, _) -> n = name) cl.ccfields
                    with
                    | Some (_, t, mut) ->
                        if cl.cstatic then
                          err st e
                            (Printf.sprintf
                               "instance field '%s' cannot be assigned from a \
                                static method"
                               name);
                        if not mut then
                          err st e
                            (Printf.sprintf
                               "cannot assign to immutable field '%s'" name);
                        unify_at st v vt t;
                        target
                    | None ->
                        err st e (Printf.sprintf "unbound variable '%s'" name))
                | None -> err st e (Printf.sprintf "unbound variable '%s'" name)))
        | AField (r, f) ->
            let r', rt = check_expr st env cls r in
            (match resolve st rt with
            | TCon (rname, args) -> (
                match Hashtbl.find_opt st.tdecls rname with
                | Some (TDRecord rd) -> (
                    match List.find_opt (fun (n, _, _) -> n = f) rd.rfields with
                    | Some (_, ft, mut) ->
                        if not mut then
                          err st e
                            (Printf.sprintf
                               "cannot assign to immutable field '%s' of \
                                record '%s'"
                               f rname);
                        let tenv =
                          List.combine rd.rtparams
                            (List.map (resolve st) args)
                        in
                        unify_at st v vt (subst_params tenv ft);
                        AField (r', f)
                    | None ->
                        err st e
                          (Printf.sprintf "record type '%s' has no field '%s'"
                             rname f))
                | _ ->
                    err st e
                      (Printf.sprintf
                         "cannot assign to field '%s' of a non-record value"
                         f))
            | _ ->
                err st e
                  (Printf.sprintf
                     "cannot assign to field '%s' of a non-record value" f))
      in
      ({ e with desc = EAssign (target', v') }, memo TUnit)
  | ELocalCall (name, args) -> (
      match builtin st name with
      | Some (params, mkret) ->
          let args', ats =
            List.split (List.map (fun x -> check_expr st env cls x) args)
          in
          let named =
            List.map (fun t -> ("arg", t)) params
          in
          check_app st ~at:e.pos
            ("builtin '" ^ name ^ "'")
            (List.combine args' ats) named;
          ({ e with desc = ELocalCall (name, args') }, memo (mkret ats))
      | None -> (
          match Hashtbl.find_opt st.funcs name with
          | Some f ->
              let args', ats =
                List.split (List.map (fun x -> check_expr st env cls x) args)
              in
              let params, ret =
                instantiate_sig st
                  (List.map
                     (fun (n, t) -> (n, check_ty st ~at:e.pos t))
                     f.fparams)
                  f.fret
              in
              check_app st ~at:e.pos
                ("function '" ^ name ^ "'")
                (List.combine args' ats) params;
              ({ e with desc = ELocalCall (name, args') }, memo ret)
          | None ->
              err st e
                (Printf.sprintf "unbound function '%s'" name)))
  | ECtor (name, args) -> (
      if name = "None" then begin
        if args <> [] then
          err st e "too many arguments to constructor 'None'";
        let args' = List.map (fun x -> fst (check_expr st env cls x)) args in
        ({ e with desc = ECtor (name, args') },
         memo (TOption (fresh st)))
      end
      else if name = "Some" then begin
        match args with
        | [ x ] ->
            let x', xt = check_expr st env cls x in
            ({ e with desc = ECtor (name, [ x' ]) },
             memo (TOption (resolve st xt)))
        | [] ->
            err st e
              "partial application of constructor 'Some': expected 1 argument, got 0"
        | _ -> err st e "too many arguments to constructor 'Some'"
      end
      else
        match Hashtbl.find_opt st.ctors name with
        | None -> err st e (Printf.sprintf "unknown constructor '%s'" name)
        | Some (vname, payload) ->
            let args', ats =
              List.split (List.map (fun x -> check_expr st env cls x) args)
            in
            if List.length args < List.length payload then
              err st e
                (Printf.sprintf
                   "partial application of constructor '%s': expected %d argument(s), got %d"
                   name (List.length payload) (List.length args));
            if List.length args > List.length payload then
              err st e
                (Printf.sprintf "too many arguments to constructor '%s'" name);
            let tparams =
              match Hashtbl.find_opt st.tdecls vname with
              | Some (TDVariant v) -> v.vtparams
              | _ -> []
            in
            let tv = List.map (fun _ -> fresh st) tparams in
            let env = List.combine tparams (List.map (resolve st) tv) in
            List.iter2
              (fun at pt -> unify_at st e at (subst_params env pt))
              ats payload;
            ({ e with desc = ECtor (name, args') },
             memo (TCon (vname, List.map (resolve st) tv))))
  | ENew (name, args) -> (
      match Hashtbl.find_opt st.classes name with
      | Some c ->
          let args', ats =
            List.split (List.map (fun x -> check_expr st env cls x) args)
          in
          let params =
            List.map (fun (n, t) -> (n, check_ty st ~at:e.pos t)) c.cparams
          in
          check_app st ~at:e.pos
            ("class '" ^ name ^ "'")
            (List.combine args' ats) params;
          ({ e with desc = ENew (name, args') }, memo (TCon (name, [])))
      | None ->
          if Hashtbl.mem st.class_types name then
            err st e (Printf.sprintf "cannot instantiate class type '%s'" name)
          else err st e (Printf.sprintf "unknown class '%s'" name))
  | ECall ({ desc = EVar "List" | ECtor ("List", []); _ }, "length", args)
    when List.assoc_opt "List" env = None ->
      (* SPEC builtin: `List.length xs` (parses as a dotted call) *)
      check_expr st env cls { e with desc = ELocalCall ("List.length", args) }
  | ECall (recv, mname, args) ->
      let e', t = method_call st env cls e recv mname args in
      (e', memo t)
  | EMatch (scr, arms) ->
      let scr', st0 = check_expr st env cls scr in
      let covers = ref [] in
      let arms', rt =
        let result = ref None in
        let arms' =
          List.map
            (fun (arm : match_arm) ->
              let binds, cov = check_pat st ~at:e.pos arm.pat st0 in
              (* a guarded arm never proves coverage: its guard can fail at
                 runtime, so exhaustiveness must come from unguarded arms *)
              if arm.guard = None then covers := cov :: !covers;
              let env' = binds @ env in
              let g' =
                match arm.guard with
                | None -> None
                | Some g ->
                    let g', gt = check_expr st env' cls g in
                    unify_at st g TBool gt;
                    Some g'
              in
              let r', rt = check_expr st env' cls arm.rhs in
              (match !result with
              | None -> result := Some rt
              | Some t0 -> unify_at_pos st e.pos t0 rt);
              { arm with guard = g'; rhs = r' })
            arms
        in
        (arms', !result)
      in
      check_exhaustive st e !covers st0;
      let rt = match rt with Some t -> t | None -> fresh st in
      ({ e with desc = EMatch (scr', arms') }, memo (resolve st rt))
  | EIf (c, t, f) ->
      let c', ct = check_expr st env cls c in
      unify_at st c TBool ct;
      let t', tt = check_expr st env cls t in
      let f', ft = check_expr st env cls f in
      unify_at st e tt ft;
      ({ e with desc = EIf (c', t', f') }, memo (resolve st tt))
  | ELet (x, e1, e2) ->
      let e1', t1 = check_expr st env cls e1 in
      let env' =
        if x = "_" then env else (x, { btyp = t1; bmut = false }) :: env
      in
      let e2', t2 = check_expr st env' cls e2 in
      ({ e with desc = ELet (x, e1', e2') }, memo t2)
  | ELetMut (x, e1, e2) ->
      let e1', t1 = check_expr st env cls e1 in
      let env' = (x, { btyp = t1; bmut = true }) :: env in
      let e2', t2 = check_expr st env' cls e2 in
      ({ e with desc = ELetMut (x, e1', e2') }, memo t2)
  | ELetTuple (xs, e1, e2) ->
      let e1', t1 = check_expr st env cls e1 in
      let us = List.map (fun _ -> fresh st) xs in
      (try unify st t1 (TTuple us)
       with Type_mismatch (_, b) ->
         err st e
           (Printf.sprintf
              "type mismatch: expected a tuple of %d element(s), found %s"
              (List.length xs) (show st b)));
      let env' =
        List.fold_left2
          (fun acc x u ->
            if x = "_" then acc else (x, { btyp = u; bmut = false }) :: acc)
          env xs us
      in
      let e2', t2 = check_expr st env' cls e2 in
      ({ e with desc = ELetTuple (xs, e1', e2') }, memo t2)
  | ESeq (e1, e2) ->
      let e1', t1 = check_expr st env cls e1 in
      (* the left of `;` is a statement position: its value is discarded,
         and the emitter renders it as a bare Java statement, so a genuine
         source sequence `a; b` requires unit on the left (SPEC).  The
         parser also desugars `let _ = e in b` and `let () = e in b` into
         ESeq (e, b) with the ESeq's position at the `let` keyword (never
         equal to e's own position), whereas a source sequence always
         carries the left operand's position; those desugared nodes are
         discards, not sequences, and stay legal for any e. *)
      if e1.pos = e.pos && not (resolve st t1 = TUnit) then
        err st e1 "the left of ';' must have type unit";
      let e2', t2 = check_expr st env cls e2 in
      ({ e with desc = ESeq (e1', e2') }, memo t2)
  | EWhile (c, b) ->
      let c', ct = check_expr st env cls c in
      unify_at st c TBool ct;
      let b', bt = check_expr st env cls b in
      unify_at st b TUnit bt;
      ({ e with desc = EWhile (c', b') }, memo TUnit)
  | EForIn (x, xs, b) ->
      let xs', xt = check_expr st env cls xs in
      let u = fresh st in
      unify_at st xs xt (TList u);
      let env' = (x, { btyp = u; bmut = false }) :: env in
      let b', bt = check_expr st env' cls b in
      unify_at st b TUnit bt;
      ({ e with desc = EForIn (x, xs', b') }, memo TUnit)
  | EForRange (x, up, lo, hi, b) ->
      let lo', lt = check_expr st env cls lo in
      unify_at st lo lt TInt;
      let hi', ht = check_expr st env cls hi in
      unify_at st hi ht TInt;
      let env' = (x, { btyp = TInt; bmut = false }) :: env in
      let b', bt = check_expr st env' cls b in
      unify_at st b TUnit bt;
      ({ e with desc = EForRange (x, up, lo', hi', b') }, memo TUnit)
  | EBin (op, l, r) ->
      let l', lt = check_expr st env cls l in
      let r', rt = check_expr st env cls r in
      unify_at st e lt rt;
      let t = resolve st lt in
      let res =
        match op with
        | Add | Sub | Mul | Div -> (
            match t with
            | TInt | TFloat -> t
            | TParam _ -> unify_at st e t TInt; TInt
            | _ ->
                err st e
                  (Printf.sprintf
                     "operator '%s' expects int or float operands, got %s"
                     (binop_str op) (show st t)))
        | Mod -> (
            match t with
            | TInt -> TInt
            | TParam _ -> unify_at st e t TInt; TInt
            | _ ->
                err st e
                  (Printf.sprintf "operator '%%' expects int operands, got %s"
                     (show st t)))
        | Eq | Ne -> (
            match t with
            | TUnit -> err st e "cannot compare unit values"
            | _ -> TBool)
        | Lt | Le | Gt | Ge -> (
            match t with
            | TInt | TFloat | TChar | TStr -> TBool
            | TParam _ -> unify_at st e t TInt; TBool
            | _ ->
                err st e
                  (Printf.sprintf
                     "operator '%s' expects int, float, char or string \
                      operands, got %s"
                     (binop_str op) (show st t)))
        | And | Or -> (
            match t with
            | TBool -> TBool
            | TParam _ -> unify_at st e t TBool; TBool
            | _ ->
                err st e
                  (Printf.sprintf "operator '%s' expects bool operands, got %s"
                     (binop_str op) (show st t)))
        | Concat -> (
            match t with
            | TStr -> TStr
            | TParam _ -> unify_at st e t TStr; TStr
            | _ ->
                err st e
                  (Printf.sprintf "operator '^' expects string operands, got %s"
                     (show st t)))
      in
      ({ e with desc = EBin (op, l', r') }, memo res)
  | EUnary (op, x) ->
      let x', xt = check_expr st env cls x in
      let res =
        match op with
        | Neg -> (
            match resolve st xt with
            | TInt | TFloat -> xt
            | TParam _ -> unify_at st x xt TInt; TInt
            | _ -> err st e "unary '-' expects an int or float operand")
        | Not -> (
            match resolve st xt with
            | TBool -> TBool
            | TParam _ -> unify_at st x xt TBool; TBool
            | _ -> err st e "unary 'not' expects a bool operand")
      in
      ({ e with desc = EUnary (op, x') }, memo (resolve st res))
  | ESelfField _ ->
      err st e "internal error: ESelfField cannot appear in checker input"

and global_value st e name =
  match Hashtbl.find_opt st.funcs name with
  | Some { fparams = []; fret; _ } ->
      if not (Hashtbl.mem st.defined name) then
        err st e
          (Printf.sprintf
             "cannot use value '%s' before it is defined (no forward \
              references to top-level values)"
             name);
      (e, fret)
  | Some { fparams = _ :: _; _ } ->
      err st e
        (Printf.sprintf "unbound variable '%s' (functions must be called \
                         with all arguments)"
           name)
  | None -> err st e (Printf.sprintf "unbound variable '%s'" name)

and method_call st env cls e recv mname args =
  (* static call: `ClassName.method args` *)
  match recv.desc with
  | EVar n when List.assoc_opt n env = None && Hashtbl.mem st.classes n ->
      let c = Hashtbl.find st.classes n in
      (match List.find_opt (fun m -> m.mname = mname) c.cmethods with
      | None ->
          err st e (Printf.sprintf "unknown method '%s' of class '%s'" mname n)
      | Some m ->
          if not m.mstatic then
            err st e
              (Printf.sprintf
                 "method '%s' of class '%s' is not static; call it on an \
                  instance"
                 mname n);
          if m.mprivate then
            (match cls with
            | Some cl when cl.cname = n -> ()
            | _ ->
                err st e
                  (Printf.sprintf
                     "private method '%s' of class '%s' cannot be called from \
                      outside the class"
                     mname n));
          let params, ret =
            instantiate_sig st
              (List.map (fun (p, t) -> (p, check_ty st ~at:e.pos t)) m.mparams)
              (check_ty st ~at:e.pos m.mret)
          in
          let args', ats =
            List.split (List.map (fun x -> check_expr st env cls x) args)
          in
          check_app st ~at:e.pos
            ("method '" ^ mname ^ "'")
            (List.combine args' ats) params;
          ({ e with desc = ECall (recv, mname, args') }, ret))
  | _ ->
      let recv', rt0 = check_expr st env cls recv in
      (match resolve st rt0 with
      | TCon (cname, _) -> (
          match Hashtbl.find_opt st.classes cname with
          | Some c -> (
              match List.find_opt (fun m -> m.mname = mname) c.cmethods with
              | Some m ->
                  if m.mstatic then
                    err st e
                      (Printf.sprintf
                         "static method '%s' of class '%s' must be called via \
                          the class name"
                         mname cname);
                  if m.mprivate then
                    (match cls with
                    | Some cl when cl.cname = cname -> ()
                    | _ ->
                        err st e
                          (Printf.sprintf
                             "private method '%s' of class '%s' cannot be \
                              called from outside the class"
                             mname cname));
                  let params, ret =
                    instantiate_sig st
                      (List.map
                         (fun (p, t) -> (p, check_ty st ~at:e.pos t))
                         m.mparams)
                      (check_ty st ~at:e.pos m.mret)
                  in
                  let args', ats =
                    List.split (List.map (fun x -> check_expr st env cls x) args)
                  in
                  check_app st ~at:e.pos
                    ("method '" ^ mname ^ "'")
                    (List.combine args' ats) params;
                  ({ e with desc = ECall (recv', mname, args') }, ret)
              | None ->
                  err st e
                    (Printf.sprintf "unknown method '%s' of class '%s'" mname
                       cname))
          | None -> (
              match Hashtbl.find_opt st.class_types cname with
              | Some ct -> (
                  match
                    List.find_opt (fun ms -> ms.msname = mname) ct.ctmethods
                  with
                  | None ->
                      err st e
                        (Printf.sprintf "unknown method '%s' of class type '%s'"
                           mname cname)
                  | Some ms ->
                      let args', ats =
                        List.split
                          (List.map (fun x -> check_expr st env cls x) args)
                      in
                      let params, ret =
                        instantiate_sig st
                          (List.map
                             (fun (p, t) -> (p, check_ty st ~at:e.pos t))
                             ms.msparams)
                          (check_ty st ~at:e.pos ms.msret)
                      in
                      check_app st ~at:e.pos
                        ("method '" ^ mname ^ "'")
                        (List.combine args' ats) params;
                      ({ e with desc = ECall (recv', mname, args') }, ret))
              | None ->
                  err st e
                    (Printf.sprintf "unknown method '%s' on a non-class value"
                       mname)))
      | _ ->
          err st e
            (Printf.sprintf "cannot call method '%s' on a non-class value"
               mname))

(* ---------------- declarations ---------------- *)

(* position of a declaration's head keyword (`type`/`let`/`class`) *)
let decl_pos (d : decl) : pos =
  match d with
  | DType (TDRecord r) -> r.rpos
  | DType (TDVariant v) -> v.vpos
  | DType (TDTypeAlias a) -> a.apos
  | DFun f -> f.fpos
  | DClass c -> c.cpos
  | DClassType ct -> ct.ctpos

(* check a function / top-level value declaration *)
let check_fun st (f : fun_decl) : fun_decl =
  (* the target entry point: a top-level `main` must have exactly one `()`
     parameter and return unit, or the emitter cannot produce `main` *)
  if st.profile.enforce_main_rule && f.fname = "main" then begin
    let ok =
      match f.fparams with
      | [ ("()", TUnit) ] -> f.fret = TUnit
      | _ -> false
    in
    if not ok then
      errp st f.fpos "`main` must have the form let main () : unit"
  end;
  (* annotations must name existing types *)
  let params =
    List.map (fun (n, t) -> (n, check_ty st ~at:f.fpos t)) f.fparams
  in
  check_params st ~at:f.fpos params;
  let ret_ann = check_ty st ~at:f.fpos f.fret in
  let env =
    List.fold_left
      (fun acc (n, t) -> (n, { btyp = t; bmut = false }) :: acc)
      [] params
  in
  let body', bt = check_expr st env None f.fbody in
  (* For top-level values the parser puts a TUnit placeholder in fret when
     there is no annotation; an annotated value arrives with an ETyped body.
     Only trust/check the annotation when the body is ETyped; otherwise the
     value's type is simply the inferred body type. *)
  let body_annotated =
    match f.fbody.desc with ETyped _ -> true | _ -> false
  in
  if f.fparams <> [] || body_annotated then
    unify_at_pos st f.fpos ret_ann bt;
  (* Reify the signature: resolve it through this declaration's own
     substitution, then rename any remaining unification variables to
     stable names (annotation source names where one exists, `@u<k>`
     otherwise).  Stored signatures must not alias the global unifier
     state: a later declaration can bind the same global subst key (source
     type-variable names are global keys) or reuse the same uvar number,
     which would silently change an earlier stored signature. *)
  let rename, fparams', fret' = reify_sig st params bt in
  drain_pending st rename;
  { f with fparams = fparams'; fret = fret'; fbody = body' }

(* check a method body: bare field/ctor-param refs become ESelfField *)
let check_method st cl (m : method_decl) : method_decl =
  let params =
    List.map (fun (n, t) -> (n, check_ty st ~at:m.mpos t)) m.mparams
  in
  check_params st ~at:m.mpos params;
  let ret = check_ty st ~at:m.mpos m.mret in
  let env =
    List.fold_left
      (fun acc (n, t) -> (n, { btyp = t; bmut = false }) :: acc)
      [] params
  in
  let body', bt = check_expr st env (Some cl) m.mbody in
  unify_at_pos st m.mpos ret bt;
  (* same reification discipline as check_fun: stored signatures must not
     alias the global unifier state *)
  let rename, mparams', mret' = reify_sig st params ret in
  drain_pending st rename;
  { m with mparams = mparams'; mret = mret'; mbody = body' }

(* Canonical form of a method signature for interface/implementation
   comparison: type variables are compared by their position in the
   signature (first appearance over parameters then return type), which is
   the v1 meaning of a method type variable — the emitter maps them to Java
   type parameters in exactly that order.  Concrete types compare
   structurally (constructor name + arguments).  The global subst is
   deliberately NOT consulted: a signature's type variables are local to
   the signature, not the checker's side table. *)
let canon_sig (params : (string * typ) list) (ret : typ) : typ list * typ =
  let next = ref 0 in
  let pos = Hashtbl.create 8 in
  let rec go (t : typ) : typ =
    match t with
    | TParam p -> (
        match Hashtbl.find_opt pos p with
        | Some i -> TParam ("#" ^ string_of_int i)
        | None ->
            let i = !next in
            incr next;
            Hashtbl.add pos p i;
            TParam ("#" ^ string_of_int i))
    | TList t -> TList (go t)
    | TOption t -> TOption (go t)
    | TTuple ts -> TTuple (List.map go ts)
    | TCon (n, ts) -> TCon (n, List.map go ts)
    | t -> t
  in
  (List.map (fun (_, t) -> go t) params, go ret)

(* every `inherit itf` interface method must be implemented by a PUBLIC,
   NON-STATIC method with a compatible signature (Java rejects weaker
   access and static implementations of interface methods) *)
let check_inherits st (c : class_decl) =
  (* Signature key: arity + canonical parameter types + canonical return
     type, using the same comparison the per-interface check below uses.
     Compatible duplicates across inherited class types share one
     implementation; incompatible duplicates are an error at the class
     declaration. *)
  let sig_key (ms : method_sig) =
    let params, ret = canon_sig ms.msparams ms.msret in
    (List.length ms.msparams, params, ret)
  in
  let first_sig = Hashtbl.create 17 in
  List.iter
    (fun itf ->
      match Hashtbl.find_opt st.class_types itf with
      | None -> ()           (* reported by the per-interface check below *)
      | Some ct ->
          List.iter
            (fun (ms : method_sig) ->
              match Hashtbl.find_opt first_sig ms.msname with
              | None -> Hashtbl.add first_sig ms.msname (sig_key ms)
              | Some k ->
                  if sig_key ms <> k then
                    errp st c.cpos
                      (Printf.sprintf
                         "inherited method '%s' has incompatible signatures in \
                          the inherited class types"
                         ms.msname))
            ct.ctmethods)
    c.cinherits;
  List.iter
    (fun itf ->
      match Hashtbl.find_opt st.class_types itf with
      | None ->
          errp st c.cpos
            (Printf.sprintf "unknown class type '%s' in inherit clause" itf)
      | Some ct ->
          List.iter
            (fun (ms : method_sig) ->
              match List.find_opt (fun m -> m.mname = ms.msname) c.cmethods with
              | None ->
                  errp st c.cpos
                    (Printf.sprintf
                       "class '%s' inherits '%s' but does not implement \
                        method '%s'"
                       c.cname itf ms.msname)
              | Some m ->
                  if m.mprivate then
                    errp st m.mpos
                      (Printf.sprintf
                         "method '%s' of class '%s' is private, but it must \
                          be public to implement method '%s' of interface \
                          '%s'"
                         ms.msname c.cname ms.msname itf);
                  if m.mstatic then
                    errp st m.mpos
                      (Printf.sprintf
                         "method '%s' of class '%s' is static and cannot \
                          implement method '%s' of interface '%s'"
                         ms.msname c.cname ms.msname itf);
                  if List.length m.mparams <> List.length ms.msparams then
                    errp st m.mpos
                      (Printf.sprintf
                         "method '%s' of class '%s' does not match interface \
                          '%s' (different arity)"
                         ms.msname c.cname itf);
                  (* Structural comparison over the checked types: both
                     sides are canonicalized with type variables renamed by
                     position in the signature (params then return), which
                     is the v1 meaning of a method type variable — the
                     emitter maps them to Java type parameters in exactly
                     that order.  The global subst is not consulted: a
                     signature's type variables are local to the signature,
                     so `show` (which resolves through the subst) would
                     compare unrelated types as equal. *)
                  let cparams =
                    List.map (fun (_, t) -> check_ty st ~at:m.mpos t)
                      m.mparams
                  in
                  let cret = check_ty st ~at:m.mpos m.mret in
                  let cps, cr =
                    canon_sig (List.map (fun t -> ("", t)) cparams) cret
                  in
                  let ips, ir = canon_sig ms.msparams ms.msret in
                  List.iter2
                    (fun pt mt ->
                      if pt <> mt then
                        errp st m.mpos
                          (Printf.sprintf
                             "method '%s' of class '%s' does not match \
                              interface '%s' (different parameter types)"
                             ms.msname c.cname itf))
                    cps ips;
                  if cr <> ir then
                    errp st m.mpos
                      (Printf.sprintf
                         "method '%s' of class '%s' does not match interface \
                          '%s' (different return type)"
                         ms.msname c.cname itf))
            ct.ctmethods)
    c.cinherits

(* check a class declaration: ctor params, fields, methods *)
let check_class st (c : class_decl) : class_decl =
  let params =
    List.map (fun (n, t) -> (n, check_ty st ~at:c.cpos t)) c.cparams
  in
  check_params st ~at:c.cpos params;
  List.iter
    (fun (cf : cfield) ->
      check_target_name st ~at:cf.cfpos ~what:"field" cf.cfname)
    c.cfields;
  (* SPEC: a val field name or constructor parameter name that equals a
     top-level value/function visible at the class declaration is rejected.
     Field initializers resolve names with cls=None (they are emitted
     inside the constructor, where the emitter's `this.name` preference
     would silently read the field instead of the global), so the name must
     be unambiguous.  Visibility at the declaration: functions are
     forward-visible (pass 1 registers every function, and calls may use
     later declarations), while values/declarations are visible only after
     their own body was checked (no forward references; st.defined).  The
     field check points at the member's `val` keyword position; the
     parameter check has no per-parameter position, so it points at the
     class head. *)
  List.iter
    (fun (cf : cfield) ->
      if
        Hashtbl.mem st.defined cf.cfname
        ||
        match Hashtbl.find_opt st.funcs cf.cfname with
        | Some f -> f.fparams <> []
        | None -> false
      then
        errp st cf.cfpos
          (Printf.sprintf
             "class member '%s' shadows a top-level name; rename one"
             cf.cfname))
    c.cfields;
  List.iter
    (fun (n, _) ->
      if
        Hashtbl.mem st.defined n
        ||
        match Hashtbl.find_opt st.funcs n with
        | Some f -> f.fparams <> []
        | None -> false
      then
        errp st c.cpos
          (Printf.sprintf
             "class member '%s' shadows a top-level name; rename one" n))
    params;
  (* ctor parameters and val fields both become Java fields of the class;
     unit `()` ctor params are dropped by the emitter and exempt *)
  (match
     find_dup
       (List.map fst (List.filter (fun (_, t) -> t <> TUnit) params)
       @ List.map (fun cf -> cf.cfname) c.cfields)
   with
  | Some n ->
      errp st
        (match List.find_opt (fun cf -> cf.cfname = n) c.cfields with
        | Some cf -> cf.cfpos
        | None -> c.cpos)
        (Printf.sprintf "duplicate member name '%s' in class '%s'" n c.cname)
  | None -> ());
  List.iter
    (fun (m : method_decl) ->
      check_target_name st ~at:m.mpos ~what:"method" m.mname)
    c.cmethods;
  (match find_dup (List.map (fun m -> m.mname) c.cmethods) with
  | Some n ->
      let m = List.find (fun m -> m.mname = n) c.cmethods in
      errp st m.mpos
        (Printf.sprintf "duplicate method '%s' in class '%s'" n c.cname)
  | None -> ());
  (* TS: methods and fields/ctor params share one member namespace (a
     field and a method of the same name are a duplicate-identifier error
     in TS, unlike Java where they are separate namespaces). *)
  let () =
    if st.profile.class_member_namespace then
      let members =
        List.map fst (List.filter (fun (_, t) -> t <> TUnit) params)
        @ List.map (fun cf -> cf.cfname) c.cfields
      in
      (match
         List.find_opt
           (fun (m : method_decl) -> List.mem m.mname members)
           c.cmethods
       with
      | Some m ->
          errp st m.mpos
            (Printf.sprintf
               "method '%s' of class '%s' collides with a field or constructor \
                parameter of the same name"
               m.mname c.cname)
      | None -> ())
  in
  (* field initializers see the constructor parameters *)
  let param_env =
    List.fold_left
      (fun acc (n, t) -> (n, { btyp = t; bmut = false }) :: acc)
      [] params
  in
  (* fields: annotation if present (unified), else inferred from the init *)
  let fields' =
    List.map
      (fun (cf : cfield) ->
        let init', it = check_expr st param_env None cf.cfinit in
        let t =
          match cf.cftyp with
          | Some t ->
              let t = check_ty st ~at:cf.cfpos t in
              unify_at_pos st cf.cfpos t it;
              resolve st t
          | None -> resolve st it
        in
        { cf with cfinit = init'; cftyp = Some t })
      c.cfields
  in
  (* in method bodies, constructor parameters and fields are both
     rewritten to ESelfField (they become private fields in Java); a static
     method gets a context with no instance state at all *)
  let cctx =
    {
      cname = c.cname;
      cself = c.cself;
      ccfields =
        List.map (fun (n, t) -> (n, t, false)) params
        @ List.map
            (fun (cf : cfield) -> (cf.cfname, Option.get cf.cftyp, cf.cfmut))
            fields';
      cstatic = false;
    }
  in
  check_inherits st c;
  let methods' =
    List.map
      (fun (m : method_decl) ->
        check_method st { cctx with cstatic = m.mstatic } m)
      c.cmethods
  in
  (* reify the stored class signature (ctor params + field types) with the
     same no-alias discipline as check_fun/check_method *)
  let rename, params', _ = reify_sig st params TUnit in
  let fields'' =
    List.map
      (fun cf ->
        { cf with
          cftyp =
            Some
              (reify_typ st rename
                 (Option.get cf.cftyp)) })
      fields'
  in
  drain_pending st rename;
  { c with cparams = params'; cfields = fields''; cmethods = methods' }

(* first type variable occurring in a type, in left-to-right order *)
let rec first_var (t : typ) : string option =
  match t with
  | TParam p -> Some p
  | TList t | TOption t -> first_var t
  | TTuple ts | TCon (_, ts) -> first_var_list ts
  | _ -> None

and first_var_list (ts : typ list) : string option =
  match ts with
  | [] -> None
  | t :: ts -> (
      match first_var t with
      | Some _ as r -> r
      | None -> first_var_list ts)

(* class type declaration: validate the method signature types, requiring
   every method signature to be monomorphic.  A class type declares no
   type parameters of its own, so a type variable in a method signature is
   free: the emitter has no generic target for it in v1 and would sink it
   to `Object`, silently changing the emitted signature. *)
let check_class_type st (ct : class_type_decl) : class_type_decl =
  let methods' =
    List.map
      (fun (ms : method_sig) ->
        check_target_name st ~at:ct.ctpos ~what:"method" ms.msname;
        let params =
          List.map (fun (n, t) -> (n, check_ty st ~at:ct.ctpos t))
            ms.msparams
        in
        check_params st ~at:ct.ctpos params;
        let msret = check_ty st ~at:ct.ctpos ms.msret in
        let var =
          match first_var_list (List.map snd params) with
          | Some _ as r -> r
          | None -> first_var msret
        in
        (if st.profile.monomorphic_class_types then
           match var with
           | Some p ->
               errp st ct.ctpos
                 (Printf.sprintf
                    "class type method '%s' uses type variable '%s'; class \
                     type signatures must be monomorphic in v1"
                    ms.msname p)
           | None -> ());
        { ms with msparams = params; msret })
      ct.ctmethods
  in
  { ct with ctmethods = methods' }

(* type declarations: validate field/payload types *)
let check_type_decl st (td : type_decl) : type_decl =
  match td with
  | TDRecord r ->
      List.iter
        (fun (n, _, _) -> check_target_name st ~at:r.rpos ~what:"field" n)
        r.rfields;
      let fields' =
        List.map (fun (n, t, m) -> (n, check_ty st ~at:r.rpos t, m)) r.rfields
      in
      TDRecord { r with rfields = fields' }
  | TDVariant v ->
      List.iter
        (fun (n, _) -> check_target_name st ~at:v.vpos ~what:"constructor" n)
        v.vctors;
      let ctors' =
        List.map
          (fun (n, payload) ->
            (n, List.map (fun t -> check_ty st ~at:v.vpos t) payload))
          v.vctors
      in
      TDVariant { v with vctors = ctors' }
  | TDTypeAlias a ->
      (* the expansion is checked in a scope where the alias's own params
         are bound to fresh unification variables, so `type 'a t = 'a
         list` validates; the stored expansion keeps the source params *)
      let args = List.map (fun _ -> fresh st) a.atparams in
      let env = List.combine a.atparams (List.map (resolve st) args) in
      let _ = check_ty st ~at:a.apos (subst_params env a.aexpands) in
      TDTypeAlias a

let check_program ~profile (p : Ast.program) =
  let types = Hashtbl.create 97
  and tdecls = Hashtbl.create 17
  and ctors = Hashtbl.create 17
  and classes = Hashtbl.create 17
  and funcs = Hashtbl.create 17
  and class_types = Hashtbl.create 17 in
  let st =
    {
      file = p.file;
      profile;
      types;
      poss = Hashtbl.create 97;
      tdecls;
      ctors;
      classes;
      funcs;
      class_types;
      subst = Hashtbl.create 17;
      uvarc = 0;
      uvars = Hashtbl.create 17;
      pending = [];
      defined = Hashtbl.create 17;
    }
  in
  let top_class = Filename.remove_extension (Filename.basename p.file) in
  if st.profile.check_basename then check_top_class_name st top_class;
  (* Names that become classes inside the generated file (the top-level
     class = file basename, records, variant interfaces, per-constructor
     records, classes, class types) share one namespace on disk.  On the
     Java target two such names differing only in case overwrite each
     other's .class output on case-insensitive filesystems, so they are
     rejected like duplicates.  Exact duplicate names keep their dedicated
     diagnostics below; this registry only fires for case-differing
     collisions.  Function/value names are excluded: methods and nested
     types are separate Java namespaces. *)
  let tns : (string, string) Hashtbl.t = Hashtbl.create 23 in
  Hashtbl.add tns (String.lowercase_ascii top_class) top_class;
  let register_tns_raw dpos name =
    let key = String.lowercase_ascii name in
    match Hashtbl.find_opt tns key with
    | Some prev when prev <> name ->
        errp st dpos
          (Printf.sprintf
             "Java class name '%s' collides with '%s' ignoring case; rename \
              one (they would overwrite each other's .class file)"
             name prev)
    | Some _ -> ()
    | None -> Hashtbl.add tns key name
  in
  (* the registry is a Java-filesystem concern; other targets skip it *)
  let register_tns dpos name =
    if st.profile.case_insensitive_type_namespace then
      register_tns_raw dpos name
  in
  (* pass 1: register all declarations (duplicates are errors) *)
  List.iter
    (fun (d : decl) ->
      let dpos = decl_pos d in
      match d with
      | DType td ->
          let name =
            match td with
            | TDRecord r -> r.rname
            | TDVariant v -> v.vname
            | TDTypeAlias a -> a.aname
          in
          check_target_name st ~at:dpos ~what:"type" name;
          register_tns dpos name;
          if Hashtbl.mem st.tdecls name then
            errp st dpos
              (Printf.sprintf "duplicate type declaration '%s'" name);
          if
            Hashtbl.mem st.classes name || Hashtbl.mem st.class_types name
          then
            errp st dpos
              (Printf.sprintf
                 "name '%s' is already used by a class or class type" name);
          if Hashtbl.mem st.ctors name then
            errp st dpos
              (Printf.sprintf "name '%s' is already used by a constructor"
                 name);
          Hashtbl.add st.tdecls name td;
          (match td with
          | TDVariant v ->
              List.iter
                (fun (cn, payload) ->
                  register_tns dpos cn;
                  if Hashtbl.mem st.ctors cn then
                    errp st dpos
                      (Printf.sprintf "duplicate constructor '%s'" cn);
                  if
                    Hashtbl.mem st.tdecls cn
                    || Hashtbl.mem st.classes cn
                    || Hashtbl.mem st.class_types cn
                  then
                    errp st dpos
                      (Printf.sprintf
                         "name '%s' is already used by a type or class" cn);
                  Hashtbl.add st.ctors cn (v.vname, payload))
                v.vctors
          | TDRecord _ | TDTypeAlias _ -> ())
      | DFun f ->
          check_target_name st ~at:dpos ~what:"function" f.fname;
          if Hashtbl.mem st.funcs f.fname then
            errp st dpos (Printf.sprintf "duplicate function '%s'" f.fname);
          (* TS: a class and a top-level function/value share one value
             namespace (a class declaration is a value in TS, unlike Java
             where types and methods are separate namespaces) *)
          if
            st.profile.value_class_namespace
            && Hashtbl.mem st.classes f.fname
          then
            errp st dpos
              (Printf.sprintf
                 "function '%s' collides with a class of the same name" f.fname);
          Hashtbl.add st.funcs f.fname f
      | DClass c ->
          check_target_name st ~at:dpos ~what:"class" c.cname;
          register_tns dpos c.cname;
          if Hashtbl.mem st.classes c.cname then
            errp st dpos (Printf.sprintf "duplicate class '%s'" c.cname);
          if Hashtbl.mem st.tdecls c.cname then
            errp st dpos
              (Printf.sprintf "name '%s' is already used by a type" c.cname);
          if Hashtbl.mem st.class_types c.cname then
            errp st dpos
              (Printf.sprintf "name '%s' is already used by a class type"
                 c.cname);
          if Hashtbl.mem st.ctors c.cname then
            errp st dpos
              (Printf.sprintf "name '%s' is already used by a constructor"
                 c.cname);
          (* TS: a class and a top-level function/value share one value
             namespace *)
          if
            st.profile.value_class_namespace
            && Hashtbl.mem st.funcs c.cname
          then
            errp st dpos
              (Printf.sprintf
                 "class '%s' collides with a function or value of the same \
                  name"
                 c.cname);
          Hashtbl.add st.classes c.cname c
      | DClassType ct ->
          check_target_name st ~at:dpos ~what:"class type" ct.ctname;
          register_tns dpos ct.ctname;
          if Hashtbl.mem st.class_types ct.ctname then
            errp st dpos
              (Printf.sprintf "duplicate class type '%s'" ct.ctname);
          if Hashtbl.mem st.tdecls ct.ctname || Hashtbl.mem st.classes ct.ctname
          then
            errp st dpos
              (Printf.sprintf "name '%s' is already used by a type or class"
                 ct.ctname);
          if Hashtbl.mem st.ctors ct.ctname then
            errp st dpos
              (Printf.sprintf "name '%s' is already used by a constructor"
                 ct.ctname);
          Hashtbl.add st.class_types ct.ctname ct)
    p.decls;
  (* pass 2: check every declaration body, in order.  The substitution is
     scoped to ONE declaration: it is reset when a declaration starts (its
     source type-variable names are keys in the GLOBAL subst table, so a
     later declaration must never see — or mutate — an earlier one's
     bindings), and the declaration's recorded expression types are
     reified (resolved + uvar-renamed) when it finishes, so stored types
     never alias the mutable unifier state. *)
  let decls' =
    List.map
      (fun (d : decl) ->
        Hashtbl.reset st.subst;
        st.pending <- [];
        match d with
        | DType td -> DType (check_type_decl st td)
        | DFun f ->
            Hashtbl.add st.defined f.fname ();
            let f' = check_fun st f in
            Hashtbl.replace st.funcs f'.fname f';
            DFun f'
        | DClass c ->
            let c' = check_class st c in
            Hashtbl.replace st.classes c'.cname c';
            DClass c'
        | DClassType ct ->
            let ct' = check_class_type st ct in
            Hashtbl.replace st.class_types ct'.ctname ct';
            DClassType ct')
      p.decls
  in
  (* SPEC: the no-unit rule applies to INFERRED composite types too.  A
     value/expression whose (resolved) type contains unit inside a list,
     option, tuple, or type-argument position is rejected, even though no
     annotation was written: the emitter would print `void` where Java
     needs a type (List.of()'s element type, a TupleN's type argument, a
     record/class type argument, a `void` local).  Unification-variable
     types like `Some (print_endline "x")`'s TOption u only become
     concrete TUnit here, at the end, so this sweep runs after resolution
     and points at the expression whose type is the offending one.  IDs
     are assigned in source order, so the sweep visits the earliest
     offending expression first: deterministic across runs. *)
  let ids = Hashtbl.fold (fun id _ acc -> id :: acc) st.types [] in
  List.iter
    (fun id ->
      let t = Hashtbl.find st.types id in
      if has_unit_inside t then begin
        let at =
          match Hashtbl.find_opt st.poss id with
          | Some p -> p
          | None -> { line = 1; col = 1 }
        in
        check_no_unit st ~at t
      end)
    (List.sort compare ids);
  ( { p with decls = decls' },
    ({ types; tdecls; ctors; classes; funcs; class_types } : tables) )
