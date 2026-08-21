(* ml2java abstract syntax tree.
   Contract module: parser, checker, and emitter are written against these
   types. Any change here must be agreed before parser/checker/emitter change.
*)

type pos = { line : int; col : int }

(* All front-end failures (parse/check) raise this with a ready-to-print
   "file.mlj:line:col: error: message" line. *)
exception Front_error of string

let format_error ~file pos msg =
  Printf.sprintf "%s:%d:%d: error: %s" file pos.line pos.col msg

let raise_at ~file pos msg = raise (Front_error (format_error ~file pos msg))

type typ =
  | TInt            (* -> Java long *)
  | TFloat          (* -> Java double *)
  | TBool           (* -> Java boolean *)
  | TChar           (* -> Java char *)
  | TStr            (* -> Java String *)
  | TUnit           (* -> Java void / unit value where needed *)
  | TParam of string        (* 'a  -> Java type variable T, U, ... *)
  | TList of typ          (* -> java.util.List<T>, immutable *)
  | TOption of typ        (* -> nullable T; None is null. Java profile rule. *)
  | TTuple of typ list    (* -> generated Tuple2/Tuple3 records *)
  | TCon of string * typ list   (* user-defined type name + type args *)

(* Built-in function names (resolved before local decls, cannot be shadowed):
   print_string print_endline print_int print_float
   string_of_int string_of_float string_of_bool
   failwith fst snd
*)

type binop =
  | Add | Sub | Mul | Div | Mod
  | Eq | Ne | Lt | Le | Gt | Ge
  | And | Or | Concat     (* Concat is ^ *)

type unop = Neg | Not

type expr = { id : int; desc : expr_desc; pos : pos }

and assign_target =
  | AVar of string                    (* x <- e          (local mutable or field) *)
  | AField of expr * string           (* r.f <- e        (record field) *)

and expr_desc =
  | EUnit
  | EInt of int
  | EFloat of float
  | EBool of bool
  | EChar of char
  | EStr of string
  | EVar of string
  | ETuple of expr list                       (* (a, b, c)  len >= 2 *)
  | EList of expr list                        (* [a; b] *)
  | ECons of expr * expr                      (* x :: xs *)
  | ERecord of (string * expr) list           (* { x = e; y = e } *)
  | EField of expr * string                   (* r.x *)
  | EAssign of assign_target * expr           (* x <- e ; r.f <- e *)
  | ECall of expr * string * expr list        (* obj # m a b *)
  | ELocalCall of string * expr list          (* f a b / Circle-ish? no, ctors are ECtor *)
  | ECtor of string * expr list               (* Circle e / Dot / Some e / None *)
  | ENew of string * expr list                (* new c args *)
  | EMatch of expr * match_arm list
  | EIf of expr * expr * expr
  | ELet of string * expr * expr              (* let x = e1 in e2 *)
  | ELetMut of string * expr * expr           (* let mutable x = e1 in e2 *)
  | ELetTuple of string list * expr * expr    (* let (a, b) = e1 in e2 *)
  | ESeq of expr * expr                       (* e1; e2 *)
  | EWhile of expr * expr                     (* while e1 do e2 done *)
  | EForIn of string * expr * expr            (* for x in xs do body done *)
  | EForRange of string * bool * expr * expr * expr
      (* for i = a to b do body done (true) / for i = a downto b (false) *)
  | EBin of binop * expr * expr
  | EUnary of unop * expr
  | ETyped of expr * typ                      (* (e : t) *)
  | ESelfField of string
      (* checker-only: inside a method, a bare EVar that names a field or
         constructor parameter is rewritten to ESelfField and means this.f.
         The parser never produces this node. *)

and match_arm = { pat : pattern; guard : expr option; rhs : expr }

and pattern =
  | PWild                                   (* _ *)
  | PVar of string
  | PUnit
  | PInt of int
  | PStr of string
  | PBool of bool
  | PChar of char
  | PCtor of string * pattern list          (* Circle r | Some x | None | Dot *)
  | PTuple of pattern list
  | PRecord of (string * pattern) list      (* { a = p1; b = p2 } *)
  | PNil                                    (* [] *)
  | PCons of pattern * pattern              (* x :: xs *)

type type_decl =
  | TDRecord of record_decl
  | TDVariant of variant_decl
  | TDTypeAlias of type_alias_decl

and type_alias_decl = {
  aname : string;
  atparams : string list;                       (* 'a 'b -> ["a";"b"] *)
  aexpands : typ;                               (* the aliased type *)
  apos : pos;           (* `type` keyword *)
}

and record_decl = {
  rname : string;
  rtparams : string list;                       (* 'a 'b -> ["a";"b"] *)
  rfields : (string * typ * bool) list;         (* name, type, mutable *)
  rpos : pos;           (* `type` keyword *)
}

and variant_decl = {
  vname : string;
  vtparams : string list;
  vctors : (string * typ list) list;            (* ctor name, payload *)
  vpos : pos;           (* `type` keyword *)
}

(* Function return annotation is required. Method return annotation required.
   Top-level `let x = e` values must have inferable type (literal, record,
   ctor, call, list, tuple, field, var). *)

type fun_decl = {
  fname : string;
  frec : bool;
  fparams : (string * typ) list;
  fret : typ;
  fbody : expr;
  fpos : pos;           (* `let` keyword *)
}

type method_sig = {
  msname : string;
  msparams : (string * typ) list;
  msret : typ;
}

type class_type_decl = {
  ctname : string;
  ctmethods : method_sig list;
  ctpos : pos;          (* `class` keyword *)
}

type cfield = {
  cfname : string;
  cfmut : bool;
  cfinit : expr;
  cftyp : typ option;    (* annotation `val x : t = e`; usually inferred *)
  cfpos : pos;           (* `val` keyword *)
}

type method_decl = {
  mname : string;
  mstatic : bool;
  mprivate : bool;
  mparams : (string * typ) list;
  mret : typ;
  mbody : expr;
  mpos : pos;            (* `method` keyword *)
}

type class_decl = {
  cname : string;
  cparams : (string * typ) list;   (* constructor parameters, become final fields *)
  cself : string;                  (* self name from `object (self)`; "self" if absent *)
  cinherits : string list;         (* `inherit printable` = Java interfaces it implements *)
  cfields : cfield list;
  cmethods : method_decl list;
  cpos : pos;            (* `class` keyword *)
}

type decl =
  | DType of type_decl
  | DFun of fun_decl
  | DClass of class_decl
  | DClassType of class_type_decl

type program = { file : string; decls : decl list }

(* The Java top-level class name for a file: basename without extension,
   unchanged. File `Demo.mlj` produces Demo.java containing everything. *)
