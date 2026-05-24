#!/data/data/com.termux/files/usr/bin/sh
#
# backup-trill-assets.sh
# Zip /data/data/com.ss.android.ugc.trill/app_assets and upload to Google Drive
# via rclone.
#
# Self-elevating: re-execs itself under `su --mount-master` (or `nsenter`) so
# that the source directory becomes visible.
#
# Prereqs (one-time):
#   pkg install zip rclone
#   rclone config           # set up your Google Drive remote
#
# Usage:
#   chmod +x backup-trill-assets.sh
#   ./backup-trill-assets.sh
#
# Optional environment overrides:
#   REMOTE=mygdrive:Backups ./backup-trill-assets.sh
#   SRC=/data/data/some.other.pkg/files ./backup-trill-assets.sh
#   KEEP_LOCAL=1 ./backup-trill-assets.sh    # don't delete local zip after upload
#

set -eu

# ---------- config ----------
SRC="${SRC:-/data/data/com.ss.android.ugc.trill/app_assets}"
REMOTE="${REMOTE:-gdrive:trill-backups}"      # <-- edit if your remote is named differently
WORK_DIR="${WORK_DIR:-/data/data/com.termux/files/home}"
TS="$(date +%Y%m%d-%H%M%S)"
ZIP_NAME="trill-assets-${TS}.zip"
ZIP_PATH="${WORK_DIR}/${ZIP_NAME}"
KEEP_LOCAL="${KEEP_LOCAL:-0}"

# ---------- pretty output ----------
log() { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- self-elevation ----------
# If we can't see the source dir, we're either not root or in the wrong mount
# namespace. Escalate transparently.
if [ ! -d "$SRC" ]; then
    if [ "$(id -u)" -ne 0 ]; then
        log "Source not visible. Re-executing under 'su --mount-master'..."
        # Pass overrides through the environment via the command string.
        exec su --mount-master -c "SRC='$SRC' REMOTE='$REMOTE' WORK_DIR='$WORK_DIR' KEEP_LOCAL='$KEEP_LOCAL' sh '$0'"
    fi
    if command -v nsenter >/dev/null 2>&1; then
        log "Already root, but wrong namespace. Entering init's mount namespace..."
        exec nsenter -t 1 -m -- sh "$0"
    fi
    die "Cannot access $SRC. Need root + global mount namespace, and either 'su --mount-master' or 'nsenter' available."
fi

# ---------- prerequisite tools ----------
# Prefer Termux-installed binaries on PATH.
export PATH="/data/data/com.termux/files/usr/bin:$PATH"
command -v zip    >/dev/null 2>&1 || die "zip not installed. Run: pkg install zip"
command -v rclone >/dev/null 2>&1 || die "rclone not installed. Run: pkg install rclone"

# ---------- check rclone remote ----------
REMOTE_NAME="${REMOTE%%:*}"
if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then
    die "rclone remote '${REMOTE_NAME}:' not configured. Run: rclone config"
fi

# ---------- inventory ----------
N_DIRS=$(find "$SRC" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
N_MP4=$(find "$SRC" -type f -name 'output.mp4' 2>/dev/null | wc -l)
N_JSON=$(find "$SRC" -type f -name 'config.json' 2>/dev/null | wc -l)
log "Source: $SRC"
log "Found ${N_DIRS} folder(s), ${N_MP4} output.mp4, ${N_JSON} config.json"
[ "$N_DIRS" -gt 0 ] || die "Nothing to back up."

# ---------- ensure workdir exists & has room ----------
mkdir -p "$WORK_DIR" || die "Cannot create $WORK_DIR"
RAW_SIZE_KB=$(du -sk "$SRC" 2>/dev/null | awk '{print $1}')
FREE_KB=$(df -Pk "$WORK_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
log "Source size: ~$((RAW_SIZE_KB / 1024)) MB   |   Free in workdir: ~$((FREE_KB / 1024)) MB"
if [ "$FREE_KB" -lt "$RAW_SIZE_KB" ]; then
    die "Not enough free space in $WORK_DIR. Free up space or set WORK_DIR= to a larger location."
fi

# ---------- zip ----------
# -0 = store, no compression. mp4 is already compressed; -0 saves a lot of CPU
#      and produces the same final size. Use -1..-9 if you want to try harder.
log "Creating ${ZIP_PATH} ..."
cd "$(dirname "$SRC")"
zip -0 -r "$ZIP_PATH" "$(basename "$SRC")" >/dev/null || die "zip failed"
ZIP_SIZE=$(du -h "$ZIP_PATH" 2>/dev/null | awk '{print $1}')
ok "Zip created: ${ZIP_NAME} (${ZIP_SIZE})"

# ---------- upload ----------
log "Uploading to ${REMOTE}/${ZIP_NAME} ..."
if ! rclone copy "$ZIP_PATH" "$REMOTE" --progress --stats-one-line; then
    die "rclone upload failed. Local zip kept at $ZIP_PATH for retry."
fi
ok "Upload complete: ${REMOTE}/${ZIP_NAME}"

# ---------- cleanup ----------
if [ "$KEEP_LOCAL" = "1" ]; then
    log "KEEP_LOCAL=1, leaving local zip at $ZIP_PATH"
else
    rm -f "$ZIP_PATH"
    ok "Removed local zip."
fi

ok "Done."
