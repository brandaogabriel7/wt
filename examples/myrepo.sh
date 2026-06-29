WT_REPO="$HOME/code/myrepo"                           # main worktree / repo root (required)
WT_SOCKET="myrepo"                                    # tmux -L socket (default: basename of WT_REPO)
WT_DEFAULT_BRANCH="main"
WT_TMUX_CONF="$HOME/.config/wt/tmux/myrepo.conf"      # optional
WT_WINDOWS=( "nvim:nvim" "shell:" "claude:claude" )   # "winname:cmd"; empty cmd = plain shell
wt_post_create() { cp "$WT_REPO/.env" "$PWD/.env"; }  # optional: seed files the new worktree needs
