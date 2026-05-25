#!/data/data/com.termux/files/usr/bin/sh
#
# extract-tiktok-effect.sh
# Convert TikTok effect previews from /data/data/com.ss.android.ugc.trill/app_assets
# into transparent WebM (VP9 + alpha), zip them, and upload to Google Drive
# via rclone.
#
# Self-elevating: re-execs under `su` + `nsenter` so the source directory
# becomes visible from inside Termux's mount namespace.
#
# Prereqs (one-time):
#   pkg install util-linux zip rclone ffmpeg jq
#   rclone config           # set up your Google Drive remote
#
# Usage:
#   chmod +x extract-tiktok-effect.sh
#   ./extract-tiktok-effect.sh
#
# Optional environment overrides:
#   REMOTE=mygdrive:Backups ./extract-tiktok-effect.sh
#   SRC=/data/data/some.other.pkg/files ./extract-tiktok-effect.sh
#   KEEP_LOCAL=1   ./extract-tiktok-effect.sh   # don't delete the local zip
#   KEEP_RESULTS=1 ./extract-tiktok-effect.sh   # don't delete the webm folder
#

set -eu

# ---------- resolve our own absolute path ----------
# su changes cwd before running the inner command, so $0 must be absolute
# before we re-exec ourselves through su/nsenter.
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
# If we can't see the source dir, we're either not root or in the wrong mount
# namespace. Escalate transparently. Note: bstk/su doesn't support `-c`, so we
# feed the command via stdin instead. nsenter switches us into init's mount
# namespace (PID 1), which has the global view of /data/data.
if [ ! -d "$SRC" ]; then
    # Locate nsenter while we're still in Termux's PATH; after su, PATH may not
    # include /data/data/com.termux/files/usr/bin.
    NSENTER="$(command -v nsenter || true)"
    SH_BIN="$(command -v sh)"

    if [ "$(id -u)" -ne 0 ]; then
        [ -n "$NSENTER" ] || die "nsenter not installed. Run: pkg install util-linux"
        log "Re-executing under su + nsenter (via stdin, bstk/su has no -c)..."
        exec su <<EOF
exec "$NSENTER" -t 1 -m -- env SRC='$SRC' REMOTE='$REMOTE' WORK_DIR='$WORK_DIR' KEEP_LOCAL='$KEEP_LOCAL' KEEP_RESULTS='$KEEP_RESULTS' "$SH_BIN" '$SELF'
EOF
    fi

    # Already root but wrong namespace.
    if [ -n "$NSENTER" ]; then
        log "Already root, entering init's mount namespace..."
        exec "$NSENTER" -t 1 -m -- "$SH_BIN" "$SELF"
    fi

    die "Cannot access $SRC. Need nsenter; run: pkg install util-linux"
fi

# ---------- prerequisite tools ----------
# Prefer Termux-installed binaries on PATH.
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
N_MP4=$(find "$SRC" -type f -name 'output.mp4' 2>/dev/null | wc -l)
N_JSON=$(find "$SRC" -type f -name 'config.json' 2>/dev/null | wc -l)
log "Source: $SRC"
log "Found ${N_DIRS} folder(s), ${N_MP4} output.mp4, ${N_JSON} config.json"
[ "$N_DIRS" -gt 0 ] || die "Nothing to convert."

# ---------- workspace + space check ----------
mkdir -p "$WORK_DIR"    || die "Cannot create $WORK_DIR"
mkdir -p "$RESULTS_DIR" || die "Cannot create $RESULTS_DIR"
RAW_SIZE_KB=$(du -sk "$SRC" 2>/dev/null | awk '{print $1}')
FREE_KB=$(df -Pk "$WORK_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
log "Source size: ~$((RAW_SIZE_KB / 1024)) MB   |   Free in workdir: ~$((FREE_KB / 1024)) MB"
if [ "$FREE_KB" -lt "$RAW_SIZE_KB" ]; then
    die "Not enough free space in $WORK_DIR. Free up space or set WORK_DIR= to a larger location."
fi

# ---------- convert each effect to WebM ----------
log "Converting effects to transparent WebM..."
n_done=0
n_skip=0
i=0

for folder_path in "$SRC"/*/; do
    folder=$(basename "$folder_path")
    config_path="${folder_path}config.json"
    video_path="${folder_path}output.mp4"
    i=$((i + 1))

    if [ ! -f "$config_path" ] || [ ! -f "$video_path" ]; then
        warn "  [$i/$N_DIRS] $folder  (missing config.json or output.mp4 - skipped)"
        n_skip=$((n_skip + 1))
        continue
    fi

    # Parse config.json: jq emits 9 space-separated numbers on one line.
    # `|| true` keeps set -e from killing us if jq fails on a bad file.
    config_output=$(
        jq -r '.portrait | (.rgbFrame + .aFrame + [(.has_audio // 0)]) | join(" ")' \
            "$config_path" 2>/dev/null || true
    )
    if [ -z "$config_output" ]; then
        warn "  [$i/$N_DIRS] $folder  (config.json parse failed - skipped)"
        n_skip=$((n_skip + 1))
        continue
    fi

    # Word-split the 9 values into positional parameters (POSIX equivalent of
    # bash's `read -r a b c < <(...)`). Default IFS splits on whitespace.
    # shellcheck disable=SC2086
    set -- $config_output
    if [ "$#" -lt 8 ]; then
        warn "  [$i/$N_DIRS] $folder  (no portrait.rgbFrame/aFrame - skipped)"
        n_skip=$((n_skip + 1))
        continue
    fi
    rgb_x=$1;   rgb_y=$2;   rgb_w=$3;   rgb_h=$4
    alpha_x=$5; alpha_y=$6; alpha_w=$7; alpha_h=$8
    has_audio=${9:-0}

    if [ "$rgb_w" = "0" ] || [ "$rgb_w" = "null" ] || [ -z "$rgb_w" ]; then
        warn "  [$i/$N_DIRS] $folder  (invalid crop coords - skipped)"
        n_skip=$((n_skip + 1))
        continue
    fi

    output_file="${RESULTS_DIR}/${folder}.webm"
    filter_complex="[0:v]crop=${rgb_w}:${rgb_h}:${rgb_x}:${rgb_y}[rgb]; [0:v]crop=${alpha_w}:${alpha_h}:${alpha_x}:${alpha_y},format=gray,scale=${rgb_w}:${rgb_h}[alpha]; [rgb][alpha]alphamerge[final]"

    if [ "$has_audio" = "1" ]; then
        audio_msg="with audio"
    else
        audio_msg="silent"
    fi
    log "  [$i/$N_DIRS] $folder  ($audio_msg)"

    # Two separate ffmpeg invocations instead of bash arrays - POSIX-safe.
    # </dev/null prevents ffmpeg from stealing the loop's stdin.
    if [ "$has_audio" = "1" ]; then
        if ffmpeg -hide_banner -loglevel error -y \
                -i "$video_path" \
                -filter_complex "$filter_complex" \
                -map '[final]' -map '0:a' \
                -c:v vp9 -c:a libopus -pix_fmt yuva420p \
                "$output_file" </dev/null; then
            n_done=$((n_done + 1))
        else
            warn "  [$i/$N_DIRS] $folder  (ffmpeg failed - skipped)"
            rm -f "$output_file"
            n_skip=$((n_skip + 1))
        fi
    else
        if ffmpeg -hide_banner -loglevel error -y \
                -i "$video_path" \
                -filter_complex "$filter_complex" \
                -map '[final]' \
                -c:v vp9 -pix_fmt yuva420p \
                "$output_file" </dev/null; then
            n_done=$((n_done + 1))
        else
            warn "  [$i/$N_DIRS] $folder  (ffmpeg failed - skipped)"
            rm -f "$output_file"
            n_skip=$((n_skip + 1))
        fi
    fi
done

ok "Converted $n_done effect(s), $n_skip skipped."
[ "$n_done" -gt 0 ] || die "Nothing converted - aborting before zip/upload."

# ---------- zip the WebM results ----------
# -0 = store, no recompression. VP9 is already compressed.
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