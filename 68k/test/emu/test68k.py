#!/usr/bin/env python3
"""Differential test: 68k dzx1_68000.S (emulated with Unicorn) vs Java Zx1-compressed streams."""
import math
import subprocess
import tempfile
from pathlib import Path

from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN
from unicorn.unicorn_const import UC_CTL_CPU_MODEL
from unicorn.m68k_const import (
    UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A5, UC_M68K_REG_A7,
    UC_M68K_REG_D0, UC_M68K_REG_PC,
)

SCRATCH = Path(__file__).resolve().parent
CP = str(Path(__file__).resolve().parents[3] / 'target' / 'classes')
import sys


def _binary(name):
    """Use <name> next to this script, else assemble 68k/<stem>.S with rmac."""
    import subprocess
    here = Path(__file__).resolve().parent
    out = here / name
    if not out.exists():
        src = here.parent.parent / (Path(name).stem + '.S')
        if not src.exists():
            raise SystemExit(f'no {out} and no {src}')
        r = subprocess.run(['rmac', '-m68000', '-fr', '+o3', '-o', str(out), str(src)],
                           capture_output=True, text=True)
        if r.returncode:
            raise SystemExit(r.stdout + r.stderr)
    return out.read_bytes()


BIN = _binary(sys.argv[1] if len(sys.argv) > 1 else 'jx1_68000.bin')
CHUNKS = [int(c) for c in sys.argv[2].split(',')] if len(sys.argv) > 2 else [16, 1, 7, 1 << 30]
SRC_OFF, DST_OFF = ([int(o) for o in sys.argv[3].split(',')] if len(sys.argv) > 3 else [8, 12])

CODE, CTX, SRC, DST, STACK_TOP, MAGIC = 0x1000, 0x20000, 0x40000, 0x80000, 0xF8000, 0xE0000
ENTRY_INIT, ENTRY_DECOMPRESS, ENTRY_RESUME = CODE + 0, CODE + 4, CODE + 8
CTX_SIZE = 22

def java_compress(data: bytes, m: int | None) -> bytes:
    with tempfile.TemporaryDirectory() as d:
        src, dst = Path(d, 'in.bin'), Path(d, 'out.zx1')
        src.write_bytes(data)
        args = ['java', '-ea', '-cp', CP, 'org.jx1.Jx1', '-f']
        if m is not None:
            args.append(f'-m{m}')
        subprocess.run(args + [str(src), str(dst)], check=True, capture_output=True)
        return dst.read_bytes()

def make_emu(compressed: bytes) -> Uc:
    uc = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
    try:
        uc.ctl_set_cpu_model(0)  # UC_CPU_M68K_M68000: plain 68000, no ColdFire leniency
    except Exception:
        pass
    for base, size in ((CODE, 0x1000), (CTX, 0x1000), (SRC, 0x10000), (DST, 0x20000),
                       (STACK_TOP - 0x4000, 0x8000), (MAGIC, 0x1000)):
        uc.mem_map(base, size)
    uc.mem_write(CODE, bytes(BIN))
    uc.mem_write(SRC, compressed)
    return uc

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
        cur_dst = int.from_bytes(uc.mem_read(CTX + DST_OFF, 4), 'big')
        emitted = cur_dst - prev_dst
        assert 0 <= emitted <= chunk, f'emitted {emitted} > chunk {chunk}'
        if more == 0:
            break
        assert emitted == chunk, f'short emission {emitted} with more pending'
        prev_dst = cur_dst
    total = int.from_bytes(uc.mem_read(CTX + DST_OFF, 4), 'big') - DST
    assert total == len(expected), f'output size {total} != {len(expected)}'
    assert bytes(uc.mem_read(DST, total)) == expected, 'output bytes differ'
    assert calls == max(1, math.ceil(len(expected) / chunk)), \
        f'{calls} calls != ceil({len(expected)}/{chunk})'
    assert call(uc, ENTRY_RESUME) == 0, 'resume after done must stay done'
    src_used = int.from_bytes(uc.mem_read(CTX + SRC_OFF, 4), 'big') - SRC
    assert src_used == len(compressed), f'consumed {src_used} of {len(compressed)} input bytes'

def run_oneshot(compressed: bytes, expected: bytes) -> None:
    uc = make_emu(compressed)
    uc.reg_write(UC_M68K_REG_A0, SRC)
    uc.reg_write(UC_M68K_REG_A1, DST)
    assert call(uc, ENTRY_DECOMPRESS) == 0
    end = uc.reg_read(UC_M68K_REG_A1)
    assert end - DST == len(expected), f'one-shot size {end - DST} != {len(expected)}'
    assert bytes(uc.mem_read(DST, len(expected))) == expected

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
        run_oneshot(compressed, data)
        for chunk in CHUNKS:
            if chunk == 1 and len(data) > 5000:
                continue
            run_resumable(compressed, data, chunk)
        print(f'PASS {name} ({len(data)} -> {len(compressed)} bytes)')
    print('ALL 68K TESTS PASS')

if __name__ == '__main__':
    sys.exit(main())
