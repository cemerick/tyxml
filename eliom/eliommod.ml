(* Ocsigen
 * http://www.ocsigen.org
 * Module eliommod.ml
 * Copyright (C) 2007 Vincent Balat
 * Laboratoire PPS - CNRS Université Paris Diderot
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, with linking exception;
 * either version 2.1 of the License, or (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.
 *)
(*****************************************************************************)
(*****************************************************************************)
(** Internal functions used by Eliom:                                        *)
(** Tables of services (global and session tables,                           *)
(** persistant and volatile data tables)                                     *)
(** Store and load services                                                  *)
(*****************************************************************************)
(*****************************************************************************)

open Lwt
open Ocsigen_http_frame
open Ocsigen_lib
open Ocsigen_extensions
open Lazy


(****************************************************************************)
let default_max_sessions_per_group = 5
let default_max_sessions_per_subnet = 1000000 (* volatiles sessions *)
(* Must be large enough, because it must work behind a reverse proxy.

   If 1 session takes 1000 bytes (data + tables etc),
   1 million sessions take 1 GB.

   If somebody opens 1000 sessions per second, 
   then it will take 1000 s (16 minutes) to reach 1000000.

   It means that regular users will have their sessions closed
   after 16 minutes of inactivity if they share their sub network with
   someone doing an attack (or if the server is behind a proxy).

   In any case, it is better to use session groups if possible.
 *)

let default_max_anonymous_services_per_subnet = 500000
let default_max_anonymous_services_per_session = 1000

let new_sitedata =
  (* We want to keep the old site data even if we reload the server *)
  (* To do that, we keep the site data in a table *)
  let module S = Hashtbl.Make(struct
                                type t = 
                                    Ocsigen_extensions.virtual_hosts * url_path
                                let equal (vh1, u1 : t) (vh2, u2 : t) =
                                  Ocsigen_extensions.equal_virtual_hosts vh1 vh2
                                  && u1 = u2
                                let hash (vh, u : t) =
                                  Hashtbl.hash (
                                    Ocsigen_extensions.hash_virtual_hosts vh, u)
                              end)
  in
  let t = S.create 5 in
  fun host site_dir ->
    let key = (host, site_dir) in
    try
      S.find t key
    with
      | Not_found ->
          let sitedata =
            {Eliom_common.servtimeout = None, [];
             datatimeout = None, [];
             perstimeout = None, [];
             site_dir = site_dir;
(*VVV encode=false??? *)
             site_dir_string = Ocsigen_lib.string_of_url_path
                ~encode:false site_dir;
             global_services = 
                Eliom_common.empty_tables 
                  default_max_anonymous_services_per_subnet false;
             session_services = Eliommod_cookies.new_service_cookie_table ();
             session_data = Eliommod_cookies.new_data_cookie_table ();
             remove_session_data = (fun cookie -> ());
             not_bound_in_data_tables = (fun cookie -> true);
             exn_handler = Eliommod_pagegen.def_handler;
             unregistered_services = [];
             unregistered_na_services = [];
             max_service_sessions_per_group =
                default_max_sessions_per_group;
             max_volatile_data_sessions_per_group =
                default_max_sessions_per_group;
             max_persistent_data_sessions_per_group =
                Some default_max_sessions_per_group;
             max_service_sessions_per_subnet =
                default_max_sessions_per_subnet;
             max_volatile_data_sessions_per_subnet =
                default_max_sessions_per_subnet;
             max_anonymous_services_per_session = 
                default_max_anonymous_services_per_session;
            }
          in
          Eliommod_gc.service_session_gc sitedata;
          Eliommod_gc.data_session_gc sitedata;
          S.add t key sitedata;
          sitedata















(*****************************************************************************)
(* Session service table *)
(** We associate to each service a function server_params -> page *)





(****************************************************************************)
(****************************************************************************)
(****************************************************************************)
open Simplexmlparser


(* The following is common to global config and site config *)
let rec parse_eliom_option
    allow_session_name
    (set_volatile_timeout,
     set_data_timeout,
     set_service_timeout,
     set_persistent_timeout)
    = 
  let parse_timeout_attrs tn attrs = 
    let aux = function
      | [("value", s)] -> s, None
      | [("sessionname", sn); ("value", s)]
      | [("value", s); ("sessionname", sn)] -> s, Some sn
      | _ -> 
          raise 
            (Error_in_config_file
               ("Eliom: Wrong attribute name for "^tn^" tag"))
    in 
    let a, sn = aux attrs in
    let a = match a with
      | "infinity" -> None
      | a -> 
          try Some (float_of_string a)
          with Failure _ -> 
            raise 
              (Error_in_config_file
                 ("Eliom: Wrong attribute value for "^tn^" tag"))
    in
    if allow_session_name || sn = None
    then
      let sn = match sn with
        | None -> None
        | Some "" -> Some None
        | c -> Some c
      in a, sn
    else
      raise 
        (Error_in_config_file
           ("Eliom: sessionname attribute not allowed for "^tn^" tag in global configuration"))
  in
  function
  | (Element ("volatiletimeout", attrs, [])) ->
      let t, snoo = parse_timeout_attrs "volatiletimeout" attrs in
      set_volatile_timeout snoo t
  | (Element ("datatimeout", attrs, [])) ->
      let t, snoo = parse_timeout_attrs "datatimeout" attrs in
      set_data_timeout snoo t
  | (Element ("servicetimeout", attrs, [])) ->
      let t, snoo = parse_timeout_attrs "servicetimeout" attrs in
      set_service_timeout snoo t
  | (Element ("persistenttimeout", attrs, [])) ->
      let t, snoo = parse_timeout_attrs "persistenttimeout" attrs in
      set_persistent_timeout snoo t
  | (Element (s, _, _)) ->
      raise (Error_in_config_file
               ("Unexpected content <"^s^"> inside eliom config"))
  | _ -> raise (Error_in_config_file ("Unexpected content inside eliom config"))


let parse_eliom_options f l = 
  let rec aux rest = function
    | [] -> rest
    | e::l -> 
        try
          parse_eliom_option true f e; 
          aux rest l
        with Error_in_config_file _ -> aux (e::rest) l
  in List.rev (aux [] l)


(*****************************************************************************)
(** Parsing global configuration for Eliommod: *)

let rec parse_global_config = function
  | [] -> ()
  | (Element ("sessiongcfrequency", [("value", s)], p))::ll ->
      (try
        let t = float_of_string s in
        Eliommod_gc.set_servicesessiongcfrequency (Some t);
        Eliommod_gc.set_datasessiongcfrequency (Some t)
      with Failure _ ->
        if s = "infinity"
        then begin
          Eliommod_gc.set_servicesessiongcfrequency None;
          Eliommod_gc.set_datasessiongcfrequency None
        end
        else raise (Error_in_config_file
                      "Eliom: Wrong value for <sessiongcfrequency>"));
      parse_global_config ll
  | (Element ("servicesessiongcfrequency", [("value", s)], p))::ll ->
      (try
        Eliommod_gc.set_servicesessiongcfrequency (Some (float_of_string s))
      with Failure _ ->
        if s = "infinity"
        then Eliommod_gc.set_servicesessiongcfrequency None
        else raise (Error_in_config_file
                      "Eliom: Wrong value for <servicesessiongcfrequency>"));
      parse_global_config ll
  | (Element ("datasessiongcfrequency", [("value", s)], p))::ll ->
      (try
        Eliommod_gc.set_datasessiongcfrequency (Some (float_of_string s))
      with Failure _ ->
        if s = "infinity"
        then Eliommod_gc.set_datasessiongcfrequency None
        else raise (Error_in_config_file
                      "Eliom: Wrong value for <datasessiongcfrequency>"));
      parse_global_config ll
  | (Element ("persistentsessiongcfrequency",
              [("value", s)], p))::ll ->
                (try
                  Eliommod_gc.set_persistentsessiongcfrequency
                    (Some (float_of_string s))
                with Failure _ ->
                  if s = "infinity"
                  then Eliommod_gc.set_persistentsessiongcfrequency None
                  else raise
                    (Error_in_config_file
                       "Eliom: Wrong value for <persistentsessiongcfrequency>"));
                parse_global_config ll
  | e::ll ->
      parse_eliom_option
        false
        ((fun _ -> Eliommod_timeouts.set_default_volatile_timeout),
         (fun _ -> Eliommod_timeouts.set_default_data_timeout),
         (fun _ -> Eliommod_timeouts.set_default_service_timeout),
         (fun _ -> Eliommod_timeouts.set_default_persistent_timeout))
        e;
      parse_global_config ll















(*****************************************************************************)

let exception_during_eliommodule_loading = ref false


(** Function to be called at the end of the initialisation phase *)
let end_init () =
  if !exception_during_eliommodule_loading then
    (* An eliom module failed with an exception. We do not check
       for the missing services, so that the exception can be correctly
       propagated by Ocsigen_extensions *)
    ()
  else
    try
      Eliom_common.verify_all_registered
        (Eliom_common.get_current_sitedata ());
      Eliom_common.end_current_sitedata ()
    with Eliom_common.Eliom_function_forbidden_outside_site_loading _ -> ()
      (*VVV The "try with" looks like a hack:
        end_init is called even for user config files ... but in that case,
        current_sitedata is not set ...
        It would be better to avoid calling end_init for user config files. *)

(** Function that will handle exceptions during the initialisation phase *)
let handle_init_exn = function
  | Eliom_common.Eliom_duplicate_registration s ->
      ("Eliom: Duplicate registration of service \""^s^
       "\". Please correct the module.")
  | Eliom_common.Eliom_there_are_unregistered_services (s, l1, l2) ->
      ("Eliom: in site /"^
       (Ocsigen_lib.string_of_url_path ~encode:false s)^" - "^
       (match l1 with
       | [] -> ""
       | [a] -> "One service or coservice has not been registered on URL /"
           ^(Ocsigen_lib.string_of_url_path ~encode:false a)^". "
       | a::ll ->
           let string_of = Ocsigen_lib.string_of_url_path ~encode:false in
           "Some services or coservices have not been registered \
             on URLs: "^
             (List.fold_left
                (fun beg v -> beg^", /"^(string_of v))
                ("/"^(string_of a))
                ll
             )^". ")^
       (match l2 with
       | [] -> ""
       | [Eliom_common.SNa_get' _] -> 
           "One non-attached GET coservice has not been registered."
       | [Eliom_common.SNa_post' _] -> 
           "One non-attached POST coservice has not been registered."
       | [Eliom_common.SNa_get_ a] -> "The non-attached GET service \""
           ^a^
           "\" has not been registered."
       | [Eliom_common.SNa_post_ a] -> "The non-attached POST service \""
           ^a^
           "\" has not been registered."
       | a::ll ->
           let string_of = function
             | Eliom_common.SNa_void_keep
             | Eliom_common.SNa_void_dontkeep
             | Eliom_common.SNa_no -> assert false
             | Eliom_common.SNa_get' _ -> "<GET coservice>"
             | Eliom_common.SNa_get_ n -> n^" (GET)"
             | Eliom_common.SNa_post' _ -> "<POST coservice>"
             | Eliom_common.SNa_post_ n -> n^" (POST)"
             | Eliom_common.SNa_get_csrf_safe _ -> " <GET CSRF-safe coservice>"
             | Eliom_common.SNa_post_csrf_safe _ -> "<POST CSRF-safe coservice>"
           in
           "Some non-attached services or coservices have not been registered: "^
             (List.fold_left
                (fun beg v -> beg^", "^(string_of v))
                (string_of a)
                ll
             )^".")^
         "\nPlease correct your modules and make sure you have linked in all the modules...")
  | Eliom_common.Eliom_function_forbidden_outside_site_loading f ->
      ("Eliom: Bad use of function \""^f^
         "\" outside site loading. \
         (for some functions, you must add the ~sp parameter \
               to use them after initialization. \
               Creation or registration of public service for example)")
  | Eliom_common.Eliom_page_erasing s ->
      ("Eliom: You cannot create a page or directory here. "^s^
       " already exists. Please correct your modules.")
  | Eliom_common.Eliom_error_while_loading_site s -> s
  | e -> raise e

(*****************************************************************************)
(** Module loading *)
let config = ref []

type module_to_load = Files of string list | Name of string

let load_eliom_module sitedata cmo_or_name content =
  let preload () =
    config := content;
    Eliom_common.begin_load_eliom_module ()
  in
  let postload () =
    Eliom_common.end_load_eliom_module ();
    config := []
  in
  try
    match cmo_or_name with
      | Files cmo -> Ocsigen_loader.loadfiles preload postload true cmo
      | Name name -> Ocsigen_loader.init_module preload postload true name
  with Ocsigen_loader.Dynlink_error (n, e) ->
    raise (Eliom_common.Eliom_error_while_loading_site
             (Printf.sprintf "Eliom: while loading %s: %s"
                n
                (try handle_init_exn e 
                 with e -> Ocsigen_lib.string_of_exn e)))



(*****************************************************************************)
(* If page has already been generated becauise there are several <eliom>
   tags in the same site:
*)
let gen_nothing () _ = 
  Lwt.return Ocsigen_extensions.Ext_do_nothing



(*****************************************************************************)
let default_module_action _ = failwith "default_module_action"

(** Parsing of config file for each site: *)
let parse_config hostpattern site_dir =
(*--- if we put the following line here: *)
  let sitedata = new_sitedata hostpattern site_dir in
(*--- then there is one service tree for each <site> *)
(*--- (mutatis mutandis for the following line:) *)
  Eliom_common.absolute_change_sitedata sitedata;
  let firsteliomtag = ref true in
  let rec parse_module_attrs file = function
    | [] -> file
    | ("name", s)::suite ->
        (match file with
           | None -> parse_module_attrs (Some (Name s)) suite
           | _ ->
               raise (Error_in_config_file
                        ("Duplicate attribute module in <eliom>")))
    | ("module", s)::suite ->
        (match file with
           | None -> parse_module_attrs (Some (Files [s])) suite
           | _ -> 
               raise (Error_in_config_file
                        ("Duplicate attribute module in <eliom>")))
    | ("findlib-package", s)::suite ->
        begin match file with
          | None ->
              begin try
                parse_module_attrs
                  (Some (Files (Ocsigen_loader.findfiles s))) suite
              with Ocsigen_loader.Findlib_error _ as e ->
                raise (Error_in_config_file
                         (Printf.sprintf "Findlib error: %s"
                            (Ocsigen_lib.string_of_exn e)))
              end
          | _ -> raise (Error_in_config_file
                          ("Duplicate attribute module in <eliom>"))
        end
    | (s, _)::_ ->
        raise
          (Error_in_config_file ("Wrong attribute for <eliom>: "^s))
  in fun _ parse_site -> function
    | Element ("eliommodule", atts, content) ->
        Eliommod_extensions.register_eliom_extension 
          default_module_action;
        (match parse_module_attrs None atts with
          | Some file_or_name ->
              exception_during_eliommodule_loading := true;
              load_eliom_module sitedata file_or_name content;
              exception_during_eliommodule_loading := false
          | _ -> ());
        if Eliommod_extensions.get_eliom_extension ()
          != default_module_action
        then
          Eliommod_pagegen.gen
            (Some (Eliommod_extensions.get_eliom_extension ()))
            sitedata
        else gen_nothing ()
    | Element ("eliom", atts, content) ->
(*--- if we put the line "new_sitedata" here, then there is
  one service table for each <eliom> tag ...
  I think the other one is the best, 
  because it corresponds to the way
  browsers manage cookies (one cookie for one site).
  Thus we can have one site in several cmo (with one session).
 *)
        let set_timeout f session_name_oo v =
          f
            ?fullsessname:(Ocsigen_lib.apply_option 
                             (Eliom_common.make_fullsessname2
                                sitedata.Eliom_common.site_dir_string)
                             session_name_oo)
            ~recompute_expdates:false
            true
            true
            sitedata
            v
        in
        let content =
          parse_eliom_options
            ((fun snoo v -> 
                set_timeout Eliommod_timeouts.set_global_data_timeout2 snoo v;
                set_timeout Eliommod_timeouts.set_global_service_timeout2 snoo v
             ),
             (set_timeout Eliommod_timeouts.set_global_data_timeout2),
             (set_timeout Eliommod_timeouts.set_global_service_timeout2),
             (set_timeout Eliommod_timeouts.set_global_persistent_timeout2))
            content
        in
        (match parse_module_attrs None atts with
          | Some file_or_name -> 
              load_eliom_module sitedata file_or_name content
          | _ -> ());
        (* We must generate the page only if it is the first <eliom> tag 
           for that site: *)
        if !firsteliomtag
        then begin
          firsteliomtag := false;
          Eliommod_pagegen.gen None sitedata
        end
        else
          gen_nothing ()
    | Element (t, _, _) ->
        raise (Ocsigen_extensions.Bad_config_tag_for_extension t)
    | _ -> raise (Error_in_config_file "(Eliommod extension)")



(*****************************************************************************)
(** extension registration *)
let () =
  register_extension
    ~name:"eliom"
    ~fun_site:parse_config
    ~end_init
    ~exn_handler:handle_init_exn
    ~init_fun:parse_global_config
    ();
  Eliommod_gc.persistent_session_gc ()

