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
                                UC_M68K_REG_D2, UC_M68K_REG_D4)
bad = []
MOD = 'ring_mod' in (POS[0] if POS else '')


def aligned_ring(n, off):
    if MOD:
        base = (t.DST + 8 + n - 1) & -n
        # Only N=1 can satisfy the fixed-ring contract at both parities.
        return base + off if n == 1 else base
    return t.DST + off


def audit(shapes):
    for name, data, m in t.testcases():
        for n, chunk, off in shapes:
            comp = t.java_compress(data, min(n, 32512))
            if MOD:
                t.BIN = t._binary(f'jx1_68000_ring_mod_{n}.bin')
            uc = t.make_emu(comp)
            ring = aligned_ring(n, off)
            assert not MOD or ring % n == 0
            uc.hook_add(UC_HOOK_MEM_READ | UC_HOOK_MEM_WRITE,
                        lambda u, ty, addr, size, val, d:
                            bad.append((name, n, chunk, off, hex(addr), size))
                            if size >= 2 and addr & 1 else None)
            uc.reg_write(UC_M68K_REG_A0, t.SRC); uc.reg_write(UC_M68K_REG_A1, ring)
            if not MOD:
                uc.reg_write(UC_M68K_REG_D2, ring + n)
            t.call(uc, t.CODE)
            while True:
                uc.reg_write(UC_M68K_REG_D4, chunk)   # the budget is per call
                more = t.call(uc, t.CODE + 4)
                if uc.reg_read(UC_M68K_REG_A1) == ring + n:
                    uc.reg_write(UC_M68K_REG_A1, ring)  # ring_mod needs this of
                if more == 0:                           # its caller; a no-op for
                    break                               # the general ring
        detail = 'contract-aligned ring bases' if MOD else 'even+odd ring bases'
        print(f'ALIGN OK {name:11s} ({len(shapes)} shapes, {detail})')
# The general decoder promises arbitrary byte alignment.  ring_mod instead
# promises N alignment, so it exercises several aligned powers of two plus
# both parities at N=1.
shapes = ([(1, 1, 0), (1, 1, 1), (256, 16, 0), (1024, 64, 0),
           (32768, 256, 0)] if MOD
          else [(1000, 16, 0), (1000, 16, 1), (511, 7, 3),
                (33000, 127, 1)])
audit(shapes)
print('ALIGNMENT AUDIT PASSED' if not bad else f'MISALIGNED ACCESSES: {bad[:5]}')
sys.exit(1 if bad else 0)
