#!/bin/bash
# Build the left-half firmware: Dec-19 production engine + Game layer + ZMK Studio (BLE RPC).
#
# This reproduces the firmware flashed 2026-08-07 (post-recovery). It builds the
# vendored zmk tree (in-tree HOGP central) with the SAME toolchain family as the
# original December builds (zmkfirmware/zmk-build-arm:stable, zephyr-sdk-0.16.9)
# and the production conf overlay (adv360_left_debug.conf — the name is a fossil;
# by Dec 19 it WAS the production tuning: HOGP 2 slots, iTrack output, USB retries,
# quiet WRN logging).
#
# Layer-order rule (hard-won): with CONFIG_ZMK_STUDIO, source-defined layers must
# precede the status="reserved" slots, and &tog indices count only non-reserved
# layers. Game therefore sits before extra1 and toggles as &tog 4.
#
# Run from the workspace root (the directory containing src/ and build/):
#   bash src/Adv360-Pro-ZMK/bin/build-left-game.sh
#   KB_NAME="Adv360 Alpha" bash src/Adv360-Pro-ZMK/bin/build-left-game.sh
#
# KB_NAME sets the Bluetooth keyboard name (CONFIG_ZMK_KEYBOARD_NAME) so a
# fleet of Adv360s shows up distinctly in pairing lists. Keep it <= 16 chars
# (longer is truncated in BLE advertisements). Renaming does NOT break
# existing bonds — identity is the BT address, not the name; hosts show the
# new name on next pairing/refresh. Each name builds into its own output
# dir so fleet images can coexist.
#
# Output: build/left-game-<slug>/zephyr/zmk.uf2  (default slug: local)

set -euo pipefail
WORK=$(pwd)
[ -d "$WORK/src/Adv360-Pro-ZMK" ] || { echo "run from the workspace root"; exit 1; }

KB_NAME="${KB_NAME:-Adv360 Pro}"
[ ${#KB_NAME} -le 16 ] || { echo "KB_NAME '$KB_NAME' is ${#KB_NAME} chars; BLE adv truncates past 16"; exit 1; }
if [ "$KB_NAME" = "Adv360 Pro" ]; then SLUG=local; else SLUG=$(echo "$KB_NAME" | tr 'A-Z ' 'a-z-' | tr -cd 'a-z0-9-'); fi

podman run --rm --network=host --security-opt label=disable \
  -v "$WORK:/work" -w /work/src/Adv360-Pro-ZMK \
  --entrypoint bash docker.io/zmkfirmware/zmk-build-arm:stable -c "
    west zephyr-export >/dev/null 2>&1
    west build -p -d /work/build/left-game-$SLUG -b adv360_left -s zmk/app -- \
      -DZMK_CONFIG=/work/src/Adv360-Pro-ZMK/config \
      -DEXTRA_CONF_FILE=/work/src/Adv360-Pro-ZMK/config/boards/arm/adv360/adv360_left_debug.conf \
      -DCONFIG_ZMK_STUDIO=y \
      -DCONFIG_ZMK_STUDIO_TRANSPORT_UART=n \
      -DCONFIG_ZMK_KEYBOARD_NAME='\"$KB_NAME\"'
  "
echo "name: $KB_NAME"
grep -E 'CONFIG_ZMK_KEYBOARD_NAME|CONFIG_BT_DEVICE_NAME=' "$WORK/build/left-game-$SLUG/zephyr/.config"
ls -la "$WORK/build/left-game-$SLUG/zephyr/zmk.uf2"
