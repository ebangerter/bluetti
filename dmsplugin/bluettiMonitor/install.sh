#!/bin/bash
# Symlink the Bluetti Monitor plugin into the DMS plugin directory.
set -e

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/DankMaterialShell/plugins"

if [ ! -d "$DEST_DIR" ]; then
    echo "install.sh: $DEST_DIR does not exist — is DankMaterialShell installed?" >&2
    exit 1
fi

if ! command -v mariadb >/dev/null 2>&1; then
    echo "install.sh: warning — the 'mariadb' client is not in PATH, the widget will show no data" >&2
fi

ln -sfn "$SRC" "$DEST_DIR/bluettiMonitor"
echo "Linked $DEST_DIR/bluettiMonitor -> $SRC"

if command -v dms >/dev/null 2>&1; then
    dms ipc plugins enable bluettiMonitor || true
    echo "Now add 'bluettiMonitor' to a DankBar section in DMS Settings."
else
    echo "dms CLI not found; enable the plugin from DMS Settings -> Plugins."
fi
