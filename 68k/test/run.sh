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

# +o3 folds 0(An) to (An). No source needs it today, and rmac matches vasm
# byte for byte without it, but it costs nothing and the next such operand
# would otherwise cost two bytes silently.
python3 gendata.py
rmac -m68000 -p +o3 -i. -i.. -o JX1TEST.PRG jx1_hatari.S                  # linear
rmac -m68000 -p +o3 -dRINGMOD=0 -i. -i.. -o JX1RING.PRG jx1_hatari_ring.S  # ring
rmac -m68000 -p +o3 -dRINGMOD=1 -i. -i.. -o JX1RMOD.PRG jx1_hatari_ring.S  # ring_mod

# --disable-video runs Hatari headless (no window); it does not change what is
# emulated - the shifter still contends for the bus, and the measured ticks are
# identical to a windowed run.
# A TOS program cannot fail the shell, so the output is the verdict: every
# program must reach DONE, and no case may report BAD.
fail=0
run() {
    out=$("$HATARI" --tos "$TOS" --machine st --cpuclock 8 --cpu-exact on \
        --compatible on --memsize 4 --sound off --conout 2 --fast-forward on \
        --disable-video 1 --run-vbls 3000 --log-level fatal "$1" 2>/dev/null)
    printf '%s\n' "$out"
    case "$out" in
        *BAD*)  echo "FAILED: $1 reported BAD"     >&2; fail=1 ;;
    esac
    case "$out" in
        *DONE*) ;;
        *)      echo "FAILED: $1 never reached DONE" >&2; fail=1 ;;
    esac
}
run JX1TEST.PRG
run JX1RING.PRG
run JX1RMOD.PRG
exit $fail
