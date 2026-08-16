# YX6 — streaming YM chiptunes on a plain 68000

YX6 is the player the root README sketches: a YM tune packed as fourteen ZX1
streams, one per sound register, each decoded through its own small ring by
[ST1_wrap.S](../68k/ST1_wrap.S). The music never exists in memory as a whole —
only fourteen rings of a few hundred bytes, refilled one register per frame.

It is a MinYMiser-style player built on ST1, and version 0.1 plays the fourteen
standard YM2149 registers. The YM6 special effects (SID voice, digidrum,
sinus-SID, sync-buzzer) are **not** played.

| Piece | What it is |
|---|---|
| [`org.yx6.Yx6`](../src/main/java/org/yx6/Yx6.java) | the packer: YM5!/YM6! in, `.yx6` out |
| [YX6.S](YX6.S) | the player library, 466 bytes plus ST1_wrap's 222 |
| [YX6_player.S](YX6_player.S) | a VBL front end: a complete TOS program |
| [mkprg.sh](mkprg.sh) | links the two around a song into a runnable `.PRG` |

## Making a tune

Distributed `.ym` files are LHA archives; unpack one first. Then:

```sh
mvn -q compile exec:exec@yx6 -Dargs="-f song.ym song.yx6"
yx6/mkprg.sh song.yx6                 # -> SONG.PRG, runnable on an ST
```

The packer's parameters are the ring size and the chunk size:

```
yx6 [-f] [-nN] [-cC] input.ym [output.yx6]
  -nN   ring size per register, in bytes (default 1024)
  -cC   values decoded per call, and the round-robin group size (default 16)
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
        bsr     YX6_play                ; d0 = 0 playing, 1 when the tune ended
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

Two register values are not written straight through. R7 gets the ST's I/O port
direction bits (`$C0`) back, because on an ST port A drives the floppy select
lines. R13 is skipped entirely on a frame whose value is `$FF`, the YM marker
for "leave the envelope alone" — writing it would restart the envelope.

## What v0.1 does not do

* **No effects.** The packer masks the YM6 effect bits out of the register
  values and warns when it drops digidrum samples. A tune that leans on SID
  voices or digidrums will play, but thinner than it should.
* **No loop point.** The file records the YM loop frame, but the player stops
  at the end and reports it. Call `YX6_init` again to play from the start.
* **Trusted input.** Beyond the magic, version and stream count, the player
  checks nothing, like the ST1 decoders it is built on.

## The `.yx6` container

Big-endian, fixed header, then the packed streams in register order:

| offset | size | field |
|---:|---:|---|
| 0 | 4 | `'YX6!'` |
| 4 | 2 | format version (1) |
| 6 | 2 | flags (0) |
| 8 | 4 | `O`, the frame count |
| 12 | 2 | player frequency in Hz |
| 14 | 2 | `S`, the stream count (14) |
| 16 | 2 | `N`, the ring size |
| 18 | 2 | `C`, values per call |
| 20 | 4 | loop frame (informational) |
| 24 | 4 | YM master clock (informational) |
| 28 | 4·S | byte offset of each stream from the start of the file |
| 84 | … | the packed streams |

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
68000 and captures every write to `$FFFF8800`. The captured register/value
pairs must match, frame by frame and in order, what the generator says a YM2149
should have received — computed from the YM data with no knowledge of the
packer or the player. It covers the default 1024/16 shape, a 256-byte ring, the
smallest ring that holds two groups, 64-value calls, the tightest legal 28/14
shape, tunes shorter than a ring, a group and a single frame, playing past the
end, and re-initialising for a second pass.

[test/run.sh](test/run.sh) goes further than emulation can: it plays the tune on
the emulated chip and **reads all fourteen registers back off the YM2149 after
every frame**, folding them into a checksum the host computed from the YM data
alone. It then replays the tune and reports the cost:

```text
SUM=OK
CALIB 12 241
T 1500 105
```

105 ticks of the 200 Hz clock for 1500 frames, with the calibration loop's
7,864,630 cycles measured at 241 ticks, works out at about **2,280 cycles per
frame** — roughly 1.4% of a 50 Hz frame on an 8 MHz ST, including the harness's
own loop and the sound chip's bus wait states. Measure your own tune before
budgeting: the byte limit is not a time limit, and how hard a chunk is to
decode depends on the data.
