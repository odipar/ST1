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
sizes = {}
for f in FILES:
    out = subprocess.run(ASM + ['-o', '/tmp/a.bin', str(K68 / f)],
                         capture_output=True, text=True)
    check(out.returncode == 0, f'{f} assembles')
    sizes[f] = Path('/tmp/a.bin').stat().st_size
    src = (K68 / f).read_text()


readme = (REPO / 'README.md').read_text()
test_readme = (K68 / 'test' / 'README.md').read_text()
lic = (REPO / 'LICENSE').read_text()

# 1. sizes and context sizes as tabled in the main README
for f in FILES:
    row = re.search(rf'\[{re.escape(f)}\]\([^)]*\) \| (\d+) B \|', readme)
    check(row and int(row.group(1)) == sizes[f],
          f'{f}: README size {row.group(1) if row else "?"} B vs actual {sizes[f]} B')

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

# 4. the budget is a per-call parameter in d4.w, not a field and not state
for f in FILES:
    src = (K68 / f).read_text()
    check('d0.w = chunk size' not in src, f'{f}: init no longer takes a chunk')
    check("d4.w = this call's budget" in src, f'{f}: resume documents the budget in d4.w')
    check('the budget in d4.w is 1..65535' in src, f'{f}: the budget range is stated')

# 5. the state encoding the entry dispatch relies on
for f in FILES:
    src = (K68 / f).read_text()
    # init writes nothing: it seeds the three registers that are not pointers.
    # The sign of lastOffset is the active-op state; d1/d3 encode START/DONE.
    check('moveq   #-128,d0' in src, f'{f}: init seeds the bit queue with $80')
    check('moveq   #1,d3' in src, f'{f}: init encodes START with lastOffset = +1')
    check('tst.w   d1' in src and 'beq.s   entry_special' in src,
          f'{f}: zero remaining dispatches START/DONE')
    check(src.count('neg.w   d3') == 2,
          f'{f}: lastOffset sign flips exactly at both LITERALS/MATCH transitions')
    check('tst.w   d3' in src, f'{f}: active-op dispatch tests signed lastOffset')
    end = src[src.index('end_marker:'):]
    check('clr.w   d1' in end and 'clr.w   d3' in end,
          f'{f}: DONE normalizes remaining and lastOffset for repeat polling')
    offset_head = src[src.index('new_offset:'):src.index('two_byte:')]
    check('moveq   #0,d1' not in offset_head and 'clr.w   d1' not in offset_head,
          f'{f}: no dead clear before new_offset')
    check('addx.w  d1,d1' in src, f'{f}: two-byte offset folds the carry')

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
    check('$BEEF0000' in src, f'{f}: poisons the clobbered registers before resume')

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
    # the size claim, which every header states the same way. Other byte
    # counts in the prose (a 256-byte ring, say) are not size claims.
    quoted = [int(n) for n in re.findall(r'\b(\d{3}) bytes, position-independent', src)]
    check(quoted == [sizes[f]], f'{f}: header quotes {quoted}, assembles to {sizes[f]}')
prose = [int(n) for n in re.findall(r'\*\*(\d{3}) bytes', readme)
         + re.findall(r'(\d{3}) bytes of position-independent code', readme)]
check(all(n in sizes.values() for n in prose),
      f'README prose quotes sizes {prose}, actual {sorted(sizes.values())}')
# There is no context block: the whole state is the caller's registers, so no
# decoder may name a5 or a context field at all, and nothing may promise one.
for f in FILES:
    src = (K68 / f).read_text()
    body = '\n'.join(l for l in src.split('\n') if not l.lstrip().startswith(';'))
    check('a5' not in body, f'{f}: no a5 in the code - there is no context block')
    check('ctx_' not in body, f'{f}: no context field left')
    check(not re.search(r'^\s+[^;\n]*\bd2\b', body, re.M),
          f'{f}: d2 is not touched by the decoder')
    check('d3.w  signed last offset' in src, f'{f}: the header maps the folded state')
check(not re.search(r'\d+-byte word-aligned context', readme),
      'README promises no context block')

# the clobbered set, stated where a caller will look for it
for f in FILES:
    src = (K68 / f).read_text()
    check('CLOBBERED    d4.w d5.l d6.l' in src and 'a4.l' in src,
          f'{f}: names the clobbered registers, with widths')
check('| **clobbered** | **`d4.w` `d5.l` `d6.l` `a4.l`** |' in readme,
      'README names the clobbered registers, with widths')

# The calling sequences in the README are code a reader will copy, so they have
# to use the registers the decoders actually use.
for block in re.findall(r'```\n(        lea     stream.*?)```', readme, re.S):
    check('bsr     jx1_resume' in block, 'README example calls jx1_resume')
    check('tst.w   d1' in block, 'README example tests remaining/result in d1')
    check(re.search(r'moveq   #\d+,d4', block), 'README example passes the budget in d4')
    check('tst.w   d0' not in block, 'README example does not test the old return register')

# 13. the operation-length contract, stated identically in all three headers and
#     backed by 68k/test/emu/boundaries.py
for f in FILES:
    src = (K68 / f).read_text()
    check('longer than 65535 bytes' in src, f'{f}: states the 65535-byte operation limit')
    check('-l65535' in src, f'{f}: points at the compressor flag that guarantees it')
check('MAX_OP = 65535' in (K68 / 'test' / 'emu' / 'boundaries.py').read_text(),
      'boundaries.py pins the same operation limit')

# 14. the compatibility check exists, is documented, and uses the repo's C sources
compat = (K68 / 'test' / 'emu' / 'compat.py').read_text()
check("REPO / 'c' / 'zx1' / 'src'" in compat.replace('CSRC = ', ''),
      'compat.py builds the C reference from the repository sources')
check('compat.py' in readme and 'Compatibility with ZX1' in readme,
      'README documents the compatibility check')
emu_readme = (K68 / 'test' / 'emu' / 'README.md').read_text()
check('compat.py' in emu_readme, 'the emulator README lists compat.py')
scripts = sorted(f.name for f in (K68 / 'test' / 'emu').glob('*.py'))
missing = [f for f in scripts if f not in emu_readme]
check(not missing, f'every emulator script is listed in its README (missing {missing})')

# 15. the trusted-input boundary is stated where a caller will see it
for f in FILES:
    check('TRUSTED INPUT ONLY' in (K68 / f).read_text(), f'{f}: states trusted-input-only')
check('### Trusted input only' in readme, 'README has the trusted-input section')

print(f'PASS {len(ok)}')
for m in bad:
    print(f'  FAIL {m}')
sys.exit(1 if bad else 0)
