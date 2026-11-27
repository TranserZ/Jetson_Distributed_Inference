#!/usr/bin/env bash
# Flash Board B as PCIe ENDPOINT (C5) — run on the x86 Ubuntu FLASH HOST, not on Jetson.
#
#   sudo setup/flash/flash_ep.sh /path/to/Linux_for_Tegra
#
# Prereqs: JetPack 6.2.3 / L4T R36.5.x BSP + sample rootfs extracted and
# `sudo ./apply_binaries.sh` done in Linux_for_Tegra (SDK Manager does this),
# Board B in Force-Recovery mode and connected over USB-C.
#
# Per NVIDIA Jetson Linux r36.5 "PCIe Endpoint Mode":
#   ODMDATA override sets nvhs-uphy-config-1 -> C5 becomes endpoint.
#   10GbE (gbe0-enable-10g) stays enabled.
# WARNING: erases Board B.
set -euo pipefail
L4T="${1:?usage: sudo $0 /path/to/Linux_for_Tegra}"
CONF="$L4T/jetson-agx-orin-devkit.conf"
ODM='ODMDATA="gbe-uphy-config-22,nvhs-uphy-config-1,hsio-uphy-config-0,gbe0-enable-10g,hsstp-lane-map-3";'

[[ $EUID -eq 0 ]] || { echo "run with sudo"; exit 1; }
[[ -f $CONF ]] || { echo "not found: $CONF"; exit 1; }
lsusb | grep -qi "0955:" || { echo "No Jetson in recovery mode on USB (lsusb | grep 0955)"; exit 1; }

cp "$CONF" "$CONF.jdi.bak"
restore() { mv -f "$CONF.jdi.bak" "$CONF"; echo "restored $CONF (future flashes = normal RP mode)"; }
trap restore EXIT
echo "$ODM" >> "$CONF"
echo ">>> flashing EP image (this erases Board B)"
cd "$L4T"
./flash.sh jetson-agx-orin-devkit mmcblk0p1
echo ">>> done. On Board B after first boot: ls /sys/kernel/config/pci_ep/controllers/  (expect 141a0000.pcie-ep)"
