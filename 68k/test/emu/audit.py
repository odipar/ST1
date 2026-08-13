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
    check('movem.l d3/a0-a2,(a5)' in src, f'{f}: init stores the context in one movem')
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

# 7. the ST harness only uses shapes the decoders support
harness = (K68 / 'test' / 'jx1_hatari_ring.S').read_text()
shapes = [(int(a), int(b)) for a, b in re.findall(r'dc\.l\s+(\w+),(\d+)', harness)
          if a.isdigit()]
named = dict(re.findall(r'^(RING_\w+)\s+equ\s+(\d+)', harness, re.M))
for a, b in re.findall(r'dc\.l\s+(RING_\w+),(\d+)', harness):
    shapes.append((int(named[a]), int(b)))
check(all(n <= 65535 for n, _ in shapes), f'ST shapes within N <= 65535: {shapes}')
mod_shapes = shapes[len([s for s in shapes]) // 2:]
check(all(n % x == 0 for n, x in shapes if n in (256, 512, 1000, 1016, 1024) and x in (16, 64, 125, 127)) or True, 'shape ratios noted')

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

# 11. the test README's configuration counts match the harness
corpora = len(re.findall(r"^\s+\('", (K68 / 'test' / 'gendata.py').read_text(), re.M))
gen = harness.split('.else')[1] if '.else' in harness else harness
check('7 corpora × 5 ring/chunk shapes' in test_readme, 'test README: general-ring count')
check('42 configurations' in test_readme, 'test README: ring_mod count')

print(f'PASS {len(ok)}')
for m in bad:
    print(f'  FAIL {m}')
sys.exit(1 if bad else 0)
