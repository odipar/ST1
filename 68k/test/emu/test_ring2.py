"""Differential test for the 0/1-return ring decompressor (jx1_68000_ring2.S).

The caller drains after every call and spots the wrap itself: the write
pointer never wraps mid-call, so "a1 == ring end" means the buffer is full
and the next call restarts at the beginning.
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
from unicorn.m68k_const import (UC_M68K_REG_A1, UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A3,
                                UC_M68K_REG_A4, UC_M68K_REG_A5, UC_M68K_REG_D0,
                                UC_M68K_REG_D1, UC_M68K_REG_D2, UC_M68K_REG_D3,
                                UC_M68K_REG_D4, UC_M68K_REG_D5,
                                UC_M68K_REG_A6, UC_M68K_REG_D6, UC_M68K_REG_D7)
# What a caller may still pass junk in. d2/d3/d4 carry the parse state and
# d5 is the budget, so the clobber set is what is left.
CLOBBERED = (UC_M68K_REG_D0, UC_M68K_REG_D1)
ENTRY_INIT, ENTRY_RESUME = t.CODE + 0, t.CODE + 4

def run_ring(compressed, expected, n, chunk, ring):
    uc = t.make_emu(compressed)
    uc.mem_write(ring - 8, b'\xAA' * (n + 16))      # canaries either side of the
    stray = []                                      # ring, checked at the end

    def guard(u, ty, addr, size, val, d):
        # The whole [addr, addr+size) interval, against exact regions: a write
        # that starts inside the ring and ends past it is still a write past it,
        # and the context is ctx_size bytes, not a comfortable 64.
        # There is no context block any more, so the ring and the stack are
        # the only places a write may land at all.
        for lo, hi in ((ring, ring + n), (t.STACK_TOP - 0x4000, t.STACK_TOP)):
            if lo <= addr and addr + size <= hi:
                return
        stray.append((addr, size))

    uc.hook_add(UC_HOOK_MEM_WRITE, guard)
    read_high = t.track_source_reads(uc, t.SRC)
    uc.reg_write(UC_M68K_REG_A0, t.SRC)
    uc.reg_write(UC_M68K_REG_A1, ring)
    t.call(uc, ENTRY_INIT)
    uc.reg_write(UC_M68K_REG_A3, ring)              # ring bounds are parameters
    uc.reg_write(UC_M68K_REG_A4, ring + n)
    uc.reg_write(UC_M68K_REG_D6, 0xDEADBEEF)
    uc.reg_write(UC_M68K_REG_D7, 0xFEEDFACE)
    uc.reg_write(UC_M68K_REG_A6, 0xCAFEBABE)

    out = bytearray()
    prev, calls = ring, 0
    while True:
        calls += 1
        assert calls < 20 + 4 * (len(expected) // max(1, min(chunk, n)) + 1), 'runaway'
        for reg in CLOBBERED:               # the ABI calls these clobbered, so
            uc.reg_write(reg, 0xBEEF0000)   # a caller may pass anything in them
        uc.reg_write(UC_M68K_REG_D5, chunk)     # the budget is a per-call
        r = t.call(uc, ENTRY_RESUME)            # parameter, not state
        dst = uc.reg_read(UC_M68K_REG_A1)      # a1 is the write pointer now
        assert dst >= prev, f'write pointer went backwards inside a call: {dst} < {prev}'
        out += uc.mem_read(prev, dst - prev)
        if dst == ring + n:                     # full: the caller wraps the write
            uc.reg_write(UC_M68K_REG_A1, ring)  # pointer, which this decoder
            prev = ring                         # requires of it (the general ring
        else:                                   # wraps for you - doing it here
            prev = dst                          # too is a no-op there)
        assert not stray, f'wrote outside the ring at {[hex(a) for a in stray[:3]]}'
        assert uc.reg_read(UC_M68K_REG_A3) == ring, 'a3 clobbered'
        assert uc.reg_read(UC_M68K_REG_A4) == ring + n, 'a4 clobbered'
        if r == 0:
            break
        assert r == 1, f'bad return {r} (this variant returns only 0/1)'
    assert t.call(uc, ENTRY_RESUME) == 0, 'not idempotent once done'
    assert uc.reg_read(UC_M68K_REG_D6) == 0xDEADBEEF, 'd6 clobbered'
    assert uc.reg_read(UC_M68K_REG_D7) == 0xFEEDFACE, 'd7 clobbered'
    assert uc.reg_read(UC_M68K_REG_A6) == 0xCAFEBABE, 'a6 clobbered'
    consumed = read_high[0] - t.SRC          # every byte of the stream, and
    assert consumed == len(compressed), (     # not one byte past it
        f'read {consumed} of {len(compressed)} input bytes')
    assert bytes(uc.mem_read(ring - 8, 8)) == b'\xAA' * 8, 'wrote before the ring'
    assert bytes(uc.mem_read(ring + n, 8)) == b'\xAA' * 8, 'wrote past the ring'
    return bytes(out)

def main():
    # every shape must satisfy N % X == 0 (the decompressor's requirement);
    # 511/7, 1000/125, 1016/127 and 33000/8 keep non-power-of-two rings in
    sizes = [(1024, 16), (1024, 64), (1024, 1), (4096, 16), (32512, 16),
             (32512, 64), (256, 16), (256, 64), (512, 64), (511, 7),
             (1000, 125), (1016, 127), (33000, 8), (3, 1), (2, 1), (1, 1),
             (32512, 32512), (4096, 4096), (1024, 1024)]   # budgets past 127
    assert all(n % c == 0 for n, c in sizes), 'a shape violates N % X == 0'
    failures = 0
    for name, data, m in t.testcases():
        for n, chunk in sizes:
            if _too_slow(data, n, chunk):
                continue
            compressed = t.java_compress(data, min(n, 32512))
            try:
                out = run_ring(compressed, data, n, chunk, t.DST + 11)  # odd base,
                                       # clear of the canary below it
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
