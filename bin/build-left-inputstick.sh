#!/bin/bash
# Build the left-half firmware WITH the InputStick client: the Dec-19 production
# engine + Game layer + ZMK Studio, plus CONFIG_ZMK_INPUTSTICK.
#
# Same engine and toolchain as bin/build-left-game.sh (see that script for the
# layer-order rule and why adv360_left_debug.conf is the production config).
# The only addition is the InputStick BLE client, which lets the keyboard drive
# an InputStick USB HID dongle as a BLE central -- typing into a host it has
# never paired with. Serial commands: !istick !istop !istatus !itype
#
# Run from the workspace root (the directory containing src/ and build/):
#   bash src/Adv360-Pro-ZMK/bin/build-left-inputstick.sh
#   KB_NAME=iistick bash src/Adv360-Pro-ZMK/bin/build-left-inputstick.sh
#
# KB_NAME sets CONFIG_ZMK_KEYBOARD_NAME, which drives BOTH the Bluetooth name
# and the USB product string. It does NOT change the UF2 bootloader's drive
# label -- that lives in the bootloader and is ADV360PRO on every unit.
#
# IMPORTANT: flashing this onto a keyboard that has never run our firmware
# requires a settings reset FIRST, or it will fault in settings_load() before
# USB comes up and look exactly like dead hardware:
#   1. double-tap reset, copy ARCHIVE/settings-reset.uf2 to the ADV360PRO drive
#      (it wipes settings and returns to the bootloader on its own)
#   2. copy this build's uf2 to the drive
#
# Output: build/left-istick-<slug>/zephyr/zmk.uf2  (default slug: iistick)

set -euo pipefail
WORK=$(pwd)
[ -d "$WORK/src/Adv360-Pro-ZMK" ] || { echo "run from the workspace root"; exit 1; }

KB_NAME="${KB_NAME:-iistick}"
[ ${#KB_NAME} -le 16 ] || { echo "KB_NAME '$KB_NAME' is ${#KB_NAME} chars; BLE adv truncates past 16"; exit 1; }
SLUG=$(echo "$KB_NAME" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-')

podman run --rm --network=host --security-opt label=disable \
  -v "$WORK:/work" -w /work/src/Adv360-Pro-ZMK \
  --entrypoint bash docker.io/zmkfirmware/zmk-build-arm:stable -c "
    west zephyr-export >/dev/null 2>&1
    west build -p -d /work/build/left-istick-$SLUG -b adv360_left -s zmk/app -- \
      -DZMK_CONFIG=/work/src/Adv360-Pro-ZMK/config \
      -DEXTRA_CONF_FILE=/work/src/Adv360-Pro-ZMK/config/boards/arm/adv360/adv360_left_debug.conf \
      -DCONFIG_ZMK_STUDIO=y \
      -DCONFIG_ZMK_STUDIO_TRANSPORT_UART=n \
      -DCONFIG_ZMK_INPUTSTICK=y \
      -DCONFIG_ZMK_INPUTSTICK_LOG_LEVEL_INF=y \
      -DCONFIG_ZMK_KEYBOARD_NAME='\"$KB_NAME\"'
  "
echo "name: $KB_NAME"
grep -E 'CONFIG_ZMK_KEYBOARD_NAME|CONFIG_BT_DEVICE_NAME=|CONFIG_ZMK_INPUTSTICK=' \
  "$WORK/build/left-istick-$SLUG/zephyr/.config"
ls -la "$WORK/build/left-istick-$SLUG/zephyr/zmk.uf2"

# Archive immediately. Build dirs are purged storage, not an archive -- west
# build -p deletes them, and a flashed-and-verified image is worth keeping.
mkdir -p "$WORK/firmware"
OUT="$WORK/firmware/adv360-left-inputstick_${SLUG}_$(date +%Y%m%d).uf2"
cp "$WORK/build/left-istick-$SLUG/zephyr/zmk.uf2" "$OUT"
echo "archived: $OUT"
sha256sum "$OUT"
