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
matching tmux conf, then opens the file in your editor: `$VISUAL`/`$EDITOR`, else `vi`;
pass `--no-edit` to skip), or write it by hand. A project file is sourced bash:

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

1. `-p <name>` / `--project <name>` flag (may appear anywhere on the line),
2. `$WT_PROJECT`,
3. auto-detection — matches `$PWD`'s repo (its `git --git-common-dir`) against each
   registered project's `WT_REPO`, so it works from the main repo or any of its worktrees.

If none match you get a clear error. Because the flag works on every command, you can
drive any project from anywhere — e.g. `wt attach -p myrepo` or `wt ls -p myrepo --all`.

## Commands

Every command accepts `-p`/`--project <name>` and `-h`/`--help` (the latter prints
detailed usage for that command, e.g. `wt new --help`).

| command | description |
| --- | --- |
| `wt init [name] [--no-edit]` | scaffold a new project config (auto-fills `WT_REPO` inside a repo) and open it in `$EDITOR` |
| `wt new <branch> [base] [--no-attach]` | create-or-resume a worktree + tmux session |
| `wt stop [branch...]` | kill tmux session(s); with no branch, the current worktree's |
| `wt rm [branch...] [--force]` | kill session(s) and remove worktree dir(s); with no branch, the current worktree's (branch kept) |
| `wt ls [--all]` | `git worktree list`, marking live sessions (`●`); `--all` spans every project |
| `wt attach [branch]` | attach to the socket, or a specific session (bootstraps main if empty) |
| `wt kill` | kill the whole project's tmux server |
| `wt doctor` | prune worktrees; find and offer to remove orphan dirs |
| `wt projects` | list registered projects |
| `wt help [command]` | general help, or detailed help for a command |

### Naming

One sanitizer is used everywhere: **`/` becomes `-`**.

- session name = sanitized branch
- worktree dir = `<WT_REPO>-<sanitized branch>` (a sibling of the main repo)

### The main session

Each project's socket always keeps a **main session** on the trunk
(`WT_DEFAULT_BRANCH`), running in the main worktree `WT_REPO` itself. The trunk has
no sibling worktree — git won't check the same branch out twice — so `WT_REPO` *is*
its home. Every `wt new` ensures this session exists, and a bare `wt attach` onto an
empty socket bootstraps it — so within `wt`, bringing a socket up always establishes
the trunk anchor, and attaching to a project lands you somewhere sensible.

- `wt new <trunk>` opens this session (no worktree is created).
- `wt attach` with no branch keeps tmux's native attach; if the socket has no session
  yet, it creates the main session and attaches to it.
- `wt stop <trunk>` kills it (it comes back on the next `wt new`).
- `wt rm <trunk>` is refused — it's the main worktree.

### `wt new`

`wt new` first ensures the socket's [main session](#the-main-session) exists. If
`<branch>` is the trunk itself, that session *is* the target, so it just attaches —
no worktree is created.

Otherwise, if the worktree dir does not exist, it is materialized in this order:

1. **refresh the trunk** — `git fetch origin`, then fast-forward the local trunk to
   `origin/<trunk>` when the trunk is checked out in `WT_REPO` and can move cleanly.
   Never destructive: a diverged or dirty trunk is left as-is (brand-new branches
   still base off the freshly-fetched `origin/<trunk>`, so they're current either way).
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
- **Always a main session.** A socket that's up always has a home-base session on the
  trunk, in `WT_REPO` — so a project is never a bag of feature sessions with no anchor.

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
