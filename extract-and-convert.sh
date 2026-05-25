#!/data/data/com.termux/files/usr/bin/bash
#
# extract-tiktok-effect.sh
# Extract TikTok effect previews from a rooted BlueStacks instance:
#   1. Read /data/data/com.ss.android.ugc.trill/app_assets/<folder>/{config.json,output.mp4}
#   2. Use the rgbFrame / aFrame coordinates in config.json to crop the
#      side-by-side source into a transparent WebM (VP9 + Opus if has_audio).
#   3. Zip all .webm results.
#   4. Upload to Google Drive via rclone.
#
# Self-elevating: re-execs under `su` + `nsenter` so /data/data/<other-app> is
# visible from inside Termux's mount namespace.
#
# Prereqs (one-time):
#   pkg install util-linux zip rclone ffmpeg jq
#   rclone config         # set up your Google Drive remote (default: gdrive)
#
# Usage:
#   chmod +x extract-tiktok-effect.sh
#   ./extract-tiktok-effect.sh
#
# Optional environment overrides:
#   REMOTE=mygdrive:Folder ./extract-tiktok-effect.sh
#   SRC=/data/data/some.other.pkg/app_assets ./extract-tiktok-effect.sh
#   KEEP_LOCAL=1 ./extract-tiktok-effect.sh      # don't delete local zip
#   KEEP_RESULTS=1 ./extract-tiktok-effect.sh    # don't delete the WebM folder
#

set -euo pipefail

# ---------- resolve our own absolute path ----------
case "$0" in
    /*) SELF="$0" ;;
    *)  SELF="$PWD/$0" ;;
esac
[ -r "$SELF" ] || { echo "Cannot locate self at $SELF" >&2; exit 1; }

# ---------- config ----------
SRC="${SRC:-/data/data/com.ss.android.ugc.trill/app_assets}"
REMOTE="${REMOTE:-gdrive:tiktok-effects}"
WORK_DIR="${WORK_DIR:-/data/data/com.termux/files/home}"
TS="$(date +%Y%m%d-%H%M%S)"
ZIP_NAME="tiktok-effects-${TS}.zip"
ZIP_PATH="${WORK_DIR}/${ZIP_NAME}"
RESULTS_DIR="${WORK_DIR}/tiktok-effects-${TS}"
KEEP_LOCAL="${KEEP_LOCAL:-0}"
KEEP_RESULTS="${KEEP_RESULTS:-0}"

# ---------- pretty output ----------
log()  { printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- self-elevation ----------
# bstk/su has no -c, so we feed commands via stdin. nsenter -t 1 -m switches
# us into init's mount namespace where /data/data/<other-app> is visible.
if [ ! -d "$SRC" ]; then
    NSENTER="$(command -v nsenter || true)"
    SH_BIN="$(command -v sh)"

    if [ "$(id -u)" -ne 0 ]; then
        [ -n "$NSENTER" ] || die "nsenter not installed. Run: pkg install util-linux"
        log "Re-executing under su + nsenter (via stdin, bstk/su has no -c)..."
        exec su <<EOF
exec "$NSENTER" -t 1 -m -- env SRC='$SRC' REMOTE='$REMOTE' WORK_DIR='$WORK_DIR' KEEP_LOCAL='$KEEP_LOCAL' KEEP_RESULTS='$KEEP_RESULTS' "$SH_BIN" '$SELF'
EOF
    fi

    if [ -n "$NSENTER" ]; then
        log "Already root, entering init's mount namespace..."
        exec "$NSENTER" -t 1 -m -- "$SH_BIN" "$SELF"
    fi

    die "Cannot access $SRC. Need nsenter; run: pkg install util-linux"
fi

# ---------- prerequisite tools ----------
export PATH="/data/data/com.termux/files/usr/bin:$PATH"
command -v ffmpeg >/dev/null 2>&1 || die "ffmpeg not installed. Run: pkg install ffmpeg"
command -v jq     >/dev/null 2>&1 || die "jq not installed. Run: pkg install jq"
command -v zip    >/dev/null 2>&1 || die "zip not installed. Run: pkg install zip"
command -v rclone >/dev/null 2>&1 || die "rclone not installed. Run: pkg install rclone"

# ---------- check rclone remote ----------
REMOTE_NAME="${REMOTE%%:*}"
if ! rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:$"; then
    die "rclone remote '${REMOTE_NAME}:' not configured. Run: rclone config"
fi

# ---------- inventory ----------
N_DIRS=$(find "$SRC" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
log "Source: $SRC"
log "Found $N_DIRS effect folder(s)"
[ "$N_DIRS" -gt 0 ] || die "Nothing to convert."

# ---------- workspace ----------
mkdir -p "$WORK_DIR"    || die "Cannot create $WORK_DIR"
mkdir -p "$RESULTS_DIR" || die "Cannot create $RESULTS_DIR"

# ---------- convert each effect ----------
log "Converting effects to transparent WebM..."
n_done=0
n_skip=0
n_total="$N_DIRS"
i=0

for folder_path in "$SRC"/*/; do
    folder="$(basename "$folder_path")"
    config_path="${folder_path}config.json"
    video_path="${folder_path}output.mp4"
    i=$((i + 1))

    if [[ ! -f "$config_path" || ! -f "$video_path" ]]; then
        warn "  [$i/$n_total] $folder  (missing config.json or output.mp4 — skipped)"
        n_skip=$((n_skip + 1))
        continue
    fi

    # Parse config.json with jq — read all six coords + has_audio in one call
    if ! read -r rgb_x rgb_y rgb_w rgb_h alpha_x alpha_y alpha_w alpha_h has_audio < <(
        jq -r '
            .portrait |
            (.rgbFrame + .aFrame + [(.has_audio // 0)]) |
            @tsv
        ' "$config_path" 2>/dev/null
    ); then
        warn "  [$i/$n_total] $folder  (config.json parse failed — skipped)"
        n_skip=$((n_skip + 1))
        continue
    fi

    if [[ -z "${rgb_w:-}" || "$rgb_w" = "null" || "$rgb_w" = "0" ]]; then
        warn "  [$i/$n_total] $folder  (no portrait.rgbFrame — skipped)"
        n_skip=$((n_skip + 1))
        continue
    fi

    output_file="${RESULTS_DIR}/${folder}.webm"
    filter_complex="[0:v]crop=${rgb_w}:${rgb_h}:${rgb_x}:${rgb_y}[rgb]; \
[0:v]crop=${alpha_w}:${alpha_h}:${alpha_x}:${alpha_y},format=gray,scale=${rgb_w}:${rgb_h}[alpha]; \
[rgb][alpha]alphamerge[final]"

    cmd=(ffmpeg -hide_banner -loglevel error -y -i "$video_path"
         -filter_complex "$filter_complex" -map '[final]')
    if [[ "$has_audio" == "1" ]]; then
        cmd+=(-map '0:a' -c:a libopus)
        audio_msg="with audio"
    else
        audio_msg="silent"
    fi
    cmd+=(-c:v vp9 -pix_fmt yuva420p "$output_file")

    log "  [$i/$n_total] $folder  ($audio_msg)"
    if "${cmd[@]}"; then
        n_done=$((n_done + 1))
    else
        warn "  [$i/$n_total] $folder  (ffmpeg failed — skipped)"
        rm -f "$output_file"
        n_skip=$((n_skip + 1))
    fi
done

ok "Converted $n_done effect(s), $n_skip skipped."
[ "$n_done" -gt 0 ] || die "Nothing converted — aborting before zip/upload."

# ---------- zip ----------
log "Creating ${ZIP_PATH} ..."
cd "$WORK_DIR"
zip -0 -r "$ZIP_PATH" "$(basename "$RESULTS_DIR")" >/dev/null || die "zip failed"
ZIP_SIZE=$(du -h "$ZIP_PATH" 2>/dev/null | awk '{print $1}')
ok "Zip created: ${ZIP_NAME} (${ZIP_SIZE})"

# ---------- upload ----------
log "Uploading to ${REMOTE}/${ZIP_NAME} ..."
if ! rclone copy "$ZIP_PATH" "$REMOTE" --progress --stats-one-line; then
    die "rclone upload failed. Local zip kept at $ZIP_PATH for retry."
fi
ok "Upload complete: ${REMOTE}/${ZIP_NAME}"

# ---------- cleanup ----------
if [ "$KEEP_RESULTS" = "1" ]; then
    log "KEEP_RESULTS=1, leaving WebM folder at $RESULTS_DIR"
else
    rm -rf "$RESULTS_DIR"
fi

if [ "$KEEP_LOCAL" = "1" ]; then
    log "KEEP_LOCAL=1, leaving local zip at $ZIP_PATH"
else
    rm -f "$ZIP_PATH"
    ok "Removed local zip."
fi

ok "Done."