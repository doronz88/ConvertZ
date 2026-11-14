# ConvertZ — design

2026-11-14. Name chosen by the owner: ConvertZ.

## Intent

A friendly Mac app for converting media files (to MP4, MP3, WAV and others) that the owner can publish on
GitHub and send to friends. The driving pain: files that Premiere Pro refuses to import, or imports badly,
until they are re-encoded with specific ffmpeg flags. The app should carry those flags so nobody has to
remember them. Premiere runs on a different Mac from the one this is developed on.

## Goals

- Drop files in, pick a preset, get output that Premiere opens. The default preset is the "fix it for
  Premiere" one.
- Works for a friend with nothing installed: no ffmpeg, no Python, no Terminal.
- Robust: odd inputs fail with a readable reason, never with a silent bad file, and never damage the source.
- Distributed the same way as Pliable: GitHub release zip plus a cask in `doronz88/homebrew-tap` that clears
  quarantine.

## Non-goals (v1)

- Windows/Linux, Intel Macs.
- Editing: trim, crop, filters, subtitles burn-in, joining files.
- HDR tone-mapping (HDR sources are flagged with a warning, converted as-is to 8-bit without tone-mapping).
- Notarization / Developer ID signing, Mac App Store, auto-update (Homebrew handles updates).
- Exposing every ffmpeg option. A small set of per-preset options only.

## Anti-goals

- A wall of codec jargon on the main screen.
- Overwriting or deleting a source file, ever.
- Leaving a half-written output file that looks finished.

## Constraints

- macOS 14+, Apple Silicon only (decision: bundling ffmpeg + ffprobe for both architectures would roughly
  double a ~150 MB app; Intel Macs are no longer supported by current macOS).
- Ad-hoc signed, not notarized. Homebrew cask strips quarantine; README documents the manual
  `xattr -dr com.apple.quarantine` step for direct downloads.
- License: app source is MIT (owner's decision). The bundled ffmpeg/ffprobe are separate executables the app
  launches as child processes; they stay under their own license (GPL for an x264-enabled build). Ship
  ffmpeg's license text in the bundle, and state the ffmpeg version, build origin and source link in the
  README and the About panel.
- Follow Pliable's project conventions (`~/dev/Pliable`): SwiftPM package, `build.sh` assembling the `.app`,
  a `Core` library target with tests, `ci.yml` + `release.yml`, bundle id `com.doronz88.ConvertZ`.

## Approaches considered

1. **Native SwiftUI app driving a bundled ffmpeg — chosen.** Small, native, builds with the toolchain already
   used for Pliable, same release and tap pipeline.
2. **Tauri (web UI + Rust).** Cross-platform, but more moving parts and less native; rejected once the owner
   confirmed Mac-only.
3. **Python/Tkinter + PyInstaller.** Fast to write; dated look, heavy and fragile packaging. Rejected as not
   "friendly".

Within approach 1, for the engine: bundling ffmpeg was chosen over requiring Homebrew ffmpeg (friends without
Homebrew) and over AVFoundation-only conversion (cannot read MKV/WebM/Opus and many of the inputs that cause
the Premiere problem in the first place).

## What the user sees

One window.

```
+--------------------------------------------------------------+
|  Convert to: [ Premiere-safe MP4  v ]   [ Options... ]       |
|  Save to:    [ Same folder as original  v ]                  |
+--------------------------------------------------------------+
|  clip01.mkv     HEVC 10-bit, variable fps, Opus    Waiting   |
|                 ! 3 things Premiere dislikes                 |
|  talk.mov       H.264 1080p 30fps, AAC             ####  62% |
|  song.flac      FLAC 44.1 kHz                      Done  ->  |
|                                                              |
|          Drop files or folders here   [ Add files... ]       |
+--------------------------------------------------------------+
|  [ Clear finished ]                    [ Cancel ]  [ Convert ]|
+--------------------------------------------------------------+
```

- Add files by drag-and-drop (files or folders, folders scanned recursively for media), the Add button, or
  dropping onto the Dock icon.
- Each row shows a one-line plain summary from probing, and, if relevant, a warning listing what Premiere is
  likely to object to (see Diagnosis). Clicking the warning expands the list.
- Per-row states: Probing, Waiting, Converting (percent + time remaining), Done (reveal in Finder), Failed
  (short reason + "Show log"), Cancelled, Skipped (e.g. audio-only file with a video preset: reason shown).
- Jobs run one at a time. Cancel stops the current job and leaves the rest waiting; rows can be removed
  individually. Dock icon shows overall progress; a notification fires when the queue finishes in background.
- Options sheet shows only what applies to the chosen preset. It includes a read-only "ffmpeg command"
  disclosure with a copy button, for the curious.
- Preset, options and save location persist between launches.

## Presets

Video:

| Preset | Output | Notes |
|---|---|---|
| **Premiere-safe MP4** (default) | `.mp4` H.264 High, yuv420p 8-bit, constant frame rate, AAC 48 kHz stereo-or-source layout, faststart | The fix-everything preset |
| ProRes 422 (editing) | `.mov` ProRes 422 (option: Proxy / LT / 422 / HQ), PCM 48 kHz | Large files, smoothest editing |
| Rewrap to MP4 (no re-encode) | `.mp4`, stream copy | Instant; if the codecs can't live in MP4, fail with a message suggesting Premiere-safe MP4 |
| H.265 MP4 (small) | `.mp4` HEVC, `hvc1` tag, AAC | For sharing, not editing |
| WebM | `.webm` VP9 + Opus | |
| GIF | `.gif`, two-pass palette, default 15 fps, max width 640 | |

Audio (video streams dropped; cover art dropped):

| Preset | Output |
|---|---|
| MP3 | constant bitrate 320k (option 192/256/320), 48 kHz option off by default (keeps source rate) |
| WAV | PCM 16-bit 48 kHz (options: 24-bit; 44.1 kHz) |
| M4A (AAC) | 256k |
| FLAC | lossless |

Premiere-safe MP4 rules (the heart of the app):

- First video stream, all audio streams; subtitle and data streams dropped.
- Variable frame rate → constant. The rate snaps to a standard one (23.976, 24, 25, 29.97, 30, 50, 59.94, 60,
  100, 120, 240) only when the source's average rate is within about 3% of it; otherwise the source's own
  average rate is kept as a constant rate (so a 12 fps screen recording stays 12 fps and 120 fps slow-motion
  keeps its frames). Option to force a specific rate. (Builder-check call, not the owner's.)
- Interlaced sources are detected, flagged in the diagnosis, and deinterlaced to frame rate (not field rate).
  Tape/broadcast workflows that need interlacing preserved are out of scope for v1. (Builder-check call.)
- Dimensions made even; source resolution kept unless the option says 2160p/1080p/720p (downscale only,
  aspect preserved).
- Rotation metadata baked into the pixels.
- Quality option: High (default, visually lossless), Medium, Small. Encoder option: "Best quality" (x264,
  default) or "Fast" (Apple hardware encoder).
- Audio: AAC 320k, 48 kHz. Sources with more than 2 channels keep their layout.
- Colour tags (primaries/transfer/matrix) carried over for SDR sources.
- Source metadata (creation date) carried over.

## Diagnosis

Probe every added file with ffprobe (JSON). Flag, in plain words:

- variable frame rate
- video codec Premiere handles poorly or not at all (anything outside H.264, HEVC, ProRes, DNxHD/HR; e.g.
  VP9, AV1, MPEG-4 ASP, Theora)
- 10-bit or 4:2:2/4:4:4 H.264; HDR transfer (PQ/HLG)
- audio codec outside AAC/PCM/MP3 (Opus, Vorbis, FLAC-in-video, etc.), or sample rate other than 44.1/48 kHz
- container Premiere doesn't import (MKV, WebM, FLV, AVI with odd codecs, TS oddities)
- odd pixel dimensions; missing or broken duration/index

A file with no flags shows "Looks fine for Premiere". Files ffprobe can't read are listed as Failed with
"Not a media file ffmpeg understands".

## Robustness rules

- Output is written under a temporary name in the destination folder and renamed on success; removed on
  failure or cancel.
- Never overwrite: on a name clash, append ` (1)`, ` (2)`... Default name is `<original> converted.<ext>` when the
  output would otherwise collide with the source; otherwise `<original>.<ext>`.
- Destination: same folder as original (default) or a chosen folder. If the destination isn't writable or
  the disk has too little free space (rough estimate), fail that job before starting with a clear message.
- Success requires ffmpeg exit 0 **and** the output re-probing as valid with a duration within tolerance of
  the source.
- On failure, the row shows a short human reason mapped from common ffmpeg errors; the full log is one click
  away and copyable.
- Progress comes from ffmpeg's machine-readable progress output, not from scraping its log.
- Quitting with jobs running asks for confirmation, then cancels cleanly (no orphaned ffmpeg process, no
  partial file).
- App keeps the Mac awake while converting.
- ffmpeg lookup: bundled copy first; for development builds without one, fall back to Homebrew's.

## Packaging and release

- `build.sh` builds the app and places `ffmpeg` and `ffprobe` in the bundle. The binaries are **not**
  committed: a script downloads a pinned static arm64 GPL build of a current ffmpeg release and verifies a
  pinned SHA-256. Preferred source: the static macOS builds at ffmpeg.martin-riedl.de; builder to verify it
  provides x264, libmp3lame, libvpx, libopus and VideoToolbox, and choose another pinned source otherwise.
- Release workflow mirrors Pliable's: on a `v*` tag, test, build, zip, publish the GitHub release with a
  checksum, and bump `Casks/convertz.rb` in `doronz88/homebrew-tap` when `TAP_DEPLOY_KEY` is set. The cask is
  modelled on `pliable.rb` (quarantine-clearing postflight, `depends_on arch: :arm64`, macOS Sonoma+).
- README: what it is, screenshot, install via tap, direct-download instructions with the quarantine step,
  preset table, ffmpeg attribution, MIT license.
- Creating the GitHub repo, pushing, tagging, adding the cask to the tap and the deploy-key secret are done
  by or with the owner's go-ahead, not as part of the build.

## Verification against Premiere

Premiere is on another Mac, so automated tests can only assert the output's probed properties, not that
Premiere opens it. Before the first release is tagged, the owner tries the default preset's output from real
problem files in Premiere. If the owner supplies the ffmpeg command they use today, it is the reference for
the default preset: where it disagrees with the rules above, it wins, and it becomes a golden test.

## Testing

- Unit tests on the core library: ffmpeg argument construction per preset and option, frame-rate snapping,
  probe JSON parsing and diagnosis, progress parsing, output naming/collision, error mapping.
- Integration tests that run real ffmpeg on small generated clips (made with ffmpeg's test sources at test
  time: VFR, 10-bit HEVC in MKV, Opus audio, odd dimensions, rotated, audio-only, no-audio) and assert the
  output's probed properties. Skipped when no ffmpeg is available.

## Left to the builder

- Internal structure, naming, concurrency model, exact encoder settings behind "High / Medium / Small".
- App icon (simple, original).
- Exact wording of messages, and the ffmpeg-error-to-plain-reason table.
- Whether hardware-encoder "Fast" mode needs a fallback to x264 on failure (suggested: yes, automatic).
