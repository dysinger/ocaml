(**************************************************************************)
(*                                                                        *)
(*                                 OCaml                                  *)
(*                                                                        *)
(*             Xavier Leroy, projet Cristal, INRIA Rocquencourt           *)
(*                                                                        *)
(*   Copyright 1996 Institut National de Recherche en Informatique et     *)
(*     en Automatique.                                                    *)
(*                                                                        *)
(*   All rights reserved.  This file is distributed under the terms of    *)
(*   the GNU Lesser General Public License version 2.1, with the          *)
(*   special exception on linking described in the file LICENSE.          *)
(*                                                                        *)
(**************************************************************************)

(* Operations on module types *)

open Asttypes
open Path
open Types


let rec scrape env mty =
  match mty with
    Mty_ident p ->
      begin try
        scrape env (Env.find_modtype_expansion p env)
      with Not_found ->
        mty
      end
  | _ -> mty

let freshen mty =
  Subst.modtype Subst.identity mty

let rec strengthen ~aliasable env mty p =
  match scrape env mty with
    Mty_signature sg ->
      Mty_signature(strengthen_sig ~aliasable env sg p 0)
  | Mty_functor(param, arg, res)
    when !Clflags.applicative_functors && Ident.name param <> "*" ->
      Mty_functor(param, arg,
        strengthen ~aliasable:false env res (Papply(p, Pident param)))
  | mty ->
      mty

and strengthen_sig ~aliasable env sg p pos =
  match sg with
    [] -> []
  | (Sig_value(_, desc) as sigelt) :: rem ->
      let nextpos =
        match desc.val_kind with
        | Val_prim _ -> pos
        | _ -> pos + 1
      in
      sigelt :: strengthen_sig ~aliasable env rem p nextpos
  | Sig_type(id, {type_kind=Type_abstract}, _) ::
    (Sig_type(id', {type_private=Private}, _) :: _ as rem)
    when Ident.name id = Ident.name id' ^ "#row" ->
      strengthen_sig ~aliasable env rem p pos
  | Sig_type(id, decl, rs) :: rem ->
      let newdecl =
        match decl.type_manifest, decl.type_private, decl.type_kind with
          Some _, Public, _ -> decl
        | Some _, Private, (Type_record _ | Type_variant _) -> decl
        | _ ->
            let manif =
              Some(Btype.newgenty(Tconstr(Pdot(p, Ident.name id, nopos),
                                          decl.type_params, ref Mnil))) in
            if decl.type_kind = Type_abstract then
              { decl with type_private = Public; type_manifest = manif }
            else
              { decl with type_manifest = manif }
      in
      Sig_type(id, newdecl, rs) :: strengthen_sig ~aliasable env rem p pos
  | (Sig_typext _ as sigelt) :: rem ->
      sigelt :: strengthen_sig ~aliasable env rem p (pos+1)
  | Sig_module(id, md, rs) :: rem ->
      let str =
        strengthen_decl ~aliasable env md (Pdot(p, Ident.name id, pos))
      in
      Sig_module(id, str, rs)
      :: strengthen_sig ~aliasable
        (Env.add_module_declaration ~check:false id md env) rem p (pos+1)
      (* Need to add the module in case it defines manifest module types *)
  | Sig_modtype(id, decl) :: rem ->
      let newdecl =
        match decl.mtd_type with
          None ->
            {decl with mtd_type = Some(Mty_ident(Pdot(p,Ident.name id,nopos)))}
        | Some _ ->
            decl
      in
      Sig_modtype(id, newdecl) ::
      strengthen_sig ~aliasable (Env.add_modtype id decl env) rem p pos
      (* Need to add the module type in case it is manifest *)
  | (Sig_class _ as sigelt) :: rem ->
      sigelt :: strengthen_sig ~aliasable env rem p (pos+1)
  | (Sig_class_type _ as sigelt) :: rem ->
      sigelt :: strengthen_sig ~aliasable env rem p pos

and strengthen_decl ~aliasable env md p =
  match md.md_type with
  | Mty_alias _ -> md
  | _ when aliasable -> {md with md_type = Mty_alias(Mta_present, p)}
  | mty -> {md with md_type = strengthen ~aliasable env mty p}

let () = Env.strengthen := strengthen

let rec make_aliases_absent mty =
  match mty with
  | Mty_alias(_, p) ->
      Mty_alias(Mta_absent, p)
  | Mty_signature sg ->
      Mty_signature(make_aliases_absent_sig sg)
  | Mty_functor(param, arg, res) ->
      Mty_functor(param, arg, make_aliases_absent res)
  | mty ->
      mty

and make_aliases_absent_sig sg =
  match sg with
    [] -> []
  | Sig_module(id, md, rs) :: rem ->
      let str =
        { md with md_type = make_aliases_absent md.md_type }
      in
      Sig_module(id, str, rs) :: make_aliases_absent_sig rem
  | sigelt :: rem ->
      sigelt :: make_aliases_absent_sig rem

let scrape_for_type_of env mty =
  let rec loop env path mty =
    match mty, path with
    | Mty_alias(_, path), _ -> begin
        try
          let md = Env.find_module path env in
          loop env (Some path) md.md_type
        with Not_found -> mty
      end
    | mty, Some path ->
        strengthen ~aliasable:false env mty path
    | _ -> mty
  in
  make_aliases_absent (loop env None mty)

(* In nondep_supertype, env is only used for the type it assigns to id.
   Hence there is no need to keep env up-to-date by adding the bindings
   traversed. *)

type variance = Co | Contra | Strict

let rec nondep_mty env va ids mty =
  match mty with
    Mty_ident p ->
      begin match Path.find_free_opt ids p with
      | Some id ->
          let expansion =
            try Env.find_modtype_expansion p env
            with Not_found ->
              raise (Ctype.Nondep_cannot_erase id)
          in
          nondep_mty env va ids expansion
      | None -> mty
      end
  | Mty_alias(_, p) ->
      begin match Path.find_free_opt ids p with
      | Some id ->
          let expansion =
            try Env.find_module p env
            with Not_found ->
              raise (Ctype.Nondep_cannot_erase id)
          in
          nondep_mty env va ids expansion.md_type
      | None -> mty
      end
  | Mty_signature sg ->
      Mty_signature(nondep_sig env va ids sg)
  | Mty_functor(param, arg, res) ->
      let var_inv =
        match va with Co -> Contra | Contra -> Co | Strict -> Strict in
      Mty_functor(param, Misc.may_map (nondep_mty env var_inv ids) arg,
                  nondep_mty
                    (Env.add_module ~arg:true param
                        (Btype.default_mty arg) env) va ids res)

and nondep_sig_item env va ids = function
  | Sig_value(id, d) ->
      Sig_value(id,
                {d with val_type = Ctype.nondep_type env ids d.val_type})
  | Sig_type(id, d, rs) ->
      Sig_type(id, Ctype.nondep_type_decl env ids (va = Co) d, rs)
  | Sig_typext(id, ext, es) ->
      Sig_typext(id, Ctype.nondep_extension_constructor env ids ext, es)
  | Sig_module(id, md, rs) ->
      Sig_module(id, {md with md_type=nondep_mty env va ids md.md_type}, rs)
  | Sig_modtype(id, d) ->
      begin try
        Sig_modtype(id, nondep_modtype_decl env ids d)
      with Ctype.Nondep_cannot_erase _ as exn ->
        match va with
          Co -> Sig_modtype(id, {mtd_type=None; mtd_loc=Location.none;
                                 mtd_attributes=[]})
        | _  -> raise exn
      end
  | Sig_class(id, d, rs) ->
      Sig_class(id, Ctype.nondep_class_declaration env ids d, rs)
  | Sig_class_type(id, d, rs) ->
      Sig_class_type(id, Ctype.nondep_cltype_declaration env ids d, rs)

and nondep_sig env va ids sg =
  List.map (nondep_sig_item env va ids) sg

and nondep_modtype_decl env ids mtd =
  {mtd with mtd_type = Misc.may_map (nondep_mty env Strict ids) mtd.mtd_type}

let nondep_supertype env ids = nondep_mty env Co ids
let nondep_sig_item env ids = nondep_sig_item env Co ids

let enrich_typedecl env p id decl =
  match decl.type_manifest with
    Some _ -> decl
  | None ->
      try
        let orig_decl = Env.find_type p env in
        if decl.type_arity <> orig_decl.type_arity then
          decl
        else
          let orig_ty =
            Ctype.reify_univars
              (Btype.newgenty(Tconstr(p, orig_decl.type_params, ref Mnil)))
          in
          let new_ty =
            Ctype.reify_univars
              (Btype.newgenty(Tconstr(Pident id, decl.type_params, ref Mnil)))
          in
          let env = Env.add_type ~check:false id decl env in
          Ctype.mcomp env orig_ty new_ty;
          let orig_ty =
            Btype.newgenty(Tconstr(p, decl.type_params, ref Mnil))
          in
          {decl with type_manifest = Some orig_ty}
      with Not_found | Ctype.Unify _ ->
        (* - Not_found: type which was not present in the signature, so we don't
           have anything to do.
           - Unify: the current declaration is not compatible with the one we
           got from the signature. We should just fail now, but then, we could
           also have failed if the arities of the two decls were different,
           which we didn't. *)
        decl

let rec enrich_modtype env p mty =
  match mty with
    Mty_signature sg ->
      Mty_signature(List.map (enrich_item env p) sg)
  | _ ->
      mty

and enrich_item env p = function
    Sig_type(id, decl, rs) ->
      Sig_type(id,
                enrich_typedecl env (Pdot(p, Ident.name id, nopos)) id decl, rs)
  | Sig_module(id, md, rs) ->
      Sig_module(id,
                  {md with
                   md_type = enrich_modtype env
                       (Pdot(p, Ident.name id, nopos)) md.md_type},
                 rs)
  | item -> item

let rec type_paths env p mty =
  match scrape env mty with
    Mty_ident _ -> []
  | Mty_alias _ -> []
  | Mty_signature sg -> type_paths_sig env p 0 sg
  | Mty_functor _ -> []

and type_paths_sig env p pos sg =
  match sg with
    [] -> []
  | Sig_value(_id, decl) :: rem ->
      let pos' = match decl.val_kind with Val_prim _ -> pos | _ -> pos + 1 in
      type_paths_sig env p pos' rem
  | Sig_type(id, _decl, _) :: rem ->
      Pdot(p, Ident.name id, nopos) :: type_paths_sig env p pos rem
  | Sig_module(id, md, _) :: rem ->
      type_paths env (Pdot(p, Ident.name id, pos)) md.md_type @
      type_paths_sig (Env.add_module_declaration ~check:false id md env)
        p (pos+1) rem
  | Sig_modtype(id, decl) :: rem ->
      type_paths_sig (Env.add_modtype id decl env) p pos rem
  | (Sig_typext _ | Sig_class _) :: rem ->
      type_paths_sig env p (pos+1) rem
  | (Sig_class_type _) :: rem ->
      type_paths_sig env p pos rem

let rec no_code_needed env mty =
  match scrape env mty with
    Mty_ident _ -> false
  | Mty_signature sg -> no_code_needed_sig env sg
  | Mty_functor(_, _, _) -> false
  | Mty_alias(Mta_absent, _) -> true
  | Mty_alias(Mta_present, _) -> false

and no_code_needed_sig env sg =
  match sg with
    [] -> true
  | Sig_value(_id, decl) :: rem ->
      begin match decl.val_kind with
      | Val_prim _ -> no_code_needed_sig env rem
      | _ -> false
      end
  | Sig_module(id, md, _) :: rem ->
      no_code_needed env md.md_type &&
      no_code_needed_sig
        (Env.add_module_declaration ~check:false id md env) rem
  | (Sig_type _ | Sig_modtype _ | Sig_class_type _) :: rem ->
      no_code_needed_sig env rem
  | (Sig_typext _ | Sig_class _) :: _ ->
      false


(* Check whether a module type may return types *)

let rec contains_type env = function
    Mty_ident path ->
      begin try match (Env.find_modtype path env).mtd_type with
      | None -> raise Exit (* PR#6427 *)
      | Some mty -> contains_type env mty
      with Not_found -> raise Exit
      end
  | Mty_signature sg ->
      contains_type_sig env sg
  | Mty_functor (_, _, body) ->
      contains_type env body
  | Mty_alias _ ->
      ()

and contains_type_sig env = List.iter (contains_type_item env)

and contains_type_item env = function
    Sig_type (_,({type_manifest = None} |
                 {type_kind = Type_abstract; type_private = Private}),_)
  | Sig_modtype _
  | Sig_typext (_, {ext_args = Cstr_record _}, _) ->
      (* We consider that extension constructors with an inlined
         record create a type (the inlined record), even though
         it would be technically safe to ignore that considering
         the current constraints which guarantee that this type
         is kept local to expressions.  *)
      raise Exit
  | Sig_module (_, {md_type = mty}, _) ->
      contains_type env mty
  | Sig_value _
  | Sig_type _
  | Sig_typext _
  | Sig_class _
  | Sig_class_type _ ->
      ()

let contains_type env mty =
  try contains_type env mty; false with Exit -> true


(* Remove module aliases from a signature *)

let rec get_prefixes = function
    Pident _ -> Path.Set.empty
  | Pdot (p, _, _)
  | Papply (p, _) -> Path.Set.add p (get_prefixes p)

let rec get_arg_paths = function
    Pident _ -> Path.Set.empty
  | Pdot (p, _, _) -> get_arg_paths p
  | Papply (p1, p2) ->
      Path.Set.add p2
        (Path.Set.union (get_prefixes p2)
           (Path.Set.union (get_arg_paths p1) (get_arg_paths p2)))

let rec rollback_path subst p =
  try Pident (Path.Map.find p subst)
  with Not_found ->
    match p with
      Pident _ | Papply _ -> p
    | Pdot (p1, s, n) ->
        let p1' = rollback_path subst p1 in
        if Path.same p1 p1' then p else rollback_path subst (Pdot (p1', s, n))

let rec collect_ids subst bindings p =
    begin match rollback_path subst p with
      Pident id ->
        let ids =
          try collect_ids subst bindings (Ident.find_same id bindings)
          with Not_found -> Ident.Set.empty
        in
        Ident.Set.add id ids
    | _ -> Ident.Set.empty
    end

let collect_arg_paths mty =
  let open Btype in
  let paths = ref Path.Set.empty
  and subst = ref Path.Map.empty
  and bindings = ref Ident.empty in
  (* let rt = Ident.create "Root" in
     and prefix = ref (Path.Pident rt) in *)
  let it_path p = paths := Path.Set.union (get_arg_paths p) !paths
  and it_signature_item it si =
    type_iterators.it_signature_item it si;
    match si with
      Sig_module (id, {md_type=Mty_alias(_, p)}, _) ->
        bindings := Ident.add id p !bindings
    | Sig_module (id, {md_type=Mty_signature sg}, _) ->
        List.iter
          (function Sig_module (id', _, _) ->
              subst :=
                Path.Map.add (Pdot (Pident id, Ident.name id', -1)) id' !subst
            | _ -> ())
          sg
    | _ -> ()
  in
  let it = {type_iterators with it_path; it_signature_item} in
  it.it_module_type it mty;
  it.it_module_type unmark_iterators mty;
  Path.Set.fold (fun p -> Ident.Set.union (collect_ids !subst !bindings p))
    !paths Ident.Set.empty

type remove_alias_args =
    { mutable modified: bool;
      exclude: Ident.t -> Path.t -> bool;
      scrape: Env.t -> module_type -> module_type }

let rec remove_aliases_mty env args mty =
  let args' = {args with modified = false} in
  let mty' =
    match args.scrape env mty with
      Mty_signature sg ->
        Mty_signature (remove_aliases_sig env args' sg)
    | Mty_alias _ ->
        let mty' = Env.scrape_alias env mty in
        if mty' = mty then mty else
        (args'.modified <- true; remove_aliases_mty env args' mty')
    | mty ->
        mty
  in
  if args'.modified then (args.modified <- true; mty') else mty

and remove_aliases_sig env args sg =
  match sg with
    [] -> []
  | Sig_module(id, md, rs) :: rem  ->
      let mty =
        match md.md_type with
          Mty_alias (_, p) when args.exclude id p ->
            md.md_type
        | mty ->
            remove_aliases_mty env args mty
      in
      Sig_module(id, {md with md_type = mty} , rs) ::
      remove_aliases_sig (Env.add_module id mty env) args rem
  | Sig_modtype(id, mtd) :: rem ->
      Sig_modtype(id, mtd) ::
      remove_aliases_sig (Env.add_modtype id mtd env) args rem
  | it :: rem ->
      it :: remove_aliases_sig env args rem

let scrape_for_functor_arg env mty =
  let exclude _id p =
    try ignore (Env.find_module p env); true with Not_found -> false
  in
  remove_aliases_mty env {modified=false; exclude; scrape} mty

let scrape_for_type_of ~remove_aliases env mty =
  if remove_aliases then begin
    let excl = collect_arg_paths mty in
    let exclude id _p = Ident.Set.mem id excl in
    let scrape _ mty = mty in
    remove_aliases_mty env {modified=false; exclude; scrape} mty
  end else begin
    scrape_for_type_of env mty
  end

(* Lower non-generalizable type variables *)

let lower_nongen nglev mty =
  let open Btype in
  let it_type_expr it ty =
    let ty = repr ty in
    match ty with
      {desc=Tvar _; level} ->
        if level < generic_level && level > nglev then set_level ty nglev
    | _ ->
        type_iterators.it_type_expr it ty
  in
  let it = {type_iterators with it_type_expr} in
  it.it_module_type it mty;
  it.it_module_type unmark_iterators mty
