#!/usr/bin/env bash
# uninstall.sh — remove the Goodix 27c6:5125 fingerprint setup
# SPDX-License-Identifier: MIT
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo ./uninstall.sh" >&2
  exit 1
fi
TARGET_USER="${SUDO_USER:-${PKEXEC_UID:+$(getent passwd "$PKEXEC_UID" | cut -d: -f1)}}"
TARGET_USER="${TARGET_USER:-root}"
TARGET_HOME="$(getent passwd "$TARGET_USER" | cut -d: -f6)"
REPO_DIR="${TARGET_HOME}/.local/share/goodix-5125/goodix-linux-27c6-5125"

echo "==> Removing pacman hook and maintainer"
rm -f /etc/pacman.d/hooks/goodix-fprint.hook /usr/local/bin/goodix-maintain.sh

echo "==> Removing udev autosuspend rule"
rm -f /etc/udev/rules.d/40-goodix-5125-power.rules
udevadm control --reload-rules 2>/dev/null || true

echo "==> Restoring /etc/pam.d/sudo from backup"
[[ -f /etc/pam.d/sudo.bak-goodix ]] && cp /etc/pam.d/sudo.bak-goodix /etc/pam.d/sudo \
  || sed -i '/pam_fprintd/d' /etc/pam.d/sudo

if [[ -d "$REPO_DIR" ]]; then
  echo "==> Running upstream uninstall"
  bash "$REPO_DIR/uninstall-goodixgf-en.sh" || echo "Upstream uninstall failed (see its output)"
fi

echo "==> Removing lock-screen fingerprint PAM (restores password-only)"
rm -f /etc/pam.d/omarchy-lock-fingerprint

echo "==> Removing enrolled fingerprints and driver clone"
fprintd-delete "$TARGET_USER" 2>/dev/null || true
rm -rf "${TARGET_HOME}/.local/share/goodix-5125"

echo "==> Done. glib shims in /usr/bin were left in place (remove manually if unwanted)."
