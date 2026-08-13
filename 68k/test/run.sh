#!/bin/sh
# Build and run the jx1 real-hardware validation harness under Hatari.
#
#   ./run.sh                      # uses the defaults below
#   HATARI=... TOS=... ./run.sh   # or point it at your own install
#
# Needs: rmac (assembler), hatari (emulator) with a TOS or EmuTOS image, and
# a compiled Java tree for the compressor (run `mvn compile` in the repo root).
set -e
cd "$(dirname "$0")"

HATARI=${HATARI:-hatari}
TOS=${TOS:-$HOME/hatari-2.6.1_macos/tos-2.06.rom}

# +o3 folds 0(An) to (An); without it rmac emits a 2-byte-larger decompressor
# (326 instead of 324). With it, rmac and vasm agree byte for byte.
python3 gendata.py
rmac -m68000 -p +o3 -i. -i.. -o JX1TEST.PRG jx1_hatari.S

# --disable-video runs Hatari headless (no window); it does not change what is
# emulated - the shifter still contends for the bus, and the measured ticks are
# identical to a windowed run.
exec "$HATARI" --tos "$TOS" --machine st --cpuclock 8 --cpu-exact on \
    --compatible on --memsize 4 --sound off --conout 2 --fast-forward on \
    --disable-video 1 --run-vbls 2500 --log-level fatal JX1TEST.PRG
