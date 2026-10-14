#!/usr/bin/env bash
# install.sh — Goodix 27c6:5125 fingerprint on Omarchy / Arch Linux
# Idempotent installer: deps + upstream driver + PAM (sudo) + lock screen + pacman hook.
# SPDX-License-Identifier: MIT
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UPSTREAM_URL="https://github.com/Rockytkg/goodix-linux-27c6-5125"
DATA_DIR="${HOME}/.local/share/goodix-5125"
REPO_DIR="${DATA_DIR}/goodix-linux-27c6-5125"
TAG="goodix-install"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo ./install.sh" >&2
  exit 1
fi
TARGET_USER="${SUDO_USER:-${PKEXEC_UID:+$(getent passwd "$PKEXEC_UID" | cut -d: -f1)}}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
DATA_DIR="${TARGET_HOME}/.local/share/goodix-5125"
REPO_DIR="${DATA_DIR}/goodix-linux-27c6-5125"

log() { logger -t "$TAG" "$1" 2>/dev/null || true; echo "==> $1"; }

# ---------- 0. Sanity checks ----------
command -v pacman >/dev/null || { echo "This installer targets Arch/Omarchy (pacman)." >&2; exit 1; }
if lsusb | grep -q '27c6:5125'; then
  log "Sensor 27c6:5125 detected"
else
  log "WARNING: sensor 27c6:5125 not visible in lsusb (continuing anyway)"
fi

# ---------- 1. Build dependencies ----------
log "Installing build dependencies"
pacman -S --needed --noconfirm --asdeps base-devel git meson ninja dos2unix \
  glib2 libgusb libusb pixman openssl zlib systemd-libs \
  gobject-introspection doctest opencv mbedtls fprintd >/dev/null

# ---------- 2. glib shims (Arch glib2 2.88 ships no glib-mkenums/glib-genmarshal) ----------
for f in glib-mkenums glib-genmarshal; do
  if [[ ! -e "/usr/bin/$f" ]]; then
    install -m 755 "${HERE}/shims/$f" "/usr/bin/$f"
    log "installed glib shim /usr/bin/$f"
  fi
done

# ---------- 3. Clone upstream driver (includes libfprint-sigfm submodule) ----------
if [[ ! -d "$REPO_DIR" ]]; then
  mkdir -p "$DATA_DIR"
  git clone --depth 1 --recurse-submodules "$UPSTREAM_URL" "$REPO_DIR"
  chown -R "$TARGET_USER:" "$DATA_DIR"
  log "Cloned upstream driver into $REPO_DIR"
else
  log "Upstream driver already present at $REPO_DIR"
fi

# ---------- 4. Build + install libfprint fork (driver goodixgf) ----------
log "Building and installing libfprint-sigfm with goodixgf driver (takes a few minutes)"
HOME="$TARGET_HOME" bash "$REPO_DIR/install-goodixgf-en.sh" >/var/log/goodix-install.log 2>&1 \
  || { echo "Driver install failed; see /var/log/goodix-install.log" >&2; exit 1; }
log "Driver installed (full log: /var/log/goodix-install.log)"

# ---------- 5. PAM: sudo with fingerprint (sufficient -> password still works) ----------
SUDO_PAM=/etc/pam.d/sudo
if ! grep -q pam_fprintd "$SUDO_PAM"; then
  cp "$SUDO_PAM" "$SUDO_PAM.bak-goodix"
  sed -i '1a auth\t\tsufficient\tpam_fprintd.so timeout=10 max_tries=2' "$SUDO_PAM"
  log "pam_fprintd added to $SUDO_PAM (backup: $SUDO_PAM.bak-goodix)"
else
  log "$SUDO_PAM already has pam_fprintd"
fi

# ---------- 6. Lock screen ----------
if command -v omarchy-apply-lock >/dev/null 2>&1; then
  # Omarchy native support: writes /etc/pam.d/omarchy-lock-fingerprint when a finger is enrolled,
  # and regenerates it on omarchy updates. It runs AFTER enrollment, so remind the user.
  log "Omarchy detected: run 'fprintd-enroll' first, then 'omarchy-apply-lock' to enable lock-screen unlock"
else
  log "Not Omarchy: see docs/how-it-works.md for hyprlock/swaylock PAM integration"
fi

# ---------- 7. pacman hook: survive every pacman -Syu ----------
install -m 755 "${HERE}/scripts/goodix-maintain.sh" /usr/local/bin/goodix-maintain.sh
sed -i "s|^REPO=.*|REPO=\"${REPO_DIR}\"|" /usr/local/bin/goodix-maintain.sh
install -m 644 "${HERE}/scripts/goodix-fprint.hook" /etc/pacman.d/hooks/goodix-fprint.hook
log "pacman hook installed (auto-repairs driver after libfprint/glib2 upgrades)"

systemctl try-restart fprintd 2>/dev/null || true

# ---------- Summary ----------
cat <<EOF

====================================================================
 Install complete. Next steps (as user '$TARGET_USER'):

   1. Enroll a finger:
        fprintd-enroll -f right-index-finger $TARGET_USER
   2. Verify:
        fprintd-verify $TARGET_USER          # expect: verify-match
   3. Lock screen (Omarchy):
        omarchy-apply-lock                   # writes the fingerprint PAM file
      then lock the screen and touch the reader.
====================================================================
EOF
