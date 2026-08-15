"""Does a caller leaving junk in the clobbered registers break the decoders?

The ABI names the registers jx1_resume clobbers, which promises nothing about
their incoming values - so a caller may legally pass anything in them.  The
three decoders now deliberately have different scratch sets, checked here.
"""
import sys, importlib.util
from pathlib import Path
SCRATCH = Path(__file__).resolve().parent
ARGS = list(sys.argv)
sp = importlib.util.spec_from_file_location('t', SCRATCH / 'test68k.py')
POS = [a for a in ARGS[1:] if not a.startswith('-')]   # flags (--full) are not positional arguments
sys.argv = ['x', POS[0] if POS else 'jx1_68000_ring.bin']
t = importlib.util.module_from_spec(sp); sp.loader.exec_module(t)
from unicorn.m68k_const import (UC_M68K_REG_A1, UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A2,
                                UC_M68K_REG_A4, UC_M68K_REG_A3, UC_M68K_REG_A5,
                                UC_M68K_REG_A6, UC_M68K_REG_D5, UC_M68K_REG_D7,
                                UC_M68K_REG_D6, UC_M68K_REG_D0, UC_M68K_REG_D1,
                                UC_M68K_REG_D2, UC_M68K_REG_D4)
BIN = POS[0] if POS else 'jx1_68000_ring.bin'
LINEAR = len(POS) > 1 and POS[1] == 'linear'
MOD = 'ring_mod' in BIN
REGS = {'d2': UC_M68K_REG_D2, 'd5': UC_M68K_REG_D5,
        'd6': UC_M68K_REG_D6, 'a2': UC_M68K_REG_A2,
        'a4': UC_M68K_REG_A4}

def run(data, n, chunk, poison):
    comp = t.java_compress(data, min(n, 32512))
    uc = t.make_emu(comp)
    ring = ((t.DST + n - 1) & -n) if MOD else t.DST
    uc.reg_write(UC_M68K_REG_A0, t.SRC); uc.reg_write(UC_M68K_REG_A1, ring)
    if not LINEAR and not MOD:
        uc.reg_write(UC_M68K_REG_D2, ring + n)   # general ring's sole bound
    t.call(uc, t.CODE)
    uc.reg_write(UC_M68K_REG_A1, ring)         # the caller holds the write pointer
    out, prev, calls = bytearray(), ring, 0
    while True:
        calls += 1
        if calls > 4 * (len(data) // max(1, min(chunk, n)) + 8):
            return 'RUNAWAY'
        for r in poison:                       # legal: these are clobbered
            uc.reg_write(REGS[r], 0xBEEF0000)
        uc.reg_write(UC_M68K_REG_D4, chunk)    # the budget is a parameter
        try:
            rc = t.call(uc, ENTRY)
        except Exception as e:
            return f'HANG/FAULT ({str(e)[:28]})'
        dst = uc.reg_read(UC_M68K_REG_A1)      # a1 is the write pointer now
        if not (ring <= dst <= ring + n):
            return f'DST OUT OF RING ({dst - ring})'
        out += uc.mem_read(prev, max(0, dst - prev))
        if dst == ring + n:
            if MOD:                             # fixed ring requires caller wrap
                uc.reg_write(UC_M68K_REG_A1, ring)
            prev = ring
        else:
            prev = dst
        if rc == 0:
            break
    return 'ok' if bytes(out) == data else f'WRONG ({len(out)} of {len(data)} bytes)'

ENTRY = t.CODE + (8 if LINEAR else 4)
# The loop below drives the ring interface. The linear decoder has no ring - it
# writes straight ahead - so the only meaningful bound for it is one that holds
# the whole output; a smaller N would flag ordinary linear output as escaping.
SIZES = (((65535, 16),) if LINEAR else
         ((1024, 16),) if MOD else ((1024, 16), (65535, 16)))
POISONS = (('d5',), ('d6',), ('a4',), ('d5', 'd6', 'a4')) if LINEAR else \
          (('d2',), ('d5',), ('d6',), ('d2', 'd5', 'd6')) if MOD else \
          (('a2',), ('d5',), ('d6',), ('a2', 'd5', 'd6'))
failures = 0
for name, data, _ in t.testcases():
    if name not in ('word-soup', 'rle-32k'):
        continue
    for n, chunk in SIZES:
        for poison in ((), *POISONS):
            r = run(data, n, chunk, poison)
            tag = 'clean' if not poison else '+'.join(poison)
            flag = '' if r == 'ok' else '   <-- FAILS'
            failures += r != 'ok'
            print(f'{BIN:12s} {name:10s} N={n:5d} X={chunk:3d} poison={tag:26s} {r}{flag}')
# The other half of the same contract: exactly which registers calls may
# destroy.  Canary every non-state register before every call and union the
# changes over a whole mixed stream.  A scratch register need not change on
# every path (ring_mod's d2 is only borrowed by a match), whereas an untouched
# register must survive every path.
CANARY = 0x5A5A0000
ALL = {'d2': UC_M68K_REG_D2, 'd4': UC_M68K_REG_D4, 'd5': UC_M68K_REG_D5,
       'd6': UC_M68K_REG_D6, 'd7': UC_M68K_REG_D7, 'a2': UC_M68K_REG_A2,
       'a3': UC_M68K_REG_A3, 'a4': UC_M68K_REG_A4, 'a5': UC_M68K_REG_A5,
       'a6': UC_M68K_REG_A6}
STATE = ('d0', 'd1', 'd3')                # plus a0/a1; general ring also has d2
EXPECTED = ({'d4', 'd5', 'd6', 'a4'} if LINEAR else
            {'d2', 'd4', 'd5', 'd6'} if MOD else
            {'d4', 'd5', 'd6', 'a2'})


def clobbered(data, n, chunk):
    comp = t.java_compress(data, min(n, 32512))
    uc = t.make_emu(comp)
    ring = ((t.DST + n - 1) & -n) if MOD else t.DST
    uc.reg_write(UC_M68K_REG_A0, t.SRC); uc.reg_write(UC_M68K_REG_A1, ring)
    if not LINEAR and not MOD:
        uc.reg_write(UC_M68K_REG_D2, ring + n)
    t.call(uc, t.CODE)
    seen, calls = set(), 0
    while True:
        calls += 1
        assert calls <= len(data) + 2, 'clobber probe did not terminate'
        initial = {name: CANARY | i for i, name in enumerate(ALL)}
        initial['d4'] = chunk
        if not LINEAR and not MOD:
            initial['d2'] = ring + n
        for name, reg in ALL.items():
            uc.reg_write(reg, initial[name])
        more = t.call(uc, ENTRY)
        seen |= {name for name, reg in ALL.items()
                 if uc.reg_read(reg) != initial[name]}
        if not LINEAR and uc.reg_read(UC_M68K_REG_A1) == ring + n and MOD:
            uc.reg_write(UC_M68K_REG_A1, ring)
        if more == 0:
            return seen


data = next(d for n, d, _ in t.testcases() if n == 'word-soup')
got = clobbered(data, 1024, 16)
if got != EXPECTED:
    print(f'{BIN:12s} clobbered set is {sorted(got)}, documented {sorted(EXPECTED)}'
          f'   <-- FAILS')
    failures += 1
else:
    print(f'{BIN:12s} clobbers exactly {" ".join(sorted(EXPECTED))}, as documented')

print(f'{"ALL POISON CASES PASS" if not failures else f"{failures} FAILURES"} '
      f'- incoming scratch is ignored and the call destroys exactly '
      f'{"/".join(sorted(EXPECTED))}')
sys.exit(1 if failures else 0)
