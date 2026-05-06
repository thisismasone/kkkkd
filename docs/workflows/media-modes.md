# Media Workflow Modes

This project supports two entrypoints:

- Push-based command parsing from commit messages.
- Manual run from GitHub Actions `workflow_dispatch`.

## Commit Command Modes

Use one command line in your commit message:

- `download: URL1 URL2` - direct files via `aria2c`
- `download-zip: URL1 URL2` - direct files, then one archive
- `download-yt: URL1 URL2` - videos via `yt-dlp`
- `download-yt-zip: URL1 URL2` - videos then one archive
- `download-yt-split: URL1 URL2` - videos with chapter split support + repo-safe chunking
- `download-web: URL` - webpage single-file offline snapshot
- `download-web-crawl: URL` - entry page + internal links (bounded crawl)

## Manual Workflow Inputs

The `Manual Media Download` workflow accepts:

- `mode` - one of `file`, `file-zip`, `yt`, `yt-zip`, `yt-split`, `web`, `web-crawl`
- `url_list` - for file/video modes
- `yt_format` - `yt-dlp` format selector (`bv*+ba/b` default)
- `offline_url` - for `web` and `web-crawl`
- `storage_mode` - currently `repo` (other values are logged and fallback to repo)
- `chunk_target_mb` - max output part size (default `95`)
- `dry_run` - resolves routing without downloading

## Chunking Policy

- All output files are checked against the threshold (`95 MB` default).
- Large videos are split using ffmpeg segment muxer where possible.
- If splitting is not possible or not a video, a split-zip fallback is used.

## Operational Notes

- Concurrency is enabled by ref to avoid overlapping push-back commits.
- Workflow commits use `[skip ci]` to prevent loops.
- Filenames are normalized via `--restrict-filenames` for safer Git paths.
