#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ASSETS_DIR="$ROOT_DIR/app_assets"
RESULTS_DIR="$ROOT_DIR/results"

mkdir -p "$RESULTS_DIR"

for folder_path in "$APP_ASSETS_DIR"/*/; do
    folder="$(basename "$folder_path")"
    config_path="$folder_path/config.json"
    video_path="$folder_path/output.mp4"

    if [[ ! -f "$config_path" || ! -f "$video_path" ]]; then
        echo "⚠ Skipping $folder (missing config.json or output.mp4)"
        continue
    fi

    # Parse config.json with jq — read all six coords + has_audio in one call
    read -r rgb_x rgb_y rgb_w rgb_h alpha_x alpha_y alpha_w alpha_h has_audio < <(
        jq -r '
            .portrait |
            (.rgbFrame + .aFrame + [(.has_audio // 0)]) |
            @tsv
        ' "$config_path"
    )

    output_file="$RESULTS_DIR/$folder.webm"

    filter_complex="[0:v]crop=${rgb_w}:${rgb_h}:${rgb_x}:${rgb_y}[rgb]; \
[0:v]crop=${alpha_w}:${alpha_h}:${alpha_x}:${alpha_y},format=gray,scale=${rgb_w}:${rgb_h}[alpha]; \
[rgb][alpha]alphamerge[final]"

    # Build the command as an array so audio flags can be conditionally added
    cmd=(ffmpeg -i "$video_path" -filter_complex "$filter_complex" -map '[final]')

    if [[ "$has_audio" == "1" ]]; then
        cmd+=(-map '0:a' -c:a libopus)
        audio_msg="yes"
    else
        audio_msg="no"
    fi

    cmd+=(-c:v vp9 -pix_fmt yuva420p "$output_file" -y)

    echo "🔄 Converting $folder → $output_file (audio: $audio_msg)"
    "${cmd[@]}"
done

echo ""
echo "✅ All conversions done! Results are in: $RESULTS_DIR"
