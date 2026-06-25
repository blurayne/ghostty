---
date: 2026-06-22T06:49:27+00:00
git_commit: 4749c4e93731067049bfbf2e4572061cef2bdd17
branch: main
topic: "Docker dev container + Flatpak build via mise"
tags: [plan, docker, flatpak, mise, build]
status: draft
---

# Docker Dev Container + Flatpak Build Implementation Plan

## Overview

Wrap all development and build operations in a Docker dev container (Ubuntu 24.04). Produce a Ghostty Flatpak bundle via `flatpak-builder` (using the existing `flatpak/com.mitchellh.ghostty.yml`), copy the artifact to `dist/build/`, and wire everything through `mise.toml` as the unified task runner for both host and container.

## Current State Analysis

- `flatpak/com.mitchellh.ghostty.yml` exists — uses GNOME runtime 50 (GTK 4.20), embeds zig 0.15.2 via `flatpak/dependencies.yml`, zig deps via `flatpak/zig-packages.json`
- `dist/` contains source distribution assets (`cmake/`, `doxygen/`, `linux/`) — not build artifacts
- No `Dockerfile`, `docker-compose.yml`, or `mise.toml` exist yet
- `AGENTS.md` (symlinked to `CLAUDE.md`) has no mention of containers

## Desired End State

- `mise run build` (on host) → starts container → produces `dist/build/com.mitchellh.ghostty.flatpak`
- `mise run install` → installs the built Flatpak locally (host)
- `mise run shell` → interactive shell inside dev container
- All agent/dev instructions mandate container usage
- `dist/build/` is gitignored

## What We're NOT Doing

- Building for macOS, Windows, or snap
- Cross-compiling for arm64 (single x86_64 target for now)
- Setting up CI/CD pipelines
- Building non-Flatpak binaries (no raw GTK binary output)
- Publishing to Flathub

## Architecture and Code Reuse

```
repo root/
├── Dockerfile               # new — Ubuntu 24.04 + flatpak-builder + mise
├── docker-compose.yml       # new — builder service, volumes
├── mise.toml                # new — task definitions (host + container)
├── .gitignore               # update — add dist/build/
├── AGENTS.md                # update — container mandate + task runner docs
└── dist/
    └── build/               # new (gitignored) — flatpak artifact lands here
        └── com.mitchellh.ghostty.flatpak
```

Build flow:
```
host: mise run build
  └─> docker compose run --rm builder mise run _flatpak-build
        └─> flatpak-builder --disable-sandbox builddir flatpak/com.mitchellh.ghostty.yml
              └─> output: dist/build/com.mitchellh.ghostty.flatpak
```

## Performance Considerations

- `flatpak-cache` named volume caches GNOME runtime (≈1GB) — avoids re-download on every build
- `flatpak-builder` caches intermediate build state in `.flatpak-builder/` — mount as volume too
- First build: ~10-20 min (GNOME runtime + zig dep downloads). Subsequent: ~2-5 min.

## Migration Notes

None — no existing build infrastructure to migrate.

---

## Phase 1: Dockerfile + docker-compose

Short summary: create the container image definition and compose service.

**Tasks**:
- [ ] Create `Dockerfile` based on `ubuntu:24.04`:
  ```dockerfile
  FROM ubuntu:24.04
  ENV DEBIAN_FRONTEND=noninteractive
  RUN apt-get update && apt-get install -y \
      flatpak flatpak-builder git curl ca-certificates \
      && rm -rf /var/lib/apt/lists/*
  # Install mise via verified installer
  RUN curl -fsSL https://mise.run | sh
  ENV PATH="/root/.local/bin:$PATH"
  # Add Flathub remote system-wide (runs as root in container)
  RUN flatpak remote-add --system --if-not-exists flathub \
      https://dl.flathub.org/repo/flathub.flatpakrepo
  WORKDIR /workspace
  ```
- [ ] Create `docker-compose.yml`:
  ```yaml
  services:
    builder:
      build: .
      image: ghostty-flatpak-builder
      volumes:
        - .:/workspace
        - flatpak-cache:/root/.local/share/flatpak
        - flatpak-builder-cache:/workspace/flatpak/.flatpak-builder
      working_dir: /workspace
  volumes:
    flatpak-cache:
    flatpak-builder-cache:
  ```

**Automated Verification**:
- [ ] `docker compose build` exits 0
- [ ] `docker compose run --rm builder flatpak --version` prints a version

---

## Phase 2: mise.toml task definitions

Short summary: define all tasks; host tasks delegate to container, container tasks run tools directly.

**Tasks**:
- [ ] Create `mise.toml` with these tasks:

  ```toml
  [tools]
  # No tools section needed — container handles toolchain

  [tasks.build]
  description = "Build Ghostty Flatpak inside dev container"
  run = "docker compose run --rm builder mise run _flatpak-build"

  [tasks.install]
  description = "Install the built Flatpak locally on host"
  run = """
  set -e
  if [ ! -f dist/build/com.mitchellh.ghostty.flatpak ]; then
    echo "No flatpak found. Run: mise run build"
    exit 1
  fi
  flatpak install --user --bundle --reinstall -y dist/build/com.mitchellh.ghostty.flatpak
  """

  [tasks.shell]
  description = "Open interactive shell in dev container"
  run = "docker compose run --rm builder bash"

  [tasks.clean]
  description = "Remove build artifacts and container caches"
  run = """
  rm -rf dist/build flatpak/builddir flatpak/repo flatpak/.flatpak-builder
  docker compose down -v
  """

  [tasks._flatpak-build]
  description = "Build flatpak bundle (run inside container)"
  run = """
  set -e
  # flatpak install --system talks to the system helper via D-Bus.
  # dbus package is a hard dep of flatpak so it's installed, but not started.
  mkdir -p /run/dbus
  dbus-daemon --system --fork

  # Install GNOME runtime if not already present
  if ! flatpak list --system --runtime | grep -q "org.gnome.Platform.*50"; then
    flatpak install --system -y flathub \
      org.gnome.Platform//50 org.gnome.Sdk//50
  fi

  # Build (no --force-clean to preserve cache between runs)
  flatpak-builder \
    --disable-sandbox \
    --repo=flatpak/repo \
    flatpak/builddir \
    flatpak/com.mitchellh.ghostty.yml

  # Export bundle
  mkdir -p dist/build
  flatpak build-bundle \
    flatpak/repo \
    dist/build/com.mitchellh.ghostty.flatpak \
    com.mitchellh.ghostty
  """
  ```

**Automated Verification**:
- [ ] `mise tasks` lists `build`, `install`, `shell`, `clean`
- [ ] `docker compose run --rm builder mise tasks` lists `_flatpak-build`

---

## Phase 3: AGENTS.md update + .gitignore

Short summary: mandate container usage in agent instructions; ignore build artifacts.

**Tasks**:
- [ ] Add to `AGENTS.md` (before the Commands section):

  ```markdown
  ## Dev Container

  All development, file operations, and builds MUST run inside the dev container.
  Use `mise` as the task runner on both host and inside the container.

  - **Start build**: `mise run build`
  - **Install locally**: `mise run install`
  - **Interactive shell**: `mise run shell`
  - **Clean**: `mise run clean`

  Never run `zig build` or `flatpak-builder` directly on the host.
  Build artifacts land in `dist/build/` after a successful build.
  ```

- [ ] Add to `.gitignore`:
  ```
  dist/build/
  flatpak/builddir/
  flatpak/repo/
  flatpak/.flatpak-builder/
  ```

**Automated Verification**:
- [ ] `.gitignore` contains `dist/build/`
- [ ] `AGENTS.md` contains "Dev Container" section

**Manual Verification**:
- [ ] Full end-to-end build succeeds:
  1. `mise run build`
  2. Verify `dist/build/com.mitchellh.ghostty.flatpak` exists
  3. `mise run install`
  4. Launch Ghostty via `flatpak run com.mitchellh.ghostty`
  5. App opens on Ubuntu 22 host

---

## References

- Existing flatpak manifest: `flatpak/com.mitchellh.ghostty.yml`
- Flatpak dep sources: `flatpak/dependencies.yml`, `flatpak/zig-packages.json`
- Reference flatpak build: https://github.com/yorickpeterse/ghostty-flatpak
- Current snap build (for pattern reference): `snap/snapcraft.yaml`
