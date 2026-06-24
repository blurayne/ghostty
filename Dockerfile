FROM ghcr.io/flathub-infra/flatpak-github-actions:gnome-50

# syntax=docker/dockerfile:1.4 cache mounts require BuildKit
# Add messagebus user/group required by dbus-daemon --system.
# This image (Freedesktop SDK) has no useradd/groupadd; edit files directly.
# dbus binary prefix is /app, so socket lives at /app/var/run/dbus/ and
# machine-id is read via /app/var/lib/dbus/machine-id -> /etc/machine-id.
RUN echo "messagebus:x:81:" >> /etc/group && \
    echo "messagebus:x:81:81::/:/bin/false" >> /etc/passwd && \
    dbus-uuidgen > /etc/machine-id && \
    mkdir -p /app/var/lib/dbus && \
    ln -sf /etc/machine-id /app/var/lib/dbus/machine-id && \
    mkdir -p /app/var/run/dbus /run/dbus

RUN --mount=type=cache,target=/root/.cache/mise-dl \
    curl -fsSL https://mise.run | sh

# Install zig 0.15.2 — same version used by flatpak-builder (dependencies.yml).
# Baked into the image so zig-build / zig-test tasks don't need to download it.
# zig expects its lib/ directory alongside the binary, so extract the whole
# tarball into /usr/local/zig and add that to PATH.
RUN --mount=type=cache,target=/root/.cache/zig-dl \
    mkdir -p /usr/local/zig /root/.cache/zig-dl && \
    ZIG_TXZ=/root/.cache/zig-dl/zig-x86_64-linux-0.15.2.tar.xz && \
    if [ ! -f "$ZIG_TXZ" ]; then \
      curl -fsSL https://ziglang.org/download/0.15.2/zig-x86_64-linux-0.15.2.tar.xz \
        -o "$ZIG_TXZ"; \
    fi && \
    tar -xJ --strip-components=1 -C /usr/local/zig < "$ZIG_TXZ"

ENV PATH="/usr/local/zig:/root/.local/bin:$PATH"

WORKDIR /workspace
