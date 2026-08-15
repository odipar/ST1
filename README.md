# jx1 — the Java version of ZX1

jx1 is a Java port of [ZX1](https://github.com/einar-saukas/ZX1) v1.5 by
Einar Saukas. It includes compatible command-line tools, a resumable Java
decompressor, and three small 68000 decompressors.

The Java additions are:

* `jx1 -mN` limits encoded back-references; `djx1 -mN` selects an N-byte
  decode ring and requires every encoded offset to fit it.
* `-lN` limits operation lengths; use `-l65535` for the 68000 decoders.
* `Decompressor.resume()` emits at most a caller-selected chunk per call.
* `Decompressor` writes through a caller-supplied ring buffer and `flip` hook.

## Compatibility with ZX1

The encoding is unchanged: every jx1 stream is a ZX1 stream and vice versa.
With no options, jx1 produces byte-identical output to the original C
compressor. `-mN` changes the parse and `-lN` splits emitted matches; neither
changes the format.

[68k/test/emu/compat.py](68k/test/emu/compat.py) builds `zx1` and `dzx1` from
[c/zx1/src](c/zx1/src), compares both compressors, cross-decompresses their
output, and checks the 68000 decoders on a C-produced stream.

## Usage

```sh
mvn package
java -ea -cp target/classes org.jx1.Jx1  [-f] [-b] [-q] [-mN] [-lN] input [output.zx1]
java -ea -cp target/classes org.jx1.Djx1 [-f] [-mN] input.zx1 [output]
```

Or run through Maven, which starts a forked JVM with assertions enabled:

```sh
mvn -q compile exec:exec@jx1  -Dargs="[-f] [-b] [-q] [-mN] [-lN] input [output.zx1]"
mvn -q compile exec:exec@djx1 -Dargs="[-f] [-mN] input.zx1 [output]"
```

Malformed-input validation uses Java `assert`, so use `-ea` when invoking the
classes directly.

## Java decompression API

`Decompressor` takes compressed input, an external ring buffer, and optionally
a chunk size X. Each `resume()` emits at most X bytes and returns `false` once
the stream is complete:

```java
while (decompressor.resume()) {
    // work between chunks
}
```

When the ring fills, the abstract `flip(buffer, length)` method decides where
its bytes go; the static `decompress` helpers collect them in memory. Instances
have no global state and can be reset and reused.

## The 68k decompressors

All three files are position-independent, ROM-safe, and keep their entire
state in registers:

| File | Code | Output | Entries |
|---|---:|---|---|
| [jx1_68000.S](68k/jx1_68000.S) | 206 B | linear buffer containing the whole output and match window | `jx1_init`, `jx1_decompress`, `jx1_resume` |
| [jx1_68000_ring.S](68k/jx1_68000_ring.S) | 252 B | arbitrary caller-supplied ring of N bytes | `jx1_init`, `jx1_resume` |
| [jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) | 212 B | aligned power-of-two ring with fixed budget X | `jx1_init`, `jx1_resume` |

Entries are four-byte jump slots in table order. Use the linear decoder unless
output must pass through bounded memory; ring decoders have no one-shot entry
because the caller must drain them.

### Trusted input only

The 68000 decoders validate nothing: not the stream, input end, destination,
or parameters. Malformed input can read or write arbitrary memory. They are
for trusted assets produced at build time; otherwise validate the stream and
decompressed length first or decode it in an isolated environment.

Their required contracts are:

* Each literal run or match is at most 65535 bytes. Compress with
  `jx1 -l65535`; over-long matches are split. An over-long literal run is
  reported but cannot be split, so that output is not 68000-safe.
* Every resume budget is in 1..65535. A zero budget makes no progress and can
  spin a drain loop forever.
* A ring has a valid size for its selected decoder, and no stream offset
  exceeds it. For N below 32512, compress with the matching `-mN`; rings of
  at least 32512 bytes cover the format's full offset range.
* Input, output, and the five state registers remain valid for the full decode.

### Calling convention

There is no context block. Preserve these five state registers between calls,
apart from the documented `a1` wrap required by a ring decoder:

| Register | Role |
|---|---|
| `a0.l` | input position |
| `a1.l` | write pointer; end of output produced so far |
| `d0.b` | bit queue |
| `d1.w` | bytes remaining; zero on return from `jx1_resume` means done |
| `d2.w` | signed offset/state: `+lastOffset` in LITERALS, `-lastOffset` in MATCH |

With `d1.w = 0`, `d2.w = -1` means START and zero means DONE. After
initialization, the linear and `ring_mod` resume entries preserve the unused
high parts of `d0`, `d1`, and `d2`. The general ring instead keeps N in
`d1.high` and `end.low` in `d2.high`, so its full `d1.l` and `d2.l` are state.

For the linear and `ring_mod` decoders, initialize with the stream in `a0` and
destination in `a1`. General-ring initialization additionally takes its
one-past-end pointer in `d3.l`. Thereafter, every `jx1_resume` takes a fresh
budget in `d3.w`; the call spends it rather than refilling it.

All three clobber `d3.w`, `d4.l`, `d5.l`, and `a2.l`. They preserve `d6`,
`d7`, `a3`–`a6`, and the stack beyond the return address.

Linear example:

```
        lea     stream,a0
        lea     output,a1
        bsr     jx1_init
.loop:
        moveq   #16,d3
        bsr     jx1_resume
        ; consume or inspect output ending at a1
        tst.w   d1
        bne.s   .loop
```

`jx1_decompress` is the linear one-shot convenience. It takes the stream in
`a0`, destination in `a1`, and returns with `a1` at the output end. The linear
destination must hold everything decompressed so far because it is also the
match window. Polling a completed stream remains harmless and leaves
`d1.w = 0`.

### General ring

[jx1_68000_ring.S](68k/jx1_68000_ring.S) accepts any alignment, N in
1..65535, and a nonzero word budget that may vary between calls. Initialization
packs the ring metadata, so no persistent bound register is needed.

```
        lea     stream,a0
        lea     ring,a3                 ; caller-held start
        lea     ring+4096,a4            ; caller-held end
        movea.l a3,a1
        move.l  a4,d3                   ; init-only end parameter
        bsr     jx1_init
.loop:
        move.l  a1,-(sp)                ; span start
        moveq   #16,d3
        bsr     jx1_resume
        movea.l (sp)+,a2
        ; consume [a2 .. a1)
        cmpa.l  a4,a1
        bne.s   .more
        movea.l a3,a1                   ; drained: wrap before next call
.more:
        tst.w   d1
        bne.s   .loop
```

The decoder may instead receive `a1` left at the end and wrap it on the next
entry. Explicit wrapping is safer for callers that save each produced span's
start. A boundary call can be shorter than its requested budget, so use the
saved and returned pointers rather than assuming X bytes were emitted.

Destination room and `position = N + destination - end` are computed modulo
65536. Because N is at most 65535, both values are exact even when the ring
crosses a 64-K boundary. A borrow from `position - offset` detects a wrapped
match source, which is brought back into the ring by adding zero-extended N.

An N-byte ring supports offsets through `min(N, 32512)`. For N below 32512,
compress with `-mN`; larger rings already cover the format's full range. The
decoder clamps once at call entry and splits only a match whose source reaches
the ring end, so bounds work is per call or match segment, not per byte.

### Power-of-two fixed-budget ring

[jx1_68000_ring_mod.S](68k/jx1_68000_ring_mod.S) removes more ring arithmetic
when all of these promises hold:

* `RING_SIZE` is assembled as a power of two from 1 through 32768.
* The ring base is aligned to `RING_SIZE`.
* Every call uses the same nonzero budget X, and X divides `RING_SIZE`.
* For `RING_SIZE < 32768`, the stream was compressed with
  `-m<RING_SIZE>`; 32768 covers the format's full 32512-byte offset range.

```
        ; assemble with RING_SIZE=4096; align ring to 4096
        lea     stream,a0
        lea     ring,a3
        movea.l a3,a1
        bsr     jx1_init
.loop:
        moveq   #16,d3                  ; fixed X; X divides RING_SIZE
        bsr     jx1_resume
        moveq   #16,d5
        sub.w   d3,d5                   ; emitted = requested - unspent
        movea.l a1,a4
        suba.l  d5,a4
        ; consume [a4 .. a1)
        tst.w   d1
        beq.s   .done
        move.w  a1,d5
        and.w   #RING_SIZE-1,d5
        bne.s   .loop
        movea.l a3,a1                   ; full and drained
        bra.s   .loop
.done:
```

Every non-final call emits exactly X bytes. The final call emits the remainder,
or a full X when the total output is divisible by X. Violating any alignment,
size, or fixed-budget promise is undefined; use the general ring when those
constraints are unsuitable.

### Testing

The hardware suite assembles fresh TOS programs, verifies every output byte,
and runs under cycle-exact Hatari or on an Atari ST:

```sh
mvn compile
HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh
```

Current raw 200 Hz ticks at X=16, in corpus order
`text/wordsoup/farmatch/period129/allsame/rle32k/maxoffset`:

| Decoder | N/X | ST ticks |
|---|---|---|
| linear | —/16 | 125/140/123/152/144/133/139 |
| general ring | 1024/16 | 145/176/145/178/170/159/155 |
| `ring_mod` | 256/16 | 144/174/142/178/167/156/153 |
| `ring_mod` | 1024/16 | 141/171/139/172/163/153/152 |

[68k/test/README.md](68k/test/README.md) documents the correctness matrix,
boundary and ABI checks, emulator limitations, and measurement method.

## Layout

| Class | Origin |
|---|---|
| `Block`, `Optimizer` | `zx1.h`, `memory.c`, `optimize.c` |
| `Compressor` | `compress.c` |
| `Decompressor` | `dzx1.c`, restructured around resumable ring output |
| `Jx1` | the `zx1` tool plus `-mN` and `-lN` |
| `Djx1` | the `dzx1` tool plus `-mN` |

Tagged versions are available from [GitHub Releases](https://github.com/odipar/jx1/releases).

## License

Dual, following the original ZX1 (see [LICENSE](LICENSE)): the compressor is
BSD 3-Clause; the decompressors may be used freely, including commercially,
when their documentation says ZX1/jx1 was used. The ZX1 format and algorithm
are by Einar Saukas. The additions are © 2026 Robbert van Dalen; the jx1 code
and experiments were written by Claude (Anthropic's Claude Code) under his
direction.
