#!/usr/bin/env python3
"""Is jx1 still ZX1?

Four questions, against the original C implementation built from this repo's
own c/zx1/src - not a fixture, and not a binary someone left lying around:

  1. does jx1 produce the same bytes as the C compressor, for the options C
     has? (the format is defined by that output)
  2. does jx1 decompress what C compresses?
  3. does C decompress what jx1 compresses, including the -mN and -lN options
     C does not have? (they change which parse is chosen, never the encoding,
     so the result has to be ordinary ZX1)
  4. do the ST1 decoders decode a stream the C compressor produced?

Question 4 is why this lives with the emulator tests: everything else here
checks jx1 against jx1, so a shared misunderstanding of the format would pass
unnoticed. This is the one script where the reference is somebody else's code.

Usage: compat.py [--quick]
"""
import hashlib
import subprocess
import sys
import tempfile
from pathlib import Path

QUICK = '--quick' in sys.argv
sys.argv = [sys.argv[0]]
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test68k as t                                                    # noqa: E402
import boundaries as b                                                 # noqa: E402
import test_wrap as w                                                  # noqa: E402

REPO = Path(__file__).resolve().parents[3]
CSRC = REPO / 'c' / 'zx1' / 'src'
CACHE = t.CACHE


def build_c():
    """Build zx1/dzx1 from the C sources in this repository."""
    sources = sorted(CSRC.glob('*.c')) + sorted(CSRC.glob('*.h'))
    if not sources:
        raise SystemExit(f'no C sources at {CSRC}')
    h = hashlib.sha1()
    for f in sources:
        h.update(f.read_bytes())
    stamp = h.hexdigest()[:12]
    out = CACHE / f'cref-{stamp}'
    if not (out / 'zx1').exists():
        out.mkdir(parents=True, exist_ok=True)
        common = ['compress.c', 'optimize.c', 'memory.c']
        for exe, files in (('zx1', ['zx1.c'] + common), ('dzx1', ['dzx1.c'])):
            r = subprocess.run(['cc', '-O2', '-o', str(out / exe)]
                               + [str(CSRC / f) for f in files],
                               capture_output=True, text=True)
            if r.returncode:
                raise SystemExit(f'building the C reference failed:\n{r.stdout}{r.stderr}')
    return out / 'zx1', out / 'dzx1'


C_ZX1, C_DZX1 = build_c()
TOOLS = hashlib.sha1(C_ZX1.read_bytes() + C_DZX1.read_bytes()).hexdigest()[:12]


def _cached(tag, data, flags, produce):
    key = CACHE / (f'{tag}-{hashlib.sha1(data).hexdigest()[:16]}'
                   f'-{"".join(flags).replace("-", "_") or "plain"}.bin')
    if key.exists():
        return key.read_bytes() or None
    out = produce() or b''
    CACHE.mkdir(exist_ok=True)
    key.write_bytes(out)
    return out or None


def _run(cmd, work, out_name):
    r = subprocess.run(cmd, capture_output=True, text=True)
    path = work / out_name
    return path.read_bytes() if r.returncode == 0 and path.exists() else None


def c_compress(data, flags=()):
    def produce():
        with tempfile.TemporaryDirectory() as d:
            w = Path(d)
            (w / 'in').write_bytes(data)
            return _run([str(C_ZX1), '-f', *flags, str(w / 'in'), str(w / 'out')], w, 'out')
    return _cached(f'c{TOOLS}', data, list(flags), produce)


def c_decompress(stream):
    with tempfile.TemporaryDirectory() as d:
        w = Path(d)
        (w / 'in').write_bytes(stream)
        return _run([str(C_DZX1), '-f', str(w / 'in'), str(w / 'out')], w, 'out')


def jx1(data, flags=()):
    def produce():
        with tempfile.TemporaryDirectory() as d:
            w = Path(d)
            (w / 'in').write_bytes(data)
            return _run(['java', '-ea', '-cp', t.CP, 'org.jx1.Jx1', '-f', *flags,
                         str(w / 'in'), str(w / 'out')], w, 'out')
    return _cached(f'j{t.COMPRESSOR}', data, list(flags), produce)


def djx1(stream):
    with tempfile.TemporaryDirectory() as d:
        w = Path(d)
        (w / 'in').write_bytes(stream)
        return _run(['java', '-ea', '-cp', t.CP, 'org.jx1.Djx1', '-f',
                     str(w / 'in'), str(w / 'out')], w, 'out')


CORPORA = [(n, d) for n, d, m in t.testcases() if m is None]
if QUICK:
    CORPORA = [(n, d) for n, d in CORPORA if len(d) <= 3000]
# The options the C compressor also has. -b and -q are whole different parses,
# so they are worth as much as the default one.
SHARED_FLAGS = [(), ('-b',), ('-q',)]
# The options it does not: they restrict which parse is chosen, and the result
# still has to be a stream C can read.
JX1_FLAGS = [('-m256',), ('-m511',), ('-l65535',), ('-m1024', '-l65535'), ('-l1000',)]


def main():
    failures = 0

    print('1. jx1 output against the C compressor, byte for byte')
    for name, data in CORPORA:
        for flags in SHARED_FLAGS:
            c, j = c_compress(data, flags), jx1(data, flags)
            if c is None or c != j:
                print(f'   FAIL {name} {" ".join(flags) or "(default)"}: '
                      f'C {len(c) if c else "refused"} vs jx1 {len(j) if j else "refused"}')
                failures += 1
    print(f'   {len(CORPORA)} corpora x {len(SHARED_FLAGS)} option sets')

    print('2. jx1 decompresses what C compresses')
    for name, data in CORPORA:
        if djx1(c_compress(data)) != data:
            print(f'   FAIL {name}')
            failures += 1
    print(f'   {len(CORPORA)} streams')

    print('3. C decompresses what jx1 compresses, including jx1-only options')
    for name, data in CORPORA:
        for flags in [()] + JX1_FLAGS:
            stream = jx1(data, flags)
            if stream is None or c_decompress(stream) != data:
                print(f'   FAIL {name} {" ".join(flags) or "(default)"}')
                failures += 1
    print(f'   {len(CORPORA)} corpora x {len(JX1_FLAGS) + 1} option sets')

    print('4. the ST1 decoders decode a stream the C compressor produced')
    decodes = 0
    for name, data in CORPORA:
        stream = c_compress(data)
        for binary, run, how in (
                ('ST1.bin', lambda s: b.run_linear(s), 'one-shot'),
                ('ST1.bin', lambda s: b.run_linear(s, 16), 'C=16'),
                ('ST1_wrap.bin',
                 lambda s, expected=data: w.run_wrap(
                     s, expected, 32512, 16, w.t.DST + 11),
                 'counted wrap N=32512 C=16'),
                ('ST1_ring.bin', lambda s: b.run_ring(s, 32512, 16),
                 'ring 32512/16')):
            if binary == 'ST1_wrap.bin':
                w.t.BIN = w.t._binary(binary)
            else:
                t.BIN = t._binary(binary)
            try:
                ok = run(stream) == data
            except Exception as e:                       # a runaway or a bad read
                ok, e = False, e
            decodes += 1
            if not ok:
                print(f'   FAIL {name} on {binary} ({how})')
                failures += 1

    print(f'   {decodes} decodes across all three decompressors')
    print('ALL COMPATIBILITY CHECKS PASS' if not failures else f'{failures} FAILURES')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
