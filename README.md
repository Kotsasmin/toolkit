# Toolkit

A collection of ready-to-use Linux system scripts with one menu to run them all: system tuning, security audits, a YouTube downloader and Pterodactyl helpers.

Created by **Kotsasmin** – [kotsasmin.net](https://kotsasmin.net)

## Install

**Arch Linux (AUR):**

```bash
yay -S kotsasmin-toolkit-git
```

**Any other distro:**

```bash
git clone https://github.com/Kotsasmin/toolkit.git
cd toolkit
./install.sh      # adds the `toolkit` command to ~/.local/bin
```

You can also skip `install.sh` and run `./toolkit.sh` straight from the folder. To update, run `git pull` in the folder.

## Usage

```bash
toolkit                       # interactive menu
toolkit media                 # YouTube video / playlist downloader
toolkit optimize status       # full system & tuning status report
toolkit optimize supertune    # adaptive low-latency tuning
toolkit security all          # full security audit
toolkit help                  # every command
```

## What's inside

| Folder | What it does |
| --- | --- |
| [`media/`](media/) | Downloads YouTube videos and playlists as MP3 or MP4, including a <10MB Discord mode. |
| [`optimization/`](optimization/) | Supertune (adaptive tuning for desktops, laptops, servers, VMs), ZRAM, TCP/BBR, SCX schedulers, hugepages, AMD tuning, and a status report of every tweak. |
| [`security/`](security/) | Audits for malware/cryptominers, network listeners, SUID/cron persistence and npm vulnerabilities. |
| [`ptero/`](ptero/) | Pterodactyl Wings prep and debugging (legacy, Calagopus support coming soon). |
| `lib/ui.sh` | The shared look (banner, menus, colours) used by every menu. |
| `toolkit.sh` | The launcher: menu and command line. |

Every script also runs on its own, e.g. `sudo ./optimization/supertune.sh --dry-run`.

## Packaging

This repository is the single source of the toolkit. The AUR package [`kotsasmin-toolkit-git`](https://aur.archlinux.org/packages/kotsasmin-toolkit-git) only holds a `PKGBUILD` that installs this repository's files, so the GitHub and AUR versions are always the same code.

## License

MIT
