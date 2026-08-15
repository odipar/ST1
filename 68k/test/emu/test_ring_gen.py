"""Differential test for the general zero/nonzero-result ring decompressor.

The caller drains after every call and spots the wrap itself: the write
pointer never wraps mid-call, so "a1 == ring end" means the buffer is full.
The end's low word is packed into d2.high at init. Tests exercise both legal
handoffs: caller-wrapped a1, and end-valued a1 for the decoder to wrap on its
next entry.
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
sys.argv = ['x', POS[0] if POS else 'jx1_68000_ring.bin']
t = importlib.util.module_from_spec(sp); sp.loader.exec_module(t)

from unicorn.unicorn_const import UC_HOOK_MEM_WRITE
from unicorn.m68k_const import (UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A2,
                                UC_M68K_REG_A3, UC_M68K_REG_A4, UC_M68K_REG_A5,
                                UC_M68K_REG_D5,
                                UC_M68K_REG_D6, UC_M68K_REG_D0, UC_M68K_REG_D1,
                                UC_M68K_REG_D2, UC_M68K_REG_D4,
                                UC_M68K_REG_A6, UC_M68K_REG_D3, UC_M68K_REG_D7)
# d1.high holds -start.low and d2.high the end address's low word. a2 is the
# transient copy pointer; d6/d7 and a3-a6 are deliberately canaried as preserved.
CLOBBERED = (UC_M68K_REG_D4, UC_M68K_REG_D5, UC_M68K_REG_A2)
PRESERVED = {UC_M68K_REG_D6: 0xD6D61234, UC_M68K_REG_D7: 0xFEEDFACE,
             UC_M68K_REG_A3: 0x00030234, UC_M68K_REG_A4: 0x00040234,
             UC_M68K_REG_A5: 0x00050234, UC_M68K_REG_A6: 0xCAFEBABE}
ENTRY_INIT, ENTRY_RESUME = t.CODE + 0, t.CODE + 4

def run_ring(compressed, expected, n, chunk, ring, caller_wrap=True):
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
    uc.reg_write(UC_M68K_REG_A0, t.SRC)
    uc.reg_write(UC_M68K_REG_A1, ring)
    end = ring + n
    uc.reg_write(UC_M68K_REG_D3, end)                # transient init parameter;
                                                     # resume has no bound input
    t.call(uc, ENTRY_INIT)
    start_meta = (-ring) & 0xFFFF
    assert uc.reg_read(UC_M68K_REG_D1) >> 16 == start_meta, \
        'init did not pack -start.low in d1.high'
    assert uc.reg_read(UC_M68K_REG_D2) >> 16 == (end & 0xFFFF), \
        'init did not pack end.low in d2.high'
    t.seed_d0_high(uc)
    for reg, canary in PRESERVED.items():
        uc.reg_write(reg, canary)

    out = bytearray()
    prev, calls = ring, 0
    while True:
        calls += 1
        assert calls < 20 + 4 * (len(expected) // max(1, min(chunk, n)) + 1), 'runaway'
        for reg in CLOBBERED:               # the ABI calls these clobbered, so
            uc.reg_write(reg, 0xBEEF0000)   # a caller may pass anything in them
        uc.reg_write(UC_M68K_REG_D3, 0xBEEF0000 | chunk)  # low word is the budget
        r = t.call(uc, ENTRY_RESUME)            # parameter, not state
        t.assert_d0_high(uc)
        dst = uc.reg_read(UC_M68K_REG_A1)      # a1 is the write pointer now
        emitted = dst - prev
        assert 0 <= emitted <= chunk, \
            f'emitted {emitted} bytes with budget {chunk}'
        if r != 0 and emitted < chunk:
            assert dst == ring + n, \
                f'short continuing call stopped at {dst:#x}, before ring end'
        out += uc.mem_read(prev, emitted)
        if dst == ring + n:                     # full buffer
            if caller_wrap:                     # hand it back wrapped, as
                uc.reg_write(UC_M68K_REG_A1, ring)   # many callers prefer...
            prev = ring                         # ...or leave it at the end and
        else:                                   # let the decoder wrap on entry
            prev = dst
        assert not stray, f'wrote outside the ring at {[hex(a) for a in stray[:3]]}'
        assert uc.reg_read(UC_M68K_REG_D1) >> 16 == start_meta, \
            'packed -start.low in d1.high changed'
        assert uc.reg_read(UC_M68K_REG_D2) >> 16 == (end & 0xFFFF), \
            'packed end.low in d2.high changed'
        for reg, canary in PRESERVED.items():
            assert uc.reg_read(reg) == canary, 'preserved register clobbered'
        if r == 0:
            break
        assert r > 0, f'bad remaining count {r}'
    assert t.call(uc, ENTRY_RESUME) == 0, 'not idempotent once done'
    t.assert_d0_high(uc)
    assert uc.reg_read(UC_M68K_REG_D1) >> 16 == start_meta, \
        'packed -start.low changed after DONE'
    assert uc.reg_read(UC_M68K_REG_D2) >> 16 == (end & 0xFFFF), \
        'packed end.low changed after DONE'
    for reg, canary in PRESERVED.items():
        assert uc.reg_read(reg) == canary, 'preserved register clobbered after DONE'
    consumed = read_high[0] - t.SRC          # every byte of the stream, and
    assert consumed == len(compressed), (     # not one byte past it
        f'read {consumed} of {len(compressed)} input bytes')
    assert bytes(uc.mem_read(ring - 8, 8)) == b'\xAA' * 8, 'wrote before the ring'
    assert bytes(uc.mem_read(ring + n, 8)) == b'\xAA' * 8, 'wrote past the ring'
    return bytes(out)

def main():
    sizes = [(1024, 16), (1024, 127), (4096, 16), (4096, 100), (32512, 16),
             (32512, 127), (256, 16), (256, 127), (512, 64), (511, 16),
             (511, 7), (1000, 127), (33000, 16), (3, 1), (2, 1), (1, 1),
             (32512, 32512), (4096, 4096), (32512, 255)]   # budgets past 127
    failures = 0
    for name, data, m in t.testcases():
        for n, chunk in sizes:
            if _too_slow(data, n, chunk):
                continue
            compressed = t.java_compress(data, min(n, 32512))
            for caller_wrap in (True, False):
                try:
                    out = run_ring(compressed, data, n, chunk, t.DST + 11,
                                   caller_wrap)     # odd base, clear of the
                                                    # canary written below it
                    assert out == data, (f'{len(out)} bytes, first diff at '
                                         f'{next((i for i, (a, b) in enumerate(zip(out, data)) if a != b), len(out))}')
                except Exception as e:
                    print(f'FAIL {name:11s} n={n:6d} X={chunk:4d} '
                          f'{"caller" if caller_wrap else "decoder"}-wrap: {e}')
                    failures += 1
        print(f'{"OK  " if not failures else "    "}{name:11s} '
              f'({len(data)} bytes through {len(sizes)} ring/chunk shapes'
              ', both wrap modes)')
    print('ALL GENERAL RING TESTS PASS' if not failures else f'{failures} FAILURES')
    return 1 if failures else 0

if __name__ == '__main__':
    sys.exit(main())
