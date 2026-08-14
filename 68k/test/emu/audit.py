"""Mechanical audit: every checkable claim in the docs against the sources."""
import re, subprocess, sys
from pathlib import Path
REPO = Path(__file__).resolve().parents[3]
K68 = REPO / '68k'
ASM = ['rmac', '-m68000', '-fr', '+o3']
ok, bad = [], []
def check(cond, msg):
    (ok if cond else bad).append(msg)

FILES = ['jx1_68000.S', 'jx1_68000_ring.S', 'jx1_68000_ring_mod.S']
sizes, ctxsize = {}, {}
for f in FILES:
    out = subprocess.run(ASM + ['-o', '/tmp/a.bin', str(K68 / f)],
                         capture_output=True, text=True)
    check(out.returncode == 0, f'{f} assembles')
    sizes[f] = Path('/tmp/a.bin').stat().st_size
    src = (K68 / f).read_text()
    ctxsize[f] = int(re.search(r'^ctx_size\s+equ\s+(\d+)', src, re.M).group(1))

readme = (REPO / 'README.md').read_text()
test_readme = (K68 / 'test' / 'README.md').read_text()
lic = (REPO / 'LICENSE').read_text()

# 1. sizes and context sizes as tabled in the main README
for f in FILES:
    row = re.search(rf'\[{re.escape(f)}\]\([^)]*\) \| (\d+) B \| (\d+) B', readme)
    check(row and int(row.group(1)) == sizes[f],
          f'{f}: README size {row.group(1) if row else "?"} B vs actual {sizes[f]} B')
    check(row and int(row.group(2)) == ctxsize[f],
          f'{f}: README context {row.group(2) if row else "?"} B vs ctx_size {ctxsize[f]}')

# 2. no long compare can read a caller-clobbered register's upper word
for f in FILES:
    src = (K68 / f).read_text()
    longcmp = re.findall(r'^\s+cmp\.l\s+(d\d),', src, re.M)
    check(not longcmp, f'{f}: no cmp.l on a data register ({longcmp})')

# 3. every documented entry exists, and the jump table matches
for f in FILES:
    src = (K68 / f).read_text()
    slots = re.findall(r'^\s+bra\.w\s+(jx1_\w+)', src, re.M)
    expect = (['jx1_init', 'jx1_decompress', 'jx1_resume'] if f == 'jx1_68000.S'
              else ['jx1_init', 'jx1_resume'])
    check(slots == expect, f'{f}: jump table {slots} vs documented {expect}')

# 4. the chunk field is a word and jx1_init documents d0.w
for f in FILES:
    src = (K68 / f).read_text()
    i = re.search(r'^jx1_init:', src, re.M).start()      # the label, not the comment
    init = src[i:i + 400]
    check('swap    d0' in init, f'{f}: init takes the chunk from d0.w into the packed word')
    check('d0.w = chunk size' in src, f'{f}: init documents d0.w')
    check('.w  chunkSize' in src, f'{f}: the field comment says word')

# 5. the state encoding the entry dispatch relies on
for f in FILES:
    src = (K68 / f).read_text()
    check('move.w  #$8080,d0' in src, f'{f}: init packs bits+START as $8080')
    # the linear version keeps the write pointer in the context (a1); the rings
    # hand it to the caller, so their movem is one register shorter
    movem = 'movem.l d3/a0-a2,(a5)' if f == 'jx1_68000.S' else 'movem.l d3/a0/a2,(a5)'
    check(movem in src, f'{f}: init stores the context in one movem')
    check('bmi.s   entry_special' in src, f'{f}: entry dispatches on the sign')
    check('moveq   #0,d4' in src, f'{f}: LITERALS = 0')
    check('st      (a5)' in src, f'{f}: DONE stored with st')
    check('moveq   #0,d3' not in src, f'{f}: no dead clear before new_offset')
    check('addx.w  d3,d3' in src, f'{f}: two-byte offset folds the carry')

# 6. no stale ctx_alloc, no stale 15-byte wording anywhere current
for f in FILES + ['test/jx1_hatari.S', 'test/jx1_hatari_ring.S']:
    src = (K68 / f).read_text()
    check('ctx_alloc' not in src, f'{f}: no ctx_alloc left')
    check('15 byte' not in src and '15-byte' not in src, f'{f}: no 15-byte wording')
check('15-byte' not in readme, 'README: no 15-byte wording')

# 7. the ST harness only uses shapes the decoders support. The two builds have
#    different contracts, so the two tables are checked against different rules.
harness = (K68 / 'test' / 'jx1_hatari_ring.S').read_text()
named = dict(re.findall(r'^(RING_\w+)\s+equ\s+(\d+)', harness, re.M))


def parse_shapes(text):
    return [(int(named.get(a, a)), int(b))
            for a, b in re.findall(r'dc\.l\s+(\w+),(\d+)', text)]


mod_shapes, gen_shapes = [], []
for m in re.finditer(r'\.if\s+RINGMOD(.*?)\.else(.*?)\.endif', harness, re.S):
    if 'shapes:' in m.group(1) and 'shapes:' in m.group(2):
        mod_shapes, gen_shapes = parse_shapes(m.group(1)), parse_shapes(m.group(2))
        break
check(bool(mod_shapes) and bool(gen_shapes),
      f'ST harness declares both shape tables ({len(mod_shapes)}/{len(gen_shapes)})')
check(all(n % x == 0 for n, x in mod_shapes),
      f'every ring_mod shape divides: {[s for s in mod_shapes if s[0] % s[1]]}')
check(any(n % x for n, x in gen_shapes),
      'the general-ring table exercises at least one non-dividing shape')
check(all(n <= 65535 for n, _ in mod_shapes + gen_shapes),
      f'ST shapes within N <= 65535: {mod_shapes + gen_shapes}')

# 8. run.sh fails on BAD, and quotes the right sizes
runsh = (K68 / 'test' / 'run.sh').read_text()
check('exit $fail' in runsh and 'BAD' in runsh, 'run.sh fails the command on BAD')
check(not re.search(r'\b(32[0-9]|33[0-9])\b', runsh), 'run.sh quotes no stale byte counts')

# 9. both harnesses poison the clobbered registers
for f in ('test/jx1_hatari.S', 'test/jx1_hatari_ring.S'):
    src = (K68 / f).read_text()
    check('$BEEF0000' in src, f'{f}: poisons d0-d5 before resume')

# 10. LICENSE names every shipped decompressor
for f in FILES:
    check(f in lic, f'LICENSE names {f}')

# 11. the test README's configuration counts, computed from the harness rather
#     than matched as prose
corpora = len(re.findall(r"^\s+\('", (K68 / 'test' / 'gendata.py').read_text(), re.M))
claim = f'{corpora} corpora × {len(gen_shapes)} ring/chunk shapes'
check(claim in test_readme, f'test README states the general-ring count ({claim})')
mod_total = corpora * len(mod_shapes)
check(f'{mod_total} configurations' in test_readme,
      f'test README states the ring_mod count ({mod_total} configurations)')

# 12. every size and context size quoted in prose, against the assembled files
for f in FILES:
    src = (K68 / f).read_text()
    quoted = [int(n) for n in re.findall(r'\b(\d{3}) bytes\b', src.split('Assumptions')[0])]
    check(all(n == sizes[f] for n in quoted),
          f'{f}: header quotes {quoted}, assembles to {sizes[f]}')
prose = [int(n) for n in re.findall(r'\*\*(\d{3}) bytes', readme)
         + re.findall(r'(\d{3}) bytes of position-independent code', readme)]
check(all(n in sizes.values() for n in prose),
      f'README prose quotes sizes {prose}, actual {sorted(sizes.values())}')
ctx_prose = [int(n) for n in re.findall(r'(\d+)-byte word-aligned context', readme)]
check(all(n in ctxsize.values() for n in ctx_prose),
      f'README prose quotes contexts {ctx_prose}, actual {sorted(set(ctxsize.values()))}')
check('the same 16-byte context' not in readme,
      'README does not claim all three share one context size')

# 13. the operation-length contract, stated identically in all three headers and
#     backed by 68k/test/emu/boundaries.py
for f in FILES:
    src = (K68 / f).read_text()
    check('longer than 65535 bytes' in src, f'{f}: states the 65535-byte operation limit')
    check('-l65535' in src, f'{f}: points at the compressor flag that guarantees it')
check('MAX_OP = 65535' in (K68 / 'test' / 'emu' / 'boundaries.py').read_text(),
      'boundaries.py pins the same operation limit')

# 14. the trusted-input boundary is stated where a caller will see it
for f in FILES:
    check('TRUSTED INPUT ONLY' in (K68 / f).read_text(), f'{f}: states trusted-input-only')
check('### Trusted input only' in readme, 'README has the trusted-input section')

print(f'PASS {len(ok)}')
for m in bad:
    print(f'  FAIL {m}')
sys.exit(1 if bad else 0)
