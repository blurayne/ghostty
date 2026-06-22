FROM ghcr.io/flathub-infra/flatpak-github-actions:gnome-50

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

RUN curl -fsSL https://mise.run | sh

ENV PATH="/root/.local/bin:$PATH"

WORKDIR /workspace
