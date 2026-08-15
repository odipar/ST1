"""Differential test for the compile-time power-of-two ring decompressor.

The caller drains after every call and spots the wrap itself: the write
pointer never wraps mid-call, so "a1 == ring end" means the buffer is full
and the caller restarts at the beginning.  Each N is assembled into a distinct
binary and each ring base is aligned to that N, as the decoder requires.
"""
import sys, importlib.util
from pathlib import Path

SCRATCH = Path(__file__).resolve().parent
ARGS = list(sys.argv)
import sys as _s
QUICK = '--quick' in _s.argv        # the whole matrix runs by default; --quick
                                    # drops the combinations whose cost is calls,
                                    # not coverage - a 32K corpus through a
                                    # 1-byte ring is 32000 emulated calls


def _too_slow(data, n, chunk):
    return QUICK and len(data) // max(1, min(chunk, n)) > 1200


sp = importlib.util.spec_from_file_location('t', SCRATCH / 'test68k.py')
POS = [a for a in ARGS[1:] if not a.startswith('-')]   # flags (--full) are not positional arguments
sys.argv = ['x', POS[0] if POS else 'jx1_68000_ring_mod.bin']
t = importlib.util.module_from_spec(sp); sp.loader.exec_module(t)

from unicorn.unicorn_const import UC_HOOK_MEM_WRITE
from unicorn.m68k_const import (UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A2,
                                UC_M68K_REG_A3, UC_M68K_REG_A4, UC_M68K_REG_D5,
                                UC_M68K_REG_D6, UC_M68K_REG_D0, UC_M68K_REG_D1,
                                UC_M68K_REG_D2, UC_M68K_REG_D4,
                                UC_M68K_REG_A6, UC_M68K_REG_D3, UC_M68K_REG_D7)
# The fixed ring has no bound registers.  d2 is the match-time saved input
# pointer; a2-a4 are all promised untouched.
CLOBBERED = (UC_M68K_REG_D2, UC_M68K_REG_D5, UC_M68K_REG_D6)
ENTRY_INIT, ENTRY_RESUME = t.CODE + 0, t.CODE + 4


def binary_name(n):
    return f'jx1_68000_ring_mod_{n}.bin'


def aligned_ring(n):
    # Leave room for the lower canary and for a complete N-byte ring in the
    # mapped destination area.  N is a power of two.
    ring = (t.DST + 8 + n - 1) & -n
    assert ring % n == 0 and ring + n + 8 <= t.DST + 0x20000
    return ring

def run_ring(compressed, expected, n, chunk, ring):
    uc = t.make_emu(compressed)
    uc.mem_write(ring - 8, b'\xAA' * (n + 16))      # canaries either side of the
    stray = []                                      # ring, checked at the end

    def guard(u, ty, addr, size, val, d):
        # Check the whole [addr, addr+size) interval: a write that starts inside
        # the ring and ends past it is still out of bounds. There is no context
        # block, so only the ring and the call stack may be written.
        for lo, hi in ((ring, ring + n), (t.STACK_TOP - 0x4000, t.STACK_TOP)):
            if lo <= addr and addr + size <= hi:
                return
        stray.append((addr, size))

    uc.hook_add(UC_HOOK_MEM_WRITE, guard)
    read_high = t.track_source_reads(uc, t.SRC)
    assert n & (n - 1) == 0 and ring % n == 0
    uc.reg_write(UC_M68K_REG_A0, t.SRC)
    uc.reg_write(UC_M68K_REG_A1, ring)
    t.call(uc, ENTRY_INIT)
    uc.reg_write(UC_M68K_REG_A2, 0x00020234)
    uc.reg_write(UC_M68K_REG_A3, 0x00030234)
    uc.reg_write(UC_M68K_REG_A4, 0x00040234)
    uc.reg_write(UC_M68K_REG_D7, 0xFEEDFACE)
    uc.reg_write(UC_M68K_REG_A6, 0xCAFEBABE)

    out = bytearray()
    prev, calls = ring, 0
    while True:
        calls += 1
        assert calls < 20 + 4 * (len(expected) // max(1, min(chunk, n)) + 1), 'runaway'
        for reg in CLOBBERED:               # the ABI calls these clobbered, so
            uc.reg_write(reg, 0xBEEF0000)   # a caller may pass anything in them
        uc.reg_write(UC_M68K_REG_D4, chunk)     # the budget is a per-call
        r = t.call(uc, ENTRY_RESUME)            # parameter, not state
        dst = uc.reg_read(UC_M68K_REG_A1)      # a1 is the write pointer now
        emitted = dst - prev
        assert 0 <= emitted <= chunk, \
            f'emitted {emitted} bytes with budget {chunk}'
        if r != 0:
            assert emitted == chunk, \
                f'short continuing call emitted {emitted} of fixed {chunk}'
        out += uc.mem_read(prev, emitted)
        if dst == ring + n:                     # full: this ABI requires the
            uc.reg_write(UC_M68K_REG_A1, ring)  # caller to wrap the write pointer
            prev = ring
        else:
            prev = dst
        assert not stray, f'wrote outside the ring at {[hex(a) for a in stray[:3]]}'
        assert uc.reg_read(UC_M68K_REG_A2) == 0x00020234, 'a2 clobbered'
        assert uc.reg_read(UC_M68K_REG_A3) == 0x00030234, 'a3 clobbered'
        assert uc.reg_read(UC_M68K_REG_A4) == 0x00040234, 'a4 clobbered'
        if r == 0:
            break
        assert r > 0, f'bad remaining count {r}'
    assert t.call(uc, ENTRY_RESUME) == 0, 'not idempotent once done'
    assert uc.reg_read(UC_M68K_REG_D7) == 0xFEEDFACE, 'd7 clobbered'
    assert uc.reg_read(UC_M68K_REG_A6) == 0xCAFEBABE, 'a6 clobbered'
    consumed = read_high[0] - t.SRC          # every byte of the stream, and
    assert consumed == len(compressed), (     # not one byte past it
        f'read {consumed} of {len(compressed)} input bytes')
    assert bytes(uc.mem_read(ring - 8, 8)) == b'\xAA' * 8, 'wrote before the ring'
    assert bytes(uc.mem_read(ring + n, 8)) == b'\xAA' * 8, 'wrote past the ring'
    return bytes(out)

def main():
    # Every N is a separately assembled power-of-two variant and every fixed
    # X divides it.  Tiny sizes pin modular arithmetic; 32768 pins the largest
    # supported compile-time ring and budgets beyond moveq's range.
    sizes = [(1, 1), (2, 1), (2, 2), (256, 1), (256, 16), (256, 64),
             (256, 256), (512, 64), (1024, 16), (1024, 64), (1024, 1024),
             (4096, 16), (4096, 4096), (32768, 16), (32768, 256),
             (32768, 32768)]
    assert all(n & (n - 1) == 0 and n % c == 0 for n, c in sizes), \
        'a shape violates the power-of-two/fixed-divisor contract'
    failures = 0
    for name, data, m in t.testcases():
        for n, chunk in sizes:
            if _too_slow(data, n, chunk):
                continue
            compressed = t.java_compress(data, min(n, 32512))
            try:
                t.BIN = t._binary(binary_name(n))
                out = run_ring(compressed, data, n, chunk, aligned_ring(n))
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
