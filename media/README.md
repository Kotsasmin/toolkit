# Media Downloader

Downloads YouTube videos and playlists with `yt-dlp` and `ffmpeg`.

```bash
toolkit media                 # from the toolkit
./media.sh                    # on its own
./media.sh -o ~/Videos/yt     # save somewhere else (or set MEDIA_OUTPUT_DIR)
```

Files go to `~/media` by default; the menu shows the full path and has an option to open the folder.

| Option | Result |
| --- | --- |
| 1 Audio | MP3, best quality, with metadata and cover art |
| 2 Video | Best quality MP4 with metadata |
| 3 Video for Discord | Single video squeezed under 10MB |
| 4 Video FHD | 1080p max, H.264 MP4 that plays everywhere |

Playlist links are saved into a folder named after the playlist, with the files numbered in playlist order. For a link to a video inside a playlist, you're asked whether you want just that video or the whole playlist.

Optional: put a `cookies.txt` (for age-restricted videos) or a `user_agent.txt` in the folder you run it from.
