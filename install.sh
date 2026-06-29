#!/usr/bin/env bash
# Symlink bin/wt onto PATH and scaffold the ~/.config/wt/ skeleton.
# Idempotent: never clobbers existing config.
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN_DIR="${WT_BIN_DIR:-$HOME/.local/bin}"
CONFIG_DIR="${WT_CONFIG_DIR:-$HOME/.config/wt}"

mkdir -p "$BIN_DIR" "$CONFIG_DIR/projects" "$CONFIG_DIR/tmux"

ln -sf "$SRC_DIR/bin/wt" "$BIN_DIR/wt"
echo "linked  $BIN_DIR/wt -> $SRC_DIR/bin/wt"

if [ ! -f "$CONFIG_DIR/config.sh" ]; then
  cat > "$CONFIG_DIR/config.sh" <<'EOF'
# wt global config (optional) — sourced before each project config.
# Put defaults shared across projects here, e.g.:
#   WT_DEFAULT_BRANCH="main"
EOF
  echo "created $CONFIG_DIR/config.sh"
else
  echo "kept    $CONFIG_DIR/config.sh (exists)"
fi

echo
echo "done. Ensure $BIN_DIR is on your PATH:"
echo "  export PATH=\"$BIN_DIR:\$PATH\""
echo
echo "To register a project, copy an example and edit it:"
echo "  cp $SRC_DIR/examples/myrepo.sh        $CONFIG_DIR/projects/<name>.sh"
echo "  cp $SRC_DIR/examples/tmux/myrepo.conf $CONFIG_DIR/tmux/<name>.conf"
