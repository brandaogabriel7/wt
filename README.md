# wt

A small, generic CLI for managing **git worktrees + per-project tmux sessions**. Each
project gets its own dedicated tmux socket (`tmux -L <socket>`), so its windows never mix
with your other work.

`wt` generalizes a set of single-repo zsh functions into a project-agnostic tool: register
any number of repos in a personal config registry and drive them all the same way.

## Requirements

- `git`
- `tmux`

No Ruby, no tmuxinator. Written in POSIX-friendly bash that runs on macOS system bash 3.2.

## Install

```sh
./install.sh
```

This symlinks `bin/wt` into `~/.local/bin/`, creates `~/.config/wt/{projects,tmux}/`, and
seeds a `config.sh`. It is idempotent and **never clobbers** existing config; it then prints
how to register your first project from `examples/`. Make sure `~/.local/bin` is on your `PATH`.

Override locations with `WT_BIN_DIR` / `WT_CONFIG_DIR`.

## Configuration

Config lives in a **personal registry** under `~/.config/wt/` — it is not committed into
each project's repo.

```
~/.config/wt/
  config.sh              # optional, sourced first; shared defaults
  projects/<name>.sh     # one file per project
  tmux/<name>.conf       # optional per-socket tmux config
```

Create one with **`wt init`** (run from inside the repo — it auto-fills `WT_REPO` and a
matching tmux conf), or write it by hand. A project file is sourced bash:

```sh
WT_REPO="$HOME/code/myrepo"                  # main worktree / repo root (required)
WT_SOCKET="myrepo"                            # tmux -L socket (default: basename of WT_REPO)
WT_DEFAULT_BRANCH="main"                      # trunk (default: main)
WT_TMUX_CONF="$HOME/.config/wt/tmux/myrepo.conf"   # optional
WT_WINDOWS=( "nvim:nvim" "shell:" "claude:claude" )  # "winname:cmd"; empty cmd = plain shell
wt_post_create() { cp "$WT_REPO/.env" "$PWD/.env"; }  # optional hook, runs in the new worktree
```

See [`examples/myrepo.sh`](examples/myrepo.sh) and
[`examples/tmux/myrepo.conf`](examples/tmux/myrepo.conf).

### Project resolution

Each command picks a project by, in order:

1. `--project <name>` flag (may appear anywhere on the line),
2. `$WT_PROJECT`,
3. auto-detection — matches `$PWD`'s repo (its `git --git-common-dir`) against each
   registered project's `WT_REPO`, so it works from the main repo or any of its worktrees.

If none match you get a clear error.

## Commands

| command | description |
| --- | --- |
| `wt init [name]` | scaffold a new project config (auto-fills `WT_REPO` when run inside a repo) |
| `wt new <branch> [base] [--no-attach]` | create-or-resume a worktree + tmux session |
| `wt stop <branch>` | kill just the tmux session (worktree + branch stay) |
| `wt rm <branch> [--force]` | kill session and remove the worktree dir (branch kept) |
| `wt ls` | `git worktree list`, marking worktrees with a live session (`●`) |
| `wt attach [branch]` | attach to the socket, or a specific session |
| `wt kill` | kill the whole project's tmux server |
| `wt doctor` | prune worktrees; find and offer to remove orphan dirs |
| `wt projects` | list registered projects |

### Naming

One sanitizer is used everywhere: **`/` becomes `-`**.

- session name = sanitized branch
- worktree dir = `<WT_REPO>-<sanitized branch>` (a sibling of the main repo)

### `wt new`

If the worktree dir does not exist, it is materialized in this order:

1. `git fetch origin --quiet`
2. **local branch** exists → `git worktree add "$dir" "$branch"`
3. else **remote branch** `origin/<branch>` exists → `git worktree add --track -b ...`
4. else **brand new** → `git worktree add -b "$branch" "$dir" "<base>"`

Then `wt_post_create` runs in the new dir (e.g. to copy `.env`), and the tmux session is
created (or attached if it already exists).

**Base** (only used when creating a brand-new branch):

- explicit `[base]` arg → used verbatim;
- else if `$PWD` is inside this project and on a non-trunk branch → that branch (lets you
  stack a new branch on the one you're working in);
- else → `origin/<WT_DEFAULT_BRANCH>` (fresh remote trunk; local trunk is often stale).

The tmux session is built from `WT_WINDOWS`: the first entry starts the server (and is the
only call that loads `WT_TMUX_CONF` via `-f`); the rest are added as detached windows so the
first window stays focused. Attach is skipped with `--no-attach`, uses `switch-client` when
already inside tmux, and `attach` otherwise.

## Design decisions

- **Pure tmux.** Sessions are driven directly with `tmux -L <socket> ...`; no tmuxinator,
  no Ruby. Only runtime deps are `tmux` + `git`.
- **bash 3.2-friendly.** No associative arrays, no `${var,,}`, no bash-4-only features.
- **Personal registry.** Per-project config lives under `~/.config/wt/`, not inside each
  repo, so the tool stays generic and your repos stay clean.
- **Dedicated socket per project.** Each project's sessions are isolated on their own
  socket and can be configured (status bar, label) independently.

## Layout

```
bin/wt                    single dispatcher: wt <command> [args]
lib/common.sh             messaging, sanitization, config + project resolution
lib/tmux.sh               tmux session lifecycle
lib/commands.sh           command implementations
examples/myrepo.sh        sample project config
examples/tmux/myrepo.conf sample per-socket tmux config
install.sh                symlink + scaffold ~/.config/wt/
```
