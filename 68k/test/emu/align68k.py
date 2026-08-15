"""opt4 alignment audit: assert no word/long access ever hits an odd address,
across even AND odd destination bases (real 68000 would address-error)."""
import sys, math, importlib.util
from pathlib import Path
SCRATCH = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('t', SCRATCH / 'test68k.py')
import sys as _s
POS = [a for a in _s.argv[1:] if not a.startswith('-')]   # flags (--full) are not positional arguments
BIN_NAME = POS[0] if POS else 'jx1_68000.bin'
sys.argv = ['x', BIN_NAME, '16', '4,8']
t = importlib.util.module_from_spec(spec); spec.loader.exec_module(t)
from unicorn.unicorn_const import UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE
from unicorn.m68k_const import (UC_M68K_REG_A0, UC_M68K_REG_A1,
                                UC_M68K_REG_D3)

def run(comp, expected, chunk, dst_bias):
    uc = t.make_emu(comp)
    bad = []
    def mem_hook(u, access, addr, size, value, _):
        if size >= 2 and addr & 1 and addr >= t.DST:  # data accesses; stack/ctx are even by design too
            bad.append((hex(addr), size))
    uc.hook_add(UC_HOOK_MEM_READ, mem_hook)
    uc.hook_add(UC_HOOK_MEM_WRITE, mem_hook)
    def mem_hook_all(u, access, addr, size, value, _):
        if size >= 2 and addr & 1:
            bad.append((hex(addr), size))
    uc.hook_add(UC_HOOK_MEM_READ, mem_hook_all)
    uc.hook_add(UC_HOOK_MEM_WRITE, mem_hook_all)
    dst = t.DST + dst_bias
    uc.reg_write(UC_M68K_REG_A0, t.SRC); uc.reg_write(UC_M68K_REG_A1, dst)
    t.call(uc, t.ENTRY_INIT)
    t.seed_word_state_highs(uc)
    calls = 0
    while True:
        uc.reg_write(UC_M68K_REG_D3, 0xBEEF0000 | chunk)
        more = t.call(uc, t.ENTRY_RESUME)
        t.assert_word_state_highs(uc)
        if more == 0:                            # the budget is refilled per call
            break
        calls += 1
        assert calls < len(expected) + 2
    got = bytes(uc.mem_read(dst, len(expected)))
    assert got == expected, f'output mismatch (bias {dst_bias}, chunk {chunk})'
    assert not bad, f'UNALIGNED ACCESSES (bias {dst_bias}, chunk {chunk}): {bad[:5]}'

for name, data, m in t.testcases():
    comp = t.java_compress(data, m)
    for bias in (0, 1):
        for chunk in (16, 127):
            run(comp, data, chunk, bias)
    print(f'ALIGN OK {name} (even+odd dst, chunks 16/127)')
print('ALIGNMENT AUDIT PASSED')
