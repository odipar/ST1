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
python3 68k/test/emu/boundaries.py            # exact operation-length limits
python3 68k/test/emu/align68k.py              # odd-address audit, linear
python3 68k/test/emu/align_ring2.py jx1_68000_ring.bin
python3 68k/test/emu/poison.py jx1_68000.bin linear
python3 68k/test/emu/poison.py jx1_68000_ring.bin
python3 68k/test/emu/audit.py                 # doc-vs-code claims
python3 68k/test/emu/cycle_model.py --check   # current ideal-cycle tables
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
already present. The ring suite covers arbitrary alignment, power-of-two and
non-power-of-two sizes, and dividing and non-dividing budgets.

## What they check beyond "the output matches"

* **`poison.py`** checks the common register contract from both ends. Both
  decoders keep their state in `a0.l`/`a1.l` and `d0.b`/`d1.w`/`d2.w`, take
  and spend the per-call budget in `d3.w`, and use `d4`/`d5`/`a2` as scratch.
  The test fills those scratch registers, plus the ignored high word of `d3`,
  with junk before every call. Then it does the converse: it canaries every
  non-state register before each call and unions the changes over a mixed
  stream. The observed set must be exactly `d3`/`d4`/`d5`/`a2`; `d6`/`d7`
  and `a3`-`a6` must survive every path. Both get a canary in the caller-owned
  upper 24 bits of `d0`; linear also gets canaries in the caller-owned high
  words of `d1` and `d2`. The ring uses those two high words for packed bounds.
* **`align68k.py` / `align_ring2.py`** hook every memory access and reject a
  `.w`/`.l` at an odd address. A real 68000 raises an address error there;
  Unicorn does not, so without this the emulator would happily bless code
  that faults on hardware. The ring is tested at even and odd bases.
* **`boundaries.py`** hand-authors streams containing one operation of an
  exact length. The corpora top out at 32000 bytes, so nothing else here can
  reach the point where an operation's length stops fitting a word; this pins
  it at 65535 on all three decode paths, and checks that `jx1 -l65535` produces
  streams that stay inside it. Every hand-authored stream is validated against
  the Java decompressor first — if the reference cannot read it, no 68k result
  from it means anything. It also places the N=65535 general ring across a
  64 KB address boundary and fills it in both caller- and decoder-wrap modes.
* **`test_ring_gen.py`** additionally requires that nothing is ever written
  outside the ring, that the write pointer never wraps inside a call, that
  the common preserved registers come back untouched, and that a finished
  stream stays finished. At general-ring init only, `d3.l` supplies the end
  pointer; init packs `-start.low` into `d1.high` and the end pointer's low
  word into `d2.high`, leaving no persistent bound register. The general suite
  checks both packed values throughout its 19 caller-wrap and decoder-wrap
  shapes.
* **`compat.py`** is the only script here whose reference is not jx1. It
  builds `zx1` and `dzx1` from `c/zx1/src` and checks that jx1's output
  matches the C compressor's byte for byte, that each side decompresses the
  other, that the `-mN` and `-lN` options still produce streams C can read,
  and — the part that belongs to this directory — that both 68000
  decoders decode a stream the C compressor produced. Everything else here
  checks jx1 against jx1, where a shared misunderstanding of the format would
  pass unnoticed.
* **`audit.py`** checks the documentation against the sources: assembled
  sizes against the README's table, that no decoder names `a5` or a context
  field at all, that every header states the common clobbered set,
  jump-table slots against the documented entries, ring shape declarations,
  no `cmp.l` on a data register, no wider-than-byte `d0` access
  during resume, the state encoding the entry dispatch relies on, and that the
  harnesses still poison and still fail on `BAD`. It also rejects timing tables
  whose decoder, compressor, corpus, model or hardware-harness inputs changed;
  `cycle_model.py --check` reruns the full instruction trace.

The hardware harness in the parent directory covers what emulation cannot:
real 68000 timing, and address errors actually faulting.
