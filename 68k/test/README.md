# Tests

Two layers. [emu/](emu/) is the differential suite under emulation — every
correctness claim about the decompressors comes from there, and it needs only
Python, Unicorn and rmac. This directory is the hardware layer, covering what
emulation cannot: real 68000 timing, and address errors that actually fault.

# Real-hardware validation

Two TOS programs exercise the decompressors on a real 68000 — under
[Hatari](https://hatari.tuxfamily.org/)'s cycle-exact Atari ST emulation, or on
actual silicon (`rmac -p` emits a plain `.PRG`; copy it to a floppy or Gotek
and run it). Both decompress embedded jx1 streams, verify every byte, and
measure decode time with the system's 200 Hz tick:

* [jx1_hatari.S](jx1_hatari.S) — [../jx1_68000.S](../jx1_68000.S), the linear
  decompressor
* [jx1_hatari_ring.S](jx1_hatari_ring.S) — the ring decompressors, streaming
  each corpus through several ring/chunk shapes. It builds twice:
  `-dRINGMOD=0` for [../jx1_68000_ring.S](../jx1_68000_ring.S) with dividing
  and non-dividing shapes, and `-dRINGMOD=1` for
  [../jx1_68000_ring_mod.S](../jx1_68000_ring_mod.S) with the dividing shapes
  its contract requires. Nothing is accumulated: each call's output is
  compared against the expected image as it is drained, and the wrap is
  detected the way the interface intends (`a1 == a3`). The point of the
  feature is visible here — 32000 bytes decompressed through a 256-byte
  buffer.

```sh
mvn compile                 # in the repo root: the compressor makes the streams
HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh
```

`run.sh` generates the corpora ([gendata.py](gendata.py) — the same seven the
emulator rig uses, same RNG stream, plus a `-m256` stream per corpus for the
ring), assembles both programs with `rmac -p +o3`, and runs them under Hatari
headless with console output on stdout.

> **On `+o3`:** it used to matter — `jx1_68000.S` wrote
> `move.l d1,ctx_packed(a5)` with `ctx_packed = 0`, which vasm folded to
> `(a5)` on its own and rmac only with `+o3`. The packed `movem.l`
> initializer removed that operand, so rmac and vasm now agree byte for byte
> either way. The flag is kept because it costs nothing and the next such
> operand would otherwise cost two bytes silently.

## The corpora

Seven cases, the same ones (and the same RNG stream) the emulator rig uses.
Each is embedded twice: compressed normally, and compressed with `-m256` so
every offset fits the smallest ring the harness tests.

| corpus | output | stream | stream (`-m256`) | what it exercises |
|---|---|---|---|---|
| text | 360 | 28 | 28 | short gammas, literals and matches mixed |
| wordsoup | 2925 | 818 | 1203 | parse-heavy: many short ops |
| farmatch | 2900 | 212 | 410 | two-byte offsets |
| period129 | 1032 | 138 | 138 | the one/two-byte offset boundary |
| allsame | 1000 | 6 | 6 | one long match |
| rle32k | 32000 | 7 | 7 | ops near the 32K `dbf`/word limit |
| maxoffset | 33012 | 32589 | 33121 | offsets up to 32512; barely compressible |

"output" is the decompressed size — what the decompressor produces and what
the cycle counts below are spent on. Note `maxoffset` at `-m256` *expands*
(33121 > 33012): a 256-byte window on random data is nearly all literals,
which is exactly the ratio cost of a small ring.

Both harnesses fill **the clobbered registers with junk before every
`jx1_resume`** — `d5`, `d6` and `a4`, which is all a caller may scribble on
now that the parse state lives in `a0`/`a1` and `d0`/`d1`/`d3` between calls.
The ABI promises nothing about their incoming values, so this is what a legal
caller may look like, and a decoder that reads their upper words is broken.
That check is what a partial-register bug in both ring decoders escaped for
want of, until an external audit found it.

## What it checks that emulation cannot

Each corpus is decompressed one-shot, resumed at chunk 16, 127 and 1, and then
one-shot into an **odd destination address**. A real 68000 raises an address
error on a misaligned word access, so that last case proves no copy path ever
widened its byte moves — Unicorn does not fault odd `.w`/`.l` accesses, so this
class of bug is invisible to the emulator rig.

Result: **all cases pass**, at every chunk size, at both destination parities.

## The ring's per-call contract, checked on hardware

The ring program runs 35 configurations (7 corpora × 5 ring/chunk shapes) and
checks every byte against the expected image — but it also verifies the
documented per-call size contract, which is where the ring/chunk ratio
matters:

| shape | ring % chunk | expected |
|---|---|---|
| R256/16 | 0 | every call a full chunk |
| R1024/16 | 0 | every call a full chunk |
| R256/127 | 2 | short calls at the wrap |
| R1000/16 | 8 | short calls at the wrap (and a ring that is not a power of two) |
| R1024/127 | 8 | short calls at the wrap |

`jx1_68000_ring_mod.S` requires the chunk to divide the ring, so its build
runs only dividing shapes — 256/16, 256/64, 1000/125, 1016/127, 1024/16,
1024/64, seven corpora, 42 configurations — and every one of them must report
`OKf`. It does, which is the fixed-size-output property confirmed on
hardware.

Each call that leaves `d1.w` nonzero must produce exactly the chunk size — unless it ran
into the end of the buffer, which the harness requires to coincide with the
write pointer reaching `a3`, and which it rejects outright when the chunk
divides the ring. The result is reported per shape: **`OKf`** when every call
was a full chunk, **`OKv`** when short calls appeared at the wrap.

```
text      R256/16=OKf R256/127=OKv R1000/16=OKf R1024/16=OKf R1024/127=OKf
wordsoup  R256/16=OKf R256/127=OKv R1000/16=OKv R1024/16=OKf R1024/127=OKv
rle32k    R256/16=OKf R256/127=OKv R1000/16=OKv R1024/16=OKf R1024/127=OKv
```

Every dividing shape reports `OKf`, exactly as documented. The non-dividing
shapes report `OKv` whenever the corpus is big enough to reach a wrap at all —
`text` (360 bytes) never wraps a 1000- or 1024-byte ring, so it stays `OKf`
there, and `allsame` (1000 bytes) exactly fills the 1000-byte ring without
wrapping.

## Timing vs the cycle model

The harness reports raw ticks plus a calibration loop of exactly known cycle
count, so the host can convert without assuming anything about the clock. A
200 Hz tick is 5 ms; at the ST's 8 MHz that is 40000 cycles. Cycles are per
full decode of one corpus: "stream" bytes in, "output" bytes out, at chunk
size X.

| corpus | stream | output | X | model | ST measured | ST vs model |
|---|---|---|---|---|---|---|
| text | 28 | 360 | 16 | 12360 | 13100 | +6.0% |
| text | 28 | 360 | 127 | 7808 | 8300 | +6.3% |
| wordsoup | 818 | 2925 | 16 | 195056 | 205333 | +5.3% |
| wordsoup | 818 | 2925 | 127 | 162134 | 172000 | +6.1% |
| farmatch | 212 | 2900 | 16 | 81514 | 84667 | +3.9% |
| farmatch | 212 | 2900 | 127 | 45180 | 46667 | +3.3% |
| period129 | 138 | 1032 | 16 | 30118 | 31400 | +4.3% |
| period129 | 138 | 1032 | 127 | 17356 | 18200 | +4.9% |
| allsame | 6 | 1000 | 16 | 28424 | 29600 | +4.1% |
| allsame | 6 | 1000 | 127 | 15824 | 16400 | +3.6% |
| rle32k | 7 | 32000 | 16 | 880974 | 913333 | +3.7% |
| rle32k | 7 | 32000 | 127 | 480240 | 493333 | +2.7% |
| maxoffset | 32589 | 33012 | 16 | 919378 | 953333 | +3.7% |
| maxoffset | 32589 | 33012 | 127 | 520550 | 540000 | +3.7% |

The ring decompressor, measured the same way through a 1024-byte ring at
chunk 16 — every corpus except `text`, `allsame` and `period129` being
several times the buffer it streams through — lands in the same band,
**+3.7% to +6.0%** over its model (mean +4.5%):

| corpus | stream | output | ring | X | model | ST measured | ST vs model |
|---|---|---|---|---|---|---|---|
| text | 28 | 360 | 1024 | 16 | 14230 | 15000 | +5.4% |
| wordsoup | 1203 | 2925 | 1024 | 16 | 241446 | 256000 | +6.0% |
| farmatch | 410 | 2900 | 1024 | 16 | 94296 | 98000 | +3.9% |
| period129 | 138 | 1032 | 1024 | 16 | 34744 | 36200 | +4.2% |
| allsame | 6 | 1000 | 1024 | 16 | 33120 | 34600 | +4.5% |
| rle32k | 7 | 32000 | 1024 | 16 | 1035518 | 1073333 | +3.7% |
| maxoffset | 33121 | 33012 | 1024 | 16 | 1025918 | 1066667 | +4.0% |

`jx1_68000_ring_mod.S`, which requires the chunk to divide the ring and
spends that on a cheaper entry, on the same shape. Its model column includes
**the caller's wrap** (`cmpa.l a3,a1 / bne.s / movea.l a2,a1`), since that
decoder does not wrap for you and the timed loop therefore executes it:

| corpus | stream | output | ring | X | model | ST measured | ST vs model |
|---|---|---|---|---|---|---|---|
| text | 28 | 360 | 1024 | 16 | 13724 | 14500 | +5.7% |
| wordsoup | 1203 | 2925 | 1024 | 16 | 237432 | 252000 | +6.1% |
| farmatch | 410 | 2900 | 1024 | 16 | 90304 | 93333 | +3.4% |
| period129 | 138 | 1032 | 1024 | 16 | 33320 | 34600 | +3.8% |
| allsame | 6 | 1000 | 1024 | 16 | 31734 | 33000 | +4.0% |
| rle32k | 7 | 32000 | 1024 | 16 | 991704 | 1026667 | +3.5% |
| maxoffset | 33121 | 33012 | 1024 | 16 | 980702 | 1013333 | +3.3% |

Same band (+3.3% to +6.1%, mean +4.3%). Side by side, in raw ticks:

| corpus | ring | ring_mod | ring_mod gain |
|---|---|---|---|
| text | 150 | 145 | +3.3% |
| wordsoup | 192 | 189 | +1.6% |
| farmatch | 147 | 140 | +4.8% |
| period129 | 181 | 173 | +4.4% |
| allsame | 173 | 165 | +4.6% |
| rle32k | 161 | 154 | +4.3% |
| maxoffset | 160 | 152 | +5.0% |

(ticks, ring 1024, chunk 16, same corpora and calibration.) Both files carry
the same entry optimisations, so the last column is the divisibility
requirement alone — measured **+1.6% to +5.0%**, against the +1.7% to +4.4%
the cycle model predicts for it, and with the caller's wrap on ring_mod's
side of the ledger.

These tables also **measure optimisation work on hardware rather than
predicting it**, which is worth doing precisely because the honest answer is
often small. The audit-driven round — START dispatched by doubling the state,
the suspend path made the fallthrough, one State.MATCH assignment instead of
two, a dead save dropped at DONE, and the gamma refill moved out of line —
took 8 to 10 bytes off each decoder and measured, on the same corpora and
calibration:

| | before | after | gain |
|---|---|---|---|
| linear, X=16 | 160/175/160/197/187/174/179 | 159/172/160/197/187/174/179 | +0.0% to +1.7% |
| linear, X=127 | 88/135/75/97/88/79/85 | 87/133/74/96/87/79/85 | +0.0% to +1.5% |
| ring 1024/16 | 177/213/177/218/208/194/192 | 175/209/176/216/206/193/190 | +0.5% to +1.9% |
| ring_mod 1024/16 | 171/210/170/210/200/187/184 | 169/205/169/208/198/186/183 | +0.5% to +2.4% |

About **1% on the resumable path** — several rows sit inside the ±1 tick
resolution — for a change set whose real return was 8–10 bytes each and a
correctness fix.

The linear decompressor then took the same write-pointer change the rings
already had, bringing its context to 12 bytes and making all three the same
size — **+1.2% to +3.2%** at chunk 16.

Then the context went away entirely: the parse state lives in the caller's
registers, so a call loads nothing on entry and stores nothing on suspend.
That is the largest single change measured here, and the one with the best
ratio of anything tried — it also took 34 to 48 bytes off each decoder:

| | before | after | gain |
|---|---|---|---|
| linear, X=16 | 155/170/156/191/181/169/174 | 134/157/130/161/152/141/144 | **+7.6% to +17.2%** (mean +14.8%) |
| linear, X=127 | 86/132/74/96/87/78/85 | 83/131/71/91/83/75/81 | +0.8% to +5.2% |
| ring 1024/16 | 175/209/176/216/206/193/190 | 153/196/150/185/176/165/161 | **+6.2% to +15.3%** (mean +13.2%) |
| ring_mod 1024/16 | 169/205/169/208/198/186/183 | 147/192/143/177/169/158/154 | **+6.3% to +15.8%** (mean +13.6%) |

Chunk 127 gains least for the usual reason: eight times fewer calls to save a
per-call cost on. The saving is about 100 cycles per call — an entry that was
a `movem`, a `move.w` and two `move.b`s, and a suspend that was the same in
reverse, both reduced to nothing.

Then the last packed field was unpacked. `d3` had carried lastOffset in its
high word, which cost a `swap` pair on every match segment — **0.11 to 0.40
swaps per output byte** across the corpora, and none at all on `maxoffset`,
which is nearly all literals. Splitting that packed long into remaining in
`d1.w` and lastOffset in `d3.w` removed them:

| | before | after | gain |
|---|---|---|---|
| linear, X=16 | 134/157/130/161/152/141/144 | 132/155/128/158/149/138/144 | +0.0% to +2.1% (mean +1.5%) |
| ring 1024/16 | 153/196/150/185/176/165/161 | 151/193/148/183/174/162/161 | +0.0% to +1.8% (mean +1.2%) |
| ring_mod 1024/16 | 147/192/143/177/169/158/154 | 145/190/141/175/166/155/153 | +0.6% to +1.9% (mean +1.3%) |

Four bytes smaller as well, and `maxoffset` measures **+0.0%** on both the
linear and the general ring — exactly what a corpus with no match segments
should show, which is the useful part of the result. The exception is `jx1_decompress`, which no longer hands
control back 251 times it never needed to: its private budget is now 65535
rather than 127, the same two bytes, worth **+4.2% to +16.3%** (mean +12.4%)
under the model. The resumable entry is unchanged, so the timed rows above do
not show it.

Finally, the last offset absorbed the operation state without absorbing the
remaining count: negative `d3.w` means LITERALS and positive means MATCH;
`d1.w = 0` together with `d3.w = +1/0` means START/DONE. That frees `d2`
without adding instructions to the hot paths. Once DONE was normalized to
`d1.w = 0`, the separate 0/1 result in `d5` was redundant too; testing `d1`
removes one `moveq` from every non-final call. The result is 6 bytes off every
decoder, exactly 4 cycles off each suspension, and 2 cycles off DONE:

| | before | after | gain |
|---|---|---|---|
| linear, X=16 | 132/155/128/158/149/138/144 | 131/154/127/157/148/137/143 | +0.6% to +0.8% |
| linear, X=127 | 83/129/70/91/83/75/81 | 83/129/70/91/82/74/81 | +0.0% to +1.3% |
| ring 1024/16 | 151/193/148/183/174/162/161 | 150/192/147/181/173/161/160 | +0.5% to +1.1% |
| ring_mod 1024/16 | 145/190/141/175/166/155/153 | 145/189/140/173/165/154/152 | +0.0% to +1.1% |

**The model holds.** Real ST decode time runs **+2.7% to +6.3%** above the
idealized 68000 cycle counts (mean +4.4%) — the gap is interrupt service and
video-DMA bus contention, not decoder behaviour. For scale, the harness's own
reference `dbf` loop, whose cycle count is exact by construction, measures
**+22.6%** over its ideal on the same machine, and a `move.b (a0)+,(a1)+` loop
+12.0%: the decompressor loses *less* to the machine than either reference.

The model's *relative* predictions — the thing optimization decisions were
actually made on — hold within **1.3%**: predicted chunk-16 / chunk-127
ratios of 1.31–2.20 against 1.29–2.20 measured.

Measurement resolution is ±1 tick, i.e. 0.4–1.3% per figure; the calibration
loop itself lands on 240 or 241 ticks depending on where the program's code
falls relative to the interrupts. Hatari settings:
`--machine st --cpuclock 8 --cpu-exact on --compatible on` (cycle-exact 68000
with prefetch), plus `--disable-video 1` to run headless — that flag only
suppresses the host window, the shifter still contends for the bus and every
measured tick is identical to a windowed run.
