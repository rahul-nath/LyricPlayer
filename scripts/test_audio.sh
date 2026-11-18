#!/bin/bash
set -eu
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
synthesize() {
    say -v "$1" -r 145 -o "$tmp/first.aiff" "$2"
    say -v "$1" -r 145 -o "$tmp/second.aiff" "$3"
    ffmpeg -nostdin -v error -y -i "$tmp/first.aiff" -i "$tmp/second.aiff" \
        -filter_complex '[0:a]apad=pad_dur=2[a];[a][1:a]concat=n=2:v=0:a=1' "$4"
}
synthesize Samantha "I parked my red bicycle beside the garden this morning. The flowers are bright yellow." \
    "After lunch we will cross the bridge and meet our friends near the river." LyricPlayerTests/TestAudio/en.m4a
synthesize Mónica "Esta mañana dejé mi bicicleta roja en el jardín. Las flores son amarillas." \
    "Después de comer vamos a cruzar el puente para visitar a nuestros amigos cerca del río." LyricPlayerTests/TestAudio/es.wav
