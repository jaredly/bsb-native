(* Copyright (C) 2015-2016 Bloomberg Finance L.P.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * In addition to the permissions granted to you by the LGPL, you may combine
 * or link a "work that uses the Library" with a publicly distributed version
 * of this file to produce a combined library or application, then distribute
 * that combined work under the terms of your choosing, with no requirement
 * to comply with the obligations normally placed on you by section 4 of the
 * LGPL version 3 (or the corresponding section of a later version of the LGPL
 * should you choose to use a later version).
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA. *)

let config_file_bak = "bsconfig.json.bak"
let get_list_string = Bsb_build_util.get_list_string
let (//) = Ext_path.combine

let resolve_package backend cwd  package_name = 
  let x =  Bsb_pkg.resolve_bs_package ~cwd package_name  in
  let nested = match backend with
    | Bsb_config_types.Js -> "js"
    | Bsb_config_types.Bytecode -> "bytecode"
    | Bsb_config_types.Native -> "native"
  in
  {
    Bsb_config_types.package_name ;
    package_install_path = x // Bsb_config.lib_ocaml // nested
  }

let parse_allowed_build_kinds map =
  let open Ext_json_types in
  match String_map.find_opt Bsb_build_schemas.allowed_build_kinds map with 
  | Some (Arr {loc_start; content = s }) ->   
    List.map (fun (s : string) ->
      match s with 
      | "js"       -> Bsb_config_types.Js
      | "native"   -> Bsb_config_types.Native
      | "bytecode" -> Bsb_config_types.Bytecode
      | str -> Bsb_exception.errorf ~loc:loc_start "'allowed-build-kinds' field expects one of, or an array of: 'js', 'bytecode' or 'native'. Found '%s'" str
    ) (Bsb_build_util.get_list_string s) 
  | Some (Str {str = "js"} )       -> [Bsb_config_types.Js]
  | Some (Str {str = "native"} )   -> [Bsb_config_types.Native]
  | Some (Str {str = "bytecode"} ) -> [Bsb_config_types.Bytecode]
  | Some (Str {str; loc} ) -> Bsb_exception.errorf ~loc:loc "'allowed-build-kinds' field expects one of, or an array of: 'js', 'bytecode' or 'native'. Found '%s'" str
  | Some x -> Bsb_exception.config_error x "'allowed-build-kinds' field expects one of, or an array of: 'js', 'bytecode' or 'native'"
  | None -> Bsb_default.allowed_build_kinds

(* Key is the path *)
let (|?)  m (key, cb) =
  m  |> Ext_json.test key cb

let parse_entries (field : Ext_json_types.t array) =
  Ext_array.to_list_map (function
      | Ext_json_types.Obj {map} ->
        (* kind defaults to bytecode *)
        let kind = ref "js" in
        let main = ref None in
        let _ = map
                |? (Bsb_build_schemas.kind, `Str (fun x -> kind := x))
                |? (Bsb_build_schemas.main, `Str (fun x -> main := Some x))
        in
        let path = begin match !main with
          (* This is technically optional when compiling to js *)
          | None when !kind = Literals.js ->
            "Index"
          | None -> 
            failwith "Missing field 'main'. That field is required its value needs to be the main module for the target"
          | Some path -> path
        end in
        if !kind = Literals.native then
          Some (Bsb_config_types.NativeTarget path)
        else if !kind = Literals.bytecode then
          Some (Bsb_config_types.BytecodeTarget path)
        else if !kind = Literals.js then
          Some (Bsb_config_types.JsTarget path)
        else
          failwith "Missing field 'kind'. That field is required and its value be 'js', 'native' or 'bytecode'"
      | _ -> failwith "Unrecognized object inside array 'entries' field.") 
    field



let package_specs_and_super_errors_from_bsconfig () = 
  let json = Ext_json_parse.parse_json_from_file Literals.bsconfig_json in
  begin match json with
    | Obj {map} ->
      let package_specs = begin 
        match String_map.find_opt Bsb_build_schemas.package_specs map with 
        | Some x ->
          Bsb_package_specs.from_json x
        | None -> 
          Bsb_package_specs.default_package_specs
      end in
      let bs_super_errors = ref false in
      map |? (Bsb_build_schemas.bs_super_errors, `Bool (fun b -> bs_super_errors := b)) |> ignore;
      (package_specs, !bs_super_errors)
    | _ -> assert false
  end

let entries_from_bsconfig () = 
  let json = Ext_json_parse.parse_json_from_file Literals.bsconfig_json in
  begin match json with
    | Obj {map} ->
      let entries = ref Bsb_default.main_entries in
      map |? (Bsb_build_schemas.entries, `Arr (fun s -> entries := parse_entries s)) |> ignore;
      !entries
    | _ -> assert false
  end



(*TODO: it is a little mess that [cwd] and [project dir] are shared*)




(** ATT: make sure such function is re-entrant. 
    With a given [cwd] it works anywhere*)
let interpret_json 
    ~override_package_specs
    ~bsc_dir 
    ~generate_watch_metadata
    ~no_dev 
    ~backend
    cwd  

  : Bsb_config_types.t =

  let reason_react_jsx = ref None in 
  let config_json = (cwd // Literals.bsconfig_json) in
  let refmt = ref None in
  let refmt_flags = ref Bsb_default.refmt_flags in
  let build_script = ref None in
  let static_libraries = ref [] in
  let package_name = ref None in 
  let namespace = ref false in 
  let bs_external_includes = ref [] in 
  let bs_super_errors = ref false in
  (** we should not resolve it too early,
      since it is external configuration, no {!Bsb_build_util.convert_and_resolve_path}
  *)
  let bsc_flags = ref Bsb_default.bsc_flags in  
  let warnings = ref Bsb_default.warnings in
  let ocamlfind_dependencies = ref [] in
  let bin_annot = ref false in
  let global_ocaml_compiler = ref false in
  let ppx_flags = ref []in 

  let js_post_build_cmd = ref None in 
  let built_in_package = ref None in
  let generate_merlin = ref true in 
  let generators = ref String_map.empty in 

  (* When we plan to add more deps here,
     Make sure check it is consistent that for nested deps, we have a 
     quck check by just re-parsing deps 
     Make sure it works with [-make-world] [-clean-world]
  *)
  let bs_dependencies = ref [] in 
  let bs_dev_dependencies = ref [] in
  (* Setting ninja is a bit complex
     1. if [build.ninja] does use [ninja] we need set a variable
     2. we need store it so that we can call ninja correctly
  *)
  let entries = ref Bsb_default.main_entries in
  let cut_generators = ref false in 
  let config_json_chan = open_in_bin config_json  in
  let global_data = Ext_json_parse.parse_json_from_chan config_json_chan  in
  match global_data with
  | Obj { map} ->
    (* The default situation is empty *)
    (match String_map.find_opt Bsb_build_schemas.use_stdlib map with      
     | Some (False _) -> 
       ()
     | None 
     | Some _ ->
      let x = Bsb_pkg.resolve_bs_package ~cwd Bs_version.package_name  in
      (* @Hack This is used by bsc, when compiling to js, AND for the .merlin
         generation.  *)
      built_in_package := Some ({
        Bsb_config_types.package_name = Bs_version.package_name;
        package_install_path = x // Bsb_config.lib_ocaml;
      });
    ) ;
    let package_specs =     
      match String_map.find_opt Bsb_build_schemas.package_specs map with 
      | Some x ->
        Bsb_package_specs.from_json x 
      | None ->  Bsb_package_specs.default_package_specs 
    in
    let allowed_build_kinds = parse_allowed_build_kinds map in
    map
    |? (Bsb_build_schemas.reason, `Obj begin fun m -> 
        match String_map.find_opt Bsb_build_schemas.react_jsx m with 

        | Some (False _)
        | None -> ()
        | Some (Flo{loc; flo}) -> 
          begin match flo with 
            | "1" -> 
              reason_react_jsx := 
                Some (Filename.quote (Filename.concat bsc_dir Literals.reactjs_jsx_ppx_exe) )
            | "2" -> 
              reason_react_jsx := 
                Some (Filename.quote 
                        (Filename.concat bsc_dir Literals.reactjs_jsx_ppx_2_exe) )
            | _ -> Bsb_exception.errorf ~loc "Unsupported jsx version %s" flo
          end
        | Some (True _) -> 
          reason_react_jsx := 
            Some (Filename.quote (Filename.concat bsc_dir Literals.reactjs_jsx_ppx_exe) 
                 )
        | Some x -> Bsb_exception.errorf ~loc:(Ext_json.loc_of x) 
                      "Unexpected input for jsx"
      end)

    |? (Bsb_build_schemas.generate_merlin, `Bool (fun b ->
        generate_merlin := b
      ))
    |? (Bsb_build_schemas.name, `Str (fun s -> package_name := Some s))
    |? (Bsb_build_schemas.namespace, `Bool (fun b ->
        namespace := b
      ))
    |? (Bsb_build_schemas.js_post_build, `Obj begin fun m ->
        m |? (Bsb_build_schemas.cmd , `Str (fun s -> 
            js_post_build_cmd := Some (Bsb_build_util.resolve_bsb_magic_file ~cwd ~desc:Bsb_build_schemas.js_post_build s)

          )
          )
        |> ignore
      end)

    |? (Bsb_build_schemas.bs_dependencies, `Arr (fun s -> bs_dependencies := Bsb_build_util.get_list_string s |> Ext_list.map (resolve_package backend cwd)))
    |? (Bsb_build_schemas.bs_dev_dependencies,
        `Arr (fun s ->
            if not  no_dev then 
              bs_dev_dependencies
              := Bsb_build_util.get_list_string s
                 |> Ext_list.map (resolve_package backend cwd))
       )

    (* More design *)
    |? (Bsb_build_schemas.bs_external_includes, `Arr (fun s -> bs_external_includes := get_list_string s))
    |? (Bsb_build_schemas.bsc_flags, `Arr (fun s -> bsc_flags := Bsb_build_util.get_list_string_acc s !bsc_flags))
    |? (Bsb_build_schemas.warnings, `Str (fun s -> warnings := !warnings ^ s))
    |? (Bsb_build_schemas.ppx_flags, `Arr (fun s -> 
        ppx_flags := s |> get_list_string |> Ext_list.map (fun p ->
            if p = "" then failwith "invalid ppx, empty string found"
            else Bsb_build_util.resolve_bsb_magic_file ~cwd ~desc:Bsb_build_schemas.ppx_flags p
          )
      ))
    |? (Bsb_build_schemas.cut_generators, `Bool (fun b -> cut_generators := b))
    |? (Bsb_build_schemas.generators, `Arr (fun s ->
        generators :=
          Array.fold_left (fun acc json -> 
              match (json : Ext_json_types.t) with 
              | Obj {map = m ; loc}  -> 
                begin match String_map.find_opt  Bsb_build_schemas.name m,
                            String_map.find_opt  Bsb_build_schemas.command m with 
                | Some (Str {str = name}), Some ( Str {str = command}) -> 
                  String_map.add name command acc 
                | _, _ -> 
                  Bsb_exception.errorf ~loc {| generators exepect format like { "name" : "cppo",  "command"  : "cppo $in -o $out"} |}
                end
              | _ -> acc ) String_map.empty  s  ))
    |? (Bsb_build_schemas.refmt, `Str (fun s -> 
        refmt := Some (Bsb_build_util.resolve_bsb_magic_file ~cwd ~desc:Bsb_build_schemas.refmt s) ))
    |? (Bsb_build_schemas.refmt_flags, `Arr (fun s -> refmt_flags := get_list_string s))
    |? (Bsb_build_schemas.entries, `Arr (fun s -> entries := parse_entries s))
    |? (Bsb_build_schemas.static_libraries, `Arr (fun s -> static_libraries := (List.map (fun v -> cwd // v) (get_list_string s))))
    |? (Bsb_build_schemas.c_linker_flags, `Arr (fun s -> static_libraries := (List.fold_left (fun acc v -> "-ccopt" :: v :: acc) [] (List.rev (get_list_string s))) @ !static_libraries))
    |? (Bsb_build_schemas.build_script, `Str (fun s -> build_script := Some s))
    |? (Bsb_build_schemas.ocamlfind_dependencies, `Arr (fun s -> ocamlfind_dependencies := get_list_string s))
    |? (Bsb_build_schemas.bs_super_errors, `Bool (fun b -> bs_super_errors := b))
    |? (Bsb_build_schemas.bin_annot, `Bool (fun b -> bin_annot := b))
    |? (Bsb_build_schemas.global_ocaml_compiler, `Bool (fun b -> global_ocaml_compiler := b))
    |> ignore ;
    begin match String_map.find_opt Bsb_build_schemas.sources map with 
      | Some x -> 
        let res = Bsb_parse_sources.parse_sources 
            {no_dev; 
             dir_index =
               Bsb_dir_index.lib_dir_index; 
             cwd = Filename.current_dir_name; 
             root = cwd;
             cut_generators = !cut_generators;
             traverse = false;
            }  x in 
        if generate_watch_metadata then
          Bsb_watcher_gen.generate_sourcedirs_meta cwd res ;     
        begin match List.sort Ext_file_pp.interval_compare  res.intervals with
          | [] -> ()
          | queue ->
            let file_size = in_channel_length config_json_chan in
            let output_file = (cwd //config_file_bak) in 
            let oc = open_out_bin output_file in
            let () =
              Ext_file_pp.process_wholes
                queue file_size config_json_chan oc in
            close_out oc ;
            close_in config_json_chan ;
            Unix.unlink config_json;
            Unix.rename output_file config_json
        end;
        let package_name =       
          match !package_name with
          | None 
            ->
              Bsb_exception.config_error global_data
              "Field name is required"
          | Some "_" 
            -> 
            Bsb_exception.config_error global_data
            "_ is a reserved package name"
          | Some name -> 
            name

        in 
        let namespace =     
          if !namespace then 
            Some (Ext_namespace.namespace_of_package_name package_name)
          else   None  in  
        let warning : Bsb_warning.t option  = 
          match String_map.find_opt Bsb_build_schemas.warnings map with 
          | None -> None 
          | Some (Obj {map }) -> Bsb_warning.from_map map 
          | Some config -> Bsb_exception.config_error config "expect an object"
        in 
        {
          package_name ;
          namespace ;    
          warning = warning;
          external_includes = !bs_external_includes;
          bsc_flags = !bsc_flags ;
          warnings = !warnings;
          ppx_flags = !ppx_flags ;
          bs_dependencies = !bs_dependencies;
          bs_dev_dependencies = !bs_dev_dependencies;
          refmt = !refmt ;
          refmt_flags = !refmt_flags ;
          js_post_build_cmd =  !js_post_build_cmd ;
          package_specs = 
            (match override_package_specs with 
             | None ->  package_specs
             | Some x -> x );
          globbed_dirs = res.globbed_dirs; 
          bs_file_groups = res.files; 
          files_to_install = String_hash_set.create 96;
          built_in_dependency = !built_in_package;
          generate_merlin = !generate_merlin ;
          reason_react_jsx = !reason_react_jsx ;  
          entries = !entries;
          generators = !generators ; 
          cut_generators = !cut_generators;
          
          
          bs_super_errors = !bs_super_errors;
          
          static_libraries = !static_libraries;
          build_script = !build_script;
          allowed_build_kinds = allowed_build_kinds;
          ocamlfind_dependencies = !ocamlfind_dependencies;
          bin_annot = !bin_annot;
          global_ocaml_compiler = !global_ocaml_compiler;
        }
      | None -> failwith "no sources specified, please checkout the schema for more details"
    end
  | _ -> failwith "bsconfig.json expect a json object {}"
