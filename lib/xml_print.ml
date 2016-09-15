(* TyXML
 * http://www.ocsigen.org/tyxml
 * Copyright (C) 2008 Vincent Balat, Mauricio Fernandez
 * Copyright (C) 2011 Pierre Chambart, Grégoire Henry
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
 * Foundation, Inc., 51 Franklin Street, Suite 500, Boston, MA 02111-1307, USA.
*)

let is_control c =
  let cc = Char.code c in
  (cc <= 8 || cc = 11 || cc = 12 || (14 <= cc && cc <= 31) || cc = 127)

let add_unsafe_char b = function
  | '<' -> Buffer.add_string b "&lt;"
  | '>' -> Buffer.add_string b "&gt;"
  | '"' -> Buffer.add_string b "&quot;"
  | '&' -> Buffer.add_string b "&amp;"
  | c when is_control c ->
    Buffer.add_string b "&#" ;
    Buffer.add_string b (string_of_int (Char.code c)) ;
    Buffer.add_string b ";"
  | c -> Buffer.add_char b c

let encode_unsafe_char s =
  let b = Buffer.create (String.length s) in
  String.iter (add_unsafe_char b) s;
  Buffer.contents b

let encode_unsafe_char_and_at s =
  let b = Buffer.create (String.length s) in
  let f = function
    | '@' -> Buffer.add_string b "&#64;"
    | c -> add_unsafe_char b c
  in
  String.iter f s;
  Buffer.contents b

let compose_decl ?(version = "1.0") ?(encoding = "UTF-8") () =
  Format.sprintf
    {|<?xml version="%s" encoding="%s"?>\n|}
    version encoding

let compose_doctype dt args =
  let pp_args fmt = function
    | [] -> ()
    | l ->
      Format.fprintf fmt " PUBLIC %a"
        (Format.pp_print_list ~pp_sep:Format.pp_print_space
           (fun fmt -> Format.fprintf fmt "%S"))
        l
  in
  Format.asprintf
    "<!DOCTYPE %s%a>"
    dt
    pp_args args

let re_end_comment = Re.(compile @@ alt [
  seq [ bos ; str ">" ] ;
  seq [ bos ; str "->" ] ;
  str "-->" ;
  str "--!>" ;
])
let escape_comment s =
  let f g = match Re.Group.get g 0 with
    | ">" -> "&gt;"
    | "->" -> "-&gt;"
    | "-->" -> "--&gt;"
    | "--!>" -> "--!&gt;"
    | s -> s
  in
  Re.replace ~all:true re_end_comment ~f s

(* copied form js_of_ocaml: compiler/javascript.ml *)
let pp_number fmt v =
  if v = infinity
  then Format.pp_print_string fmt "Infinity"
  else if v = neg_infinity
  then Format.pp_print_string fmt "-Infinity"
  else if v <> v
  then Format.pp_print_string fmt "NaN"
  else
    let vint = int_of_float v in
    (* compiler 1000 into 1e3 *)
    if float_of_int vint = v
    then
      let rec div n i =
        if n <> 0 && n mod 10 = 0
        then div (n/10) (succ i)
        else
        if i > 2
        then Format.fprintf fmt "%de%d" n i
        else Format.pp_print_int fmt vint in
      div vint 0
    else
      let s1 = Printf.sprintf "%.12g" v in
      if v = float_of_string s1
      then Format.pp_print_string fmt s1
      else
        let s2 = Printf.sprintf "%.15g" v in
        if v = float_of_string s2
        then Format.pp_print_string fmt s2
        else  Format.fprintf fmt "%.18g" v

let string_of_number v =
  Format.asprintf "%a" pp_number v

module Utf8 = struct
  type utf8 = string

  let normalize src =
    let warn = ref false in
    let buffer = Buffer.create (String.length src) in
    Uutf.String.fold_utf_8
      (fun _ _ d ->
         match d with
         | `Uchar code -> Uutf.Buffer.add_utf_8 buffer code
         | `Malformed _ ->
               Uutf.Buffer.add_utf_8 buffer Uutf.u_rep;
               warn:=true)
      () src;
    (Buffer.contents buffer, !warn)

  let normalization_needed src =
    let rec loop src i l =
      i < l &&
      match src.[i] with
      (* Characters that need to be encoded in HTML *)
      | '\034' | '\038' | '\060' |'\062' ->
          true
      (* ASCII characters *)
      | '\009' | '\010' | '\013' | '\032'..'\126' ->
          loop src (i + 1) l
      | _ ->
          true
    in
    loop src 0 (String.length src)

  let normalize_html src =
    if normalization_needed src then begin
      let warn = ref false in
      let buffer = Buffer.create (String.length src) in
      Uutf.String.fold_utf_8
        (fun _ _ d ->
           match d with
           | `Uchar 34 ->
               Buffer.add_string buffer "&quot;"
           | `Uchar 38 ->
               Buffer.add_string buffer "&amp;"
           | `Uchar 60 ->
               Buffer.add_string buffer "&lt;"
           | `Uchar 62 ->
               Buffer.add_string buffer "&gt;"
           | `Uchar code ->
               let u =
                 (* Illegal characters in html
                  http://en.wikipedia.org/wiki/Character_encodings_in_HTML
                  http://www.w3.org/TR/html5/syntax.html *)
                 if (* A. control C0 *)
                   (code <= 31 && code <> 9 && code <> 10 && code <> 13)
                   (* B. DEL + control C1
                    - invalid in html
                    - discouraged in xml;
                      except 0x85 see http://www.w3.org/TR/newline
                      but let's discard it anyway *)
                   || (code >= 127 && code <= 159)
                   (* C. UTF-16 surrogate halves : already discarded by uutf *)
                   (* || (code >= 0xD800 && code <= 0xDFFF) *)
                   (* D. BOOM related *)
                   || code land 0xFFFF = 0xFFFE
                   || code land 0xFFFF = 0xFFFF
                 then (warn:=true; Uutf.u_rep)
                 else code
               in
               Uutf.Buffer.add_utf_8 buffer u
           | `Malformed _ ->
               Uutf.Buffer.add_utf_8 buffer Uutf.u_rep;
               warn:=true)
        () src;
      (Buffer.contents buffer, !warn)
    end else
      (src, false)

end

module type TagList = sig val emptytags : string list end

(** Format based printers *)

let pp_noop _fmt _ = ()

module Make_fmt
    (Xml : Xml_sigs.Iterable)
    (I : TagList) =
struct
  open Xml

  module S = Set.Make(String)
  let is_emptytag = match I.emptytags with
    | [] -> fun _ -> false
    | l ->
      let set = List.fold_left (fun s x -> S.add x s) S.empty l in
      fun x -> S.mem x set

  let pp_encode encode fmt s =
    Format.pp_print_string fmt (encode s)

  let pp_sep = function
    | Space -> fun fmt () -> Format.pp_print_char fmt ' '
    | Comma -> fun fmt () -> Format.pp_print_string fmt ", "

  let pp_attrib_value encode fmt a = match acontent a with
    | AFloat f -> Format.fprintf fmt "\"%a\"" pp_number f
    | AInt i -> Format.fprintf fmt "\"%d\"" i
    | AStr s -> Format.fprintf fmt "%S" (encode s)
    | AStrL (sep, slist) ->
      Format.fprintf fmt "\"%a\""
        (Format.pp_print_list ~pp_sep:(pp_sep sep) (pp_encode encode)) slist

  let pp_attrib encode fmt a =
    Format.fprintf fmt
      " %s=%a" (aname a) (pp_attrib_value encode) a

  let pp_attribs encode =
    Format.pp_print_list ~pp_sep:pp_noop (pp_attrib encode)

  let pp_closedtag encode fmt tag attrs =
    if is_emptytag tag then
      Format.fprintf fmt "<%s%a/>" tag (pp_attribs encode) attrs
    else
      Format.fprintf fmt "<%s%a></%s>" tag (pp_attribs encode) attrs tag

  let rec pp_tag encode fmt tag attrs taglist =
    match taglist with
    | [] -> pp_closedtag encode fmt tag attrs
    | _ ->
      Format.fprintf fmt "<%s%a>%a</%s>"
        tag
        (pp_attribs encode) attrs
        (pp_elts encode) taglist
        tag

  and pp_elt encode fmt elt = match content elt with
    | Comment texte ->
      Format.fprintf fmt "<!--%s-->" (escape_comment texte)

    | Entity e ->
      Format.fprintf fmt "&%s;" e

    | PCDATA texte ->
      pp_encode encode fmt texte

    | EncodedPCDATA texte ->
      Format.pp_print_string fmt texte

    | Node (name, xh_attrs, xh_taglist) ->
      pp_tag encode fmt name xh_attrs xh_taglist

    | Leaf (name, xh_attrs) ->
      pp_closedtag encode fmt name xh_attrs

    | Empty -> ()

  and pp_elts encode =
    Format.pp_print_list ~pp_sep:pp_noop (pp_elt encode)

  let pp ?(encode=encode_unsafe_char) () =
    pp_elt encode

end

module Make_typed_fmt
    (Xml : Xml_sigs.Iterable)
    (Typed_xml : Xml_sigs.Typed_xml with module Xml := Xml) =
struct

  module P = Make_fmt(Xml)(Typed_xml.Info)

  (* Add an xmlns tag on the html element if it's not already present *)
  let prepare_document doc =
    let doc = Typed_xml.doc_toelt doc in
    match Xml.content doc with
    | Xml.Node (n, a, c) ->
      let a =
        if List.exists (fun a -> Xml.aname a = "xmlns") a
        then a
        else Xml.string_attrib "xmlns" Typed_xml.Info.namespace :: a
      in
      Xml.node ~a n c
    | _ -> doc

  let pp_elt ?(encode=encode_unsafe_char) () fmt foret =
    P.pp_elt encode fmt (Typed_xml.toelt foret)

  let pp ?(encode = encode_unsafe_char) ?advert () fmt doc =
    Format.pp_print_string fmt Typed_xml.Info.doctype ;

    begin match advert with
      | Some s -> Format.fprintf fmt "<!-- %s -->\n" s
      | None -> Format.pp_print_newline fmt ()
    end ;

    P.pp_elt encode fmt (prepare_document doc)

end

module Make
    (Xml : Xml_sigs.Iterable)
    (I : TagList)
    (O : Xml_sigs.Output) =
struct

  let (++) = O.concat

  open Xml

  let separator_to_string = function
    | Space -> " "
    | Comma -> ", "

  let attrib_value_to_string encode a = match acontent a with
    | AFloat f -> Printf.sprintf "\"%s\"" (string_of_number f)
    | AInt i -> Printf.sprintf "\"%d\"" i
    | AStr s -> Printf.sprintf "\"%s\"" (encode s)
    | AStrL (sep, slist) ->
      Printf.sprintf "\"%s\""
        (encode (String.concat (separator_to_string sep) slist))

  let attrib_to_string encode a =
    Printf.sprintf "%s=%s" (aname a) (attrib_value_to_string encode a)

  let rec xh_print_attrs encode attrs = match attrs with
    | [] -> O.empty
    | attr::queue ->
      O.put (" "^ attrib_to_string encode attr)
      ++ xh_print_attrs encode queue

  and xh_print_closedtag encode tag attrs =
    if I.emptytags = [] || List.mem tag I.emptytags
    then
      (O.put ("<"^tag)
       ++ xh_print_attrs encode attrs
       ++ O.put " />")
    else
      (O.put ("<"^tag)
       ++ xh_print_attrs encode attrs
       ++ O.put ("></"^tag^">"))

  and xh_print_tag encode tag attrs taglist =
    if taglist = []
    then xh_print_closedtag encode tag attrs
    else
      (O.put ("<"^tag)
       ++ xh_print_attrs encode attrs
       ++ O.put ">"
       ++ xh_print_taglist encode taglist
       ++ O.put ("</"^tag^">"))

  and print_nodes encode name xh_attrs xh_taglist queue =
    xh_print_tag encode name xh_attrs xh_taglist
    ++ xh_print_taglist encode queue

  and xh_print_taglist encode taglist =
    match taglist with

    | [] -> O.empty

    | elt :: queue -> match content elt with

      | Comment texte ->
        O.put ("<!--"^(encode texte)^"-->")
        ++ xh_print_taglist encode queue

      | Entity e ->
        O.put ("&"^e^";") (* no encoding *)
        ++ xh_print_taglist encode queue

      | PCDATA texte ->
        O.put (encode texte)
        ++ xh_print_taglist encode queue

      | EncodedPCDATA texte ->
        O.put texte
        ++ xh_print_taglist encode queue

      | Node (name, xh_attrs, xh_taglist) ->
        print_nodes encode name xh_attrs xh_taglist queue

      | Leaf (name, xh_attrs) ->
        print_nodes encode name xh_attrs [] queue

      | Empty ->
        xh_print_taglist encode queue

  let print_list ?(encode = encode_unsafe_char) foret =
    O.make (xh_print_taglist encode foret)

end

module Make_typed
    (Xml : Xml_sigs.Iterable)
    (Typed_xml : Xml_sigs.Typed_xml with module Xml := Xml)
    (O : Xml_sigs.Output) =
struct

  module P = Make(Xml)(Typed_xml.Info)(O)
  let (++) = O.concat

  let print_list ?(encode = encode_unsafe_char) foret =
    O.make (P.xh_print_taglist encode (List.map Typed_xml.toelt foret))

  let print ?(encode = encode_unsafe_char) ?(advert = "") doc =
    let doc = Typed_xml.doc_toelt doc in
    let doc = match Xml.content doc with
      | Xml.Node (n, a, c) ->
        let a =
          if List.exists (fun a -> Xml.aname a = "xmlns") a
          then a
          else Xml.string_attrib "xmlns" Typed_xml.Info.namespace :: a
        in
        Xml.node ~a n c
      | _ -> doc in
    O.make
      (O.put Typed_xml.Info.doctype
       ++ O.put (if advert <> "" then ("<!-- " ^ advert ^ " -->\n") else "\n")
       ++ P.xh_print_taglist encode [doc])

end

module Simple_output(M : sig val put: string -> unit end) = struct
  type out = unit
  type m = unit -> unit
  let empty () = ()
  let concat f1 f2 () = f1 (); f2 ()
  let put s () = M.put s
  let make f = f ()
end

module Make_simple
    (Xml : Xml_sigs.Iterable)
    (I : TagList) =
struct

  let print_list ~output =
    let module M = Make(Xml)(I)(Simple_output(struct let put = output end)) in
    M.print_list

end

module Make_typed_simple
    (Xml : Xml_sigs.Iterable)
    (Typed_xml : Xml_sigs.Typed_xml with  module Xml := Xml) =
struct

  let print_list ~output =
    let module M =
      Make_typed(Xml)(Typed_xml)(Simple_output(struct let put = output end)) in
    M.print_list

  let print ~output =
    let module M =
      Make_typed(Xml)(Typed_xml)(Simple_output(struct let put = output end)) in
    M.print

end
