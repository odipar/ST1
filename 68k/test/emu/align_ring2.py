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
from unicorn.m68k_const import (UC_M68K_REG_A1, UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A5,
                                UC_M68K_REG_D0, UC_M68K_REG_A3, UC_M68K_REG_A4)
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
            uc.reg_write(UC_M68K_REG_D0, chunk); uc.reg_write(UC_M68K_REG_A3, ring); uc.reg_write(UC_M68K_REG_A4, ring + n)
            uc.reg_write(UC_M68K_REG_A5, t.CTX)
            t.call(uc, t.CODE)
            while t.call(uc, t.CODE + 4) != 0:
                pass
        print(f'ALIGN OK {name:11s} ({len(shapes)} shapes, even+odd ring bases)')
pow2 = len(POS) > 1 and POS[1] == 'pow2'
shapes = ([(1024, 16, 0), (1024, 16, 1), (4096, 64, 3), (256, 16, 1)] if pow2
          else [(1000, 16, 0), (1000, 16, 1), (511, 7, 3), (33000, 127, 1)])
audit(shapes)
print('ALIGNMENT AUDIT PASSED' if not bad else f'MISALIGNED ACCESSES: {bad[:5]}')
sys.exit(1 if bad else 0)
