# command implementations. Each resolves a project (except init/projects/help).

cmd_init() {
  local name="${1:-}" root="" common repo conf dest
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

  name="$(wt_sanitize "$branch")"
  dir="$WT_REPO-$name"

  if [ ! -d "$dir" ]; then
    git -C "$WT_REPO" fetch origin --quiet || wt_status "warning: fetch failed (continuing offline)"
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

  if [ "$no_attach" = 1 ]; then
    wt_status "not attaching (--no-attach)"
  else
    wt_attach_session "$name"
  fi
}

cmd_stop() {
  local branch="${1:-}" name
  [ -n "$branch" ] || wt_die "usage: wt stop <branch>"
  wt_require_tmux
  wt_resolve_project
  name="$(wt_sanitize "$branch")"
  if tmux -L "$WT_SOCKET" kill-session -t "=$name" 2>/dev/null; then
    wt_status "stopped session '$name' (worktree and branch kept)"
  else
    wt_status "no live session '$name' on socket '$WT_SOCKET'"
  fi
}

cmd_rm() {
  local force=0 branch name dir pos
  pos=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --force|-f) force=1; shift ;;
      --)         shift; while [ $# -gt 0 ]; do pos+=("$1"); shift; done ;;
      -*)         wt_die "wt rm: unknown option: $1" ;;
      *)          pos+=("$1"); shift ;;
    esac
  done
  branch="${pos[0]:-}"
  [ -n "$branch" ] || wt_die "usage: wt rm <branch> [--force]"
  wt_resolve_project
  wt_require_repo
  name="$(wt_sanitize "$branch")"
  dir="$WT_REPO-$name"
  if command -v tmux >/dev/null 2>&1 && tmux -L "$WT_SOCKET" kill-session -t "=$name" 2>/dev/null; then
    wt_status "stopped session '$name'"
  fi
  if [ "$force" = 1 ]; then
    git -C "$WT_REPO" worktree remove --force "$dir" || wt_die "git worktree remove failed: $dir"
  else
    git -C "$WT_REPO" worktree remove "$dir" || wt_die "git worktree remove failed: $dir (uncommitted changes? retry: wt rm $branch --force)"
  fi
  wt_status "removed worktree -> $dir (branch '$branch' kept)"
}

cmd_ls() {
  wt_resolve_project
  wt_require_repo
  local sessions=""
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
  wt_require_tmux
  wt_resolve_project
  local branch="${1:-}"
  if [ -n "$branch" ]; then
    wt_attach_session "$(wt_sanitize "$branch")"
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

usage: wt <command> [args] [--project <name>]

commands:
  init [name]                        scaffold a project config (auto-fills repo if inside one)
  new <branch> [base] [--no-attach]  create-or-resume worktree + tmux session
  stop <branch>                      kill the tmux session (worktree + branch kept)
  rm <branch> [--force]              kill session and remove the worktree dir (branch kept)
  ls                                 list worktrees, marking ones with a live session (●)
  attach [branch]                    attach to the socket (or a specific session)
  kill                               kill the whole project's tmux server
  doctor                             prune worktrees, find/offer to clean orphan dirs
  projects                           list registered projects
  help                               show this help

project resolution: --project <name>, or $WT_PROJECT, else auto-detected from $PWD's repo.
config: ~/.config/wt/projects/<name>.sh   (see examples/ in the wt repo)
EOF
}
