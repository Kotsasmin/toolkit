#!/usr/bin/env bash
#
# Media downloader: YouTube videos and playlists with yt-dlp and ffmpeg.
# Created by Kotsasmin - https://kotsasmin.net
#
# Usage: media.sh [-o|--output DIR] [--from-toolkit]
#   Files are saved to ~/media unless -o DIR or the MEDIA_OUTPUT_DIR variable says otherwise.

SCRIPT_DIR="$(cd -P "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
UI_LIB="$SCRIPT_DIR/../lib/ui.sh"
if [ ! -f "$UI_LIB" ]; then
    echo "[✗] Missing $UI_LIB, run this from the full toolkit folder." >&2
    exit 1
fi
# shellcheck source=../lib/ui.sh
source "$UI_LIB"

FROM_TOOLKIT=false
output_dir="${MEDIA_OUTPUT_DIR:-$HOME/media}"
while [ $# -gt 0 ]; do
    case "$1" in
        --from-toolkit) FROM_TOOLKIT=true ;;
        -o|--output)
            [ -n "${2:-}" ] || { msg_err "$1 needs a folder"; exit 1; }
            output_dir="$2"
            shift
            ;;
        -h|--help)
            sed -n '2,8p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
    esac
    shift
done

if [ "$FROM_TOOLKIT" = "true" ]; then
    LEAVE_LABEL="Back to Main Menu"
else
    LEAVE_LABEL="Exit"
fi

# Wait for Enter before leaving when started from the toolkit menu, otherwise the menu
# clears the screen right away and the message is never seen.
fail() {
    msg_err "$*"
    [ "$FROM_TOOLKIT" = "true" ] && ui_pause "Press [Enter] to return to main menu..."
    exit 1
}

install_hint() {
    if command -v pacman &>/dev/null; then
        echo "sudo pacman -S $1"
    elif command -v apt-get &>/dev/null; then
        echo "sudo apt install $1"
    elif command -v dnf &>/dev/null; then
        echo "sudo dnf install $1"
    elif command -v zypper &>/dev/null; then
        echo "sudo zypper install $1"
    else
        echo "your package manager ($1)"
    fi
}

missing=()
command -v yt-dlp &>/dev/null || missing+=(yt-dlp)
if ! command -v ffmpeg &>/dev/null || ! command -v ffprobe &>/dev/null; then
    missing+=(ffmpeg)
fi
if [ ${#missing[@]} -gt 0 ]; then
    fail "Missing ${missing[*]}. Install with: $(install_hint "${missing[*]}")"
fi

mkdir -p "$output_dir" || fail "Cannot create $output_dir"
output_dir="$(cd "$output_dir" && pwd)"

user_agent="Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"
if [ -f "user_agent.txt" ]; then
    user_agent=$(xargs < user_agent.txt)
fi

# Use android/ios clients to avoid HTTP 403 Forbidden PO token blocks.
yt_args=(
    --user-agent "$user_agent"
    --extractor-args "youtube:player_client=android,ios,web"
    --restrict-filenames
)
if [ -f "cookies.txt" ]; then
    yt_args+=(--cookies "cookies.txt")
fi

SINGLE_TEMPLATE="%(title)s-%(id)s.%(ext)s"
# Each playlist gets its own folder, numbered so the files stay in playlist order.
PLAYLIST_TEMPLATE="%(playlist_title)s/%(playlist_index)03d-%(title)s-%(id)s.%(ext)s"

# pick_scope URL ALLOW_PLAYLIST: sets SCOPE to "single" or "playlist".
pick_scope() {
    local url="$1" allow_playlist="$2" scope_choice
    SCOPE="single"
    [[ "$url" == *"list="* ]] || return 0

    local has_video=false
    [[ "$url" == *"v="* || "$url" == *"youtu.be/"* || "$url" == *"/shorts/"* ]] && has_video=true

    if [ "$allow_playlist" != "true" ]; then
        if [ "$has_video" = "true" ]; then
            msg_warn "This option takes one video, the rest of the playlist is skipped."
            return 0
        fi
        msg_err "This option needs a single video link, not a playlist."
        return 1
    fi

    if [ "$has_video" = "false" ]; then
        SCOPE="playlist"
        return 0
    fi

    echo ""
    msg_info "This link is a video inside a playlist."
    ui_option 1 "Just this video"
    ui_option 2 "The whole playlist" "YouTube Mixes can be hundreds of videos"
    ui_read_choice "Select [1-2]: " scope_choice || return 1
    [ "$scope_choice" = "2" ] && SCOPE="playlist"
    return 0
}

# scope_args: yt-dlp arguments for the chosen scope.
scope_args() {
    if [ "$SCOPE" = "playlist" ]; then
        echo "--yes-playlist"
        echo "-o"
        echo "$output_dir/$PLAYLIST_TEMPLATE"
    else
        echo "--no-playlist"
        echo "-o"
        echo "$output_dir/$SINGLE_TEMPLATE"
    fi
}

download_discord() {
    local url="$1" timestamp temp_file output_file duration
    timestamp=$(date +%s)
    temp_file="$output_dir/.temp_video_${timestamp}.mp4"
    output_file="$output_dir/discord_video_${timestamp}.mp4"

    yt-dlp "${yt_args[@]}" --no-playlist -f "bestvideo[height<=480]+bestaudio/best[height<=480]" \
        --merge-output-format mp4 --no-add-metadata -o "$temp_file" "$url" || return 1
    [ -f "$temp_file" ] || return 1

    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$temp_file")
    duration="${duration%.*}"
    if ! [[ "$duration" =~ ^[0-9]+$ ]] || [ "$duration" -lt 1 ]; then
        rm -f "$temp_file"
        msg_err "Could not determine video duration."
        return 1
    fi

    local target_size_bytes=9500000 audio_bitrate=64000 video_bitrate actual_size
    video_bitrate=$((target_size_bytes * 8 / duration - audio_bitrate))
    actual_size=$(wc -c < "$temp_file")

    if [ "$actual_size" -le "$target_size_bytes" ]; then
        msg_info "File is already under 10MB."
        mv "$temp_file" "$output_file"
    elif [ "$video_bitrate" -lt 50000 ]; then
        rm -f "$temp_file"
        msg_err "Video is too long to fit in 10MB at a watchable quality."
        return 1
    else
        msg_info "Compressing to <10MB (target video bitrate: $((video_bitrate / 1000))k)..."
        local passlog="$output_dir/.ffmpeg2pass_${timestamp}"
        ffmpeg -y -i "$temp_file" -c:v libx264 -preset slower -b:v "$video_bitrate" -pass 1 \
            -passlogfile "$passlog" -an -f mp4 /dev/null &&
        ffmpeg -i "$temp_file" -c:v libx264 -preset slower -b:v "$video_bitrate" -pass 2 \
            -passlogfile "$passlog" -c:a aac -b:a "$audio_bitrate" -map_metadata -1 "$output_file"
        local rc=$?
        rm -f "$temp_file" "$passlog"*
        [ $rc -eq 0 ] || return 1
    fi
    SAVED_TO="$output_file"
}

# download CHOICE: asks for a link and downloads it. Returns non-zero on failure.
download() {
    local choice="$1" url
    echo ""
    read -rp "Enter YouTube video or playlist URL: " url || return 1
    url="${url//[[:space:]]/}"
    if [ -z "$url" ]; then
        msg_err "No URL provided."
        return 1
    fi

    SAVED_TO="$output_dir"
    if [ "$choice" = "3" ]; then
        pick_scope "$url" false || return 1
        echo ""
        msg_info "Downloading video for Discord (<10MB)..."
        download_discord "$url" || { msg_err "Download failed (see the output above)."; return 1; }
        return 0
    fi

    pick_scope "$url" true || return 1
    local out_args=()
    mapfile -t out_args < <(scope_args)
    [ "$SCOPE" = "playlist" ] && SAVED_TO="$output_dir/<playlist name>"

    echo ""
    case "$choice" in
        1)
            msg_info "Downloading audio (MP3)..."
            yt-dlp "${yt_args[@]}" "${out_args[@]}" -x --audio-format mp3 --audio-quality 0 \
                --add-metadata --embed-thumbnail "$url"
            ;;
        2)
            msg_info "Downloading video (max quality)..."
            yt-dlp "${yt_args[@]}" "${out_args[@]}" -f "bestvideo+bestaudio/best" \
                --merge-output-format mp4 --add-metadata --embed-thumbnail "$url"
            ;;
        4)
            msg_info "Downloading video (1080p max, H.264/MP4)..."
            yt-dlp "${yt_args[@]}" "${out_args[@]}" \
                -S "res:1080,vcodec:h264,ext:mp4:m4a" \
                -f "bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/bestvideo[height<=1080][vcodec^=avc1]+bestaudio/best[height<=1080][vcodec^=avc1]/best[height<=1080]/best" \
                --merge-output-format mp4 --add-metadata --embed-thumbnail "$url"
            ;;
    esac || { msg_err "Download failed (see the yt-dlp output above)."; return 1; }
}

while true; do
    ui_banner "Media Downloader"
    echo -e "  ${BOLD}Saves to:${NC} $output_dir"
    echo -e "  ${BOLD}Accepts:${NC}  YouTube videos and playlists"
    echo ""
    ui_title "Select download type:"
    ui_option 1 "Audio" "MP3, max quality, metadata"
    ui_option 2 "Video" "max quality, metadata"
    ui_option 3 "Video for Discord" "<10MB, no metadata, single video"
    ui_option 4 "Video FHD" "1080p max, H.264/MP4 compatible, no re-encoding"
    ui_option 5 "Open output folder"
    ui_back 0 "$LEAVE_LABEL"
    echo ""
    ui_read_choice "Select an option [0-5]: " choice || exit 0

    case "$choice" in
        0|q|Q|b|B)
            exit 0
            ;;
        1|2|3|4)
            if download "$choice"; then
                echo ""
                msg_ok "Done! Saved to $SAVED_TO"
                if ui_confirm "Open the output folder?"; then
                    open_target "$output_dir"
                fi
            fi
            ui_pause "Press [Enter] to return to the media menu..."
            ;;
        5)
            open_target "$output_dir"
            ui_pause "Press [Enter] to return to the media menu..."
            ;;
        *)
            ui_invalid "$choice"
            ;;
    esac
done
