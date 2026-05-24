#!/bin/sh
#
# root-bluestacks.sh
# One-shot rooting of a BlueStacks Android emulator from Termux.
#
# What it does:
#   1. Installs android-tools (adb) if missing.
#   2. Connects via adb to the local BlueStacks instance.
#   3. Uses the pre-installed /system/xbin/bstk/su to elevate.
#   4. Remounts /system rw, copies bstk/su -> /system/bin/su, sets setuid,
#      then remounts /system ro.
#   5. Verifies that `su` now returns uid 0.
#
# Prerequisite (one-time, manual):
#   In BlueStacks: Settings -> Advanced -> "Android Debug Bridge" = ON.
#
# Usage (inside Termux):
#   chmod +x root-bluestacks.sh
#   ./root-bluestacks.sh
#

set -eu

# ---------- pretty output ----------
log() { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- helpers ----------
# Is there at least one device in "device" state?
has_device() {
    adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {f=1} END{exit !f}'
}

# Return the first attached device's serial (e.g. emulator-5554)
device_serial() {
    adb devices 2>/dev/null | awk 'NR>1 && $2=="device" {print $1; exit}'
}

# Run a command via adb shell, strip the stray CR that adb appends.
ash() {
    adb shell "$@" | tr -d '\r'
}

# ---------- 1. ensure adb is installed ----------
if ! command -v adb >/dev/null 2>&1; then
    log "android-tools not found; installing via pkg..."
    pkg install -y android-tools >/dev/null \
        || die "Failed to install android-tools. Run 'pkg update' and try again."
fi

# ---------- 2. start adb and wait for a device ----------
log "Starting adb daemon..."
adb start-server >/dev/null 2>&1 || true

log "Waiting for a device (up to 15s)..."
i=0
while [ "$i" -lt 15 ]; do
    if has_device; then break; fi
    sleep 1
    i=$((i + 1))
done

has_device || die "No ADB device detected. In BlueStacks, turn ON \
Settings -> Advanced -> 'Android Debug Bridge', then rerun this script."

ok "Connected: $(device_serial)"

# ---------- 3. confirm this is a BlueStacks instance ----------
if ! adb shell '[ -x /system/xbin/bstk/su ]'; then
    die "/system/xbin/bstk/su not found. This script only works on BlueStacks emulators."
fi

# ---------- 4. short-circuit if already rooted ----------
uid="$(ash 'su -c "id -u" 2>/dev/null' || true)"
uid="$(printf '%s' "$uid" | tr -d ' \n')"
if [ "$uid" = "0" ]; then
    ok "Already rooted: /system/bin/su exists and returns uid 0. Nothing to do."
    exit 0
fi

# ---------- 5. install /system/bin/su via bstk/su ----------
log "Elevating with bstk/su and installing /system/bin/su..."
adb shell "/system/xbin/bstk/su -c 'set -e; \
mount -o rw,remount /system && \
cp -f /system/xbin/bstk/su /system/bin/su && \
chmod 06755 /system/bin/su && \
mount -o ro,remount /system'" \
    || die "Root install step failed. /system may still be mounted rw — reboot the emulator to reset."

# ---------- 6. verify ----------
log "Verifying..."
uid="$(ash 'su -c "id -u"' || true)"
uid="$(printf '%s' "$uid" | tr -d ' \n')"
if [ "$uid" = "0" ]; then
    ok "Root installed successfully."
    ok "Type 'su' in Termux (or any shell on the device) to get a root shell."
else
    die "Verification failed: 'su -c id -u' did not return 0 (got: '$uid')."
fi
