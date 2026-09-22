# devcontainer - A containerized dev environment for AI agents

Arch Linux dev containers for working with coding agents such as Claude Code.
Podman walls off the project, bubblewrap sandboxes the agent's commands inside
the container, your dotfiles are mounted read-only, git-crypt confidential
folders are masked so nothing in the container can read them, and files the
host executes are read-only inside.

The isolation lives only in this repo, installed on the host as `devc`.
Projects carry no devcontainer files for it: `devc dev` works in any git repo.

```
Containerfile.base    arch-dev:base   shell/editor env, LSPs, paru, bwrap, socat
Containerfile.aio     arch-dev:aio    base + Python, Java, Julia, Rust, Typst, C/C++, Claude Code
justfile              local image builds, `just install`
.github/workflows/    weekly image builds to ghcr.io
devc/                 host launcher, recipes, config generator, post-create, tests
snippets/             host-side config: mounts, Claude Code settings
claudian/             wrapper that runs Obsidian Claudian's agent in a project's devc container
```

## Quick start

After the [one-time setup](#one-time-setup):

```sh
cd ~/projects/foo
devc dev
```

The project must be a git repository (`.git` a directory, not a worktree),
and its path must not contain `,` or `:`. Nothing is added to the repo except
empty mountpoint directories that podman leaves behind (`confidential/`,
`.claude/` where they were absent); `devc` ignores any `.devcontainer/` the
repo has.

The first `devc dev` stages your Claude Code config, generates the project's
devcontainer.json in `~/.cache/devc/<id>/`, pulls the image, creates the
container and runs `post-create.sh`: it copies the staged config in, fills the
tldr cache and checks that bwrap works (look for its `OK` or `WARNING` line).
Then it verifies the masks and read-only overlays and opens zsh.

## One-time setup

1. **Install the tools** on the host: podman, [just](https://github.com/casey/just),
   jq, rsync and the devcontainer CLI (AUR `devcontainer-cli` or
   `npm i -g @devcontainers/cli`).
2. **Install devc**: `just install` in this repo. It runs `devc/tests/run.sh`,
   then copies `devc` to `~/.local/bin`, its recipes, generator and
   post-create to `~/.local/share/devc`, and the Claudian wrapper to
   `~/.local/bin`. Copies, not symlinks: the host runs them, so a change here
   takes effect only after the next `just install`.
3. **Personal mounts**: copy `snippets/mounts.env` to
   `~/.config/devcontainer/mounts.env` and keep it in your dotfiles. Each
   `DEVC_MOUNT_n` becomes one mount of the generated config, in slot order;
   any number of slots. Paths use `${HOME}`, which expands when devc sources
   the file. Slot 2 mounts the `nvim-data` volume; fill it with
   `just refresh-nvim-data` from this repo. Slot 9 mounts the staged Claude
   Code config (see [Security model](#security-model)); `devc up` refuses a
   slot that mounts `~/.claude` itself.
4. **Claude Code sandbox**: merge `snippets/claude-settings.json` into
   `~/.claude/settings.json`. It enables the bwrap sandbox fail-closed
   (`failIfUnavailable: true`, `allowUnsandboxedCommands: false`) with a
   network allowlist. Check the key names against your Claude Code version.
5. **Claude Code config in git** (optional): `git init` in `~/.claude` with
   `snippets/claude-repo.gitignore` as `.gitignore`, so you can `git diff`
   what an agent changed inside a container.
6. **Auth (required)**: run `claude setup-token` on the host and save the
   token to `~/.config/devcontainer/claude-oauth-token` (mode 600):

   ```sh
   install -m 600 /dev/stdin ~/.config/devcontainer/claude-oauth-token   # paste, Ctrl-D
   ```

   Slot 10 mounts it read-only at `/run/secrets/claude-oauth-token`, and the
   image's `claude` wrapper exports it as `CLAUDE_CODE_OAUTH_TOKEN`. `devc up`
   refuses to start without that slot, or if the file is missing, empty or
   not mode 600, and prints the commands to fix it. The token lasts a year
   and never refreshes. `.credentials.json` is not shared on purpose: its
   refresh token rotates on every refresh, so copies on host and in
   containers log each other out.

devc uses the images at `ghcr.io/butzo/arch-dev`. To build your own, see
[Your own images](#your-own-images).

## Commands

### In a project (`devc`)

| Command                 | What it does                                                                       |
| ----------------------- | ---------------------------------------------------------------------------------- |
| `devc dev`              | start the container if needed, verify isolation, open zsh                          |
| `devc up`               | stage the Claude Code config, regenerate the config, create or start the container |
| `devc enter`            | open zsh in the running container                                                  |
| `devc verify-isolation` | check masks are empty tmpfs and overlays are read-only                             |
| `devc stop`             | stop the container; its state is kept                                              |
| `devc rebuild`          | recreate the container (new image, new overlays, changed mounts.env)               |
| `devc update`           | pull the newest image, then `rebuild`                                              |
| `devc raw-enter`        | `podman exec` straight in if the devcontainer CLI misbehaves                       |

`up` and `rebuild` refuse to start without a usable token file (see setup
step 6) or if mounts.env mounts all of `~/.claude`. `up` also restarts a
running container whose file overlays went stale (see
[Stale overlays](#stale-overlays)).

Masks and overlays follow what exists in the project when the container is
created. After adding `.obsidian/`, `.devcontainer/` or a `justfile`, run
`devc rebuild`; until you do, `verify-isolation` (and so `devc dev`) fails,
and so does `devc up` on a running container.

Inside the container: `nvim .`, `claude`, and ad-hoc `paru -S` or `pacman -S`.
Packages installed that way disappear with the container; add the ones you
keep to `Containerfile.aio`.

### In this repo (`justfile`)

| Command                              | What it does                                       |
| ------------------------------------ | -------------------------------------------------- |
| `just build`                         | build `base`, then `aio` (the default)             |
| `just build-base` / `just build-aio` | build one image                                    |
| `just rebuild`                       | build both images without layer cache              |
| `just push`                          | push `base` and `aio` to the registry              |
| `just pull`                          | pull `aio`                                         |
| `just prune`                         | remove dangling images                             |
| `just refresh-nvim-data`             | fill the `nvim-data` volume                        |
| `just install`                       | test, then install `devc` and the Claudian wrapper |

## Images

`base` is the shell and editor environment: zsh, neovim, LSPs and formatters,
CLI tools, paru, bubblewrap and socat (the Claude Code sandbox needs both), with
a `dev` user at UID 1000. `aio` adds the language toolchains and Claude Code.

Tags are `base` and `aio`, plus dated `base-YYYY-MM-DD` and `aio-YYYY-MM-DD`
for pinning. CI rebuilds every Monday at 04:00 UTC with `--no-cache` so
pacman packages are fresh, on every push that changes a Containerfile or the
workflow, and on demand from the Actions tab.

### Your own images

1. Fork this repo and replace `ghcr.io/butzo` in `justfile`,
   `Containerfile.aio`, `.github/workflows/build.yml`, `devc/base.json` and
   `devc/devc.just`.
2. Run the workflow once from the Actions tab.
3. Make the `arch-dev` package public (profile → Packages → `arch-dev` →
   settings), or `podman login ghcr.io` with a `read:packages` token on every
   machine that pulls.

## Confidential folders

`devc/gen-config` writes each project's mounts from what the project contains;
it is the single source of truth for them.

The workspace is mounted at its host path (path identity), so absolute paths
in tool output mean the same thing inside and out.

**Masks**: in every project, an empty tmpfs covers `confidential/` and
`.git/git-crypt`, even where they are absent, so a later `confidential/` is
covered from the first start. Neither git-crypt plaintext nor the key is
visible inside the container. The masks use `notmpcopyup`: without it podman
copies the host files into the tmpfs. `.git` stays writable, so agents can
commit; git shows the masked files as deleted, and a container-only
`~/.claude/CLAUDE.md` tells the agent never to stage those deletions.

**Read-only overlays**: paths the host executes are mounted a second time,
read-only, on top of the workspace. A writable copy would let an agent run
code on the host, where the plaintext lives.

| Path                                  | When                                                       |
| ------------------------------------- | ---------------------------------------------------------- |
| `.git/hooks`, `.git/config`           | always (host git and obsidian-git run them)                |
| `.claude/`                            | always; an empty read-only tmpfs if the project has none   |
| `.obsidian/` + mask over `.claudian/` | if `.obsidian/` exists (Obsidian vault)                    |
| `.devcontainer/`                      | if it exists (devc never reads it, but other tools run it) |
| `justfile`                            | if it exists (host runs its recipes)                       |
| `~/.local/share/devc` at `/opt/devc`  | always (post-create runs from there)                       |

In a vault, `.obsidian/` holds plugin code Obsidian loads and `.claudian/`
holds Claudian's transcripts, which may contain confidential notes attached in
the host UI.

`devc dev` runs `verify-isolation` before opening a shell.

### Stale overlays

A read-only overlay over a single _file_ pins its inode. Host git never edits
`.git/config` in place: it writes `config.lock` and renames it over (`git
checkout -b` with tracking, `branch -u`, `push -u`, `remote add`,
`git config`), and some editors save a `justfile` the same way. The
container's overlay then covers a deleted file, and the path resolves to the
new, writable file. Directory overlays are immune.

`devc up` (and `devc dev`) checks for this and restarts the container, which
binds the current file again; home dir, installed packages and the seeded
`~/.claude` survive, running processes (agent sessions included) do not. The
Claudian wrapper refuses to start an agent while an overlay is stale and asks
you to run `devc up`; it never restarts the container itself.

Between a host write to `.git/config` and the next `devc up` or Claudian
spawn, the container can write `.git/config`.

## Claudian

Claudian is an Obsidian plugin that runs Claude Code from inside a vault.
`claudian/claudian-podman.js` runs that agent inside the vault's devc container
instead of on the host:

1. `devc up` in the vault (see Obsidian vaults above).
2. `just install` in this repo.
3. In Claudian's settings, set the Claude CLI path to
   `~/.local/bin/claudian-podman.js` (absolute) and restart Obsidian.

The wrapper finds the container by its `devc.managed=true` and
`devcontainer.local_folder` labels (the vault path, or a parent of Claudian's
working directory), starts it if it is stopped, refuses if an overlay is
stale, and `podman exec`s `claude` there with only `CLAUDE_*`/`ANTHROPIC_*`
variables forwarded, by name. A `CLAUDE_CODE_OAUTH_TOKEN` in Obsidian's
environment wins over the token file. Set `CLAUDIAN_WRAPPER_DEBUG=/path/to/log`
in Claudian's environment settings to log what it runs.

Context Claudian attaches in the Obsidian UI (the open note, @mentions,
selections) comes from the host and bypasses the container.

## Security model

- **podman** bounds the project: only the workspace and the read-only mounts
  are visible. `--userns=keep-id` keeps file ownership in line with the host.
  devc adds no capabilities, privileges or security options (the devcontainer
  CLI adds `--security-opt label=disable` for podman itself).
- **bwrap** (the Claude Code sandbox) bounds agent commands inside the
  container and fails closed. `dev` has passwordless sudo, so it is defense
  in depth (mainly the network allowlist), not the boundary.
- **Read-only overlays** keep the agent from writing files the host executes,
  including devc itself (`/opt/devc`, installed by copy).
- **Git**: your identity is mounted read-only, so commits work. SSH keys and
  the agent never enter the container; push from the host.
- **Claude Code config**: `devc up` stages an allowlist of host `~/.claude`
  (`settings.json`, `CLAUDE.md`, agents, commands, hooks,
  plugins, rules, skills, `.git`, ...) into `~/.cache/devcontainer/claude-seed`,
  which mounts.env mounts read-only at `/claude-seed`; `post-create.sh` copies
  it into the container. The rest of `~/.claude` (`projects/`, `file-history/`,
  `backups/`, session data) holds transcripts and file snapshots of every other
  project and never enters. `~/.claude.json` stays container-local. The copy is
  disposable: inspect changes with `git diff` inside and redo the ones you
  want on the host.
- **Auth**: the OAuth token file is readable inside the container by design.
- **Not covered**: other files the host runs (`Makefile`, `package.json`
  scripts, `.envrc`, `.vscode/tasks.json`) are writable from the container.

## Migrating from project-template

Projects set up with the old in-repo `project-template/`:

1. `podman rm -f` the old container (its labels point at the in-repo config).
2. Diff the project's `justfile` against the old template; delete it only if
   identical. A `justfile` with project recipes stays and gets an overlay.
3. Remove `.devcontainer/` and `.claude/.gitkeep`; keep real `.claude/` content.
4. Commit in the project, then `devc dev`.

## Known issues

- The devcontainer CLI is Docker-first. Podman works, but keep
  `devc raw-enter` handy. `updateRemoteUserUID` is off because keep-id
  handles UIDs.
- `devcontainer up --mount` only accepts `type=bind|volume,source,target`
  (no `readonly`, no `tmpfs`), which is why devc writes every mount into the
  generated devcontainer.json. Check that a read-only mount really is one by
  `touch`ing a file in it.
- A repo's own devcontainer (its image, features, toolchain) is not used:
  every project runs `arch-dev:aio`. Using it for dependency packing is not
  solved yet.
- The Bash sandbox write-protects Claude Code's config paths and creates a
  placeholder for any that is missing, which fails inside the read-only
  `.claude` (`Can't create file .../.claude/skills: Read-only file
system`). post-create adds the workspace `.claude` to
  `sandbox.filesystem.denyWrite` in the container's user settings, so the
  sandbox skips those paths instead.
- bwrap inside podman needs nested unprivileged user namespaces;
  post-create reports whether it works. Its fresh `/proc` mount fails in the
  container, so post-create sets `sandbox.enableWeakerNestedSandbox` in the
  container's user settings, which binds the container's own `/proc` instead.
- Symlinks inside a mounted directory dangle in the container. Stow config
  directories as folder links, not per file.
- Clipboard: pasting into the container works through the terminal. Copying
  out of nvim uses OSC 52; in kitty, allow it with
  `clipboard_control write-clipboard write-primary`.
