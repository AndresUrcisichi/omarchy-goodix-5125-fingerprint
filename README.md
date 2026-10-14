# omarchy-goodix-5125-fingerprint

Habilita el lector de huella **Goodix `27c6:5125`** (Huawei MateBook y otros laptops) en **Omarchy / Arch Linux**, con integración completa de `sudo` y pantalla de bloqueo, y **persistencia automática** ante actualizaciones de pacman.

> `27c6:5125` **no está soportado por libfprint oficial** (1.94). Este proyecto lo hace funcionar usando el driver comunitario
> [`Rockytkg/goodix-linux-27c6-5125`](https://github.com/Rockytkg/goodix-linux-27c6-5125) (userspace C: libusb + TLS-PSK + matching SIGFM)
> y agrega la capa que falta para Omarchy: instalación reproducible, integración PAM y auto-reparación tras cada `pacman -Syu`.

> 🤖 **¿Eres un agente de IA ayudando a alguien?** Lee [`AGENTS.md`](AGENTS.md): protocolo de diagnóstico por fases, matriz de síntomas → reparación, reglas de seguridad (firmware, PSK/dual-boot, PAM) y criterio de aceptación.

---

## Qué hace

| # | Función | Detalle |
|---|---------|---------|
| 1 | **Driver libfprint** | Compila e instala el fork `libfprint-sigfm` de [goodix-fp-linux-dev](https://github.com/goodix-fp-linux-dev/libfprint) con el driver `goodixgf` (protocolo Goodix, TLS-PSK AES-128-GCM, matching SIGFM/SIFT vía OpenCV) |
| 2 | **Sudo con huella** | `pam_fprintd` como `sufficient` en `/etc/pam.d/sudo` (la contraseña sigue como respaldo; los comandos `NOPASSWD` no cambian) |
| 3 | **Desbloqueo de pantalla** | Omarchy: crea `/etc/pam.d/omarchy-lock-fingerprint` vía `omarchy-apply-lock` (soporte nativo). Otros setups: nota en `docs/how-it-works.md` |
| 4 | **Persistencia ante pacman** | Hook de pacman (`/etc/pacman.d/hooks/goodix-fprint.hook`) que tras cada upgrade de `libfprint` o `glib2` re-instala el fork, restaura los shims de glib y reinicia `fprintd` |
| 5 | **Shims glib** | glib2 ≥ 2.88 (Arch) ya no incluye `glib-mkenums`/`glib-genmarshal` aunque el `.pc` los declara; este repo los incluye y el hook los restaura si pacman los pisa |

## Hardware soportado

- Sensor: `Goodix Fingerprint Device` USB **`27c6:5125`** (chipid `0x2504`, 80×64, familia GF_ST411SEC).
- Visto funcionando en laptops **Huawei** (MateBook series). El código del driver upstream también cubre `27c6:5135` con `--pid 0x5135`.
- Comprueba tu lector: `lsusb | grep 27c6`

## Requisitos

- Arch Linux / Omarchy (probado en Omarchy, Hyprland, kernel 6.x, glib2 2.88, gcc 15)
- `fprintd` (se instala automáticamente si falta)
- Sin dual-boot con Windows **en el mismo sensor**: la primera inicialización en Linux provisiona un PSK aleatorio en el MCU del sensor y Windows dejaría de matchear hasta re-parear (ver [issues upstream](https://github.com/goodix-fp-linux-dev/goodix-fp-dump/issues/80))

## Instalación

```bash
git clone https://github.com/AndresUrcisichi/omarchy-goodix-5125-fingerprint.git
cd omarchy-goodix-5125-fingerprint
sudo ./install.sh
```

El script es **idempotente** (puedes re-ejecutarlo). Al terminar:

```bash
fprintd-enroll -f right-index-finger $USER   # registra tu dedo (3-8 toques, cambia la posición)
fprintd-verify $USER                         # verifica (debe decir "verify-match")
```

Luego bloquea la pantalla (o usa `sudo`) y toca el lector.

## Desinstalación

```bash
sudo ./uninstall.sh
```

Restaura el PAM de sudo desde el backup, remueve el hook, ejecuta el uninstall del driver upstream y borra el clon.

## Estructura

```
install.sh                  instalador idempotente (deps + driver + PAM + hook)
uninstall.sh                desinstalador limpio
scripts/goodix-maintain.sh  mantenedor invocado por el hook (re-instala fork, restaura shims, chequea ABI)
scripts/goodix-fprint.hook  hook de pacman (Trigger: libfprint, glib2)
scripts/goodix_probe.py     sondeo read-only del sensor vía pyusb (lee versión de firmware, comando 0xA8)
shims/                      glib-mkenums / glib-genmarshal (Python, de GNOME glib-2-88) para glib2 2.88 de Arch
docs/how-it-works.md        protocolo, auditoría del driver, troubleshooting
```

## Troubleshooting

```bash
# Estado del dispositivo según fprintd
fprintd-list $USER

# Log del driver (score SIGFM: "sigfm score N/20", umbral 20)
sudo mkdir -p /etc/systemd/system/fprintd.service.d
printf '[Service]\nEnvironment=GOODIX_DEBUG=1\nEnvironment=G_MESSAGES_DEBUG=all\n' \
  | sudo tee /etc/systemd/system/fprintd.service.d/goodix-debug.conf
sudo systemctl daemon-reload && sudo systemctl restart fprintd
journalctl -u fprintd -f        # tocar el lector ahora

# Actividad del mantenedor tras un upgrade
journalctl -t goodix-maintain -b
sudo cat /var/log/goodix-install.log    # solo si hubo rebuild completo

# CLI de diagnóstico del driver (el USB es exclusivo: detener fprintd primero)
sudo systemctl stop fprintd
sudo ~/.local/share/goodix-5125/goodix-linux-27c6-5125/goodix-cli --info
sudo systemctl start fprintd
```

- Si tras un upgrade grande la huella deja de matchear: `fprintd-delete $USER && fprintd-enroll -f right-index-finger $USER`.
- Si pacman actualiza `glib2` con cambio de soname, el hook detecta la ABI rota (`ldd` con `not found`) y lanza rebuild completo automáticamente.

## Créditos y licencias

- **Driver y protocolo:** [`Rockytkg/goodix-linux-27c6-5125`](https://github.com/Rockytkg/goodix-linux-27c6-5125) (GPL-2.0-or-later) — este repo **no redistribuye** su código ni el firmware (`st411sec_app.bin`, © Goodix; el clon lo descarga upstream).
- **Fork libfprint:** [`goodix-fp-linux-dev/libfprint`](https://github.com/goodix-fp-linux-dev/libfprint) (branch `libfprint-sigfm`).
- **Alternativa sin flash para firmware 12509:** [`sorguido/goodix-27c6-5125`](https://github.com/sorguido/goodix-27c6-5125).
- **Glue de este repo** (install/uninstall/hook/maintain/shims): MIT — ver [LICENSE](LICENSE).
