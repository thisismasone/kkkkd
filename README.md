# github-sandbox

## Download files, videos, and webpages with GitHub Actions 

This repository provides GitHub workflow automation for:

- File downloads via `aria2c`
- Video downloads via `yt-dlp` + `ffmpeg`
- Offline webpage capture via headless browser tooling
- Automatic size guardrails for GitHub repository limits

## Setup

1. Fork the repository.
2. In your repository, open `Settings -> Actions -> General`.
3. Under **Workflow permissions**, enable **Read and write permissions**.

No extra secret is required for the default push-back flow.

## Trigger methods

- Commit-message trigger on pushes (`Download from Commit & Save to Repo`).
- Manual trigger with typed inputs (`Manual Media Download`).

## Commit command grammar

Add one of these command lines inside the commit message:

```text
download: URL1 URL2
download-zip: URL1 URL2
download-yt: URL1 URL2
download-yt-zip: URL1 URL2
download-yt-split: URL1 URL2
download-web: URL
download-web-crawl: URL
```

### What each mode does

- `download` - direct files saved into `downloads/`
- `download-zip` - direct files, then one timestamped archive
- `download-yt` - video download via `yt-dlp` (with `youtube-dl` fallback)
- `download-yt-zip` - video download, then one timestamped archive
- `download-yt-split` - chapter-aware video download plus repo-safe chunking
- `download-web` - offline single-file webpage snapshot, MHTML fallback if needed
- `download-web-crawl` - offline snapshot for entry page plus internal links
- After each run, files are auto-organized into dated folders by category:
  `downloads/files/YYYY-MM-DD`, `downloads/videos/YYYY-MM-DD`,
  `downloads/archives/YYYY-MM-DD`, `downloads/chunks/YYYY-MM-DD`,
  and `downloads/web/YYYY-MM-DD`.
- All download modes now group results per input URL under type folders:
  `downloads/files/YYYY-MM-DD/<url-folder>/`,
  `downloads/yt/YYYY-MM-DD/<url-folder>/`,
  `downloads/web/YYYY-MM-DD/<url-folder>/`.
  Chunks/split zips stay in that same URL folder.

## Size limits and chunking

GitHub blocks files larger than 100 MiB in regular repositories.  
This project uses a default 95 MB safety target:

- Video outputs are split with ffmpeg when possible.
- Other large files are split with multipart zip fallback.

You can adjust this in manual runs using `chunk_target_mb`.

## YouTube quality profiles

For YouTube modes you can use `yt_quality` with explicit max resolution:

- `144p`, `240p`, `360p`, `480p`, `720p`, `1080p`, `1440p`, `2160p`

The downloader always prefers video+audio formats and merges to mp4 where needed.

## YouTube cookies via GitHub Secrets

To improve YouTube download reliability, pass browser-exported cookies as a secret.

Recommended secret:

- `YOUTUBE_COOKIES_B64` (base64 of Netscape cookie file)

Optional alternative:

- `YOUTUBE_COOKIES` (raw multi-line Netscape cookie file content)

Create base64 on your machine:

```bash
base64 -w 0 76e3aa23-44da-4304-b09b-c6fefee2430d.txt
```

Then add the output as repository secret `YOUTUBE_COOKIES_B64`.

The workflow automatically writes cookies to a temporary file at runtime and passes it to `yt-dlp`/`youtube-dl`; nothing is committed to git.

## Local interactive facade

Use the interactive script to avoid manual git commands:

```bash
bash scripts/facade/download-and-commit.sh
```

You can also run it with flags:

```bash
bash scripts/facade/download-and-commit.sh --mode yt-split --url "https://www.youtube.com/watch?v=dQw4w9WgXcQ" --yes
```

The facade will:

1. Build the right workflow command.
2. Create a small marker change.
3. Commit and push to your selected branch.

### Purge downloads from git history

To truly remove historical download blobs (and download-only commits) from git history:

```bash
bash scripts/facade/download-and-commit.sh --purge-download-history
```

To also force-push rewritten history to remote:

```bash
bash scripts/facade/download-and-commit.sh --purge-download-history --purge-push --yes
```

Notes:

- This rewrites history for all refs and is destructive for shared clones.
- Teammates must re-clone or hard-reset after force-push.

## Reference docs

- Advanced mode details: `docs/workflows/media-modes.md`
- Main push workflow: `.github/workflows/download-with-aria2.yaml`
- Manual dispatch workflow: `.github/workflows/media-download-manual.yaml`
