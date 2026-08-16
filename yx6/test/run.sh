#!/bin/sh
# Build and run the YX6 real-hardware validation harness under Hatari.
#
#   ./run.sh                      # uses the defaults below
#   HATARI=... TOS=... ./run.sh   # or point it at your own install
#
# Needs: rmac (assembler), hatari (emulator) with a TOS or EmuTOS image, and a
# compiled Java tree for the packer (run `mvn compile` in the repo root).
set -e
cd "$(dirname "$0")"

HATARI=${HATARI:-hatari}
TOS=${TOS:-$HOME/hatari-2.6.1_macos/tos-2.06.rom}

python3 gendata.py
# -i../../68k/test finds hatari_util.inc: the console and 200 Hz timing
# helpers are shared with the ST1 harnesses rather than copied.
rmac -m68000 -p +o3 -i. -i.. -i../../68k -i../../68k/test \
     -o YX6TEST.PRG YX6_test.S

# A TOS program cannot fail the shell, so its output is the verdict: it must
# reach DONE, and no line may report BAD.
out=$("$HATARI" --tos "$TOS" --machine st --cpuclock 8 --cpu-exact on \
    --compatible on --memsize 4 --sound off --conout 2 --fast-forward on \
    --disable-video 1 --run-vbls 6000 --log-level fatal YX6TEST.PRG 2>/dev/null)
printf '%s\n' "$out"

fail=0
case "$out" in
    *BAD*)  echo "FAILED: YX6TEST.PRG reported BAD"     >&2; fail=1 ;;
esac
case "$out" in
    *DONE*) ;;
    *)      echo "FAILED: YX6TEST.PRG never reached DONE" >&2; fail=1 ;;
esac
exit $fail
