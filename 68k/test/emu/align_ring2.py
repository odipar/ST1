"""Odd-address audit: a real 68000 address-errors on a misaligned .w/.l access.
Unicorn does not, so hook every access and assert size>=2 implies an even address."""
import sys, importlib.util
from pathlib import Path
SCRATCH = Path(__file__).resolve().parent
ARGS = list(sys.argv)
sp = importlib.util.spec_from_file_location('t', SCRATCH / 'test68k.py')
POS = [a for a in ARGS[1:] if not a.startswith('-')]   # flags (--full) are not positional arguments
sys.argv = ['x', POS[0] if POS else 'jx1_68000_ring.bin']
t = importlib.util.module_from_spec(sp); sp.loader.exec_module(t)
from unicorn.unicorn_const import UC_HOOK_MEM_READ, UC_HOOK_MEM_WRITE
from unicorn.m68k_const import (UC_M68K_REG_A1, UC_M68K_REG_A0,
                                UC_M68K_REG_D1, UC_M68K_REG_D2,
                                UC_M68K_REG_D3)
bad = []


def audit(shapes):
    for name, data, m in t.testcases():
        for n, chunk, off in shapes:
            comp = t.java_compress(data, min(n, 32512))
            uc = t.make_emu(comp)
            ring = t.DST + off
            uc.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE,
                        lambda u, ty, addr, size, val, d:
                            bad.append((name, n, chunk, off, hex(addr), size))
                            if size >= 2 and addr & 1 else None)
            uc.reg_write(UC_M68K_REG_A0, t.SRC); uc.reg_write(UC_M68K_REG_A1, ring)
            uc.reg_write(UC_M68K_REG_D3, ring + n)  # transient init bound
            t.call(uc, t.CODE)
            assert uc.reg_read(UC_M68K_REG_D1) >> 16 == ((-ring) & 0xFFFF)
            assert uc.reg_read(UC_M68K_REG_D2) >> 16 == ((ring + n) & 0xFFFF)
            while True:
                uc.reg_write(UC_M68K_REG_D3, 0xBEEF0000 | chunk)
                more = t.call(uc, t.CODE + 4)
                assert uc.reg_read(UC_M68K_REG_D1) >> 16 == ((-ring) & 0xFFFF)
                assert uc.reg_read(UC_M68K_REG_D2) >> 16 == ((ring + n) & 0xFFFF)
                if more != 0 and uc.reg_read(UC_M68K_REG_A1) == ring + n:
                    uc.reg_write(UC_M68K_REG_A1, ring)
                if more == 0:
                    break
        print(f'ALIGN OK {name:11s} ({len(shapes)} shapes, even+odd ring bases)')


shapes = [(1000, 16, 0), (1000, 16, 1), (511, 7, 3), (33000, 127, 1)]
audit(shapes)
print('ALIGNMENT AUDIT PASSED' if not bad else f'MISALIGNED ACCESSES: {bad[:5]}')
sys.exit(1 if bad else 0)
