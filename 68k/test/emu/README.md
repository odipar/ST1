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
python3 68k/test/emu/test_ring_gen.py         # ring: 13 corpora × 16 shapes
python3 68k/test/emu/test_ring2.py            # ring_mod: dividing shapes only
python3 68k/test/emu/align68k.py              # odd-address audit, linear
python3 68k/test/emu/align_ring2.py jx1_68000_ring.bin pow2   # ...and ring
python3 68k/test/emu/poison.py                # the ABI's clobbered registers
python3 68k/test/emu/audit.py                 # 67 doc-vs-code claims
```

Each takes a binary name and assembles `68k/<name>.S` if it is not already
present, so `test_ring_gen.py jx1_68000_ring_mod.bin` runs the general-ring
suite against the other decoder. **The ring suites take a few minutes** —
they run several hundred full decodes, including 32 KB corpora through
1-byte rings.

## What they check beyond "the output matches"

* **`poison.py`** fills `d0-d5` with junk before every call. jx1 declares
  those registers clobbered, which says nothing about their *incoming*
  values, so a caller may legally pass anything in them. A partial-register
  bug in both ring decoders survived months of testing because every harness
  politely passed clean registers; this is the script that reproduces it.
  The two ring suites poison as a matter of course now.
* **`align68k.py` / `align_ring2.py`** hook every memory access and reject a
  `.w`/`.l` at an odd address. A real 68000 raises an address error there;
  Unicorn does not, so without this the emulator would happily bless code
  that faults on hardware.
* **`test_ring*.py`** additionally require that nothing is ever written
  outside the ring, that the write pointer never wraps inside a call, that
  `a3`/`a4`/`d6`/`d7` come back untouched, that a finished stream stays
  finished, and — for `ring_mod` — that every call but the last emits
  exactly one chunk.
* **`audit.py`** checks the documentation against the sources: assembled
  sizes and context sizes against the README's table, jump-table slots
  against the documented entries, no `cmp.l` on a data register, the state
  encoding the entry dispatch relies on, and that the harnesses still poison
  and still fail on `BAD`.

The hardware harness in the parent directory covers what emulation cannot:
real 68000 timing, and address errors actually faulting.
