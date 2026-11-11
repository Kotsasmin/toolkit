#!/bin/bash

RED='\033[0;31m'
NC='\033[0m'

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

FROM_TOOLKIT=false
for arg in "$@"; do
    if [[ "$arg" == "--from-toolkit" ]]; then
        FROM_TOOLKIT=true
    fi
done

# Wait for Enter before leaving when started from the toolkit menu, otherwise the menu
# clears the screen right away and the message is never seen.
pause_if_toolkit() {
    if [ "$FROM_TOOLKIT" = "true" ]; then
        echo ""
        read -rp "Press [Enter] to return to main menu..."
    fi
}

fail() {
    echo -e "${RED}Error: $*${NC}" >&2
    pause_if_toolkit
    exit 1
}

install_hint() {
    if command_exists pacman; then
        echo "sudo pacman -S $1"
    elif command_exists apt-get; then
        echo "sudo apt install $1"
    elif command_exists dnf; then
        echo "sudo dnf install $1"
    elif command_exists zypper; then
        echo "sudo zypper install $1"
    else
        echo "your package manager"
    fi
}

missing=()
command_exists yt-dlp || missing+=(yt-dlp)
command_exists ffmpeg || missing+=(ffmpeg)
command_exists ffprobe || { command_exists ffmpeg && missing+=(ffprobe); }
if [ ${#missing[@]} -gt 0 ]; then
    pkgs="${missing[*]}"
    pkgs="${pkgs/ffprobe/ffmpeg}"
    fail "missing ${missing[*]}. Install with: $(install_hint "$pkgs")"
fi

if [ "$FROM_TOOLKIT" = "true" ]; then
    output_dir="${HOME}/media"
else
    output_dir="output"
fi
mkdir -p "$output_dir" || fail "cannot create $output_dir"

# User-Agent handling XD
user_agent="Mozilla/5.0 (X11; Linux x86_64; rv:130.0) Gecko/20100101 Firefox/130.0"
if [ -f "user_agent.txt" ]; then
    user_agent=$(cat user_agent.txt | xargs)
fi

# Use android/ios clients to prevent HTTP 403 Forbidden PO token blocks. Lets see if it works
yt_args=(
    --user-agent "$user_agent"
    --extractor-args "youtube:player_client=android,ios,web"
)

# Optional: and soon to be added cookies
if [ -f "cookies.txt" ]; then
    yt_args+=(--cookies "cookies.txt")
fi

while true; do
    echo "Select download type:"
    echo "1) Audio (MP3, Max Quality, Metadata)"
    echo "2) Video (Max Quality, Metadata)"
    echo "3) Video for Discord (<10MB, No Metadata)"
    echo "4) Video (FHD 1080p max, H.264/MP4 Compatible, No Recoding)"
    if [ "$FROM_TOOLKIT" = "true" ]; then
        echo "0) Back (Return to Main Menu)"
    else
        echo "0) Exit"
    fi
    read -r choice || exit 0
    # Drop spaces and a stray carriage return so " 1" or "1\r" still count as 1.
    choice="${choice//[[:space:]]/}"

    case $choice in
        0|q|Q|b|B)
            if [ "$FROM_TOOLKIT" = "true" ]; then
                echo "Returning to Main Menu..."
            fi
            exit 0
            ;;
        1|2|3|4)
            break
            ;;
        *)
            echo -e "${RED}Invalid choice '$choice', pick 0-4.${NC}"
            echo ""
            ;;
    esac
done

echo "Enter YouTube URL:"
read -r url
url="${url//[[:space:]]/}"

[ -z "$url" ] && fail "No URL provided."

case $choice in
    1)
        echo "Downloading Audio (MP3)..."
        yt-dlp "${yt_args[@]}" -x --audio-format mp3 --audio-quality 0 --add-metadata --embed-thumbnail --restrict-filenames -o "$output_dir/%(title)s-%(id)s.%(ext)s" "$url" || fail "download failed (see yt-dlp output above)."
        echo "Done! Saved to $output_dir/"
        ;;
    2)
        echo "Downloading Video (Max Quality)..."
        yt-dlp "${yt_args[@]}" -f "bestvideo+bestaudio/best" --merge-output-format mp4 --add-metadata --embed-thumbnail --restrict-filenames -o "$output_dir/%(title)s-%(id)s.%(ext)s" "$url" || fail "download failed (see yt-dlp output above)."
        echo "Done! Saved to $output_dir/"
        ;;
    3)
        echo "Downloading Video for Discord (<10MB)..."
        timestamp=$(date +%s)
        temp_file="$output_dir/temp_video_${timestamp}.mp4"
        output_file="$output_dir/discord_video_${timestamp}.mp4"

        yt-dlp "${yt_args[@]}" -f "bestvideo[height<=480]+bestaudio/best[height<=480]" --merge-output-format mp4 --no-add-metadata --restrict-filenames -o "$temp_file" "$url"

        [ -f "$temp_file" ] || fail "download failed (see yt-dlp output above)."

        duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$temp_file")

        duration="${duration%.*}"
        if [ -z "$duration" ] || [ "$duration" -lt 1 ] 2>/dev/null; then
            rm -f "$temp_file"
            fail "could not determine video duration."
        fi

        target_size_bytes=9500000
        target_total_bitrate=$((target_size_bytes * 8 / duration))
        audio_bitrate=64000
        video_bitrate=$((target_total_bitrate - audio_bitrate))

        actual_size=$(wc -c < "$temp_file")
        if [ "$actual_size" -le "$target_size_bytes" ]; then
            echo "File is already under 10MB. Renaming..."
            mv "$temp_file" "$output_file"
        else
            echo "Compressing to <10MB (Target Bitrate: $((video_bitrate / 1000))k)..."
            ffmpeg -y -i "$temp_file" -c:v libx264 -preset slower -b:v "$video_bitrate" -pass 1 -an -f mp4 /dev/null
            ffmpeg -i "$temp_file" -c:v libx264 -preset slower -b:v "$video_bitrate" -pass 2 -c:a aac -b:a "$audio_bitrate" -map_metadata -1 "$output_file"
            rm "$temp_file"
            rm "ffmpeg2pass-0.log" "ffmpeg2pass-0.mbtree" 2>/dev/null
        fi

        echo "Done! Saved to $output_file"
        ;;
    4)
        echo "Downloading Video (FHD 1080p max, H.264/MP4 Compatible)..."
        yt-dlp "${yt_args[@]}" \
            -S "res:1080,vcodec:h264,ext:mp4:m4a" \
            -f "bestvideo[height<=1080][vcodec^=avc1]+bestaudio[ext=m4a]/bestvideo[height<=1080][vcodec^=avc1]+bestaudio/best[height<=1080][vcodec^=avc1]/best[height<=1080]/best" \
            --merge-output-format mp4 \
            --add-metadata \
            --embed-thumbnail \
            --restrict-filenames \
            -o "$output_dir/%(title)s-%(id)s.%(ext)s" \
            "$url" || fail "download failed (see yt-dlp output above)."
        echo "Done! Saved to $output_dir/"
        ;;
esac

pause_if_toolkit
