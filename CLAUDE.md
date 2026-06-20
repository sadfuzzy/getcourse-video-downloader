# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A utility to download HLS video streams from GetCourse.ru without re-encoding. It fetches `.m3u8` playlists, downloads `.ts`/`.bin` segments, and concatenates them into a single output file.

## Implementations

| File | Language | Description | Extra Dependencies |
|---|---|---|---|
| `getcourse-video-downloader.sh` | Bash | Sequential download (PP=1 default) | none |
| `getcourse-video-speed.sh` | Bash | Parallel download with progress bar (PP=4 default) | `parallel`, `pv` |
| `getcourse-video-downloader.go` | Go | Parallel download, no extra deps (PP=4 default) | Go ≥ 1.16 |

## Commands

```bash
# Bash — sequential
bash getcourse-video-downloader.sh "PLAYLIST_URL" output.ts

# Bash — parallel with progress bar
bash getcourse-video-speed.sh "PLAYLIST_URL" output.ts
PP=8 bash getcourse-video-speed.sh "PLAYLIST_URL" output.ts

# Go — run directly (no go.mod needed, stdlib only)
go run getcourse-video-downloader.go "PLAYLIST_URL" output.ts
PP=8 go run getcourse-video-downloader.go "PLAYLIST_URL" output.ts

# Go — build binary
make build
./getcourse-video-downloader "PLAYLIST_URL" output.ts
make clean
```

## Architecture

All three implementations share the same two-phase flow:

### Phase 1: Playlist resolution

GetCourse serves two playlist formats — the code must handle both:
- **Direct segments**: the fetched URL is itself a segment manifest listing `http…` lines ending in `.ts` or `.bin` (same format, different extension)
- **Quality ladder**: the fetched URL is a master playlist whose last line points to another `.m3u8` at the highest resolution — fetch that second URL to get the segment manifest

Detection: `grep -qE '^https?://.*\.(ts|bin)'` for direct segments; fall back to `tail -n1` otherwise.

### Phase 2: Segment download + concatenation

Segments are downloaded as zero-padded files `00000.ts`, `00001.ts`, … into a temp dir, then `cat`-ed in glob order into the output file.

Key conventions:
- `set -eu` + `set -o pipefail` — strict mode in all bash scripts
- `set +f` — **enables** glob expansion so `*.ts` safely expands during concatenation
- `umask 077` on temp dir creation
- 12 retries per segment (`--retry 12` / loop in Go)

### Per-implementation differences

**`getcourse-video-downloader.sh`**
- PP=1 by default (sequential); PP>1 switches to GNU `parallel` but hardcodes `-j 6` (PP value is ignored in that branch)
- Random tmpdir, cleaned via `trap … EXIT`

**`getcourse-video-speed.sh`**
- Deterministic tmpdir at `/tmp/getcourse_<md5_of_url_path>` — the query string is stripped before hashing so re-runs with a freshly signed URL for the same video reuse already-downloaded segments
- Skips segments that already exist and have content (`[ -s "$f" ]`)
- Uses `pv` for concatenation progress; prints segment counts before/after download
- Explicit `rm -rf "$tmpdir"` at end (no EXIT trap)

**`getcourse-video-downloader.go`**
- Goroutine pool via a buffered channel used as a semaphore (`semaphore <- struct{}{}` / `<-semaphore`)
- Random tmpdir, cleaned via `defer os.RemoveAll`
- `hasVideoSegments` strips query string before checking `.ts`/`.bin` suffix (case-insensitive)
- No progress bar; prints per-segment retry failures to stdout

## Known Issues / Gotchas

**`getcourse-video-downloader.sh` PP>1 is broken**: The script reads PP but ignores it in the parallel branch — `-j 6` is hardcoded. Don't "fix" this here; use `getcourse-video-speed.sh` if configurable parallelism is needed.

**`getcourse-video-speed.sh` has no EXIT trap by design**: The deterministic tmpdir + explicit `rm -rf` at end (instead of a `trap … EXIT`) is intentional. If the script is killed mid-download, partial `.ts` files survive in `/tmp/getcourse_<hash>/`. A re-run with any freshly-signed URL for the same video resumes from the cached segments. Adding a trap would break this. The other bash script uses a random tmpdir + trap because it has no resume capability.

**Segment numbering differs between implementations**: `getcourse-video-speed.sh` uses GNU parallel's `{#}` (1-based), Go uses an explicit counter starting at 0. Both glob-sort correctly; mixing the two for a resume is not supported.

**`.gitignore` only covers the built binary**: Output `.ts` files are not gitignored — keep downloads outside the repo root or add them manually.
