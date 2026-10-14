# How it works

Technical notes for `omarchy-goodix-5125-fingerprint`. Everything here was verified on real
hardware: Goodix `27c6:5125` (chipid `0x2504`, sensor 80×64, firmware `GF_ST411SEC_APP_12508`)
on Omarchy (Arch, kernel 6.x, glib2 2.88).

## 1. The device

- USB CDC-ACM composite device: iface 0 = CDC comm (INT EP `0x82`), iface 1 = CDC data
  (BULK-OUT `0x01`, BULK-IN `0x81`). No kernel driver binds to it.
- The kernel does not bind a fingerprint driver and `libfprint` 1.94 does not list `27c6:5125`,
  so `fprintd` reports `No devices available` out of the box.

## 2. Why a fork, and why this glue

`Rockytkg/goodix-linux-27c6-5125` implements the full userspace protocol stack
(init → OTP/config → TLS-PSK → image capture) plus a `goodixgf` driver inside a
`libfprint` fork (`goodix-fp-linux-dev/libfprint`, branch `libfprint-sigfm`) where
enrollment/matching uses SIGFM (OpenCV SIFT keypoints + geometric voting, score
threshold 20). The fork replaces the system `libfprint-2.so.2` (same SONAME).

What the fork alone does not give you on Omarchy:

| Problem | Solution in this repo |
|---|---|
| `pacman -Syu` upgrades `libfprint` and silently restores the stock library | pacman hook → `goodix-maintain.sh` re-runs `meson install -C libfprint/build` (2 s, no rebuild) |
| Arch `glib2` ≥ 2.88 no longer ships `glib-mkenums` / `glib-genmarshal`, but `glib-2.0.pc` still declares them → `meson setup` fails with "erroneous value" | Shims (Python, from GNOME `glib-2-88` branch) installed to `/usr/bin`; hook restores them if pacman overwrites |
| If `glib2` upgrades with a new library soname, the previously built fork breaks at load | `goodix-maintain.sh` checks `ldd` for `not found` and triggers a full rebuild via upstream `install-goodixgf-en.sh` |
| No PAM wiring for sudo | `auth sufficient pam_fprintd.so timeout=10 max_tries=2` prepended in `/etc/pam.d/sudo` (backup kept). `NOPASSWD` entries in sudoers are unaffected: sudo skips PAM entirely for them |
| Lock screen | Omarchy ships native fingerprint support: `omarchy-apply-lock` writes `/etc/pam.d/omarchy-lock-fingerprint` when an enrolled finger exists, and regenerates it on Omarchy updates. `omarchy-shell` re-checks the PAM file on every lock (`refreshFingerprintStatus`) |

## 3. Choosing a driver by firmware version (read-only probe)

Driver init in the Rockytkg project compares the MCU version against its embedded
firmware image (`GF_ST411SEC_APP_12508`) and **flashes the sensor if it differs**.
Before installing anything you can read the sensor firmware with `scripts/goodix_probe.py`
(pyusb, commands NOP + `GetEvkVersion 0xA8` only, no PSK provisioning, no flash):

```bash
sudo pip install pyusb   # or distro package
sudo python3 scripts/goodix_probe.py
```

- `GF_ST411SEC_APP_12508` → this project works with zero flash.
- `GF_ST411SEC_APP_12509` → prefer [`sorguido/goodix-27c6-5125`](https://github.com/sorguido/goodix-27c6-5125), which supports 12508/12509 with factory-preserved firmware.

## 4. Audit summary of the driver we install

Static review of `src/` (~13k lines C) of the Rockytkg project performed before install:

- No network calls, no `system()`/`popen()`, no shell execution anywhere in the C code.
- Firmware update path has a CRC pre-check and only runs when the MCU version differs
  from the embedded image; with 12508 == 12508 it is skipped entirely.
- PSK provisioning: on first init the host generates a random 32-byte PSK, writes it
  white-box-encrypted to the MCU and caches it in `/var/lib/fprint/goodix/` (root) —
  **this is what breaks Windows dual-boot matching on the same sensor**.
- TLS: `TLS-PSK-WITH-AES-128-GCM-SHA256`, built with mbedtls 4.x.

## 5. Verification performed

- `goodix-cli --info`: full init, TLS handshake, FDT baseline, config download OK.
- `fprintd-enroll` right-index-finger: completed.
- `fprintd-verify`: `verify-match`, `sigfm score 136/20` (threshold 20), observed via
  `GOODIX_DEBUG=1 G_MESSAGES_DEBUG=all` on `fprintd.service`.
- Hook smoke test: `meson install` re-run, shims untouched, `fprintd` restarted, verify still matches.

## 6. Known limitations

- The pacman hook cannot re-enroll your finger (needs a human). After a **major** libfprint
  upgrade, if verify returns no-match: `fprintd-delete $USER && fprintd-enroll -f right-index-finger $USER`.
- `goodix-cli` needs the USB device exclusively: `systemctl stop fprintd` first.
- Only Arch-family distros are automated; the upstream project also documents Debian/Fedora.
