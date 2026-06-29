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
