#!/bin/bash
# Optional desktop generator for the Apple Music tab.
set -eu
usage() { echo 'Usage: build_lyrics.sh [--language en|es] (--track TITLE_OR_FILE | PLAYLIST)' >&2; exit 2; }
lang=en
if [ "${1:-}" = --language ]; then [ "$#" -ge 3 ] || usage; lang=$2; shift 2; fi
case "$lang" in en|es) ;; *) usage;; esac
mode=playlist
if [ "${1:-}" = --track ]; then mode=track; shift; fi
[ "$#" -eq 1 ] || usage
target=$1
root="$(cd "$(dirname "$0")/.." && pwd)"
model="${WHISPER_MODEL:-$root/Vendor/ggml-base.bin}"
cli="${WHISPER_BIN:-whisper-cli}"
out="${LYRIC_OUT_DIR:-$root/lyrics}"
[ -f "$model" ] || { echo "Missing model: $model" >&2; exit 1; }
mkdir -p "$out"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
generate() {
  [ -f "$1" ] || { echo "Cannot read audio: $1" >&2; return 1; }
  case "$2" in *'/'*|''|.|..) echo 'Track title cannot be used as a filename' >&2; return 1;; esac
  ffmpeg -nostdin -loglevel error -y -i "$1" -vn -ar 16000 -ac 1 -c:a pcm_s16le "$tmp/input.wav"
  rm -f "$tmp/result.lrc"
  "$cli" -m "$model" -l "$lang" -f "$tmp/input.wav" -olrc -of "$tmp/result" -ml 100 -sow
  grep -Eq '^\[[0-9]+:[0-9]+\.[0-9]+\].*[^[:space:]]' "$tmp/result.lrc" || { echo 'No timed speech recognized.' >&2; return 1; }
  mv "$tmp/result.lrc" "$out/$2.lrc"
}
if [ "$mode" = track ] && [ -f "$target" ]; then
  name="$(basename "$target")"; generate "$target" "${name%.*}"; exit
fi
osascript - "$mode" "$target" > "$tmp/tracks" <<'APPLESCRIPT'
on run argv
    set lookupMode to item 1 of argv
    set query to item 2 of argv
    tell application "Music"
        if lookupMode is "track" then
            set matches to (every file track of library playlist 1 whose name is query)
            if (count matches) is not 1 then error "Expected one exact track title."
        else
            set matches to every file track of playlist query
            if (count matches) is 0 then error "Empty playlist."
        end if
        set rows to ""
        repeat with t in matches
            set titleText to name of t
            set filePath to POSIX path of (location of t)
            repeat with separator in {tab, return, linefeed}
                if titleText contains (contents of separator) or filePath contains (contents of separator) then error "Unsupported tab or newline in track."
            end repeat
            set rows to rows & titleText & tab & filePath & linefeed
        end repeat
        return rows
    end tell
end run
APPLESCRIPT
while IFS=$'\t' read -r name src; do
  [ -n "$src" ] || continue
  if [ "$mode" = playlist ] && [ -f "$out/$name.lrc" ]; then continue; fi
  generate "$src" "$name"
done < "$tmp/tracks"
