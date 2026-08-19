#!/bin/bash

command_exists() {
    command -v "$1" >/dev/null 2>&1
}


if ! command_exists yt-dlp; then
    echo "Error: yt-dlp is not installed. Please install it (e.g., yay -S yt-dlp)."
    exit 1
fi

if ! command_exists ffmpeg; then
    echo "Error: ffmpeg is not installed. Please install it (e.g., yay -S ffmpeg)."
    exit 1
fi


output_dir="output"
[ ! -d "$output_dir" ] && mkdir -p "$output_dir"

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

echo "Select download type:"
echo "1) Audio (MP3, Max Quality, Metadata)"
echo "2) Video (Max Quality, Metadata)"
echo "3) Video for Discord (<10MB, No Metadata)"
echo "4) Video (FHD 1080p max, H.264/MP4 Compatible, No Recoding)"
read -r choice

echo "Enter YouTube URL:"
read -r url

if [ -z "$url" ]; then
    echo "Error: No URL provided."
    exit 1
fi

case $choice in
    1)
        echo "Downloading Audio (MP3)..."
        yt-dlp "${yt_args[@]}" -x --audio-format mp3 --audio-quality 0 --add-metadata --embed-thumbnail --restrict-filenames -o "$output_dir/%(title)s-%(id)s.%(ext)s" "$url"
        ;;
    2)
        echo "Downloading Video (Max Quality)..."
        yt-dlp "${yt_args[@]}" -f "bestvideo+bestaudio/best" --merge-output-format mp4 --add-metadata --embed-thumbnail --restrict-filenames -o "$output_dir/%(title)s-%(id)s.%(ext)s" "$url"
        ;;
    3)
        echo "Downloading Video for Discord (<10MB)..."
        timestamp=$(date +%s)
        temp_file="$output_dir/temp_video_${timestamp}.mp4"
        output_file="$output_dir/discord_video_${timestamp}.mp4"

        yt-dlp "${yt_args[@]}" -f "bestvideo[height<=480]+bestaudio/best[height<=480]" --merge-output-format mp4 --no-add-metadata --restrict-filenames -o "$temp_file" "$url"

        if [ ! -f "$temp_file" ]; then
            echo "Error: Download failed."
            exit 1
        fi

        duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$temp_file")

        if [ -z "$duration" ]; then
            echo "Could not determine video duration."
            rm "$temp_file"
            exit 1
        fi

        target_size_bytes=9500000
        target_total_bitrate=$((target_size_bytes * 8 / ${duration%.*}))
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
            "$url"
        ;;
    *)
        echo "Invalid choice."
        exit 1
        ;;
esac
