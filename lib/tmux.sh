# tmux session lifecycle on a per-project socket (tmux -L <socket>).
# Session targets use the "=name" exact-match form to avoid tmux prefix matching.

wt_session_exists() {
  tmux -L "$WT_SOCKET" has-session -t "=$1" 2>/dev/null
}

# Build the windows from WT_WINDOWS ("winname:cmd"; empty cmd = plain shell).
# The first entry starts the server (gets -f conf); the rest are added detached.
wt_create_session() {
  local name="$1" dir="$2" first=1 entry win cmd base
  if [ -n "$WT_TMUX_CONF" ] && [ ! -f "$WT_TMUX_CONF" ]; then
    wt_status "warning: WT_TMUX_CONF not found ($WT_TMUX_CONF); using default tmux config"
  fi
  for entry in "${WT_WINDOWS[@]}"; do
    case "$entry" in
      *:*) win="${entry%%:*}"; cmd="${entry#*:}" ;;
      *)   win="$entry"; cmd="" ;;
    esac
    [ -n "$win" ] || win="shell"
    if [ "$first" = 1 ]; then
      first=0
      base=(tmux -L "$WT_SOCKET")
      [ -n "$WT_TMUX_CONF" ] && [ -f "$WT_TMUX_CONF" ] && base=(tmux -L "$WT_SOCKET" -f "$WT_TMUX_CONF")
      if [ -n "$cmd" ]; then
        "${base[@]}" new-session -d -s "$name" -c "$dir" -n "$win" "$cmd"
      else
        "${base[@]}" new-session -d -s "$name" -c "$dir" -n "$win"
      fi
    else
      if [ -n "$cmd" ]; then
        tmux -L "$WT_SOCKET" new-window -d -t "=$name" -c "$dir" -n "$win" "$cmd"
      else
        tmux -L "$WT_SOCKET" new-window -d -t "=$name" -c "$dir" -n "$win"
      fi
    fi
  done
}

wt_attach_session() {
  local name="$1"
  if [ -n "${TMUX:-}" ]; then
    tmux -L "$WT_SOCKET" switch-client -t "=$name"
  else
    tmux -L "$WT_SOCKET" attach -t "=$name"
  fi
}

# The trunk's session name. Its home is the main worktree ($WT_REPO): git won't
# check the default branch out in a sibling worktree, so it has no "-<branch>" dir.
wt_main_session_name() { wt_sanitize "$WT_DEFAULT_BRANCH"; }

# Guarantee the socket has a home-base session on the trunk, in the main worktree.
# Idempotent: a no-op if it's already running. Called by every command that brings
# the server up, so a project's socket always has a session on its default branch.
wt_ensure_main_session() {
  local name
  name="$(wt_main_session_name)"
  wt_session_exists "$name" && return 0
  wt_create_session "$name" "$WT_REPO"
  wt_status "started main session '$name' on socket '$WT_SOCKET' ($WT_REPO)"
}
