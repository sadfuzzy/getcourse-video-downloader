# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A bash utility to download HLS video streams from GetCourse.ru without re-encoding. It fetches `.m3u8` playlists, downloads `.ts` segments, and concatenates them into a single output file.

## Implementations

| File | Language | Description | Extra Dependencies |
|---|---|---|---|
| `getcourse-video-downloader.sh` | Bash | Sequential download | none |
| `getcourse-video-speed.sh` | Bash | Parallel download with progress bar | `parallel`, `pv` |
| `getcourse-video-downloader.go` | Go | Parallel download (no extra deps) | Go ≥ 1.16 |

**Run bash scripts:**
```bash
bash getcourse-video-downloader.sh "PLAYLIST_URL" output.ts
bash getcourse-video-speed.sh "PLAYLIST_URL" output.ts
PP=8 bash getcourse-video-speed.sh "PLAYLIST_URL" output.ts  # custom parallelism
```

**Required deps for bash:** `bash`, `curl`, `grep`, `coreutils`

**Run Go implementation:**
```bash
go run getcourse-video-downloader.go "PLAYLIST_URL" output.ts
PP=8 go run getcourse-video-downloader.go "PLAYLIST_URL" output.ts  # custom parallelism

# Or build a binary first:
go build -o getcourse-video-downloader getcourse-video-downloader.go
./getcourse-video-downloader "PLAYLIST_URL" output.ts
```

**No `go.mod`** — single-file program, uses only stdlib, `go run` works directly.

## Architecture

Both scripts follow the same flow:

1. **Playlist resolution** — fetch the URL; if the playlist contains another `.m3u8` reference (quality ladder), extract the last entry (highest resolution) and fetch that instead
2. **Segment download** — parse all `http…` lines from the resolved playlist; download each as a zero-padded file (`00000.ts`, `00001.ts`, …) into a secure temp dir
3. **Concatenation** — `cat` all segments in order into the output file; temp dir removed on `EXIT` trap

**Parallel version differences:** uses `parallel -j${PP:-4}` for concurrent segment downloads and pipes the concatenation through `pv` for a progress bar.

**Key conventions in the scripts:**
- `set -eu` — strict mode throughout
- `umask 077` on temp dir creation
- 12-retry curl loops for unreliable connections
- `set +f` disabled globbing to safely expand segment filenames
