# YX6 — streaming YM chiptunes on a plain 68000

YX6 is the player the root README sketches: a YM tune packed as fourteen ZX1
streams, one per sound register, each decoded through its own small ring by
[ST1_wrap.S](../68k/ST1_wrap.S). The music never exists in memory as a whole —
only fourteen rings of a few hundred bytes, refilled one register per frame.

It is a MinYMiser-style player built on ST1, and version 0.2 plays the fourteen
standard YM2149 registers and loops. The YM6 special effects (SID voice,
digidrum, sinus-SID, sync-buzzer) are **not** played.

| Piece | What it is |
|---|---|
| [`org.yx6.Yx6`](../src/main/java/org/yx6/Yx6.java) | the packer: YM5!/YM6! in, `.yx6` out |
| [YX6.S](YX6.S) | the player library, 810 bytes plus ST1_wrap's 222 |
| [YX6_player.S](YX6_player.S) | a VBL front end: a complete TOS program |
| [mkprg.sh](mkprg.sh) | links the two around a song into a runnable `.PRG` |
| [play.sh](play.sh) | one command: pack a `.ym`, build it, play it under Hatari |

## Test driving one

Distributed `.ym` files are LHA archives; unpack one first. Then:

```sh
yx6/play.sh song.ym                   # 1024-byte rings, 16 values per call
yx6/play.sh -n256 song.ym             # smaller rings: less RAM, worse ratio
yx6/play.sh -n2048 -c32 song.ym       # longer calls: cheaper on average
yx6/play.sh -o song.ym                # play once instead of looping
```

[play.sh](play.sh) packs the tune, builds a player around it and starts Hatari
with sound on. **Press SPACE in the Hatari window to stop**: the program exits,
and the script closes the emulator behind it — nothing asks you to confirm
anything. Point it at your own install with `HATARI=` and `TOS=`. Everything it
builds is kept next to the tune in `<name>-n<ring>-c<chunk>/`, so you can
compare two ring sizes by ear and keep both.

Or do the steps yourself:

```sh
mvn -q compile exec:exec@yx6 -Dargs="-f song.ym song.yx6"
yx6/mkprg.sh song.yx6                 # -> SONG.PRG, runnable on an ST
```

`mkprg.sh -m` builds the same program but has it drop a `YX6DONE.MRK` file as
it exits; that is how `play.sh` knows the tune has stopped. A plain build never
touches the disk.

The packer's parameters are the ring size and the chunk size:

```
yx6 [-f] [-o] [-nN] [-cC] [-lF] input.ym [output.yx6]
  -nN   ring size per register, in bytes (default 1024)
  -cC   values decoded per call, and the round-robin group size (default 16)
  -lF   loop from frame F, overriding the YM header
  -o    play once: pack no loop section
```

`N` decides how much RAM the player needs (`14 × N`) and how far back the
packer may reference, so it trades memory for compression. `C` must be at least
14 — one refill slot per register — and must divide `N`, which is what lets the
player use ST1_wrap rather than the bigger general ring decoder. The packer
enforces both, packs every stream with `-mN` so no back-reference reaches
outside the ring, and with `-l65535` so no operation outruns the 68000
decoder's word counters.

On a synthetic 1500-frame tune, the fourteen registers pack from 21000 bytes to
about 2300 — the streams for registers that barely change cost a few bytes each.

## Playing it

```
        lea     song,a0                 ; the .yx6 file, loaded anywhere
        lea     workspace,a1            ; even address, YX6_FIXED+(14*N) bytes
        bsr     YX6_init                ; d0 = 0 when the file was accepted
   vbl:                                 ; once per frame, in supervisor mode
        lea     workspace,a0
        bsr     YX6_play                ; d0 = 0 played, 1 wrapped, -1 ended
        bsr     YX6_stop                ; silence the three voices
```

`YX6_play` clobbers `d0`–`d5` and `a0`–`a3`, and leaves `d6`, `d7` and
`a4`–`a6` alone, the same promise ST1 makes. Include both `YX6.S` and
`ST1_wrap.S`; the order does not matter.

### The schedule

A tune is `O` frames long. Each register owns a ring of `N` bytes and a saved
decoder state. On every VBL the player reads one value from each of the
fourteen rings and refills exactly one register — register `k` on the frame
where `frame mod C` is `k`:

```text
VBL  0: use value  0 from every register; refill R0
VBL  1: use value  1 from every register; refill R1
...
VBL 13: use value 13 from every register; refill R13
VBL 14: use value 14 from every register; no refill
VBL 15: use value 15 from every register; no refill
```

Every register is therefore one full group ahead of what is being read, and the
work per frame is flat: fourteen register writes plus one 16-byte decoder call.
The player counts the calls itself and wraps a ring's write pointer when it
lands on the ring end, which is exactly ST1_wrap's contract — there is no DONE
state to poll and no bound check inside the decoder.

### Looping

A ZX1 stream can only be restarted from its beginning, so a looping tune is
packed as two sets of streams split at the loop frame `L`: an intro covering
frames `[0, L)` and a loop covering `[L, O)`. When a register's section runs
out mid-refill the player starts its loop stream over — a fresh decoder writing
on into the same ring — so the rings hold one continuous sequence and the read
side never learns that anything happened. Nothing requires `L` to fall on a
group boundary; a refill that straddles the split just decodes two pieces.

`YX6_play` returns 1 on the frame that ends the tune (the next one is `L`), so
a caller can count passes. A tune packed with `-o` has no loop section: after
its last frame `YX6_play` returns -1 and writes nothing.

The loop frame comes from the YM header by default. The split costs a little
compression, since the loop half cannot reference the intro half — nothing at
all for a tune that loops from frame 0, and about 19% on the synthetic test
tune when it loops from the middle.

### Writing the chip

The fourteen writes are unrolled through a `YX6_WRITE` macro, one invocation per
register, so the register number is an assembled-in immediate and the value goes
straight from the ring to the chip without passing through a data register:

```
        move.b  #\number,(a2)          ; select
        move.b  (a1),2(a2)              ; and write
        adda.l  d3,a1                   ; on to the next register's ring
```

Two registers are not written that way. R7 gets the ST's I/O port direction bits
(`$C0`) back, because on an ST port A drives the floppy select lines. R13 is
skipped entirely on a frame whose value is `$FF`, the YM marker for "leave the
envelope alone" — writing it would restart the envelope.

Skipping registers whose value has not changed — the obvious next trick — was
measured and **dropped**: on an ST a sound-chip access costs only about 1.5
cycles more than a RAM one (32 vs 27 ticks for 56000 stores, against 12 for the
bare loop), so the compare that would save a write costs about as much as the
write.

The burst runs with interrupts masked. Selecting a register and writing it are
two bus cycles, and TOS's own handlers use the sound chip in between — its
floppy motor timeout writes port A. Without the mask a write can land on
whatever register the interrupt selected. It costs about 24 cycles a frame.

## What v1.0 does not do

* **No effects.** The packer masks the YM6 effect bits out of the register
  values and warns when it drops digidrum samples. A tune that leans on SID
  voices or digidrums will play, but thinner than it should.
* **Trusted input.** Beyond the magic, version and stream count, the player
  checks nothing, like the ST1 decoders it is built on.

## The `.yx6` container

Big-endian, fixed header, then the packed streams in register order:

| offset | size | field |
|---:|---:|---|
| 0 | 4 | `'YX6!'` |
| 4 | 2 | format version (2) |
| 6 | 2 | flags: bit 0 set when the tune loops |
| 8 | 4 | `O`, the frame count |
| 12 | 2 | player frequency in Hz |
| 14 | 2 | `S`, the stream count (14) |
| 16 | 2 | `N`, the ring size |
| 18 | 2 | `C`, values per call |
| 20 | 4 | `L`, the loop frame; equal to `O` when the tune plays once |
| 24 | 4 | YM master clock (informational) |
| 28 | 4·S | byte offset of each intro stream, covering frames `[0, L)` |
| 84 | 4·S | byte offset of each loop stream, covering frames `[L, O)` |
| 140 | … | the packed streams |

Packed sizes are not stored: ST1 counts output bytes, not input bytes, so the
player never needs them.

## Tests

```sh
mvn test                                  # the packer: format, masking, shapes
python3 yx6/test/emu/test_yx6.py          # the player, against the YM data
HATARI=... TOS=... yx6/test/run.sh        # the player, on emulated hardware
```

[test_yx6.py](test/emu/test_yx6.py) packs a synthetic tune with the real Java
tool, assembles YX6.S with ST1_wrap.S, runs the player under Unicorn as a plain
68000 and captures every write to `$FFFF8800`. What must match is the **chip's
contents** after each frame — computed from the YM data with no knowledge of the
packer or the player — plus the R13 writes themselves, since those restart the
envelope and are observable in their own right. It covers the default 1024/16
shape, a 256-byte ring, the smallest ring that holds two groups, 64-value calls,
the tightest legal 28/14 shape, tunes shorter than a ring, a group and a single
frame, a loop point that is not on a group boundary, a loop section shorter than
one group, several passes round the loop, playing a `-o` tune past its end, and
re-initialising for a second pass.

[test/run.sh](test/run.sh) goes further than emulation can: it plays a looping
tune on the emulated chip and **reads all fourteen registers back off the YM2149
after every frame**, folding them into a checksum the host computed from the YM
data alone, and past the end so the loop is crossed. It then replays the tune
and reports the cost:

```text
SUM=OK wraps=1 sum=2941391492
CALIB 12 241
T 1700 90
```

90 ticks of the 200 Hz clock for 1700 frames, with the calibration loop's
7,864,630 cycles measured at 241 ticks, works out at about **1,730 cycles per
frame** — roughly 1.1% of a 50 Hz frame on an 8 MHz ST, including the harness's
own loop and the sound chip's bus wait states. Measure your own tune before
budgeting: the byte limit is not a time limit, and how hard a chunk is to
decode depends on the data.

Most of what is left is the decoder itself: at `C=16` a refill decodes 16 bytes
on fourteen frames out of every sixteen. Raising `C` amortises the per-call cost
over more bytes — `-c32` saves roughly another 6% on average — at the price of a
refill frame that costs twice as much, which is the wrong trade if your frame
budget is tight.

The harness masks interrupts while it verifies, and so should anything that
reads the chip back: selecting a register and reading it are two bus cycles, and
TOS's own handlers use the sound chip between them.
