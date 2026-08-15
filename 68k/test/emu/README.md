# Emulator tests

The differential suite behind every correctness claim about the 68000
decompressors. Each script assembles the decoder with rmac, runs it under
[Unicorn](https://www.unicorn-engine.org/) as a plain 68000, and checks the
output byte-for-byte against the project's own Java compressor — so the
reference is the implementation the format is defined by, not a fixture.

```sh
mvn compile                                   # the compressor makes the streams
pip install unicorn                           # plus rmac on PATH

python3 68k/test/emu/test68k.py               # linear: 13 corpora × chunks
python3 68k/test/emu/test_ring_gen.py         # ring: 13 corpora × 19 shapes
python3 68k/test/emu/test_ring2.py            # ring_mod: 16 compiled N/X shapes
python3 68k/test/emu/boundaries.py            # exact operation-length limits
python3 68k/test/emu/align68k.py              # odd-address audit, linear
python3 68k/test/emu/align_ring2.py jx1_68000_ring.bin
python3 68k/test/emu/align_ring2.py jx1_68000_ring_mod.bin
python3 68k/test/emu/poison.py jx1_68000.bin linear
python3 68k/test/emu/poison.py jx1_68000_ring.bin
python3 68k/test/emu/poison.py jx1_68000_ring_mod.bin
python3 68k/test/emu/audit.py                 # 113 doc-vs-code claims
python3 68k/test/emu/compat.py                # jx1 vs the original C zx1
```

Every script runs its whole matrix by default. `--quick` drops combinations
whose cost is calls rather than coverage (a 32 KB corpus through a 1-byte ring
is 32000 emulated calls). Almost all of the runtime is emulation: compressing
the two 32 KB corpora costs 12 of the 13 seconds of a cold run, and optimal
parsing is quadratic-ish in the match window, so the streams are cached in
`.streams/` under a key that covers both the corpus bytes and the compiled
compressor — recompile the Java side and every stream is regenerated.
`compat.py` caches the same way, keyed on the compiled C reference as well,
and builds that reference once (a cold first run is about 80 seconds, almost
all of it the two compressors working).

Most scripts take a binary name and assemble `68k/<name>.S` if it is not
already present. The fixed-ring suite is deliberately stricter: every tested
power-of-two N is assembled from `jx1_68000_ring_mod.S` with
`-dRING_SIZE=N`, cached under a name such as
`jx1_68000_ring_mod_4096.bin`, and run only with fixed budgets that divide N.
Its ring base is aligned to N. The general suite remains separate because it
also covers arbitrary alignment, non-power-of-two sizes and non-dividing
budgets.

## What they check beyond "the output matches"

* **`poison.py`** checks the register contract from both ends. It fills the
  decoder-specific scratch registers with junk before every call, since a
  caller may legally pass anything in them: `d5`/`d6`/`a4` for linear,
  `d5`/`d6`/`a2` for the general ring, and `d2`/`d5`/`d6` for `ring_mod`.
  Then it does the converse: it canaries every non-state register before each
  call and unions the changes over a mixed stream. The observed sets must be
  exactly those scratch registers plus the spent `d4.w`; a match-only scratch
  such as `ring_mod`'s `d2` need not change on a literal call, while an
  untouched register must survive every path.
* **`align68k.py` / `align_ring2.py`** hook every memory access and reject a
  `.w`/`.l` at an odd address. A real 68000 raises an address error there;
  Unicorn does not, so without this the emulator would happily bless code
  that faults on hardware. The general ring is tested at even and odd bases;
  `ring_mod` is tested at the N-aligned bases its contract requires (including
  both parities when N=1).
* **`boundaries.py`** hand-authors streams containing one operation of an
  exact length. The corpora top out at 32000 bytes, so nothing else here can
  reach the point where an operation's length stops fitting a word; this pins
  it at 65535 on all four decode paths, and checks that `jx1 -l65535` produces
  streams that stay inside it. Every hand-authored stream is validated against
  the Java decompressor first — if the reference cannot read it, no 68k result
  from it means anything.
* **`test_ring*.py`** additionally require that nothing is ever written
  outside the ring, that the write pointer never wraps inside a call, that
  the decoder-specific preserved registers come back untouched, and that a
  finished stream stays finished. The general suite also checks its preserved
  `d2` end bound and packed N in `d1.high`, in both caller-wrap and
  decoder-wrap modes. The fixed suite checks preserved `a2`/`a3`/`a4` and
  requires every continuing call to emit exactly one chunk; its caller wraps
  `a1` when it reaches the end.
* **`compat.py`** is the only script here whose reference is not jx1. It
  builds `zx1` and `dzx1` from `c/zx1/src` and checks that jx1's output
  matches the C compressor's byte for byte, that each side decompresses the
  other, that the `-mN` and `-lN` options still produce streams C can read,
  and — the part that belongs to this directory — that the three 68000
  decoders decode a stream the C compressor produced. Everything else here
  checks jx1 against jx1, where a shared misunderstanding of the format would
  pass unnoticed.
* **`audit.py`** checks the documentation against the sources: assembled
  sizes against the README's table, that no decoder names `a5` or a context
  field at all, that every header states its decoder-specific clobbered set,
  jump-table slots against the documented entries, fixed-ring shape/alignment
  declarations, no `cmp.l` on a data register, the state encoding the entry
  dispatch relies on, and that the harnesses still poison and still fail on
  `BAD`.

The hardware harness in the parent directory covers what emulation cannot:
real 68000 timing, and address errors actually faulting.
