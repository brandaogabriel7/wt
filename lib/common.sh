# common helpers: messaging, sanitization, config + project resolution, preflight.

wt_status() { printf '%s\n' "$*"; }
wt_die() { printf 'wt: %s\n' "$*" >&2; exit 1; }

# Open a file in the user's editor: $VISUAL, then $EDITOR, then vi. A no-op when
# stdin isn't a terminal (scripts/CI) or the editor isn't found, so it never hangs
# or fails a non-interactive run — it just points at the file instead.
wt_edit_file() {
  local file="$1" editor="${VISUAL:-${EDITOR:-vi}}" bin
  if [ ! -t 0 ]; then
    wt_status "not a terminal; edit it yourself: $file"
    return 0
  fi
  bin="${editor%% *}"                     # first word ($EDITOR may carry args)
  if ! command -v "$bin" >/dev/null 2>&1; then
    wt_status "editor '$bin' not found; edit it yourself: $file"
    return 0
  fi
  $editor "$file"                         # unquoted on purpose: allow "code --wait" etc.
}

# branch -> name: the ONE sanitizer used everywhere. "/" becomes "-".
wt_sanitize() { printf '%s' "${1//\//-}"; }

wt_require_tmux() {
  command -v tmux >/dev/null 2>&1 || wt_die "tmux is not installed"
}

wt_require_repo() {
  [ -d "$WT_REPO" ] || wt_die "WT_REPO does not exist: $WT_REPO (project '$WT_PROJECT_NAME')"
  git -C "$WT_REPO" rev-parse --git-dir >/dev/null 2>&1 || wt_die "not a git repository: $WT_REPO"
}

# Absolute shared git dir for a repo path (identical across all of a repo's worktrees).
wt_common_dir() {
  if [ -n "${1:-}" ]; then
    git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null
  else
    git rev-parse --path-format=absolute --git-common-dir 2>/dev/null
  fi
}

# Match $PWD's repo against each registered project's WT_REPO; echo the project name.
wt_detect_project() {
  local here f name repo
  here="$(wt_common_dir)"
  [ -n "$here" ] || return 1
  for f in "$WT_CONFIG_DIR"/projects/*.sh; do
    [ -f "$f" ] || continue
    name="$(basename "$f" .sh)"
    repo="$( . "$f" >/dev/null 2>&1; printf '%s' "${WT_REPO:-}" )"
    [ -n "$repo" ] || continue
    [ "$(wt_common_dir "$repo")" = "$here" ] || continue
    printf '%s' "$name"
    return 0
  done
  return 1
}

wt_load_project() {
  local name="$1"
  local f="$WT_CONFIG_DIR/projects/$name.sh"
  [ -f "$f" ] || wt_die "no such project: '$name' (looked in $WT_CONFIG_DIR/projects). Try: wt projects"
  WT_REPO=""; WT_SOCKET=""; WT_DEFAULT_BRANCH=""; WT_TMUX_CONF=""; WT_WINDOWS=()
  unset -f wt_post_create 2>/dev/null
  . "$f"
  [ -n "$WT_REPO" ] || wt_die "project '$name': WT_REPO is not set in $f"
  [ -n "$WT_SOCKET" ] || WT_SOCKET="$(basename "$WT_REPO")"
  [ -n "$WT_DEFAULT_BRANCH" ] || WT_DEFAULT_BRANCH="main"
  [ "${#WT_WINDOWS[@]}" -eq 0 ] && WT_WINDOWS=( "shell:" )
  WT_PROJECT_NAME="$name"
}

wt_resolve_project() {
  local name="$WT_PROJECT_OVERRIDE"
  [ -n "$name" ] || name="${WT_PROJECT:-}"
  if [ -z "$name" ]; then
    name="$(wt_detect_project)" || wt_die "could not detect a project from $PWD; pass -p <name> or set WT_PROJECT (see: wt projects)"
  fi
  wt_load_project "$name"
}

# Branch checked out in $PWD, but ONLY when $PWD belongs to the resolved project's
# repo (same git common dir). Empty + return 1 otherwise, so 'stop'/'rm' can infer
# their target from the worktree you're standing in without ever guessing wrong.
wt_current_branch() {
  local here cur
  here="$(wt_common_dir)"
  [ -n "$here" ] || return 1
  [ "$here" = "$(wt_common_dir "$WT_REPO")" ] || return 1
  cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ -n "$cur" ] && [ "$cur" != "HEAD" ] || return 1   # unborn/detached: can't infer
  printf '%s' "$cur"
}

wt_run_post_create() {
  declare -f wt_post_create >/dev/null 2>&1 || return 0
  wt_post_create
}

# Resolve the base ref for a BRAND-NEW branch (case c only).
wt_resolve_base() {
  local explicit="$1" cur="" here there
  if [ -n "$explicit" ]; then
    printf '%s' "$explicit"; return
  fi
  here="$(wt_common_dir)"
  there="$(wt_common_dir "$WT_REPO")"
  if [ -n "$here" ] && [ "$here" = "$there" ]; then
    cur="$(git rev-parse --abbrev-ref HEAD 2>/dev/null)"
    [ "$cur" = "HEAD" ] && cur=""   # detached
  fi
  if [ -n "$cur" ] && [ "$cur" != "$WT_DEFAULT_BRANCH" ]; then
    printf '%s' "$cur"              # stack onto the branch I'm working in
  else
    printf '%s' "origin/$WT_DEFAULT_BRANCH"   # fresh remote trunk; local is often stale
  fi
}

# Refresh the trunk before branching off it, so new worktrees start from the
# latest. Always fetch; then fast-forward the LOCAL trunk only when it's the
# checked-out branch of the main worktree and can move cleanly. Never destructive:
# a diverged or dirty trunk is left untouched (new branches still base off the
# freshly-fetched origin/<trunk>, so they're current either way).
wt_update_trunk() {
  git -C "$WT_REPO" fetch origin --quiet || { wt_status "warning: fetch failed (continuing offline)"; return; }
  local cur
  cur="$(git -C "$WT_REPO" rev-parse --abbrev-ref HEAD 2>/dev/null)"
  [ "$cur" = "$WT_DEFAULT_BRANCH" ] || return 0   # trunk not checked out here; nothing to pull
  if git -C "$WT_REPO" merge --ff-only --quiet "origin/$WT_DEFAULT_BRANCH" 2>/dev/null; then
    wt_status "synced $WT_DEFAULT_BRANCH with origin/$WT_DEFAULT_BRANCH in $WT_REPO"
  else
    wt_status "note: could not fast-forward $WT_DEFAULT_BRANCH (diverged or dirty); leaving it as-is"
  fi
}
