"""Differential test for the 0/1-return ring decompressor (jx1_68000_ring2.S).

The caller drains after every call and spots the wrap itself: the write
pointer never wraps mid-call, so "a1 == ring end" means the buffer is full
and the next call restarts at the beginning.
"""
import sys, importlib.util
from pathlib import Path

SCRATCH = Path(__file__).resolve().parent
ARGS = list(sys.argv)
sp = importlib.util.spec_from_file_location('t', SCRATCH / 'test68k.py')
sys.argv = ['x', ARGS[1] if len(ARGS) > 1 else 'jx1_68000_ring.bin']
t = importlib.util.module_from_spec(sp); sp.loader.exec_module(t)

from unicorn.unicorn_const import UC_HOOK_MEM_WRITE
from unicorn.m68k_const import (UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A3,
                                UC_M68K_REG_A4, UC_M68K_REG_A5, UC_M68K_REG_D0,
                                UC_M68K_REG_D1, UC_M68K_REG_D2, UC_M68K_REG_D3,
                                UC_M68K_REG_D4, UC_M68K_REG_D5,
                                UC_M68K_REG_D6, UC_M68K_REG_D7)
CLOBBERED = (UC_M68K_REG_D0, UC_M68K_REG_D1, UC_M68K_REG_D2,
             UC_M68K_REG_D3, UC_M68K_REG_D4, UC_M68K_REG_D5)
ENTRY_INIT, ENTRY_RESUME = t.CODE + 0, t.CODE + 4
CTX_DST = 8

def run_ring(compressed, expected, n, chunk, ring):
    uc = t.make_emu(compressed)
    uc.mem_write(ring, b'\xAA' * (n + 64))
    stray = []
    uc.hook_add(UC_HOOK_MEM_WRITE,
                lambda u, ty, addr, size, val, d:
                    stray.append(addr) if not (ring <= addr < ring + n
                                               or t.CTX <= addr < t.CTX + 64
                                               or addr >= t.STACK_TOP - 0x4000) else None)
    uc.reg_write(UC_M68K_REG_A0, t.SRC)
    uc.reg_write(UC_M68K_REG_A1, ring)
    uc.reg_write(UC_M68K_REG_D0, chunk)
    uc.reg_write(UC_M68K_REG_A5, t.CTX)
    t.call(uc, ENTRY_INIT)
    uc.reg_write(UC_M68K_REG_A3, ring)              # ring bounds are parameters
    uc.reg_write(UC_M68K_REG_A4, ring + n)
    uc.reg_write(UC_M68K_REG_D6, 0xDEADBEEF)
    uc.reg_write(UC_M68K_REG_D7, 0xFEEDFACE)

    out = bytearray()
    prev, calls = ring, 0
    while True:
        calls += 1
        assert calls < 20 + 4 * (len(expected) // max(1, min(chunk, n)) + 1), 'runaway'
        for reg in CLOBBERED:               # the ABI calls these clobbered, so
            uc.reg_write(reg, 0xBEEF0000)   # a caller may pass anything in them
        r = t.call(uc, ENTRY_RESUME)
        dst = int.from_bytes(uc.mem_read(t.CTX + CTX_DST, 4), 'big')
        assert dst >= prev, f'write pointer went backwards inside a call: {dst} < {prev}'
        out += uc.mem_read(prev, dst - prev)
        prev = ring if dst == ring + n else dst      # full: next call restarts
        assert not stray, f'wrote outside the ring at {[hex(a) for a in stray[:3]]}'
        assert uc.reg_read(UC_M68K_REG_A3) == ring, 'a3 clobbered'
        assert uc.reg_read(UC_M68K_REG_A4) == ring + n, 'a4 clobbered'
        if r == 0:
            break
        assert r == 1, f'bad return {r} (this variant returns only 0/1)'
    assert t.call(uc, ENTRY_RESUME) == 0, 'not idempotent once done'
    assert uc.reg_read(UC_M68K_REG_D6) == 0xDEADBEEF, 'd6 clobbered'
    assert uc.reg_read(UC_M68K_REG_D7) == 0xFEEDFACE, 'd7 clobbered'
    return bytes(out)

def main():
    sizes = [(1024, 16), (1024, 127), (4096, 16), (4096, 100), (32512, 16),
             (32512, 127), (256, 16), (256, 127), (512, 64), (511, 16),
             (511, 7), (1000, 127), (33000, 16), (3, 1), (2, 1), (1, 1)]
    failures = 0
    for name, data, m in t.testcases():
        for n, chunk in sizes:
            compressed = t.java_compress(data, min(n, 32512))
            try:
                out = run_ring(compressed, data, n, chunk, t.DST + 3)   # odd base
                assert out == data, (f'{len(out)} bytes, first diff at '
                                     f'{next((i for i, (a, b) in enumerate(zip(out, data)) if a != b), len(out))}')
            except Exception as e:
                print(f'FAIL {name:11s} n={n:6d} X={chunk:4d}: {e}')
                failures += 1
        print(f'{"OK  " if not failures else "    "}{name:11s} '
              f'({len(data)} bytes through {len(sizes)} ring/chunk shapes)')
    print('ALL RING2 TESTS PASS' if not failures else f'{failures} FAILURES')
    return 1 if failures else 0

if __name__ == '__main__':
    sys.exit(main())
