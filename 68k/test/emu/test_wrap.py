"""Differential test for the caller-counted ST1_wrap ring decoder.

For packed input size I, output size O, ring size N and chunk size C, legal
shapes have N % C == 0. The caller resets a1 after F=N/C full calls and makes
exactly ceil(O/C) calls, using O%C as the final budget when needed. ST1_wrap
has no DONE state, so the caller never makes an extra completion poll.
"""
import importlib.util
import math
import sys
from pathlib import Path

SCRATCH = Path(__file__).resolve().parent
ARGS = list(sys.argv)
QUICK = '--quick' in ARGS

spec = importlib.util.spec_from_file_location('t', SCRATCH / 'test68k.py')
positional = [a for a in ARGS[1:] if not a.startswith('-')]
sys.argv = ['x', positional[0] if positional else 'ST1_wrap.bin']
t = importlib.util.module_from_spec(spec)
spec.loader.exec_module(t)

from unicorn.unicorn_const import UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE
from unicorn.m68k_const import (
    UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A2, UC_M68K_REG_A3,
    UC_M68K_REG_A4, UC_M68K_REG_A5, UC_M68K_REG_A6,
    UC_M68K_REG_D0, UC_M68K_REG_D1, UC_M68K_REG_D2, UC_M68K_REG_D3,
    UC_M68K_REG_D4, UC_M68K_REG_D5, UC_M68K_REG_D6, UC_M68K_REG_D7,
)

ENTRY_INIT, ENTRY_RESUME = t.CODE, t.CODE + 4
CLOBBERED = (UC_M68K_REG_D4, UC_M68K_REG_D5, UC_M68K_REG_A2)
PRESERVED = {
    UC_M68K_REG_D6: 0xD6D61234,
    UC_M68K_REG_D7: 0xFEEDFACE,
    UC_M68K_REG_A3: 0x00030234,
    UC_M68K_REG_A4: 0x00040234,
    UC_M68K_REG_A5: 0x00050234,
    UC_M68K_REG_A6: 0xCAFEBABE,
}


def _too_slow(output_size, n, c):
    return QUICK and math.ceil(output_size / c) > 1200


def run_wrap(compressed, expected, n, c, ring):
    assert 1 <= c <= n <= 65535 and n % c == 0
    output_size = len(expected)
    total_calls = math.ceil(output_size / c)
    calls_per_fill = n // c

    uc = t.make_emu(compressed)
    uc.mem_write(ring - 8, b'\xAA' * (n + 16))
    bad_writes = []
    bad_reads = []

    def guard_write(u, ty, address, size, value, data):
        for low, high in ((ring, ring + n),
                          (t.STACK_TOP - 0x4000, t.STACK_TOP)):
            if low <= address and address + size <= high:
                return
        bad_writes.append((address, size))

    def guard_ring_read(u, ty, address, size, value, data):
        if not (ring <= address and address + size <= ring + n):
            bad_reads.append((address, size))

    uc.hook_add(UC_HOOK_MEM_WRITE, guard_write)
    uc.hook_add(UC_HOOK_MEM_READ, guard_ring_read,
                begin=t.DST, end=t.DST + 0x1FFFF)
    input_high = t.track_source_reads(uc, t.SRC)

    uc.reg_write(UC_M68K_REG_A0, t.SRC)
    uc.reg_write(UC_M68K_REG_A1, ring)
    uc.reg_write(UC_M68K_REG_D3, 0xBEEF0000 | n)
    t.call(uc, ENTRY_INIT)

    start_meta = (-ring) & 0xFFFF
    assert uc.reg_read(UC_M68K_REG_D1) >> 16 == start_meta, \
        'init did not pack -ring_start.low in d1.high'
    assert uc.reg_read(UC_M68K_REG_D2) >> 16 == n, \
        'init did not pack N in d2.high'
    t.seed_d0_high(uc)
    for register, canary in PRESERVED.items():
        uc.reg_write(register, canary)

    output = bytearray()
    previous = ring
    slot = 0
    wraps = 0

    for call_index in range(total_calls):
        remaining_output = output_size - call_index * c
        budget = min(c, remaining_output)
        for register in CLOBBERED:
            uc.reg_write(register, 0xBEEF0000)
        uc.reg_write(UC_M68K_REG_D3, 0xBEEF0000 | budget)

        t.call(uc, ENTRY_RESUME)
        t.assert_d0_high(uc)
        current = uc.reg_read(UC_M68K_REG_A1)
        emitted = current - previous
        assert emitted == budget, \
            f'call {call_index + 1} emitted {emitted}, expected {budget}'
        output.extend(uc.mem_read(previous, emitted))

        assert not bad_writes, \
            f'wrote outside the ring at {[hex(a) for a, _ in bad_writes[:3]]}'
        assert not bad_reads, \
            f'read outside the ring at {[hex(a) for a, _ in bad_reads[:3]]}'
        assert uc.reg_read(UC_M68K_REG_D1) >> 16 == start_meta, \
            'packed -ring_start.low changed'
        assert uc.reg_read(UC_M68K_REG_D2) >> 16 == n, \
            'packed N changed'
        for register, canary in PRESERVED.items():
            assert uc.reg_read(register) == canary, 'preserved register clobbered'

        final = call_index + 1 == total_calls
        slot += 1
        if not final and slot == calls_per_fill:
            assert current == ring + n, 'F calls did not end at ring+N'
            uc.reg_write(UC_M68K_REG_A1, ring)
            previous = ring
            slot = 0
            wraps += 1
        else:
            assert current <= ring + n, 'destination crossed ring end'
            previous = current

    assert len(output) == output_size
    assert bytes(output) == expected
    assert wraps == (output_size - 1) // n
    assert input_high[0] - t.SRC == len(compressed), \
        f'consumed {input_high[0] - t.SRC} bytes, expected I={len(compressed)}'
    assert bytes(uc.mem_read(ring - 8, 8)) == b'\xAA' * 8
    assert bytes(uc.mem_read(ring + n, 8)) == b'\xAA' * 8
    return bytes(output)


def main():
    shapes = [
        (1, 1), (2, 2), (48, 16), (255, 15), (256, 16),
        (512, 64), (1000, 40), (1024, 16), (1024, 128),
        (4096, 16), (32512, 16),
    ]
    failures = 0
    ring = t.DST + 11                 # odd, unaligned, and safe for every N
    cases = t.testcases()
    if not QUICK:
        cases += [('rle-64k', b'Z' * 65536, 1)]

    for name, data, maximum_offset in cases:
        for n, c in shapes:
            if _too_slow(len(data), n, c):
                continue
            compressed = t.java_compress(data, min(n, 32512))
            try:
                result = run_wrap(compressed, data, n, c, ring)
                assert result == data
            except Exception as error:
                print(f'FAIL {name:11s} N={n:5d} C={c:4d}: {error}')
                failures += 1
        print(f'{"OK  " if not failures else "    "}{name:11s} '
              f'({len(data)} O bytes through counted rings)')

    if not QUICK:
        data = b'Q' * 65536
        n, c = 65535, 255
        compressed = t.java_compress(data, 32512)
        try:
            assert run_wrap(compressed, data, n, c, ring) == data
            print('OK  N=65535 boundary (one wrap, partial final call)')
        except Exception as error:
            print(f'FAIL N=65535 boundary: {error}')
            failures += 1

    print('ALL COUNTED-WRAP TESTS PASS' if not failures else f'{failures} FAILURES')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
