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
python3 68k/test/emu/boundaries.py            # exact operation-length limits
python3 68k/test/emu/align68k.py              # odd-address audit, linear
python3 68k/test/emu/align_ring2.py jx1_68000_ring.bin pow2   # ...and ring
python3 68k/test/emu/poison.py                # the ABI's clobbered registers
python3 68k/test/emu/audit.py                 # 113 doc-vs-code claims
python3 68k/test/emu/compat.py                # jx1 vs the original C zx1
```

Every script runs its whole matrix by default and the nine runs together take
**about 25 seconds**, so there is no reason to run a subset; `--quick` exists
anyway, and drops the combinations whose cost is calls rather than coverage (a
32 KB corpus through a 1-byte ring is 32000 emulated calls). Almost all of
that time is emulation: compressing the two 32 KB corpora costs 12 of the 13
seconds of a cold run, and optimal parsing is quadratic-ish in the match
window, so the streams are cached in `.streams/` under a key that covers both
the corpus bytes and the compiled compressor — recompile the Java side and
every stream is regenerated. `compat.py` caches the same way, keyed on the
compiled C reference as well, and builds that reference once (a cold first run
is about 80 seconds, almost all of it the two compressors working).

Each script takes a binary name and assembles `68k/<name>.S` if it is not
already present, so `test_ring2.py jx1_68000_ring.bin` runs the general ring
through `ring_mod`'s dividing-shape matrix. The reverse does not hold: the
general suite's non-dividing shapes are outside `ring_mod`'s contract, and it
reports failures there by design.

## What they check beyond "the output matches"

* **`poison.py`** checks the register contract from both ends. It fills the
  clobbered registers — `d5`, `d6`, `a4` — with junk before every call, since
  a caller may legally pass anything in them; a partial-register bug in both
  ring decoders survived months of testing because every harness politely
  passed clean ones. Then it does the converse: it canaries every register
  the contract does not call state (including newly freed `d2`) and checks that a call destroys **exactly**
  `d4`, `d5`, `d6` and `a4`. The two ring suites poison as a matter of course
  now.
* **`align68k.py` / `align_ring2.py`** hook every memory access and reject a
  `.w`/`.l` at an odd address. A real 68000 raises an address error there;
  Unicorn does not, so without this the emulator would happily bless code
  that faults on hardware.
* **`boundaries.py`** hand-authors streams containing one operation of an
  exact length. The corpora top out at 32000 bytes, so nothing else here can
  reach the point where an operation's length stops fitting a word; this pins
  it at 65535 on all four decode paths, and checks that `jx1 -l65535` produces
  streams that stay inside it. Every hand-authored stream is validated against
  the Java decompressor first — if the reference cannot read it, no 68k result
  from it means anything.
* **`test_ring*.py`** additionally require that nothing is ever written
  outside the ring, that the write pointer never wraps inside a call, that
  `a2`/`a3`/`d2`/`d7`/`a6` come back untouched, that a finished stream stays
  finished, and — for `ring_mod` — that every call but the last emits
  exactly one chunk. They drive the interface the way the documentation
  describes it: `a1` in and out, wrapped by the caller when it reaches the
  end of the ring.
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
  field at all, that every header states the clobbered set, jump-table slots
  against the documented entries, no `cmp.l` on a data register, the state
  encoding the entry dispatch relies on, and that the harnesses still poison
  and still fail on `BAD`.

The hardware harness in the parent directory covers what emulation cannot:
real 68000 timing, and address errors actually faulting.
