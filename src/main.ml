open Lwt
open Printf
open Github_t
open Github_j
open Github

type return_status = Error | Finished of (Unix.process_status * string * string)

let read_channel chan =
  let buffer_size = 1024 in
  let buf = Buffer.create buffer_size in
  let s = String.create buffer_size in
  let rec aux buf s =
    let chars_read = input chan s 0 buffer_size in
    Buffer.add_substring buf s 0 chars_read;
    if chars_read <> 0 then aux buf s
  in 
  aux buf s;
  Buffer.contents buf
    
let log_file log_path out =
  match log_path with
      None -> ()
    | Some log -> 
        (* prerr_endline ("logging in " ^ log); *)
        let ch = open_out_gen [Open_wronly; Open_append; Open_creat] 0o644 log in
        output_string ch out;
        close_out ch
          
let execute ?(env=[| |]) ?log_path path cmd =
  prerr_endline ("Executing " ^ cmd ^ " in " ^ path);
  let curpath = Unix.getcwd () in
  try
    Unix.chdir path;
    let ic, oc, ec = Unix.open_process_full cmd env in
    let out = read_channel ic in
    let err = read_channel ec in
    let exit_status = Unix.close_process_full (ic, oc, ec) in
    Unix.chdir curpath;
    log_file log_path out;
    log_file log_path err;
    Finished (exit_status,out,err)
  with 
  | e -> 
    Unix.chdir curpath;
    Printexc.print_backtrace stderr;
    Error

let run ?(env=[| |]) path cmd  =
  let get_error_code = function
    | Unix.WEXITED r -> r
    | Unix.WSIGNALED r -> r
    | Unix.WSTOPPED r -> r in      
  let res = execute ~env ~log_path:"/tmp/prdup.log" path cmd in
  match res with
    Finished (Unix.WEXITED 0,_,_) -> () (* OK !! *)
  | Error -> failwith (cmd ^ " : Error")
  | Finished (r,_,_) -> 
    failwith (cmd ^ " : Failed with code " ^ (string_of_int (get_error_code r)))

let api = "https://api.github.com"

let create_pull_request ~title ~description ~user ~branch_name ~dest_branch ~repo ~token ~caller =
  let pull = { pull_request_title = title; pull_request_body = Some description;
	       pull_request_base = dest_branch; pull_request_head = (caller ^ ":" ^ branch_name) } in
  let body = string_of_pull_request pull in
  let uri =  Uri.of_string (Printf.sprintf "%s/repos/%s/%s/pulls" api user repo) in
  API.post ~body ~uri ~token ~expected_code:`Created (fun body -> return body)
  
let prepare_git_repo ~dest_branch ~user ~repo ~shas ~branch_name ~caller ~user_name ~user_email =
  let repo_path = "/tmp/" ^ repo in
  let cmds = [
    ("/tmp", ("git clone -b " ^ dest_branch ^ " git@github.com:xen-org/xen-api.git"));
    (repo_path, ("git config user.name " ^ user_name));
    (repo_path, ("git config user.email " ^ user_email));
    (repo_path, ("git remote add " ^ user ^ " git@github.com:" ^ user ^ "/" ^ repo ^ ".git"));
    (repo_path, ("git fetch " ^ user));
    (repo_path, ("git checkout -b " ^ branch_name));
  ] in
  let cherry_pick sha = run repo_path ("git cherry-pick " ^ sha) in
  try 
    if caller <> user then
      run repo_path ("git remote add " ^ caller ^ " git@github.com:" ^ caller ^ "/" ^ repo ^ ".git");
    List.iter (fun (path,cmd) -> run path cmd) cmds;
    List.iter (fun sha -> cherry_pick sha) shas;
    run repo_path ("git push " ^ caller ^ " " ^ branch_name)
  with Failure s -> prerr_endline s;
    ()
      
let get_token ~user ~pass =
  let r = Github.Token.create ~user ~pass () in
  lwt auth = Github.Monad.run r in
  let token = Github.Token.of_auth auth in
  prerr_endline (Github.Token.to_string token);
  return token

let pullrequest_commits ~user ~repo ~issue_number =
  Uri.of_string (Printf.sprintf "%s/repos/%s/%s/pulls/%d/commits" api user repo issue_number)

let get_pullrequest ~token ~repo ~user ~issue_number =
  let uri = URI.repo_issue ~user ~repo ~issue_number in
  API.get ~token ~uri (fun b -> return (issue_of_string b))

let get_pullrequest_commits ~token ~repo ~user ~issue_number =
  let uri = pullrequest_commits ~user ~repo ~issue_number in
  API.get ~token ~uri (fun b -> return (repo_commits_of_string b))

let pr_info ~user ~pass ~issue_number ~dest_branch ~repo ~branch_name ~user_name ~user_email =
  lwt token = get_token ~user ~pass in
  lwt r = 
    let open Github.Monad in
    run (
      get_pullrequest ~token ~user:"xen-org" ~repo ~issue_number >>=
	fun pr ->
      eprintf "pullrequest %s user %s\n" pr.issue_title pr.issue_user.user_login;
      get_pullrequest_commits ~token ~user:"xen-org" ~repo ~issue_number >>=
	fun cs -> let shas = List.map (fun c -> c.repo_commit_sha) cs in
		  prepare_git_repo ~dest_branch ~user:pr.issue_user.user_login ~repo ~shas 
		    ~branch_name ~caller:user ~user_name ~user_email;
		  create_pull_request ~title:pr.issue_title ~description:pr.issue_body ~user:"xen-org" ~branch_name ~dest_branch ~repo ~token ~caller:user >>= fun body -> prerr_endline body;
		  return ()
    ) in
  return ()
    
let _ = 
  let usage = Printf.sprintf
    "Usage: %s -u <username> -p <password> -n <pr-number> -r <repo> -d <destination-branch> -b <new-branch-name>"
    Sys.argv.(0)
  in
  let username = ref None in
  let password = ref None in
  let issue_number = ref None in
  let repo = ref None in
  let dest_branch = ref None in
  let branch_name = ref None in
  let git_user_name = ref None in
  let git_user_email = ref None in
  Arg.parse
    [
      ("-u", Arg.String (fun x -> username := Some x), "Github username");
      ("-p", Arg.String (fun x -> password := Some x), "Github password");
      ("-n", Arg.Int (fun x -> issue_number := Some x), "Github issue number");
      ("-r", Arg.String (fun x -> repo := Some x), "Github repo");
      ("-d", Arg.String (fun x -> dest_branch := Some x), "Github destination branch");
      ("-b", Arg.String (fun x -> branch_name := Some x), "Github new branch name");
      ("-g", Arg.String (fun x -> git_user_name := Some x), "Git committer name");
      ("-e", Arg.String (fun x -> git_user_email := Some x), "Git committer email");
    ]
    (fun x -> Printf.eprintf "Warning: ignoring unexpected argument %s\n" x)
    usage;
  match !username, !password, !issue_number, !repo, !dest_branch, !branch_name, !git_user_name, !git_user_email with
  | Some u, Some p, Some n, Some r, Some d, Some b, Some g, Some e ->
    Printf.printf "OK.\n";
    Lwt_main.run (
      pr_info ~user:u ~pass:p ~issue_number:n ~repo:r ~dest_branch:d ~branch_name:b ~user_name:g
	~user_email:e
    ) 
  | _, _, _, _, _, _, _, _ ->
    print_endline usage;
    exit 1