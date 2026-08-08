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
# Output: build/left-game-local/zephyr/zmk.uf2

set -euo pipefail
WORK=$(pwd)
[ -d "$WORK/src/Adv360-Pro-ZMK" ] || { echo "run from the workspace root"; exit 1; }

podman run --rm --network=host --security-opt label=disable \
  -v "$WORK:/work" -w /work/src/Adv360-Pro-ZMK \
  --entrypoint bash docker.io/zmkfirmware/zmk-build-arm:stable -c "
    west zephyr-export >/dev/null 2>&1
    west build -p -d /work/build/left-game-local -b adv360_left -s zmk/app -- \
      -DZMK_CONFIG=/work/src/Adv360-Pro-ZMK/config \
      -DEXTRA_CONF_FILE=/work/src/Adv360-Pro-ZMK/config/boards/arm/adv360/adv360_left_debug.conf \
      -DCONFIG_ZMK_STUDIO=y \
      -DCONFIG_ZMK_STUDIO_TRANSPORT_UART=n
  "
ls -la "$WORK/build/left-game-local/zephyr/zmk.uf2"
