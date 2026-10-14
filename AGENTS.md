# AGENTS.md — Protocol for AI agents repairing fingerprint installs

This file is for coding agents (Claude Code, Codex, Cursor, pi, etc.) helping a human
whose Goodix `27c6:5125` fingerprint reader is broken on Omarchy / Arch Linux, whether
this repo installed it or not. Follow the phases in order. Gather evidence with
read-only commands first; every mutating action has a guard rule.

Write responses in the user's language. Quote real command output as evidence; label
guesses as hypotheses.

## Ground rules (never violate)

1. **Never flash the sensor firmware without reading its current version first**
   (`scripts/goodix_probe.py`, Phase 1). The Rockytkg driver flashes when the MCU
   version differs from its embedded `GF_ST411SEC_APP_12508`. A user on `12509` who
   wants factory firmware must use `sorguido/goodix-27c6-5125` instead.
2. **Never provision the PSK silently if the user dual-boots Windows on the same
   sensor.** First Linux init writes a random PSK into the MCU and Windows stops
   matching until re-pairing. Ask explicitly and let the user decide (ref:
   goodix-fp-dump issue #80).
3. **Backup any PAM file before editing** (`cp /etc/pam.d/X /etc/pam.d/X.bak-<reason>`).
   A broken `/etc/pam.d/sudo` can lock a user out of root access.
4. **Never leave the system without a working auth fallback**: `pam_fprintd` must be
   `sufficient` (never `required`) in `/etc/pam.d/sudo`, so password always remains.
5. **The USB device is exclusive.** `goodix-cli` needs `systemctl stop fprintd` first;
   restart fprintd afterwards. Never run `goodix-cli` and fprintd operations at once.
6. Root commands without a TTY fail with `sudo: a terminal is required`. In desktop
   agent sessions use `pkexec` with the graphical environment exported, or ask the
   user to run the command in their own terminal.

## Phase 1 — Evidence gathering (read-only, always do all of it)

Run these and record outputs before changing anything:

```bash
# A. Is the sensor visible? Expected: "27c6:5125 Shenzhen Goodix ... Fingerprint"
lsusb | grep -i '27c6'

# B. Which firmware does the sensor run? (needs root; pure read-only)
sudo python3 scripts/goodix_probe.py        # or pip install pyusb first

# C. Does fprintd see it? Expected: "found 1 devices"
fprintd-list "$USER"

# D. Is the installed libfprint the fork?
pacman -Q libfprint                          # which version pacman knows about
ldd /usr/lib/libfprint-2.so.2 | grep 'not found'   # broken ABI = empty output is good
strings /usr/lib/libfprint-2.so.2 | grep -m1 goodixgf || echo "STOCK libfprint (no goodixgf)"

# E. Driver state files
ls -la /var/lib/fprint/goodix/ 2>/dev/null   # goodix.dat must exist after first init

# F. Recent errors
journalctl -u fprintd -b --no-pager | tail -50
journalctl -t goodix-maintain -b --no-pager | tail -20
```

## Phase 2 — Diagnosis matrix

Map evidence to a case, then jump to the repair. Do not improvise around the matrix.

| Symptom (evidence) | Diagnosis | Repair |
|---|---|---|
| A empty: sensor not in lsusb | Hardware/BIOS level | Not a Linux driver issue. User: check BIOS security/USB, other OS. Stop here. |
| A ok, B fails/timeout with no driver installed | Device in bad USB state | `usbreset` or reboot; if persists, suspect cable/hub. Stop here. |
| B says `12509` and user wants factory firmware | Wrong driver family | Use sorguido/goodix-27c6-5125; do NOT run Rockytkg init. Stop here. |
| C: `No devices available` + D: `STOCK libfprint` | Fork never installed or wiped by pacman upgrade | Re-run `sudo ./install.sh` (idempotent), then Phase 4 test |
| C ok but D: `libfprint-2.so.2 not owned` or ldd shows `not found` | ABI broken after glib2 soname change | `sudo /usr/local/bin/goodix-maintain.sh` (full rebuild path), restart fprintd |
| C ok, D ok, enroll works, `fprintd-verify` → `verify-no-match` | Templates vs driver mismatch (post-upgrade) or low-quality enroll | Debug scores (Phase 3); if scores < 20 consistently: `fprintd-delete $USER` + re-enroll |
| C ok but lock screen has no fingerprint option (Omarchy) | `/etc/pam.d/omarchy-lock-fingerprint` missing | Run `omarchy-apply-lock`; check `omarchy-shell lock status` shows `"fingerprint":true` after next lock |
| sudo prompts password, no finger prompt | PAM line missing or after `pam_unix` | Check Phase 1 E-adjacent: `grep pam_fprintd /etc/pam.d/sudo`; fix order (must be first auth line) |
| pacman hook didn't fire after upgrade | Hook/maintainer missing | Verify `/etc/pacman.d/hooks/goodix-fprint.hook` + `/usr/local/bin/goodix-maintain.sh` exist and REPO path is right |
| `meson setup` fails: `glib_mkenums ... erroneous value` | glib shims missing (glib2 ≥ 2.88 Arch) | Install `shims/glib-mkenums` + `shims/glib-genmarshal` to `/usr/bin` (from this repo), rerun install |
| Every verify returns `sigfm score 0/20` immediately | Air capture, finger not detected | User technique: press firmly 1-2 s; check journal for `finger down` events; if none, FDT calibration — re-run `goodix-cli --info` after stopping fprintd |

## Phase 3 — Debug scoring (when matches fail)

```bash
sudo mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=GOODIX_DEBUG=1\nEnvironment=G_MESSAGES_DEBUG=all\n' \
  | sudo tee /etc/systemd/system/fprintd.service.d/goodix-debug.conf
sudo systemctl daemon-reload && sudo systemctl restart fprintd
```

Then have the user touch the reader while running `fprintd-verify $USER`, and read:

```bash
journalctl -u fprintd --since '-2 min' --no-pager | grep -E 'sigfm|finger|capture'
```

Interpretation:
- `sigfm score >= 20` → match. If result still no-match, report upstream bug with logs.
- `sigfm score 0/20` right after a real `finger down` + captured frame → enroll/template
  mismatch → re-enroll.
- No `sigfm` line at all with `G_MESSAGES_DEBUG=all` active → matching stage never ran;
  capture failed. Look for `no image frame received`.
- Remove the drop-in when done (`rm` + daemon-reload + restart) — it is verbose.

## Phase 4 — Verification after any repair (acceptance test)

A repair is done only when ALL of these pass:

1. `fprintd-list "$USER"` lists the enrolled finger.
2. `fprintd-verify "$USER"` prints `verify-match` (user touches the reader).
3. `grep pam_fprintd /etc/pam.d/sudo` returns the `sufficient` line (first auth line).
4. User confirms: `sudo -k && sudo echo ok` in their own terminal → finger prompt → `ok`.
5. (Omarchy) `omarchy-shell lock status` → after locking once, `"fingerprint":true`.

Report to the user: what failed, what you changed (files + backups), what passed.

## Notes on this repo's layout

- `install.sh` is idempotent and safe to re-run as root; it does NOT touch enrolled prints.
- Upstream driver lives at `~/.local/share/goodix-5125/goodix-linux-27c6-5125/`
  (installed by this repo). If the user installed the driver manually, locate it via
  `find / -maxdepth 6 -name 'goodixgf.c' 2>/dev/null` inside libfprint trees, or ask.
- The pacman hook calls `/usr/local/bin/goodix-maintain.sh` with `REPO=` rewritten at
  install time. If the user moved the clone, fix `REPO=` there.
- Upstream docs: `docs/protocol.md`, `docs/audit.md` and `docs/libfprint-integration.md`
  inside the Rockytkg clone — read them before deep protocol work.
