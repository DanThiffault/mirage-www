open Mirage_types.V1
open Lwt
open Printf

module Main (C:CONSOLE) (FS:KV_RO) (TMPL:KV_RO) (Server:Cohttp_lwt.Server) = struct

  let start c fs tmpl http =

    let read_tmpl name =
      TMPL.size tmpl name
      >>= function
      | `Error (TMPL.Unknown_key _) -> fail (Failure ("read " ^ name))
      | `Ok size ->
        TMPL.read tmpl name 0 (Int64.to_int size)
        >>= function
        | `Error (TMPL.Unknown_key _) -> fail (Failure ("read " ^ name))
        | `Ok bufs -> return (Cstruct.copyv bufs)
    in

    let read_fs name =
      FS.size fs name
      >>= function
      | `Error (FS.Unknown_key _) -> fail (Failure ("read " ^ name))
      | `Ok size ->
        FS.read fs name 0 (Int64.to_int size)
        >>= function
        | `Error (FS.Unknown_key _) -> fail (Failure ("read " ^ name))
        | `Ok bufs -> return (Cstruct.copyv bufs)
    in

    (* dynamic response *)
    let dyn ?(headers=[]) req body =
      printf "Dispatch: dynamic URL %s\n%!" (Uri.path (Server.Request.uri req));
      body >>= fun body ->
      let status = `OK in
      let headers = Cohttp.Header.of_list headers in
      Server.respond_string ~headers ~status ~body ()
    in

    let read_entry = (fun name -> read_tmpl name >|= Cow.Markdown.of_string) in
    let blog_feed = Site_config.blog (fun n -> read_entry ("/blog/"^n)) in
    let wiki_feed = Site_config.wiki (fun n -> read_entry ("/wiki/"^n)) in
    let updates_feed = Site_config.updates read_entry in
    let links_feed = Site_config.links read_entry in

    let updates_feeds = [
      `Blog (blog_feed, Data.Blog.entries);
      `Wiki (wiki_feed, Data.Wiki.entries);
    ] in
    let dyn_xhtml = dyn ~headers:Cowabloga.Headers.html in

    lwt blog_dispatch    = Blog.dispatch blog_feed Data.Blog.entries in
    lwt wiki_dispatch    = Wiki.dispatch wiki_feed Data.Wiki.entries in
    lwt links_dispatch   = Pages.Links.dispatch links_feed Data.Links.entries in
    lwt updates_dispatch =
      Pages.Index.dispatch ~feed:updates_feed ~feeds:updates_feeds
    in

    (* dispatch non-file URLs *)
    let dispatch req =
      function
      | [] | [""] | [""; "index.html"] ->
        dyn_xhtml req (Pages.Index.t ~feeds:updates_feeds read_tmpl)
      | [""; "about"]
      | [""; "community"] ->
        dyn_xhtml req (Pages.About.t read_tmpl)
      | "" :: "blog" :: tl ->
        let headers, t = blog_dispatch tl in
        dyn ~headers req t
      | "" :: "updates" :: tl ->
        let headers, t = updates_dispatch tl in
        dyn ~headers req t
      | "" :: "docs" :: tl
      | "" :: "wiki" :: tl ->
        let headers, t = wiki_dispatch tl in
        dyn ~headers req t
      | "" :: "links" :: tl ->
        links_dispatch tl
      | x -> Server.respond_not_found ~uri:(Server.Request.uri req) ()
    in

    (* HTTP callback *)
    let callback conn_id ?body req =
      let path = Uri.path (Server.Request.uri req) in
      let rec remove_empty_tail = function
        | [] | [""] -> []
        | hd::tl -> hd :: remove_empty_tail tl in
      let path_elem =
        remove_empty_tail (Re_str.(split_delim (regexp_string "/") path))
      in
      C.log_s c (Printf.sprintf "URL: %s" path)
      >>= fun () ->
      try_lwt
        read_fs path
        >>= fun body ->
        Server.respond_string ~status:`OK ~body ()
      with exn ->
        dispatch req path_elem
    in
    let spec = {
      Server.callback;
      conn_closed = fun _ () -> ();
    } in
    http spec

end
