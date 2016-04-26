(*---------------------------------------------------------------------------
   Copyright (c) 2016 Daniel C. Bünzli. All rights reserved.
   Distributed under the ISC license, see terms at the end of the file.
   %%NAME%% %%VERSION%%
  ---------------------------------------------------------------------------*)

open Topkg_result

module Cmd = Topkg_cmd
module OS = Topkg_os

let parse_changes lines =
  try
    let parse_line l = match Topkg_string.cut ~sep:' ' l with
    | None -> failwith (Topkg_string.strf "%S: can't parse log line" l)
    | Some cut -> cut
    in
    Ok (List.(rev @@ rev_map parse_line lines))
  with Failure msg -> Error (`Msg msg)

(* Version control system repositories *)

type commit_ish = string

type kind = [ `Git | `Hg ]

let pp_kind ppf = function
| `Git -> Format.pp_print_string ppf "git"
| `Hg -> Format.pp_print_string ppf "hg"

let dirtify id = id ^ "-dirty"

type t = kind * Topkg_fpath.t

let git = Cmd.v (OS.Env.opt_var "TOPKG_GIT" ~absent:"git")
let hg = Cmd.v (OS.Env.opt_var "TOPKG_HG" ~absent:"hg")

let vcs_cmd kind dir = match kind with
| `Git -> Cmd.(git % "--git-dir" % dir)
| `Hg -> Cmd.(hg % "--repository" % dir)

let v k ~dir = (k, dir)
let kind r = fst r
let dir r = snd r
let cmd (kind, dir) = vcs_cmd kind dir

(* Git support *)

let find_git () = OS.Cmd.exists git >>= function
| false -> Ok None
| true ->
    let git_dir = Cmd.(git % "rev-parse" % "--git-dir") in
    OS.Cmd.(run_out ~err:OS.File.null git_dir |> out_string) >>= function
    | (dir, (_, `Exited 0)) -> Ok (Some (v `Git dir))
    | _ -> Ok None

let err_git cmd c = R.error_msgf "%a exited with %d" Cmd.dump cmd c
let run_git r args out =
  let git = Cmd.(cmd r %% args) in
  OS.Cmd.(run_out git |> out) >>= function
  | (v, (_, `Exited 0)) -> Ok v
  | (_, (_, `Exited c)) -> err_git git c

let git_is_dirty r =
  let diff = Cmd.(cmd r % "diff" % "--quiet" % "HEAD") in
  OS.Cmd.(run_status ~err:OS.File.null diff) >>= function
  | `Exited 0 -> Ok false
  | `Exited 1 -> Ok true
  | `Exited c -> err_git diff c

let git_file_is_dirty r file =
  let diff = Cmd.(cmd r % "diff-index" % "--quiet" % "HEAD" % p file) in
  OS.Cmd.(run_status ~err:OS.File.null diff) >>= function
  | `Exited 0 -> Ok false
  | `Exited 1 -> Ok true
  | `Exited c -> err_git diff c

let dirtify_if ~dirty r id = match dirty with
| false -> Ok id
| true ->
    git_is_dirty r >>= fun is_dirty ->
    Ok (if is_dirty then dirtify id else id)

let git_head ~dirty r =
  run_git r Cmd.(v "rev-parse" % "HEAD") OS.Cmd.out_string
  >>= fun id -> dirtify_if ~dirty r id

let git_commit_id ~dirty r commit_ish =
  let dirty = dirty && commit_ish = "HEAD" in
  let id = Cmd.(v "rev-parse" % "--verify" % (commit_ish ^ "^{commit}")) in
  run_git r id OS.Cmd.out_string >>= fun id -> dirtify_if ~dirty r id

let git_commit_ptime_s r commit_ish =
  let time = Cmd.(v "show" % "-s" % "--format=%ct" % commit_ish) in
  run_git r time OS.Cmd.out_string
  >>= fun ptime -> try Ok (int_of_string ptime) with
  | Failure _ -> R.error_msgf "Could not parse timestamp from %S" ptime

let git_describe ~dirty r commit_ish =
  let dirty = dirty && commit_ish = "HEAD" in
  run_git r
    Cmd.(v "describe" % "--always" %% on dirty (v "--dirty") %%
         on (not dirty) (v commit_ish))
    OS.Cmd.out_string

let git_tags r =
  run_git r Cmd.(v "tag" % "--list") OS.Cmd.out_lines

let git_changes r ~after ~until =
  let range =
    if after = "" then until else
    Topkg_string.strf "%s..%s" after until
  in
  let changes = Cmd.(v "log" % "--oneline" % "--no-decorate" % range) in
  run_git r changes OS.Cmd.out_lines
  >>= fun commits -> parse_changes commits

let git_tracked_files r ~tree_ish =
  let tracked = Cmd.(v "ls-tree" % "--name-only" % "-r" % tree_ish) in
  run_git r tracked OS.Cmd.out_lines

let git_clone r ~dir:d =
  let clone = Cmd.(git % "clone" % "--local" % (dir r) % d) in
  OS.Cmd.(run_status ~err:OS.File.null clone) >>= function
  | `Exited 0 -> Ok ()
  | `Exited c -> err_git clone c

let git_checkout r ~branch ~commit_ish =
  let branch = match branch with
  | None -> Cmd.empty
  | Some branch -> Cmd.(v "-b" % branch)
  in
  run_git r Cmd.(v "checkout" % "--quiet" %% branch % commit_ish)
  OS.Cmd.out_string
  >>= fun _ -> Ok ()

let git_commit_files r ~msg files =
  let msg = match msg with None -> Cmd.empty | Some m -> Cmd.(v "-m" % m) in
  let files = Cmd.(of_list @@ List.map p files) in
  run_git r Cmd.(v "commit" %% msg %% files) OS.Cmd.out_stdout

let git_tag r ~force ~sign ~msg ~commit_ish tag =
  let msg = match msg with None -> Cmd.empty | Some m -> Cmd.(v "-m" % m) in
  let flags = Cmd.(on force (v "-f") %% on sign (v "-s")) in
  run_git r Cmd.(v "tag" % "-a" %% flags %% msg % tag % commit_ish)
    OS.Cmd.out_stdout

let git_delete_tag r tag =
  run_git r Cmd.(v "tag" % "-d" % tag) OS.Cmd.out_stdout

(* Hg support *)

let hg_rev commit_ish = match commit_ish with "HEAD" -> "tip" | c -> c

let find_hg () = OS.Cmd.exists hg >>= function
| false -> Ok None
| true ->
    let hg_root = Cmd.(hg % "root") in
    OS.Cmd.(run_out ~err:OS.File.null hg_root |> out_string) >>= function
    | (dir, (_, `Exited 0)) -> Ok (Some (v `Hg dir))
    | _ -> Ok None

let err_hg cmd c = R.error_msgf "%a exited with %d" Cmd.dump cmd c
let run_hg r args out =
  let hg = Cmd.(cmd r %% args) in
  OS.Cmd.(run_out hg |> out) >>= function
  | (v, (_, `Exited 0)) -> Ok v
  | (_, (_, `Exited c)) -> err_hg hg c

let hg_id r ~rev =
  run_hg r Cmd.(v "id" % "-i" % "--rev" % rev) OS.Cmd.out_string
  >>= fun id ->
  let len = String.length id in
  let is_dirty = String.length id > 0 && id.[len - 1] = '+' in
  let id = if is_dirty then String.sub id 0 (len - 1) else id in
  Ok (id, is_dirty)

let hg_is_dirty r =
  hg_id r ~rev:"tip" >>= function (id, is_dirty) -> Ok is_dirty

let hg_file_is_dirty r file =
  run_hg r Cmd.(v "status" % p file) OS.Cmd.out_string >>= function
  | "" -> Ok false
  | _ -> Ok true

let hg_head ~dirty r =
  hg_id r ~rev:"tip" >>= function (id, is_dirty) ->
  Ok (if is_dirty && dirty then dirtify id else id)

let hg_commit_id ~dirty r ~rev =
  hg_id r ~rev >>= fun (id, is_dirty) ->
  Ok (if is_dirty && dirty then dirtify id else id)

let hg_commit_ptime_s r ~rev =
  let time = Cmd.(v "log" % "--template" % "'{date(date, \"%s\")}'" %
                  "--rev" % rev)
  in
  run_git r time OS.Cmd.out_string
  >>= fun ptime -> try Ok (int_of_string ptime) with
  | Failure _ -> R.error_msgf "Could not parse timestamp from %S" ptime

let hg_describe ~dirty r ~rev =
  let get_distance s = try Ok (int_of_string s) with
  | Failure _ -> R.error_msgf "%s: Could not parse hg tag distance." (dir r)
  in
  let parent t =
    run_hg r Cmd.(v "parent" % "--rev" % rev % "--template" % t)
      OS.Cmd.out_string
  in
  parent "{latesttagdistance}" >>= get_distance
  >>= begin function
  | 1 -> parent "{latesttag}"
  | n -> parent "{latesttag}-{latesttagdistance}-{node|short}"
  end
  >>= fun descr -> match dirty with
  | false -> Ok descr
  | true ->
      hg_id ~rev:"tip" r >>= fun (_, is_dirty) ->
      Ok (if is_dirty then dirtify descr else descr)

let hg_tags r = run_hg r Cmd.(v "tags" % "--quiet" (* sic *)) OS.Cmd.out_lines

let hg_changes r ~after ~until =
  let rev = Topkg_string.strf "%s::%s" after until in
  let changes =
    Cmd.(v "log" % "--template" % "{node|short} {desc|firstline}\\n"
         % "--rev" % rev)
  in
  run_hg r changes OS.Cmd.out_lines
  >>= fun commits -> parse_changes commits
  >>= function
  | [] -> Ok []
  | after :: rest -> Ok (List.rev rest) (* hg order is reverse from git *)

let hg_tracked_files r ~rev =
  run_hg r Cmd.(v "manifest" % "--rev" % rev) OS.Cmd.out_lines

let hg_clone r ~dir:d =
  let clone = Cmd.(hg % "clone" % (dir r) % d) in
  OS.Cmd.(run_status ~err:OS.File.null clone) >>= function
  | `Exited 0 -> Ok ()
  | `Exited c -> err_hg clone c

let hg_checkout r ~branch ~rev =
  run_hg r Cmd.(v "update" % "--rev" % rev) OS.Cmd.out_string
  >>= fun _ -> match branch with
  | None -> Ok ()
  | Some branch ->
      run_hg r Cmd.(v "branch" % branch) OS.Cmd.out_string >>= fun _ -> Ok ()

let hg_commit_files r ~msg files =
  let msg = match msg with None -> Cmd.empty | Some m -> Cmd.(v "-m" % m) in
  let files = Cmd.(of_list @@ List.map p files) in
  run_hg r Cmd.(v "commit" %% msg %% files) OS.Cmd.out_stdout

let hg_tag r ~force ~sign ~msg ~rev tag =
  if sign then R.error_msgf "Tag signing is not supported by hg" else
  let msg = match msg with None -> Cmd.empty | Some m -> Cmd.(v "-m" % m) in
  run_hg r Cmd.(v "tag" %% on force (v "-f") %% msg % "--rev" % rev % tag)
    OS.Cmd.out_stdout

let hg_delete_tag r tag =
  run_git r Cmd.(v "tag" % "--remove" % tag) OS.Cmd.out_stdout

(* Generic VCS support *)

let find ?dir () = match dir with
| None ->
    begin find_git () >>= function
      | Some _ as v -> Ok v
      | None -> find_hg ()
    end
| Some dir ->
    let git_dir = Topkg_fpath.append dir ".git" in
    OS.Dir.exists git_dir >>= function
    | true -> Ok (Some (v `Git git_dir))
    | false ->
        let hg_dir = Topkg_fpath.append dir ".hg" in
         OS.Dir.exists hg_dir >>= function
         | true -> Ok (Some (v `Hg hg_dir))
         | false -> Ok None

let get ?dir () = find ?dir () >>= function
| Some r -> Ok r
| None ->
    let dir = match dir with None -> OS.Dir.current () | Some dir -> Ok dir in
    dir >>= function dir ->
    R.error_msgf "%s: No VCS repository found" dir

let pp ppf r = Format.fprintf ppf "(%a, %s)" pp_kind (kind r) (dir r)

(* Repository state *)

let is_dirty = function
| (`Git, _  as r) -> git_is_dirty r
| (`Hg, _ as r ) -> hg_is_dirty r

let not_dirty r = is_dirty r >>= function
| false -> Ok ()
| true -> R.error_msgf "The VCS repo is dirty, commit or stash your changes."

let file_is_dirty r file = match r with
| (`Git, _  as r) -> git_file_is_dirty r file
| (`Hg, _ as r ) -> hg_file_is_dirty r file

let head ?(dirty = true) = function
| (`Git, _ as r) -> git_head ~dirty r
| (`Hg, _ as r) -> hg_head ~dirty r

let commit_id ?(dirty = true) ?(commit_ish = "HEAD") = function
| (`Git, _ as r) -> git_commit_id ~dirty r commit_ish
| (`Hg, _ as r) -> hg_commit_id ~dirty r ~rev:(hg_rev commit_ish)

let commit_ptime_s ?(commit_ish = "HEAD") = function
| (`Git, _ as r) -> git_commit_ptime_s r commit_ish
| (`Hg, _ as r) -> hg_commit_ptime_s r ~rev:(hg_rev commit_ish)

let describe ?(dirty = true) ?(commit_ish = "HEAD") = function
| (`Git, _ as r) -> git_describe ~dirty r commit_ish
| (`Hg, _ as r) -> hg_describe ~dirty r ~rev:(hg_rev commit_ish)

let tags = function
| (`Git, _ as r) -> git_tags r
| (`Hg, _ as r) -> hg_tags r

let changes ?(until = "HEAD") r ~after = match r with
| (`Git, _ as r) -> git_changes r ~after ~until
| (`Hg, _ as r) -> hg_changes r ~after:(hg_rev after) ~until:(hg_rev until)

let tracked_files ?(tree_ish = "HEAD") = function
| (`Git, _ as r) -> git_tracked_files r ~tree_ish
| (`Hg, _ as r) -> hg_tracked_files r ~rev:(hg_rev tree_ish)

(* Operations *)

let clone r ~dir = match r with
| (`Git, _ as r) -> git_clone r ~dir
| (`Hg, _ as r) -> hg_clone r ~dir

let checkout ?branch r ~commit_ish = match r with
| (`Git, _ as r) -> git_checkout r ~branch ~commit_ish
| (`Hg, _ as r) -> hg_checkout r ~branch ~rev:(hg_rev commit_ish)

let commit_files ?msg r files = match r with
| (`Git, _ as r) -> git_commit_files r ~msg files
| (`Hg, _ as r) -> hg_commit_files r ~msg files

let tag ?(force = false) ?(sign = false) ?msg ?(commit_ish = "HEAD") r tag =
  match r with
  | (`Git, _ as r) -> git_tag r ~force ~sign ~msg ~commit_ish tag
  | (`Hg, _ as r) -> hg_tag r ~force ~sign ~msg ~rev:(hg_rev commit_ish) tag

let delete_tag r tag = match r with
| (`Git, _ as r) -> git_delete_tag r tag
| (`Hg, _ as r) -> hg_delete_tag r tag

(*---------------------------------------------------------------------------
   Copyright (c) 2016 Daniel C. Bünzli

   Permission to use, copy, modify, and/or distribute this software for any
   purpose with or without fee is hereby granted, provided that the above
   copyright notice and this permission notice appear in all copies.

   THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
   WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
   MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
   ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
   WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
   ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
   OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
  ---------------------------------------------------------------------------*)
