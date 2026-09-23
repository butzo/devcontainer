# Local image builds (CI does the weekly ones — see .github/workflows/build.yml)
registry := "ghcr.io/butzo"
bust := `date +%F`

default: build

# build base, then aio
build: build-base build-aio

# build the base image (dated cache bust refreshes pacman once a day)
build-base:
    podman build --build-arg CACHE_BUST={{bust}} \
      -f Containerfile.base -t {{registry}}/arch-dev:base .

# build aio on top of the local base image
build-aio:
    podman build --build-arg BASE={{registry}}/arch-dev:base \
      -f Containerfile.aio -t {{registry}}/arch-dev:aio .

# Force-fresh rebuild (ignores layer cache entirely)
rebuild:
    podman build --no-cache -f Containerfile.base -t {{registry}}/arch-dev:base .
    podman build --no-cache --build-arg BASE={{registry}}/arch-dev:base \
      -f Containerfile.aio -t {{registry}}/arch-dev:aio .

# push the local base and aio tags to the registry
push:
    podman push {{registry}}/arch-dev:base
    podman push {{registry}}/arch-dev:aio

# pull the latest aio image
pull:
    podman pull {{registry}}/arch-dev:aio

# remove dangling images
prune:
    podman image prune -f

# install nvim plugins and treesitter parsers into the nvim-data volume,
# which containers mount read-only; rerun after changing the nvim config.
# keep-id matches the devcontainer's UID mapping; the chown fixes a volume root
# that podman created as root. nvim exits 0 even when the bootstrap clone
# fails, hence the explicit check.
refresh-nvim-data:
    podman run --rm --userns=keep-id \
      -v nvim-data:/home/dev/.local/share/nvim \
      -v ~/.config/nvim:/home/dev/.config/nvim:ro \
      {{registry}}/arch-dev:aio \
      sh -c 'sudo chown -R dev:dev ~/.local/share/nvim && \
        nvim --headless "+Lazy! restore" "+TSUpdateSync" +qa && \
        test -d ~/.local/share/nvim/lazy/lazy.nvim || \
        { echo "refresh-nvim-data: lazy.nvim missing from volume" >&2; exit 1; }'

# run the devc tests, then install devc (~/.local/bin/devc + ~/.local/share/devc)
# and the Claudian wrapper (Obsidian's "Claude CLI path"). Copies, not
# symlinks: the host runs them, so edits here (possibly by an agent in a
# devcontainer of this repo) only take effect when installed again.
install:
    devc/tests/run.sh
    install -Dm755 devc/devc ~/.local/bin/devc
    install -Dm755 -t ~/.local/share/devc devc/gen-config devc/post-create.sh
    install -Dm644 -t ~/.local/share/devc devc/devc.just devc/base.json
    install -Dm644 devc/_devc ~/.local/share/devc/_devc
    install -Dm755 claudian/claudian-podman.js ~/.local/bin/claudian-podman.js
