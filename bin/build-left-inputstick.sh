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
# CONFIG_ZMK_LOGGING_MINIMAL=y is NOT optional here. adv360_left_debug.conf asks
# for quiet logging with CONFIG_ZMK_LOG_LEVEL_WRN=y, and that setting does
# nothing: zmk/app/Kconfig defines its own ZMK_LOG_LEVEL with `default 4` under
# `if !ZMK_LOGGING_MINIMAL`, and that definition precedes the Kconfig template's
# conditional defaults, so DEBUG wins. The result is a per-keystroke trace
# through split_central_notify_func that overflows the deferred log buffer --
# and CONFIG_LOG_MODE_OVERFLOW then DROPS our messages to make room. The
# InputStick handshake was invisible for exactly this reason.
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

# Identify the image by BOTH repos. The config repo alone names a commit that
# may contain none of the running firmware code -- that lives in zmk/.
# This goes into the BLE Device Information Service so a unit can be identified
# over Bluetooth without a serial console (!version prints the same thing).
repo_id() {
    local dir=$1 c d
    c=$(git -C "$dir" rev-parse --short=8 HEAD 2>/dev/null || echo unknown)
    d=$(git -C "$dir" status --porcelain --ignore-submodules=none 2>/dev/null | head -c1)
    [ -n "$d" ] && c="$c-dirty"
    echo "$c"
}
FW_REV="$(repo_id "$WORK/src/Adv360-Pro-ZMK") zmk:$(repo_id "$WORK/src/Adv360-Pro-ZMK/zmk")"
echo "firmware revision: $FW_REV"

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
      -DCONFIG_ZMK_LOGGING_MINIMAL=y \
      -DCONFIG_BT_DIS_FW_REV=y \
      -DCONFIG_BT_DIS_FW_REV_STR='\"$FW_REV\"' \
      -DCONFIG_ZMK_KEYBOARD_NAME='\"$KB_NAME\"'
  "
echo "name: $KB_NAME"
grep -E 'CONFIG_ZMK_KEYBOARD_NAME|CONFIG_BT_DEVICE_NAME=|CONFIG_ZMK_INPUTSTICK=|CONFIG_BT_DIS_FW_REV' \
  "$WORK/build/left-istick-$SLUG/zephyr/.config"
ls -la "$WORK/build/left-istick-$SLUG/zephyr/zmk.uf2"

# Archive immediately. Build dirs are purged storage, not an archive -- west
# build -p deletes them, and a flashed-and-verified image is worth keeping.
mkdir -p "$WORK/firmware"
OUT="$WORK/firmware/adv360-left-inputstick_${SLUG}_$(date +%Y%m%d).uf2"
cp "$WORK/build/left-istick-$SLUG/zephyr/zmk.uf2" "$OUT"
echo "archived: $OUT"
sha256sum "$OUT"
