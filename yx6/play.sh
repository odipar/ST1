#!/bin/sh
# play.sh - test drive a YM tune: pack it, build a player, run it under Hatari.
#
#   yx6/play.sh song.ym                  # 1024-byte rings, 16 values per call
#   yx6/play.sh -n256 song.ym            # smaller rings: less RAM, worse ratio
#   yx6/play.sh -n2048 -c32 song.ym      # longer calls: cheaper on average
#   yx6/play.sh -l0 song.ym              # loop from the start, whatever the
#                                        # YM header says
#   yx6/play.sh -o song.ym               # play once and stop
#
# Press SPACE in the Hatari window to stop; the program asks Hatari to quit on
# its way out, so the script returns. Everything it builds lands in a work
# directory next to the tune, so you can keep the .yx6 and the .PRG.
#
# Needs rmac, hatari with a TOS image, and a compiled Java tree (it runs
# `mvn compile` for you if target/classes is missing).
#
#   HATARI=/path/to/hatari TOS=/path/to/tos.img yx6/play.sh song.ym
set -e

YX6_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$YX6_DIR/.." && pwd)

HATARI=${HATARI:-hatari}
TOS=${TOS:-$HOME/hatari-2.6.1_macos/tos-2.06.rom}
RING=1024
CHUNK=16
LOOP=""

while [ $# -gt 0 ]; do
    case $1 in
        -n*)  RING=${1#-n} ;;
        -c*)  CHUNK=${1#-c} ;;
        -l*)  LOOP="-l${1#-l}" ;;
        -o)   LOOP="-o" ;;
        -h|--help)
            sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)   echo "play.sh: unknown option $1" >&2; exit 1 ;;
        *)    break ;;
    esac
    shift
done

tune=$1
if [ -z "$tune" ]; then
    echo "usage: play.sh [-nRING] [-cCHUNK] [-lFRAME|-o] song.ym" >&2
    exit 1
fi
if [ ! -f "$tune" ]; then
    echo "play.sh: no such file: $tune" >&2
    exit 1
fi
if [ ! -f "$TOS" ]; then
    echo "play.sh: no TOS image at $TOS - set TOS=/path/to/tos.img" >&2
    exit 1
fi

# Everything for this run goes in one directory, named after the tune, so a
# second run with a different ring size does not overwrite the first.
stem=$(basename "$tune" | sed 's/\.[Yy][Mm]$//')
work=$(cd "$(dirname "$tune")" && pwd)/$stem-n$RING-c$CHUNK
mkdir -p "$work"

if [ ! -d "$REPO/target/classes" ]; then
    echo "play.sh: building the packer"
    (cd "$REPO" && mvn -q compile)
fi

echo "play.sh: packing $tune"
java -ea -cp "$REPO/target/classes" org.yx6.Yx6 -f \
     "-n$RING" "-c$CHUNK" $LOOP "$tune" "$work/$stem.yx6" \
    | grep -vE '^  R' || true                   # the per-register table is noise here

"$YX6_DIR/mkprg.sh" -m "$work/$stem.yx6" "$work/PLAY.PRG"

# -m built a program that drops this file as it exits, which is how the script
# below knows to close the emulator. Clear any leftover from an earlier run.
marker=$work/YX6DONE.MRK
rm -f "$marker"

echo "play.sh: starting Hatari - press SPACE in its window to stop"
# Sound on, real speed, a window: this is a listening test, not a measurement.
# --confirm-quit off so that closing it never asks anything.
"$HATARI" --tos "$TOS" --machine st --cpuclock 8 --memsize 4 \
    --sound 44100 --ym-mixing model \
    --window --zoom 2 --confirm-quit off --log-level fatal \
    "$work/PLAY.PRG" &
hatari=$!

# Wait for whichever comes first: the program dropping its marker, or the
# emulator being closed by hand. Nothing here needs an answer from the user.
while kill -0 "$hatari" 2>/dev/null; do
    if [ -f "$marker" ]; then
        kill "$hatari" 2>/dev/null || true
        for _ in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$hatari" 2>/dev/null || break
            sleep 0.3
        done
        kill -9 "$hatari" 2>/dev/null || true
        break
    fi
    sleep 0.2
done
wait "$hatari" 2>/dev/null || true
rm -f "$marker"
echo "play.sh: stopped. The tune and the program are in $work"
