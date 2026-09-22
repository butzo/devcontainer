# devcontainer - A containerized dev environment for AI agents

Arch Linux dev containers for working with coding agents such as Claude Code.
Podman walls off the project, bubblewrap sandboxes the agent's commands inside
the container, your dotfiles are mounted read-only, git-crypt confidential
folders are masked so nothing in the container can read them, and files the
host executes are read-only inside.

```
Containerfile.base    arch-dev:base   shell/editor env, LSPs, paru, bwrap, socat
Containerfile.aio     arch-dev:aio    base + Python, Java, Julia, Rust, Typst, C/C++, Claude Code
justfile              local image builds, Claudian wrapper install
.github/workflows/    weekly image builds to ghcr.io
project-template/     copy into a project: .devcontainer/ + .claude/ + justfile
snippets/             host-side config: mounts, Claude Code settings
claudian/             wrapper that runs Obsidian Claudian's agent in a project's devcontainer
```

## Quick start

After the [one-time setup](#one-time-setup):

```sh
cp -r ~/devcontainer/project-template/{.devcontainer,.claude,justfile} ~/projects/foo/
cd ~/projects/foo
just dev
```

The project must be a git repository (`.git` a directory, not a worktree).
Commit `.devcontainer/`, `.claude/` and `justfile` in the project.
devcontainer.json holds no personal paths, so collaborators (VS Code included)
use the same file.

The first `just dev` stages your Claude Code config, pulls the image, creates
the container and runs `post-create.sh`: it copies the staged config in, fills
the tldr cache and checks that bwrap works (look for its `OK` or `WARNING`
line). Then it verifies the masks and read-only overlays and opens zsh.

## One-time setup

1. **Install the tools** on the host: podman, [just](https://github.com/casey/just),
   rsync and the devcontainer CLI (AUR `devcontainer-cli` or
   `npm i -g @devcontainers/cli`). The template justfile passes
   `--docker-path podman`; change `engine` there to use Docker.
2. **Personal mounts**: copy `snippets/mounts.env` to
   `~/.config/devcontainer/mounts.env` and keep it in your dotfiles. Each
   `DEVC_MOUNT_n` fills one of ten mount slots in devcontainer.json; unset
   slots become an empty tmpfs. Paths use `${HOME}`, which expands when the
   justfile sources the file. Slot 2 mounts the `nvim-data` volume; fill it
   with `just refresh-nvim-data` from this repo. Slot 9 mounts the staged
   Claude Code config (see [Security model](#security-model)); `just up`
   refuses a slot that mounts `~/.claude` itself.
3. **Claude Code sandbox**: merge `snippets/claude-settings.json` into
   `~/.claude/settings.json`. It enables the bwrap sandbox fail-closed
   (`failIfUnavailable: true`, `allowUnsandboxedCommands: false`) with a
   network allowlist. Check the key names against your Claude Code version.
4. **Claude Code config in git** (optional): `git init` in `~/.claude` with
   `snippets/claude-repo.gitignore` as `.gitignore`, so you can `git diff`
   what an agent changed inside a container.
5. **Auth (required)**: run `claude setup-token` on the host and save the
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

The template uses the images at `ghcr.io/butzo/arch-dev`. To build your own,
see [Your own images](#your-own-images).

## Commands

### In a project (`project-template/justfile`)

| Command                 | What it does                                                      |
| ----------------------- | ----------------------------------------------------------------- |
| `just dev`              | start the container if needed, verify isolation, open zsh         |
| `just up`               | stage the Claude Code config, create or start the container       |
| `just enter`            | open zsh in the running container                                 |
| `just verify-isolation` | check masks are empty tmpfs and overlays are read-only            |
| `just stop`             | stop the container; its state is kept                             |
| `just rebuild`          | recreate the container (new image, devcontainer.json, mounts.env) |
| `just update`           | pull the newest image, then `rebuild`                             |
| `just raw-enter`        | `podman exec` straight in if the devcontainer CLI misbehaves      |

`up` and `rebuild` refuse to start if a required mask or overlay is missing
from devcontainer.json, if an enabled overlay's host path is missing, or if
mounts.env mounts all of `~/.claude`.

Inside the container: `nvim .`, `claude`, and ad-hoc `paru -S` or `pacman -S`.
Packages installed that way disappear with the container; add the ones you
keep to `Containerfile.aio`.

### In this repo (`justfile`)

| Command                              | What it does                                  |
| ------------------------------------ | --------------------------------------------- |
| `just build`                         | build `base`, then `aio` (the default)        |
| `just build-base` / `just build-aio` | build one image                               |
| `just rebuild`                       | build both images without layer cache         |
| `just push`                          | push `base` and `aio` to the registry         |
| `just pull`                          | pull `aio`                                    |
| `just prune`                         | remove dangling images                        |
| `just refresh-nvim-data`             | fill the `nvim-data` volume                   |
| `just install-claudian`              | copy the Claudian wrapper to `~/.local/bin`   |

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
   `Containerfile.aio`, `.github/workflows/build.yml` and `project-template/`.
2. Run the workflow once from the Actions tab.
3. Make the `arch-dev` package public (profile → Packages → `arch-dev` →
   settings), or `podman login ghcr.io` with a `read:packages` token on every
   machine that pulls.

## Confidential folders

The workspace is mounted at its host path (path identity), so absolute paths
in tool output mean the same thing inside and out.

For repos that use git-crypt, devcontainer.json mounts an empty tmpfs over
`confidential/` and `.git/git-crypt`. Neither the plaintext nor the key is
visible inside the container, however it is started. The masks use
`notmpcopyup`: without it podman copies the host files into the tmpfs.
`.git` stays writable, so agents can commit; git shows the masked files as
deleted, and a container-only `~/.claude/CLAUDE.md` tells the agent never to
stage those deletions.

**Read-only overlays**: paths the host executes are mounted a second time,
read-only, on top of the workspace: `.git/hooks`, `.git/config` (host git and
obsidian-git run them), `.claude/` (host Claude Code project settings and
hooks), `.devcontainer/` and `justfile`. A writable copy would let an agent run
code on the host, where the plaintext lives. Comment out the `.claude` line
only if you never run Claude Code on the host in that project.

**Obsidian vaults**: create `.obsidian/` and enable the two commented lines in
devcontainer.json: a read-only overlay over `.obsidian/` (plugin code
Obsidian loads) and a mask over `.claudian/` (Claudian's transcripts, which may
hold confidential notes attached in the host UI). `just up` refuses a vault
without them.

`just dev` runs `verify-isolation` before opening a shell.

## Claudian

Claudian is an Obsidian plugin that runs Claude Code from inside a vault.
`claudian/claudian-podman.js` runs that agent inside the vault's devcontainer
instead of on the host:

1. Set up the vault as a template project (see Obsidian vaults above) and
   `just up` in it.
2. `just install-claudian` in this repo.
3. In Claudian's settings, set the Claude CLI path to
   `~/.local/bin/claudian-podman.js` (absolute) and restart Obsidian.

The wrapper finds the container by its `devcontainer.local_folder` label (the
vault path, or a parent of Claudian's working directory), starts it if it is
stopped, and `podman exec`s `claude` there with only `CLAUDE_*`/`ANTHROPIC_*`
variables forwarded, by name. Set `CLAUDIAN_WRAPPER_DEBUG=/path/to/log` in
Claudian's environment settings to log what it runs.

Context Claudian attaches in the Obsidian UI (the open note, @mentions,
selections) comes from the host and bypasses the container.

## Security model

- **podman** bounds the project: only the workspace and the read-only mounts
  are visible. `--userns=keep-id` keeps file ownership in line with the host.
- **bwrap** (the Claude Code sandbox) bounds agent commands inside the
  container and fails closed.
- **Read-only overlays** keep the agent from writing files the host executes.
- **Git**: your identity is mounted read-only, so commits work. SSH keys and
  the agent never enter the container; push from the host.
- **Claude Code config**: `just up` stages an allowlist of host `~/.claude`
  (`settings.json`, `CLAUDE.md`, agents, commands, hooks,
  plugins, rules, skills, `.git`, ...) into `~/.cache/devcontainer/claude-seed`,
  which mounts.env mounts read-only at `/claude-seed`; `post-create.sh` copies
  it into the container. The rest of `~/.claude` (`projects/`, `file-history/`,
  `backups/`, session data) holds transcripts and file snapshots of every other
  project and never enters. `~/.claude.json` stays container-local. The copy is
  disposable: inspect changes with `git diff` inside and redo the ones you
  want on the host.

## Known issues

- The devcontainer CLI is Docker-first. Podman works, but keep
  `just raw-enter` handy. `updateRemoteUserUID` is off because keep-id
  handles UIDs.
- `devcontainer up --mount` only accepts `type=bind|volume,source,target`
  (no `readonly`, no `tmpfs`), which is why mounts live in slots in
  devcontainer.json. Check that a read-only mount really is one by `touch`ing
  a file in it.
- VS Code does not run the justfile: no config staging, no `_guard`. The masks
  and overlays in devcontainer.json still apply.
- The Bash sandbox write-protects Claude Code's config paths and creates a
  placeholder for any that is missing, which fails inside the read-only
  `.claude` overlay (`Can't create file .../.claude/skills: Read-only file
  system`). post-create adds the workspace `.claude` to
  `sandbox.filesystem.denyWrite` in the container's user settings, so the
  sandbox skips those paths instead. Only when the overlay is enabled.
- bwrap inside podman needs nested unprivileged user namespaces;
  post-create reports whether it works. The fix is a custom seccomp profile;
  to test, add `--security-opt seccomp=unconfined` to `runArgs`.
- Symlinks inside a mounted directory dangle in the container. Stow config
  directories as folder links, not per file.
- Clipboard: pasting into the container works through the terminal. Copying
  out of nvim uses OSC 52; in kitty, allow it with
  `clipboard_control write-clipboard write-primary`.
