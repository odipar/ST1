#!/usr/bin/env python3
"""Differential test: 68k dzx1_68000.S (emulated with Unicorn) vs Java Zx1-compressed streams."""
import hashlib
import math
import re
import subprocess
import tempfile
from pathlib import Path

from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN
from unicorn.unicorn_const import UC_CTL_CPU_MODEL, UC_HOOK_MEM_READ
from unicorn.m68k_const import (
    UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A5, UC_M68K_REG_A6,
    UC_M68K_REG_A7, UC_M68K_REG_D0, UC_M68K_REG_D6, UC_M68K_REG_D7,
    UC_M68K_REG_PC,
)

import sys

SCRATCH = Path(__file__).resolve().parent
CP = str(Path(__file__).resolve().parents[3] / 'target' / 'classes')


PREBUILT = '--binary' in sys.argv   # opt in to testing a supplied .bin instead
_ASSEMBLED = {}


def _binary(name):
    """Assemble 68k/<stem>.S fresh and return it.

    Deliberately not "use the .bin if one is lying around": those files are
    gitignored build products, so that rule turns an ordinary edit-and-rerun
    into silently testing the previous binary. Assembly costs milliseconds.
    Pass --binary to test a supplied file on purpose.
    """
    if name in _ASSEMBLED:
        return _ASSEMBLED[name]
    here = Path(__file__).resolve().parent
    out = here / name
    if PREBUILT:
        if not out.exists():
            raise SystemExit(f'--binary given but no {out}')
        return _ASSEMBLED.setdefault(name, out.read_bytes())
    src = here.parent.parent / (Path(name).stem + '.S')
    if not src.exists():
        raise SystemExit(f'no {src}')
    with tempfile.TemporaryDirectory() as d:
        target = Path(d, name)
        r = subprocess.run(['rmac', '-m68000', '-fr', '+o3', '-o', str(target), str(src)],
                           capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(r.stdout + r.stderr)
        return _ASSEMBLED.setdefault(name, target.read_bytes())


POS = [a for a in sys.argv[1:] if not a.startswith('-')]   # flags are not positional
BIN = _binary(POS[0] if POS else 'jx1_68000.bin')
CHUNKS = [int(c) for c in POS[1].split(',')] if len(POS) > 1 else [16, 1, 7, 127]
QUICK = '--quick' in sys.argv     # the whole matrix runs by default: with the
                                  # streams cached below, every combination
                                  # together costs a few seconds. --quick drops
                                  # the ones whose cost is calls, not coverage

CODE, CTX, SRC, DST, STACK_TOP, MAGIC = 0x1000, 0x20000, 0x40000, 0x80000, 0xF8000, 0xE0000
# Registers the calling convention promises to preserve. a5 is here because
# jx1_decompress uses it for its private context and must put it back.
PRESERVED = {UC_M68K_REG_A5: 0x00021234, UC_M68K_REG_A6: 0xCAFEBABE,
             UC_M68K_REG_D6: 0xDEADBEEF, UC_M68K_REG_D7: 0xFEEDFACE}
PRESERVED_NAMES = {UC_M68K_REG_A5: 'a5', UC_M68K_REG_A6: 'a6',
                   UC_M68K_REG_D6: 'd6', UC_M68K_REG_D7: 'd7'}
ENTRY_INIT, ENTRY_DECOMPRESS, ENTRY_RESUME = CODE + 0, CODE + 4, CODE + 8
CTX_SIZE = 22

CACHE = SCRATCH / '.streams'      # optimal parsing is quadratic-ish in the match
                                  # window, so a 32K corpus costs seconds to
                                  # compress and every script here wants the same
                                  # streams: compress each (corpus, -m) once


def _compressor_id() -> str:
    """Fingerprint of the compiled compressor.

    The cache below is only sound if it cannot survive a change to the thing it
    is caching - these tests exist to catch exactly that. Keying on the class
    files means any recompile of the Java side invalidates every stream.
    """
    h = hashlib.sha1()
    for f in sorted(Path(CP).rglob('*.class')):
        st = f.stat()
        h.update(f'{f}:{st.st_size}:{st.st_mtime_ns}'.encode())
    return h.hexdigest()[:12]


COMPRESSOR = _compressor_id()


def java_compress(data: bytes, m: int | None) -> bytes:
    key = CACHE / f'{COMPRESSOR}-{hashlib.sha1(data).hexdigest()[:16]}-m{m}.zx1'
    if key.exists():
        return key.read_bytes()
    with tempfile.TemporaryDirectory() as d:
        src, dst = Path(d, 'in.bin'), Path(d, 'out.zx1')
        src.write_bytes(data)
        args = ['java', '-ea', '-cp', CP, 'org.jx1.Jx1', '-f']
        if m is not None:
            args.append(f'-m{m}')
        subprocess.run(args + [str(src), str(dst)], check=True, capture_output=True)
        out = dst.read_bytes()
    CACHE.mkdir(exist_ok=True)
    key.write_bytes(out)           # keyed by corpus content AND compiled
    return out                     # compressor: both invalidate on any change

def context_size(name: str) -> int:
    """The decoder's own ctx_size, so guards cannot drift from the source."""
    src = (SCRATCH.parent.parent / (Path(name).stem + '.S')).read_text()
    return int(re.search(r'^ctx_size\s+equ\s+(\d+)', src, re.M).group(1))


def make_emu(compressed: bytes, src_bias: int = 0) -> Uc:
    uc = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
    try:
        uc.ctl_set_cpu_model(0)  # UC_CPU_M68K_M68000: plain 68000, no ColdFire leniency
    except Exception:
        pass
    for base, size in ((CODE, 0x1000), (CTX, 0x1000), (SRC, 0x10000), (DST, 0x20000),
                       (STACK_TOP - 0x4000, 0x8000), (MAGIC, 0x1000)):
        uc.mem_map(base, size)
    uc.mem_write(CODE, bytes(BIN))
    uc.mem_write(SRC + src_bias, compressed)   # the stream has no alignment
    return uc                                  # requirement: it is read bytewise

def track_source_reads(uc: Uc, src_at: int) -> list[int]:
    """Records how far into the compressed stream the decoder reads.

    Stronger than reading ctx_src afterwards, and independent of it: the field
    is only guaranteed while a stream is suspended, whereas the last byte
    actually fetched pins both "consumed everything" and "read nothing past the
    end" - and the end marker is the last thing any stream contains.
    """
    high = [src_at]
    uc.hook_add(UC_HOOK_MEM_READ,
                lambda u, ty, addr, size, val, d: high.__setitem__(
                    0, max(high[0], addr + size)),
                begin=src_at, end=src_at + 0x20000)
    return high


def call(uc: Uc, entry: int, timeout_insns: int = 200_000_000) -> int:
    sp = STACK_TOP - 256
    uc.mem_write(sp, MAGIC.to_bytes(4, 'big'))
    uc.reg_write(UC_M68K_REG_A7, sp)
    uc.reg_write(UC_M68K_REG_PC, entry)
    uc.emu_start(entry, MAGIC, count=timeout_insns)
    assert uc.reg_read(UC_M68K_REG_PC) == MAGIC, 'call did not return'
    return uc.reg_read(UC_M68K_REG_D0) & 0xFFFFFFFF

def run_resumable(compressed: bytes, expected: bytes, chunk: int) -> None:
    uc = make_emu(compressed)
    read_high = track_source_reads(uc, SRC)
    uc.reg_write(UC_M68K_REG_A0, SRC)
    uc.reg_write(UC_M68K_REG_A1, DST)
    uc.reg_write(UC_M68K_REG_D0, chunk)
    uc.reg_write(UC_M68K_REG_A5, CTX)
    call(uc, ENTRY_INIT)

    calls, prev_dst = 0, DST
    while True:
        calls += 1
        assert calls <= len(expected) + 2, 'resume loop does not terminate'
        more = call(uc, ENTRY_RESUME)
        cur_dst = uc.reg_read(UC_M68K_REG_A1)   # a1 is where the interface says
        emitted = cur_dst - prev_dst            # the output ends; the context
                                                # field is not live after DONE
        assert 0 <= emitted <= chunk, f'emitted {emitted} > chunk {chunk}'
        if more == 0:
            break
        assert emitted == chunk, f'short emission {emitted} with more pending'
        prev_dst = cur_dst
    total = uc.reg_read(UC_M68K_REG_A1) - DST
    assert total == len(expected), f'output size {total} != {len(expected)}'
    assert bytes(uc.mem_read(DST, total)) == expected, 'output bytes differ'
    assert calls == max(1, math.ceil(len(expected) / chunk)), \
        f'{calls} calls != ceil({len(expected)}/{chunk})'
    assert call(uc, ENTRY_RESUME) == 0, 'resume after done must stay done'
    assert read_high[0] - SRC == len(compressed), \
        f'read {read_high[0] - SRC} of {len(compressed)} input bytes'

def run_oneshot(compressed: bytes, expected: bytes, src_bias: int = 0) -> None:
    uc = make_emu(compressed, src_bias)
    uc.reg_write(UC_M68K_REG_A0, SRC + src_bias)
    uc.reg_write(UC_M68K_REG_A1, DST)
    for reg, canary in PRESERVED.items():          # jx1_decompress promises to
        uc.reg_write(reg, canary)                  # leave these alone, a5 included
    sp_after = STACK_TOP - 256 + 4          # call() pushes the return address
    assert call(uc, ENTRY_DECOMPRESS) == 0
    end = uc.reg_read(UC_M68K_REG_A1)
    assert end - DST == len(expected), f'one-shot size {end - DST} != {len(expected)}'
    assert bytes(uc.mem_read(DST, len(expected))) == expected
    for reg, canary in PRESERVED.items():
        assert uc.reg_read(reg) == canary, f'{PRESERVED_NAMES[reg]} not restored'
    assert uc.reg_read(UC_M68K_REG_A7) == sp_after, (
        f'stack not balanced: a7 = {uc.reg_read(UC_M68K_REG_A7):#x}, '
        f'expected {sp_after:#x}')

def testcases() -> list[tuple[str, bytes, int | None]]:
    import random
    r = random.Random(42)
    words = [bytes(r.randrange(256) for _ in range(r.randrange(3, 10))) for _ in range(20)]
    soup = b''.join(words[r.randrange(20)] + b' ' for _ in range(400))
    block = bytes(r.randrange(256) for _ in range(200))
    period128 = (bytes(r.randrange(256) for _ in range(128))) * 8
    period129 = (bytes(r.randrange(256) for _ in range(129))) * 8
    maxoff = bytes(r.randrange(256) for _ in range(32512))
    return [
        ('one-byte', b'*', None),
        ('two-same', b'aa', None),
        ('alternating', bytes(i % 2 for i in range(64)), None),
        ('all-same', b'A' * 1000, None),
        ('text', b'abracadabra hocus pocus abracadabra ' * 10, None),
        ('word-soup', soup, None),
        ('far-match', block + b'x' * 2500 + block, None),
        ('period-128', period128, None),   # one-byte offset boundary
        ('period-129', period129, None),   # two-byte offset boundary
        ('m511', soup, 511),
        ('m1', b'B' * 500, 1),
        ('max-offset', maxoff + maxoff[:500], None),  # offsets up to 32512
        ('rle-32k', b'A' * 32000, None),  # single ops near the 32K dbf/word limit
    ]

def main() -> None:
    for name, data, m in testcases():
        compressed = java_compress(data, m)
        for src_bias in (0, 1, 2, 3):     # the stream is read a byte at a time,
            run_oneshot(compressed, data, src_bias)   # so no alignment is implied
        for chunk in CHUNKS:
            if QUICK and (len(data) // max(1, chunk) > 1200
                          or (chunk == 1 and len(data) > 5000)):
                continue
            run_resumable(compressed, data, chunk)
        print(f'PASS {name} ({len(data)} -> {len(compressed)} bytes)')
    print('ALL 68K TESTS PASS')

if __name__ == '__main__':
    sys.exit(main())
