#!/bin/bash
# goodix-maintain.sh — invoked by the pacman hook /etc/pacman.d/hooks/goodix-fprint.hook
# Runs after every upgrade of libfprint and/or glib2:
#   1. Restores glib shims (glib-mkenums/glib-genmarshal) if pacman removed/overwrote them.
#   2. Re-installs the libfprint-sigfm fork (goodixgf driver) that pacman overwrites.
#   3. If the installed library has broken ABI (deps "not found"), performs a full rebuild.
#   4. Restarts fprintd.
# Note: after a libfprint upgrade the enrolled prints may need re-registration:
#   fprintd-delete $USER && fprintd-enroll -f right-index-finger $USER
# SPDX-License-Identifier: MIT

REPO="/home/CHANGE_ME/.local/share/goodix-5125/goodix-linux-27c6-5125"  # rewritten by install.sh
TAG="goodix-maintain"

log() { logger -t "$TAG" "$1"; echo "[goodix-maintain] $1"; }

# --- 1. glib shims ---
for f in glib-mkenums glib-genmarshal; do
    if [ ! -e "/usr/bin/$f" ]; then
        cp "$REPO/shims/$f" "/usr/bin/$f" && chmod +x "/usr/bin/$f" \
            && log "restored glib shim /usr/bin/$f"
    fi
done

# --- 2. Reinstall libfprint fork if pacman owns the installed file ---
if pacman -Qo /usr/lib/libfprint-2.so.2 >/dev/null 2>&1; then
    log "libfprint-2.so.2 is pacman-owned -> reinstalling goodixgf fork"
    if meson install -C "$REPO/libfprint/build" >/dev/null 2>&1; then
        log "meson install OK"
    else
        log "meson install failed -> full rebuild"
        bash "$REPO/install-goodixgf-en.sh" >/var/log/goodix-install.log 2>&1 \
            && log "full rebuild OK (log: /var/log/goodix-install.log)" \
            || log "full rebuild FAILED (see /var/log/goodix-install.log)"
    fi
fi

# --- 3. Verify ABI of the installed library ---
if ldd /usr/lib/libfprint-2.so.2 2>/dev/null | grep -q 'not found'; then
    log "broken ABI detected -> full rebuild"
    bash "$REPO/install-goodixgf-en.sh" >/var/log/goodix-install.log 2>&1 \
        && log "ABI rebuild OK" || log "ABI rebuild FAILED"
fi

# --- 4. Restart fprintd ---
systemctl try-restart fprintd 2>/dev/null && log "fprintd restarted"
log "done. If fprintd-verify gives no-match after an upgrade, re-enroll the finger."
exit 0
