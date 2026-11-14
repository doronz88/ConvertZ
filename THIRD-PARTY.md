# Third-party software

ConvertZ itself is MIT licensed (see LICENSE).

The app bundle also contains **FFmpeg** (`ffmpeg` and `ffprobe`, version 9.0.2), which ConvertZ runs as separate
programs. FFmpeg is not part of ConvertZ's source and is not covered by ConvertZ's license. This build of FFmpeg
includes GPL components (such as x264 and x265) and is licensed under the GNU General Public License, version 3;
the full text is in `ffmpeg-LICENSE.txt`.

- FFmpeg project and source code: https://ffmpeg.org/download.html
- The binaries are the static macOS arm64 builds (unchanged apart from being re-signed) from https://ffmpeg.martin-riedl.de, whose build
  scripts are at https://git.martin-riedl.de/ffmpeg/build-script
- `Tools/fetch-ffmpeg.sh` records the exact download and its checksums.
