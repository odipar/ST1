"""Does a caller leaving junk in the clobbered data registers break the rings?

The ABI says jx1_resume CLOBBERS d0-d5, which promises nothing about their
incoming values - so a caller may legally pass anything in them.
"""
import sys, importlib.util
from pathlib import Path
SCRATCH = Path(__file__).resolve().parent
ARGS = list(sys.argv)
sp = importlib.util.spec_from_file_location('t', SCRATCH / 'test68k.py')
sys.argv = ['x', ARGS[1] if len(ARGS) > 1 else 'jx1_68000_ring.bin']
t = importlib.util.module_from_spec(sp); sp.loader.exec_module(t)
from unicorn.m68k_const import (UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A3,
                                UC_M68K_REG_A4, UC_M68K_REG_A5, UC_M68K_REG_D0,
                                UC_M68K_REG_D1, UC_M68K_REG_D2, UC_M68K_REG_D3,
                                UC_M68K_REG_D4, UC_M68K_REG_D5)
REGS = {'d0': UC_M68K_REG_D0, 'd1': UC_M68K_REG_D1, 'd2': UC_M68K_REG_D2,
        'd3': UC_M68K_REG_D3, 'd4': UC_M68K_REG_D4, 'd5': UC_M68K_REG_D5}

def run(data, n, chunk, poison):
    comp = t.java_compress(data, min(n, 32512))
    uc = t.make_emu(comp)
    ring = t.DST
    uc.reg_write(UC_M68K_REG_A0, t.SRC); uc.reg_write(UC_M68K_REG_A1, ring)
    uc.reg_write(UC_M68K_REG_D0, chunk); uc.reg_write(UC_M68K_REG_A5, t.CTX)
    t.call(uc, t.CODE)
    uc.reg_write(UC_M68K_REG_A3, ring); uc.reg_write(UC_M68K_REG_A4, ring + n)
    out, prev, calls = bytearray(), ring, 0
    while True:
        calls += 1
        if calls > 4 * (len(data) // max(1, min(chunk, n)) + 8):
            return 'RUNAWAY'
        for r in poison:                       # legal: these are clobbered
            uc.reg_write(REGS[r], 0xBEEF0000)
        try:
            rc = t.call(uc, ENTRY)
        except Exception as e:
            return f'HANG/FAULT ({str(e)[:28]})'
        dst = int.from_bytes(uc.mem_read(t.CTX + 8, 4), 'big')
        if not (ring <= dst <= ring + n):
            return f'DST OUT OF RING ({dst - ring})'
        out += uc.mem_read(prev, max(0, dst - prev))
        prev = ring if dst == ring + n else dst
        if rc == 0:
            break
    return 'ok' if bytes(out) == data else f'WRONG ({len(out)} of {len(data)} bytes)'

BIN = ARGS[1] if len(ARGS) > 1 else 'jx1_68000_ring.bin'
ENTRY = t.CODE + (8 if len(ARGS) > 2 and ARGS[2] == 'linear' else 4)
for name, data, _ in t.testcases():
    if name not in ('word-soup', 'rle-32k'):
        continue
    for n, chunk in ((1024, 16), (65535, 16)):
        for poison in ([], ['d5'], ['d0'], ['d0','d1','d2','d3','d4','d5']):
            r = run(data, n, chunk, poison)
            tag = 'clean' if not poison else '+'.join(poison)
            flag = '' if r == 'ok' else '   <-- FAILS'
            print(f'{BIN:12s} {name:10s} N={n:5d} X={chunk:3d} poison={tag:26s} {r}{flag}')
