#!/usr/bin/env bash
# Flash Adv360 Pro halves with the newest firmware in firmware/.
#
# Usage: bin/flash.sh [left|right|both]   (default: both, left first)
#
# For each half, put it in bootloader mode when prompted:
#   hold Mod (top inner right-thumb key) + tap that half's inner-column
#   key on the Tab row (&bootloader on the Mod layer).
# The half mounts as a FAT drive labeled ADV360PRO; we copy the matching
# .uf2 and the board flashes and reboots itself.
set -euo pipefail
cd "$(dirname "$0")/.."

case "${1:-both}" in
  left)  SIDES="left" ;;
  right) SIDES="right" ;;
  both)  SIDES="left right" ;;
  *) echo "usage: $0 [left|right|both]" >&2; exit 1 ;;
esac

newest_uf2() { ls -t firmware/*-"$1"-*.uf2 2>/dev/null | head -1; }

wait_for_bootloader() { # echoes mountpoint of ADV360PRO, or fails after 180s
  local dev mp deadline=$((SECONDS + 180))
  while (( SECONDS < deadline )); do
    dev=$(lsblk -rno NAME,LABEL | awk '$2 == "ADV360PRO" {print "/dev/" $1; exit}')
    if [[ -n "${dev:-}" ]]; then
      mp=$(lsblk -rno MOUNTPOINT "$dev" | head -1)
      if [[ -z "$mp" ]]; then
        udisksctl mount -b "$dev" >/dev/null 2>&1 || true
        mp=$(lsblk -rno MOUNTPOINT "$dev" | head -1)
      fi
      [[ -n "$mp" ]] && { echo "$mp"; return 0; }
    fi
    sleep 1
  done
  return 1
}

for side in $SIDES; do
  uf2=$(newest_uf2 "$side")
  [[ -n "$uf2" ]] || { echo "no $side .uf2 in firmware/ — run make first" >&2; exit 1; }
  echo
  echo ">>> $side half: $(basename "$uf2")"
  echo "    Enter bootloader: hold Mod + tap the $side half's Tab-row inner-column key."
  echo "    Waiting up to 180s for the ADV360PRO drive..."
  mp=$(wait_for_bootloader) || { echo "    timed out waiting for bootloader" >&2; exit 1; }
  echo "    Mounted at $mp — copying..."
  # The board reboots as soon as the last UF2 block lands, which can make
  # cp/sync report EIO on a vanished device — that is success, not failure.
  cp "$uf2" "$mp/" 2>/dev/null || true
  sync 2>/dev/null || true
  while lsblk -rno LABEL | grep -q '^ADV360PRO$'; do sleep 1; done
  echo "    $side half flashed and rebooting."
done

echo
echo "Done. Verify: hold Mod + tap V into a text field — macro_ver types the build stamp."
