(* Copyright (C) 2014, Thomas Leonard
 * See the README file for details, or visit http://0install.net.
 *)

(** Type-safe access to the XML formats.
 * See:
 * http://0install.net/interface-spec.html
 * http://0install.net/selections-spec.html *)

open Support.Common
open General
open Constants

module Q = Support.Qdom
module AttrMap = Q.AttrMap

module Compile = Support.Qdom.NsQuery(COMPILE_NS)

type 'a t = Q.element

let simple_content elem =
  elem.Q.last_text_inside

type binding_node =
  [ `environment | `executable_in_path | `executable_in_var | `binding]

type binding =
  [ `environment of [`environment] t
  | `executable_in_path of [`executable_in_path] t
  | `executable_in_var of [`executable_in_var] t
  | `binding of [`binding] t ]

type dependency_node = [ `requires | `restricts | `runner ]

type dependency =
  [ `requires of [`requires] t
  | `restricts of [`restricts] t
  | `runner of [`runner] t]

type attr_node =
  [ `group
  | `implementation
  | `compile_impl
  | `package_impl ]

(** Create a map from interface URI to <selection> elements. *)
let make_selection_map sels =
  sels |> ZI.fold_left ~init:StringMap.empty ~name:"selection" (fun m sel ->
    StringMap.add (ZI.get_attribute "interface" sel) sel m
  )

let get_runner elem =
  match elem |> ZI.map ~name:"runner" (fun a -> a) with
  | [] -> None
  | [runner] -> Some runner
  | _ -> Q.raise_elem "Multiple <runner>s in" elem

let parse_selections root =
  ZI.check_tag "selections" root;
  match root.Q.child_nodes |> List.filter (fun child -> ZI.tag child = Some "command") with
  | [] -> root
  | old_commands ->
      (* 0launch 0.52 to 1.1 *)
      try
        let iface = ref (Some (ZI.get_attribute FeedAttr.interface root)) in
        let index = ref (make_selection_map root) in
        old_commands |> List.iter (fun command ->
          let current_iface = !iface |? lazy (Q.raise_elem "No additional command expected here!" command) in
          let sel = StringMap.find current_iface !index |? lazy (Q.raise_elem "Missing selection for '%s' needed by" current_iface command) in
          let command = {command with Q.attrs = command.Q.attrs |> AttrMap.add_no_ns "name" "run"} in
          index := !index |> StringMap.add current_iface {sel with Q.child_nodes = command :: sel.Q.child_nodes};
          match get_runner command with
          | None -> iface := None
          | Some runner -> iface := Some (ZI.get_attribute "interface" runner)
        );
        {
          root with
          Q.child_nodes = !index |> StringMap.map_bindings (fun _ child -> child);
          Q.attrs = root.Q.attrs |> AttrMap.add_no_ns "command" "run"
        }
      with Safe_exception _ as ex -> reraise_with_context ex "... migrating from old selections format"

let selections = ZI.map (fun x -> x) ~name:"selection"

let rec filter_if_0install_version node =
  match node.Q.attrs |> AttrMap.get_no_ns FeedAttr.if_0install_version with
  | Some expr when not (Version.parse_expr expr About.parsed_version) -> None
  | Some _expr -> Some {
    node with Q.child_nodes = Support.Utils.filter_map filter_if_0install_version node.Q.child_nodes;
    attrs = node.Q.attrs |> AttrMap.remove ("", FeedAttr.if_0install_version) 
  }
  | None -> Some {
    node with Q.child_nodes = Support.Utils.filter_map filter_if_0install_version node.Q.child_nodes;
  }

let parse_feed root =
  let root =
    match filter_if_0install_version root with
    | Some root -> root
    | None -> Q.raise_elem "Feed requires 0install version %s (we are %s):" (ZI.get_attribute FeedAttr.if_0install_version root) About.version root
  in

  begin match ZI.tag root with
  | Some "interface" | Some "feed" -> ()
  | _ ->
      ZI.check_ns root;
      Q.raise_elem "Expected <interface>, not" root end;

  ZI.get_attribute_opt "min-injector-version" root
  |> if_some (fun min_version ->
      if Version.parse min_version > About.parsed_version then
        Q.raise_elem "Feed requires 0install version %s or later (we are %s):" min_version About.version root
  );
  root

let make_impl ?source_hint ?child_nodes attrs =
  ZI.make ?source_hint ?child_nodes ~attrs "implementation"

let make_command ?path ?shell_command ~source_hint name =
  let attrs = AttrMap.singleton "name" name in
  let attrs = match path with
    | None -> attrs
    | Some path -> attrs |> AttrMap.add_no_ns "path" path in
  let attrs = match shell_command with
    | None -> attrs
    | Some shell_command -> attrs |> AttrMap.add_no_ns "shell-command" shell_command in
  ZI.make ~attrs ?source_hint "command"

let with_interface iface elem =
  {elem with Q.attrs = elem.Q.attrs |> Q.AttrMap.add_no_ns "interface" iface}

let get_command name elem =
  let is_command node = ((ZI.tag node = Some "command") && (ZI.get_attribute "name" node = name)) in
  Q.find is_command elem

let get_command_ex name elem =
  match get_command name elem with
  | Some command -> command
  | None -> Q.raise_elem "No <command> with name '%s' in" name elem

let path = ZI.get_attribute_opt "path"
let local_path = ZI.get_attribute_opt "local-path"
let command_name = ZI.get_attribute "name"
let binding_name = command_name

let arg_children parent =
  parent |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "arg" -> Some (`arg child)
    | Some "for-each" -> Some (`for_each child)
    | _ -> None
  )

let bool_opt attr elem =
  match Q.AttrMap.get attr elem.Q.attrs with
  | Some "true" -> Some true
  | Some "false" -> Some false
  | Some x -> Q.raise_elem "Invalid '%s' value '%s' on" (snd attr) x elem
  | None -> None

let item_from = ZI.get_attribute "item-from"
let separator = ZI.get_attribute_opt "separator"
let command = ZI.get_attribute_opt "command"
let interface = ZI.get_attribute "interface"
let from_feed = ZI.get_attribute_opt "from-feed"
let version = ZI.get_attribute "version"
let version_opt = ZI.get_attribute_opt "version"
let id = ZI.get_attribute "id"
let doc_dir = ZI.get_attribute_opt "doc-dir"
let arch elem = Q.AttrMap.get_no_ns "arch" elem.Q.attrs
let source = bool_opt ("", "source")

let uri = ZI.get_attribute_opt "uri"
let uri_exn = ZI.get_attribute "uri"
let src = ZI.get_attribute "src"
let langs = ZI.get_attribute_opt "langs"
let main = ZI.get_attribute_opt "main"
let self_test = ZI.get_attribute_opt "self-test"
let before = ZI.get_attribute_opt "before"
let not_before = ZI.get_attribute_opt "not-before"
let os elem = ZI.get_attribute_opt "os" elem |> pipe_some Arch.parse_os
let use = ZI.get_attribute_opt "use"
let distribution = ZI.get_attribute_opt "distribution"
let distributions = ZI.get_attribute_opt "distributions"
let href = ZI.get_attribute "href"
let icon_type = ZI.get_attribute_opt "type"

let insert = ZI.get_attribute_opt "insert"
let value = ZI.get_attribute_opt "value"
let mode = ZI.get_attribute_opt "mode"
let default = ZI.get_attribute_opt "default"

let feed_metadata root =
  root.Q.child_nodes |> Support.Utils.filter_map (fun node ->
    match ZI.tag node with
    | Some "name" -> Some (`name node)
    | Some "feed" -> Some (`feed_import node)
    | Some "feed-for" -> Some (`feed_for node)
    | Some "category" -> Some (`category node)
    | Some "needs-terminal" -> Some (`needs_terminal node)
    | Some "homepage" -> Some (`homepage node)
    | Some "icon" -> Some (`icon node)
    | Some "replaced-by" -> Some (`replaced_by node)
    | _ -> None
  )

let group_children group =
  group.Q.child_nodes |> Support.Utils.filter_map (fun node ->
    match ZI.tag node with
    | Some "group" -> Some (`group node)
    | Some "implementation" -> Some (`implementation node)
    | Some "package-implementation" -> Some (`package_impl node)
    | _ -> None
  )

let package = ZI.get_attribute "package"
let quick_test_file = ZI.get_attribute_opt FeedAttr.quick_test_file
let quick_test_mtime elem = ZI.get_attribute_opt FeedAttr.quick_test_mtime elem |> pipe_some (fun s -> Some (Int64.of_string s))

let compile_command group = group.Q.attrs |> AttrMap.get (COMPILE_NS.ns, "command")
let compile_min_version sel = sel.Q.attrs |> AttrMap.get (COMPILE_NS.ns, "min-version")
let requires_compilation = bool_opt ("", "requires-compilation")

let retrieval_methods impl =
  List.filter Recipe.is_retrieval_method impl.Q.child_nodes

let importance dep =
  match ZI.get_attribute_opt FeedAttr.importance dep with
  | None | Some "essential" -> `essential
  | _ -> `recommended

let classify_dep elem =
  match ZI.tag elem with
  | Some "runner" -> `runner elem
  | Some "requires" -> `requires elem
  | Some "restricts" -> `restricts elem
  | _ -> assert false

let classify_binding_opt child =
  match ZI.tag child with
  | Some "environment" -> Some (`environment child)
  | Some "executable-in-path" -> Some (`executable_in_path child)
  | Some "executable-in-var" -> Some (`executable_in_var child)
  | Some "binding" | Some "overlay" -> Some (`binding child)
  | _ -> None

let classify_binding elem =
  match classify_binding_opt elem with
  | Some b -> b
  | None -> assert false

let bindings parent =
  ZI.filter_map classify_binding_opt parent

let element_of_dependency = function
  | `requires d -> d
  | `runner d -> d
  | `restricts d -> d

let element_of_binding = function
  | `environment b -> b
  | `executable_in_path b -> b
  | `executable_in_var b -> b
  | `binding b -> b

let restrictions parent =
  parent |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "version" -> Some (`version child)
    | _ -> None
  )

let raise_elem = Q.raise_elem
let log_elem = Q.log_elem
let show_with_loc = Q.show_with_loc
let as_xml x = x
let fmt () = Q.show_with_loc

let deps_and_bindings sel =
  sel |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "requires" -> Some (`requires child)
    | Some "restricts" -> Some (`restricts child)
    | Some "command" -> Some (`command child)
    | _ -> classify_binding_opt child
  )

let command_children sel =
  sel |> ZI.filter_map (fun child ->
    match ZI.tag child with
    | Some "requires" -> Some (`requires child)
    | Some "restricts" -> Some (`restricts child)
    | Some "runner" -> Some (`runner child)
    | _ -> classify_binding_opt child
  )

let compile_template =
  Q.find (fun child ->
    Compile.tag child = Some "implementation"
  )

let compile_include_binary = bool_opt (COMPILE_NS.ns, "include-binary")

let get_text tag langs feed =
  let best = ref None in
  feed |> ZI.iter ~name:tag (fun elem ->
    let new_score = elem.Q.attrs |> AttrMap.get (xml_ns, FeedAttr.lang) |> Support.Locale.score_lang langs in
    match !best with
    | Some (_old_summary, old_score) when new_score <= old_score -> ()
    | _ -> best := Some (elem.Q.last_text_inside, new_score)
  );
  match !best with
  | None -> None
  | Some (summary, _score) -> Some summary

let get_summary = get_text "summary"
let get_description = get_text "description"

let dummy_restricts = ZI.make "restricts"
