#!/usr/bin/env python3
"""goodix_probe.py — read-only probe for the Goodix 27c6:5125 fingerprint sensor.

Implements the minimal framing of the Goodix CDC protocol (as documented in the
Rockytkg/goodix-linux-27c6-5125 repo) just to run NOP + GetEvkVersion (0xA8).
It never provisions the PSK, never flashes firmware and never changes device
state beyond SET_CONTROL_LINE_STATE (DTR), which is required to activate the
CDC data endpoints.

Use it to find out the sensor firmware version BEFORE installing a driver:
drivers embed a specific firmware image (e.g. GF_ST411SEC_APP_12508); if your
sensor runs a different version, a driver whose init performs firmware updates
would flash it. This probe lets you pick the right project without touching
the device.

Requires: pip install pyusb (and root, or a udev rule granting access).
SPDX-License-Identifier: MIT
"""
import sys
import usb.core
import usb.util

VID, PID = 0x27C6, 0x5125
EP_OUT, EP_IN = 0x01, 0x81
IFACE_DATA = 1
IFACE_COMM = 0

def hdr_cks(a, b, c):
    return (a + b + c) & 0xFF

def data_cks(cmd, data):
    s = ((cmd & 0xFE) + (len(data) + 1) + ((len(data) + 1) >> 8)) & 0xFF
    for b in data:
        s = (s + b) & 0xFF
    return (0xAA - s) & 0xFF

def build_cmd(cmd, data):
    paylen = len(data) + 4
    frame = bytearray()
    frame += bytes([0xA0, paylen & 0xFF, paylen >> 8,
                    hdr_cks(0xA0, paylen & 0xFF, paylen >> 8)])
    frame.append(cmd)
    frame += bytes([(len(data) + 1) & 0xFF, ((len(data) + 1) >> 8) & 0xFF])
    frame += data
    frame.append(data_cks(cmd, data))
    return frame

def send(dev, frame):
    pad = frame + b"\x00" * (-len(frame) % 64)
    dev.write(EP_OUT, pad, 1000)

def read_frame(dev, tmo_ms=2000):
    buf = b""
    deadline = tmo_ms
    while deadline > 0 and len(buf) < 4:
        try:
            buf += bytes(dev.read(EP_IN, 64, 100))
        except usb.core.USBError:
            deadline -= 100
    if len(buf) < 4 or (buf[0] >> 4) not in (0xA, 0xB, 0xC):
        return None
    if buf[3] != hdr_cks(buf[0], buf[1], buf[2]):
        return None
    total = (buf[1] | (buf[2] << 8)) + 4
    while len(buf) < total:
        try:
            buf += bytes(dev.read(EP_IN, 64, 100))
        except usb.core.USBError:
            break
    return buf[:total]

def main():
    dev = usb.core.find(idVendor=VID, idProduct=PID)
    if dev is None:
        print("ERROR: device 27c6:5125 not found")
        return 1
    print(f"Device: {dev.idVendor:04x}:{dev.idProduct:04x} bus {dev.bus} dev {dev.address}")
    if dev.is_kernel_driver_active(IFACE_DATA):
        print("NOTE: kernel driver active on iface 1, detaching")
        dev.detach_kernel_driver(IFACE_DATA)
    dev.set_configuration()
    dev.ctrl_transfer(0x21, 0x22, 0x03, IFACE_COMM, b"", 1000)  # DTR=1 (CDC activate)

    send(dev, bytes([0xA0, 0x08, 0x00, 0xA8, 0x01, 0x05, 0, 0, 0, 0, 0, 0x88]))  # NOP
    read_frame(dev, 1000)

    send(dev, build_cmd(0xA8, bytes([0, 0])))  # GetEvkVersion
    for _ in range(10):
        f = read_frame(dev, 1500)
        if f is None:
            break
        cb = f[4]
        if (cb >> 4) in (0xB, 0xC):
            continue
        if cb == 0xA8:
            dlen = f[5] | (f[6] << 8)
            data = f[7:7 + max(0, dlen - 1)]
            ver = data[0:33].split(b"\x00")[0].decode("ascii", "replace").strip()
            if not ver.startswith("GF"):
                ver = "G" + ver  # first byte may be consumed by the status offset
            print(f"FIRMWARE: {ver}")
            if "12508" in ver:
                print("=> matches Rockytkg/goodix-linux-27c6-5125 embedded firmware; no flash needed")
            elif "12509" in ver:
                print("=> firmware 12509: prefer sorguido/goodix-27c6-5125 (no-flash path)")
            return 0
    print("FIRMWARE: not obtained (timeout)")
    return 2

if __name__ == "__main__":
    sys.exit(main())
