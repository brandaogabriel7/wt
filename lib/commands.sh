# command implementations. Each resolves a project (except init/projects/help).

cmd_init() {
  local name="" edit=1 root="" common repo conf dest pos
  pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-edit) edit=0; shift ;;
      --edit)    edit=1; shift ;;
      --)        shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      -*)        wt_die "wt init: unknown option: $1" ;;
      *)         pos+=("$1"); shift ;;
    esac
  done
  name="${pos[0]:-}"
  common="$(wt_common_dir)"
  [ -n "$common" ] && root="$(cd -P "$(dirname "$common")" 2>/dev/null && pwd)"
  if [ -z "$name" ]; then
    [ -n "$root" ] || wt_die "usage: wt init <name>   (or run inside a git repo to auto-name)"
    name="$(basename "$root")"
  fi
  dest="$WT_CONFIG_DIR/projects/$name.sh"
  [ -e "$dest" ] && wt_die "project '$name' already exists: $dest (not overwriting)"
  if [ -n "$root" ]; then
    case "$root" in
      "$HOME"/*) repo="\$HOME/${root#"$HOME"/}" ;;
      *)         repo="$root" ;;
    esac
  else
    repo="\$HOME/path/to/$name"
  fi
  mkdir -p "$WT_CONFIG_DIR/projects" "$WT_CONFIG_DIR/tmux"
  {
    printf 'WT_REPO="%s"\n' "$repo"
    printf 'WT_SOCKET="%s"\n' "$name"
    printf 'WT_DEFAULT_BRANCH="main"\n'
    printf 'WT_TMUX_CONF="$HOME/.config/wt/tmux/%s.conf"\n' "$name"
    printf 'WT_WINDOWS=( "nvim:nvim" "shell:" "claude:claude" )\n'
    printf '# wt_post_create() { cp "$WT_REPO/.env" "$PWD/.env"; }\n'
  } > "$dest"
  wt_status "created project '$name' -> $dest"
  conf="$WT_CONFIG_DIR/tmux/$name.conf"
  if [ -e "$conf" ]; then
    wt_status "kept existing tmux conf -> $conf"
  else
    {
      printf 'source-file -q ~/.tmux.conf\n'
      printf "set -g status-style 'bg=colour22,fg=white'\n"
      printf "set -g status-left ' %s | '\n" "$name"
      printf 'set -g status-left-length 16\n'
    } > "$conf"
    wt_status "created tmux conf -> $conf"
  fi
  [ -n "$root" ] || wt_status "set WT_REPO in $dest (could not auto-detect a repo here)"
  [ "$edit" = 1 ] && wt_edit_file "$dest"
  wt_status "then: wt new <branch> --project $name"
}

cmd_new() {
  local no_attach=0 branch base rbase name dir pos
  pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-attach) no_attach=1; shift ;;
      --)          shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      -*)          wt_die "wt new: unknown option: $1" ;;
      *)           pos+=("$1"); shift ;;
    esac
  done
  branch="${pos[0]:-}"
  base="${pos[1]:-}"
  [ -n "$branch" ] || wt_die "usage: wt new <branch> [base] [--no-attach]"
  wt_require_tmux
  wt_resolve_project
  wt_require_repo

  # Invariant: the socket always keeps a home-base session on the trunk, living in
  # the main worktree ($WT_REPO). Ensure it before creating any other session.
  wt_ensure_main_session

  name="$(wt_sanitize "$branch")"

  # The trunk has no sibling worktree (git won't check it out twice) — it *is* the
  # main session ensured above, so skip worktree/session setup and just attach.
  if [ "$branch" != "$WT_DEFAULT_BRANCH" ]; then
    dir="$WT_REPO-$name"

    if [ ! -d "$dir" ]; then
      wt_update_trunk
      if git -C "$WT_REPO" show-ref --verify --quiet "refs/heads/$branch"; then
        git -C "$WT_REPO" worktree add "$dir" "$branch" || wt_die "git worktree add failed"
        wt_status "created worktree from local branch '$branch' -> $dir"
      elif git -C "$WT_REPO" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
        git -C "$WT_REPO" worktree add --track -b "$branch" "$dir" "origin/$branch" || wt_die "git worktree add failed"
        wt_status "created worktree tracking origin/$branch -> $dir"
      else
        rbase="$(wt_resolve_base "$base")"
        git -C "$WT_REPO" worktree add -b "$branch" "$dir" "$rbase" || wt_die "git worktree add failed"
        wt_status "created worktree for new branch '$branch' off $rbase -> $dir"
      fi
      ( cd "$dir" && wt_run_post_create ) || wt_status "warning: post-create hook failed"
    else
      wt_status "worktree exists -> $dir"
    fi

    if wt_session_exists "$name"; then
      wt_status "session '$name' already running on socket '$WT_SOCKET'"
    else
      wt_create_session "$name" "$dir"
      wt_status "started session '$name' on socket '$WT_SOCKET'"
    fi
  fi

  if [ "$no_attach" = 1 ]; then
    wt_status "not attaching (--no-attach)"
  else
    wt_attach_session "$name"
  fi
}

cmd_stop() {
  local pos=() branch
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      -*) wt_die "wt stop: unknown option: $1" ;;
      *)  pos+=("$1"); shift ;;
    esac
  done
  wt_require_tmux
  wt_resolve_project
  if [ "${#pos[@]}" -eq 0 ]; then
    branch="$(wt_current_branch)" || wt_die "usage: wt stop [branch...]   (or run inside a worktree to infer it)"
    pos=("$branch")
  fi
  for branch in "${pos[@]}"; do wt_stop_one "$branch"; done
}

wt_stop_one() {
  local branch="$1" name
  name="$(wt_sanitize "$branch")"
  if tmux -L "$WT_SOCKET" kill-session -t "=$name" 2>/dev/null; then
    wt_status "stopped session '$name' (worktree and branch kept)"
  else
    wt_status "no live session '$name' on socket '$WT_SOCKET'"
  fi
}

cmd_rm() {
  local force=0 branch pos=() rc=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) force=1; shift ;;
      --)         shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      -*)         wt_die "wt rm: unknown option: $1" ;;
      *)          pos+=("$1"); shift ;;
    esac
  done
  wt_resolve_project
  wt_require_repo
  if [ "${#pos[@]}" -eq 0 ]; then
    branch="$(wt_current_branch)" || wt_die "usage: wt rm [branch...] [--force]   (or run inside a worktree to infer it)"
    pos=("$branch")
  fi
  # Never abort a batch on one failure: report it, keep going, exit non-zero.
  for branch in "${pos[@]}"; do wt_rm_one "$branch" "$force" || rc=1; done
  return $rc
}

wt_rm_one() {
  local branch="$1" force="$2" name dir
  if [ "$branch" = "$WT_DEFAULT_BRANCH" ]; then
    wt_status "skip '$branch': refusing to remove the main worktree (trunk lives in $WT_REPO); use 'wt stop $branch'"
    return 1
  fi
  name="$(wt_sanitize "$branch")"
  dir="$WT_REPO-$name"
  if command -v tmux >/dev/null 2>&1 && tmux -L "$WT_SOCKET" kill-session -t "=$name" 2>/dev/null; then
    wt_status "stopped session '$name'"
  fi
  if [ "$force" = 1 ]; then
    git -C "$WT_REPO" worktree remove --force "$dir" || { wt_status "warning: git worktree remove failed: $dir"; return 1; }
  else
    git -C "$WT_REPO" worktree remove "$dir" || { wt_status "warning: git worktree remove failed: $dir (uncommitted changes? retry: wt rm $branch --force)"; return 1; }
  fi
  wt_status "removed worktree -> $dir (branch '$branch' kept)"
}

cmd_ls() {
  local all=0 f name any=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --all|-a) all=1; shift ;;
      --)       shift; break ;;
      -*)       wt_die "wt ls: unknown option: $1" ;;
      *)        wt_die "wt ls: unexpected argument: $1" ;;
    esac
  done
  if [ "$all" = 0 ]; then
    wt_resolve_project
    wt_require_repo
    wt_ls_one
    return
  fi
  # --all: one section per registered project. A broken/missing project is noted
  # and skipped (in a subshell, so wt_load_project's die can't abort the sweep).
  for f in "$WT_CONFIG_DIR"/projects/*.sh; do
    [ -f "$f" ] || continue
    any=1
    name="$(basename "$f" .sh)"
    ( if ! wt_load_project "$name" >/dev/null 2>&1; then
        printf '── %s  (config error; skipped)\n' "$name"; exit 0
      fi
      printf '── %s  (%s)\n' "$name" "$WT_REPO"
      [ -d "$WT_REPO" ] || { wt_status "   WT_REPO missing: $WT_REPO"; exit 0; }
      wt_ls_one )
  done
  [ "$any" = 0 ] && wt_status "no projects registered. Add one: wt init"
}

wt_ls_one() {
  local sessions="" line br name mark
  command -v tmux >/dev/null 2>&1 && sessions="$(tmux -L "$WT_SOCKET" list-sessions -F '#{session_name}' 2>/dev/null)"
  # Session name is the sanitized branch; recover it from each worktree's [branch].
  git -C "$WT_REPO" worktree list | while IFS= read -r line; do
    case "$line" in
      *\[*\]*) br="${line##*\[}"; br="${br%%\]*}"; name="$(wt_sanitize "$br")" ;;
      *)       name="" ;;
    esac
    mark="  "
    if [ -n "$name" ] && printf '%s\n' "$sessions" | grep -qxF "$name"; then mark="● "; fi
    printf '%s%s\n' "$mark" "$line"
  done
}

cmd_attach() {
  local pos=() branch
  while [ $# -gt 0 ]; do
    case "$1" in
      --) shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      -*) wt_die "wt attach: unknown option: $1" ;;
      *)  pos+=("$1"); shift ;;
    esac
  done
  wt_require_tmux
  wt_resolve_project
  branch="${pos[0]:-}"
  if [ -n "$branch" ]; then
    wt_attach_session "$(wt_sanitize "$branch")"
    return
  fi
  # No branch: plain socket attach, keeping tmux's native behavior. Only when the
  # socket has no session yet do we bootstrap the trunk's main session to land on.
  if ! tmux -L "$WT_SOCKET" list-sessions >/dev/null 2>&1; then
    wt_require_repo
    wt_ensure_main_session
    wt_attach_session "$(wt_main_session_name)"
  elif [ -n "${TMUX:-}" ]; then
    wt_die "already inside tmux; run 'wt attach <branch>' to switch to a specific session"
  else
    tmux -L "$WT_SOCKET" attach
  fi
}

cmd_kill() {
  wt_require_tmux
  wt_resolve_project
  if tmux -L "$WT_SOCKET" kill-server 2>/dev/null; then
    wt_status "killed tmux server on socket '$WT_SOCKET'"
  else
    wt_status "no tmux server running on socket '$WT_SOCKET'"
  fi
}

cmd_doctor() {
  wt_resolve_project
  wt_require_repo
  git -C "$WT_REPO" worktree prune
  wt_status "ran: git worktree prune"
  # Canonicalize both sides to physical paths so symlinks (e.g. /tmp) don't misclassify.
  local found=0 d rp p cp reg=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    cp="$(cd -P "$p" 2>/dev/null && pwd)" || cp="$p"
    reg="$reg$cp
"
  done <<< "$(git -C "$WT_REPO" worktree list --porcelain | sed -n 's/^worktree //p')"
  local ans
  for d in "$WT_REPO"-*; do
    [ -d "$d" ] || continue
    rp="$(cd -P "$d" 2>/dev/null && pwd)" || rp="$d"
    printf '%s\n' "$reg" | grep -qxF "$rp" && continue
    found=1
    printf 'orphan dir (not a registered worktree): %s\n' "$d"
    printf '  remove it? [y/N] '
    ans=""; read -r ans
    case "$ans" in
      y|Y) rm -rf "$d" && wt_status "  removed $d" ;;
      *)   wt_status "  kept $d" ;;
    esac
  done
  [ "$found" = 0 ] && wt_status "clean: no orphan directories under $(basename "$WT_REPO")-*"
}

cmd_projects() {
  local f name any=0
  for f in "$WT_CONFIG_DIR"/projects/*.sh; do
    [ -f "$f" ] || continue
    any=1
    name="$(basename "$f" .sh)"
    ( . "$f" >/dev/null 2>&1
      printf '%-16s %-42s socket:%s\n' "$name" "${WT_REPO:-?}" "${WT_SOCKET:-$(basename "${WT_REPO:-?}")}" )
  done
  [ "$any" = 0 ] && wt_status "no projects registered. Add one: $WT_CONFIG_DIR/projects/<name>.sh"
}

cmd_help() {
  cat <<'EOF'
wt — git worktrees + per-project tmux sessions

usage: wt <command> [args] [-p|--project <name>]

commands:
  init [name] [--no-edit]            scaffold a project config (auto-fills repo inside one), open in $EDITOR
  new <branch> [base] [--no-attach]  create-or-resume worktree + tmux session
  stop [branch...]                   kill tmux session(s); no branch = current worktree
  rm [branch...] [--force]           kill session(s) + remove worktree dir(s); no branch = current worktree
  ls [--all]                         list worktrees + live sessions (●); --all spans every project
  attach [branch]                    attach to the socket (or a session); bootstraps main if empty
  kill                               kill the whole project's tmux server
  doctor                             prune worktrees, find/offer to clean orphan dirs
  projects                           list registered projects
  help [command]                     show this help, or detailed help for a command

run 'wt <command> --help' for details and examples on any command.

the socket always keeps a main session on the trunk (WT_DEFAULT_BRANCH) in WT_REPO:
'wt new' ensures it, 'wt new <trunk>' opens it (no worktree), and a bare 'wt attach'
onto an empty socket bootstraps it.

project resolution: -p/--project <name>, or $WT_PROJECT, else auto-detected from $PWD's repo.
config: ~/.config/wt/projects/<name>.sh   (see examples/ in the wt repo)
EOF
}

# Per-command help. `wt <cmd> --help` and `wt help <cmd>` route here; an unknown
# or empty command falls back to the global overview.
wt_usage() {
  local resolves=1
  case "$1" in
    init)
      resolves=0
      cat <<'EOF'
usage: wt init [name] [--no-edit]

Scaffold a project config at ~/.config/wt/projects/<name>.sh plus a matching
tmux conf, then open the config in $VISUAL/$EDITOR (else vi). Run inside a git
repo to auto-fill WT_REPO and default the name to the repo's basename.

  name        project name (default: basename of the repo you're in)
  --no-edit   don't open the new config in your editor
EOF
      ;;
    new)
      cat <<'EOF'
usage: wt new <branch> [base] [--no-attach]

Create-or-resume a worktree for <branch> and its tmux session, then attach.
Resolution: an existing local branch is checked out; else a matching
origin/<branch> is tracked; else a new branch is created off [base]. If
<branch> is the trunk it opens the main session in WT_REPO (no new worktree).

  base          ref to branch from when creating a NEW branch
                (default: the branch you're on, else origin/<trunk>)
  --no-attach   set everything up but don't attach
EOF
      ;;
    stop)
      cat <<'EOF'
usage: wt stop [branch...]

Kill the tmux session for each branch; the worktree and branch are kept.
With no branch, infers it from the worktree you're standing in.

  branch...   one or more branches (omit to use the current worktree)
EOF
      ;;
    rm)
      cat <<'EOF'
usage: wt rm [branch...] [--force]

Kill the session and remove the worktree directory for each branch; the branch
itself is kept. Refuses the trunk (use 'wt stop'). With no branch, infers it
from the worktree you're standing in. A failure on one branch is reported but
does not stop the rest.

  branch...   one or more branches (omit to use the current worktree)
  --force     remove even with uncommitted changes / untracked files
EOF
      ;;
    ls)
      cat <<'EOF'
usage: wt ls [--all]

List the project's worktrees, marking ones with a live tmux session (●).

  --all   list every registered project's worktrees and sessions
EOF
      ;;
    attach)
      cat <<'EOF'
usage: wt attach [branch]

Attach to the project's tmux socket. With [branch], target that branch's
session. A bare attach onto an empty socket bootstraps the trunk's main
session. To reach a project from anywhere, add -p <name>:

  wt attach -p myproject             # main session of another project
  wt attach some-branch -p myproj    # a specific session there
EOF
      ;;
    kill)
      cat <<'EOF'
usage: wt kill

Kill the whole project's tmux server (every session on its socket). Worktrees
and branches are left untouched.
EOF
      ;;
    doctor)
      cat <<'EOF'
usage: wt doctor

Prune stale worktree registrations (git worktree prune), then find directories
matching <repo>-* that aren't registered worktrees and offer to remove them.
EOF
      ;;
    projects)
      resolves=0
      cat <<'EOF'
usage: wt projects

List registered projects with their WT_REPO and socket.
EOF
      ;;
    help)
      resolves=0
      cat <<'EOF'
usage: wt help [command]

Show the general overview, or detailed help for a specific command
(equivalent to 'wt <command> --help').
EOF
      ;;
    *)
      cmd_help
      return
      ;;
  esac
  [ "$resolves" = 1 ] && cat <<'EOF'

project: resolved from -p/--project <name>, then $WT_PROJECT, then $PWD's repo.
EOF
  return 0
}
