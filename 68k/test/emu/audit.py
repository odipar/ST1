"""Mechanical audit: every checkable claim in the docs against the sources."""
import re, subprocess, sys
from pathlib import Path
REPO = Path(__file__).resolve().parents[3]
K68 = REPO / '68k'
ASM = ['rmac', '-m68000', '-fr', '+o3']
ok, bad = [], []
def check(cond, msg):
    (ok if cond else bad).append(msg)

FILES = ['ST1.S', 'ST1_ring.S', 'ST1_wrap.S']
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
    slots = re.findall(r'^\s+bra\.w\s+(ST1_\w+)', src, re.M)
    expect = (['ST1_init', 'ST1_decompress', 'ST1_resume'] if f == 'ST1.S'
              else ['ST1_init', 'ST1_resume'])
    check(slots == expect, f'{f}: jump table {slots} vs documented {expect}')

# 4. the budget is a per-call parameter in d3.w, not a field and not state
for f in FILES:
    src = (K68 / f).read_text()
    check('d0.w = chunk size' not in src, f'{f}: init no longer takes a chunk')
    check("d3.w = this call's budget" in src, f'{f}: resume documents the budget in d3.w')
    check('the budget in d3.w is 1..65535' in src, f'{f}: the budget range is stated')

# 5. the state encoding each entry dispatch relies on
for f in FILES:
    src = (K68 / f).read_text()
    # init writes nothing: it seeds the three registers that are not pointers.
    # The sign of lastOffset is the active-op state. Linear/general ring keep a
    # repeatable DONE state; counted wrap trusts T and only dispatches zero as
    # the initial START.
    check('moveq   #-128,d0' in src, f'{f}: init seeds the bit queue with $80')
    check('moveq   #-1,d2' in src,
          f'{f}: init encodes START with -lastOffset = -1')
    if f == 'ST1_wrap.S':
        check('tst.w   d1' in src and 'beq.s   begin_literals' in src and
              'entry_special:' not in src,
              f'{f}: zero remaining dispatches only the initial START')
    else:
        check('tst.w   d1' in src and
              ('beq.s   entry_special' in src or 'bne.s   op_body' in src),
              f'{f}: zero remaining dispatches START/DONE')
    check(src.count('neg.w   d2') == 2,
          f'{f}: lastOffset sign flips exactly at both LITERALS/MATCH transitions')
    check('tst.w   d2' in src, f'{f}: active-op dispatch tests signed lastOffset')
    if f == 'ST1_wrap.S':
        check('bpl.s   resume_return' in src and 'end_marker:' not in src and
              'clr.w   d2' not in src,
              f'{f}: final marker returns without creating a DONE state')
    else:
        end = src[src.index('end_marker:'):]
        check('clr.w   d1' not in end and 'clr.w   d2' in end,
              f'{f}: DONE reuses proven-zero remaining and normalizes lastOffset')
    offset_head = src[src.index('new_offset:'):src.index('two_byte:')]
    offset_decode = src[src.index('new_offset:'):src.index('got_offset:')]
    check('moveq   #0,d1' not in offset_head and 'clr.w   d1' not in offset_head,
          f'{f}: no dead clear before new_offset')
    check('roxr.b  #1,d4' in offset_decode and
          'roxr.b  #1,d5' in offset_decode and
          'addx.w  d4,d4' in offset_decode,
          f'{f}: offset decoder folds both selector carries')
    check('move.w  d4,d2' in src and
          'addq.b  #2,d5' in offset_decode and
          'sub.w   #128,d2' not in offset_decode and
          'sub.w   #32512,d2' not in offset_decode and
          'neg.w   d2' not in offset_decode,
          f'{f}: offset decoder reuses DBF -1 and produces -lastOffset directly')
    check('adda.w  d2,a2' in src,
          f'{f}: match source consumes the negated offset directly')

# 6. no stale ctx_alloc, no stale 15-byte wording anywhere current
for f in FILES + ['test/ST1_test.S', 'test/ST1_wrap_test.S',
                  'test/ST1_ring_test.S']:
    src = (K68 / f).read_text()
    check('ctx_alloc' not in src, f'{f}: no ctx_alloc left')
    check('15 byte' not in src and '15-byte' not in src, f'{f}: no 15-byte wording')
check('15-byte' not in readme, 'README: no 15-byte wording')

# 7. the ST ring harness covers both dividing and non-dividing legal shapes.
harness = (K68 / 'test' / 'ST1_ring_test.S').read_text()
named = dict(re.findall(r'^(RING_\w+)\s+equ\s+(\d+)', harness, re.M))


def parse_shapes(text):
    values = named
    return [(int(values.get(a, a)), int(b))
            for a, b in re.findall(r'dc\.l\s+(\w+),(\d+)', text)]


shape_block = harness[harness.index('shapes:'):harness.index('m_calib:')]
gen_shapes = parse_shapes(shape_block)
check(bool(gen_shapes), f'ST harness declares general-ring shapes ({gen_shapes})')
check(any(n % x for n, x in gen_shapes),
      'the general-ring table exercises at least one non-dividing shape')
check(all(1 <= n <= 65535 and 1 <= x <= 65535 for n, x in gen_shapes),
      f'ST shapes stay within the general-ring contract: {gen_shapes}')

# 8. run.sh fails on BAD, and quotes the right sizes
runsh = (K68 / 'test' / 'run.sh').read_text()
check('exit $fail' in runsh and 'BAD' in runsh, 'run.sh fails the command on BAD')
check(not re.search(r'\b(32[0-9]|33[0-9])\b', runsh), 'run.sh quotes no stale byte counts')

# 9. all hardware harnesses poison the clobbered registers
for f in ('test/ST1_test.S', 'test/ST1_wrap_test.S', 'test/ST1_ring_test.S'):
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
    state_words = ('d2.w  signed offset/state' if f == FILES[0]
                   else 'signed offset/state in the low word')
    check(state_words in src, f'{f}: the header maps the folded state')
decoder_bodies = {
    f: '\n'.join(line for line in (K68 / f).read_text().splitlines()
                  if not line.lstrip().startswith(';'))
    for f in FILES
}
for f, body in decoder_bodies.items():
    check(re.search(r'^\s+.*\bd2\b', body, re.M), f'{f}: d2 holds lastOffset/state')
    check(re.search(r'^\s+.*\ba2\b', body, re.M), f'{f}: a2 is the copy source')
    check(not re.search(r'^\s+.*\bd6\b', body, re.M), f'{f}: d6 is untouched')
    check(not re.search(r'^\s+.*\ba[3-6]\b', body, re.M),
          f'{f}: a3-a6 are untouched')

# Gamma decoding is woven into the operation parser rather than called as a
# subroutine, and the copy ladder deliberately gives d5 the remainder/dispatch
# index while d4 carries the full-pass count. Pin the complete instruction
# shapes: a partial remap can still assemble and silently copy the wrong count.
def instruction_text(src):
    return '\n'.join(re.sub(r'\s+', ' ', code)
                     for line in src.splitlines()
                     if (code := line.split(';', 1)[0].strip()))


ladder_remap = re.compile(
    r'moveq\s+#(7|15),d5\n'
    r'and\.w\s+d4,d5\n'
    r'lsr\.w\s+#(3|4),d4\n'
    r'add\.w\s+d5,d5\n'
    r'neg\.w\s+d5\n'
    r'jmp\s+ladder_end\(pc,d5\.w\)')
woven_tail = re.compile(r'gamma_done:\nadd\.w\s+d4,d1')
gamma_core = re.compile(
    r'get_gamma:\n'
    r'addq\.w\s+#1,d1[\s\S]*?'
    r'addx\.w\s+d1,d1')
literal_gamma_fallthrough = re.compile(
    r'begin_literals:\n'
    r'neg\.w\s+d2\n'
    r'gamma_seed0:\n'
    r'moveq\s+#0,d4\n'
    r'get_gamma:')
literal_transition = re.compile(
    r'literals_transition:\n'
    r'add\.b\s+d0,d0\n'
    r'bcs\.s\s+new_offset\n'
    r'neg\.w\s+d2\n'
    r'bra\.s\s+gamma_seed0')
offset_decoder = re.compile(
    r'new_offset:\n'
    r'move\.b\s+\(a0\)\+,d4\n'
    r'roxr\.b\s+#1,d4\n'
    r'bcc\.s\s+got_offset\n'
    r'two_byte:\n'
    r'move\.b\s+\(a0\)\+,d5\n'
    r'roxr\.b\s+#1,d5\n'
    r'addx\.w\s+d4,d4\n'
    r'addq\.b\s+#2,d5\n'
    r'lsl\.w\s+#8,d5\n'
    r'add\.w\s+d5,d4\n'
    r'bpl\.s\s+(?:end_marker|resume_return)\n'
    r'got_offset:\n'
    r'move\.w\s+d4,d2')
for f in FILES:
    code = instruction_text((K68 / f).read_text())
    check(not re.search(r'\bbsr(?:\.[a-z])?\s+get_gamma\b', code),
          f'{f}: gamma decoder is woven in, with no BSR get_gamma')
    check(bool(woven_tail.search(code)),
          f'{f}: gamma tail adds the d4 seed and installs d1.w')
    check(bool(gamma_core.search(code)),
          f'{f}: gamma value is built directly in d1.w')
    check(bool(literal_gamma_fallthrough.search(code)),
          f'{f}: literal entry falls directly into get_gamma')
    check(bool(literal_transition.search(code)),
          f'{f}: from-last matches share the zero gamma seed')
    check(bool(offset_decoder.search(code)),
          f'{f}: new offsets reuse DBF/X and decode directly in d2.w')
    check(bool(re.search(r'tst\.w\s+d2\nbpl\.s\s+(?:source_ready|literal_source)',
                         code)),
          f'{f}: positive state selects literals')
    check(bool(re.search(r'tst\.w\s+d2\nbmi\.s\s+match_copied', code)),
          f'{f}: negative state selects the match tail')
    marker_target = 'resume_return' if f == 'ST1_wrap.S' else 'end_marker'
    check(bool(re.search(rf'add\.w\s+d5,d4\nbpl\.s\s+{marker_target}', code)),
          f'{f}: nonnegative decoded offsets select the end marker')
    ladder = ladder_remap.findall(code)
    expected_ladder = [('15', '4')]
    check(ladder == expected_ladder and
          code.count('dbf d4,ladder') == 1 and
          'jmp ladder_end(pc,d4.w)' not in code and
          'dbf d5,ladder' not in code,
          f'{f}: ladder uses d5 dispatch and d4 DBF exactly once')
    check('and.w #7,d4' not in code,
          f'{f}: ladder has no old immediate mask into d4')

# The pinned ROXR sequence folds both the short-offset and -32512 biases into
# bytes that started at $ff. Check its word result against the format formula
# for every selector encoding, including the end marker and reserved values.
offset_mismatches = []
for low in range(256):
    if not low & 1:
        got = 0xff00 | (0x80 | (low >> 1))
        want = ((low >> 1) - 128) & 0xffff
        if got != want:
            offset_mismatches.append((low, None, got, want))
        continue
    for high in range(256):
        low_word = 0xff00 | (0x80 | (low >> 1))
        folded_low = (2 * low_word + (high & 1)) & 0xffff
        folded_high = ((0x80 | (high >> 1)) + 2) & 0xff
        got = (folded_low + (folded_high << 8)) & 0xffff
        raw = (high >> 1) * 256 + (low & 254) + (high & 1)
        want = (raw - 32512) & 0xffff
        if got != want:
            offset_mismatches.append((low, high, got, want))
check(not offset_mismatches,
      f'ROXR offset algebra matches all encodings ({offset_mismatches[:1]})')

for f in FILES[1:]:
    code = instruction_text((K68 / f).read_text())
    gamma_tail = code[code.index('gamma_done:'):code.index('gamma_refill:')]
    check('resume_fresh:' in code and 'bra.s resume_fresh' in gamma_tail,
          f'{f}: woven gamma tail routes through resume_fresh')
    check(bool(re.search(
        r'move\.w\s+d3,d4\nsegment:\ncmp\.w\s+d1,d4\n'
        r'bls\.s\s+budget_fits\nmove\.w\s+d1,d4', code)),
          f'{f}: segment min starts from the seeded budget')
    check(bool(re.search(
        r'resume_fresh:\nmove\.w\s+d3,d4\nbne\.s\s+segment', code)),
          f'{f}: continuation test also seeds the next segment')
    check(bool(re.search(r'add\.w\s+d2,d5\nbcs\.s\s+copy', code)),
          f'{f}: offset addition carry selects an unwrapped ring source')

# Linear exposes only d1.w/d2.w. Their caller-owned upper halves must never
# become accidental scratch on resume. The ring deliberately uses both highs
# for -start.low and end.low, so it is excluded from this check.
for f in (FILES[0],):
    src = (K68 / f).read_text()
    resume = src[src.index('ST1_resume:'):]
    wide = re.findall(r'^\s+(?:\w+\.l\s+[^;]*\bd[12]\b|swap\s+d[12]\b)',
                      resume, re.M)
    check(not wide, f'{f}: resume leaves d1.high/d2.high untouched ({wide})')

# d0 exposes only its low byte as state in every decoder. Init may seed the
# whole register, but resume must preserve the caller-owned upper 24 bits.
for f in FILES:
    src = (K68 / f).read_text()
    resume = src[src.index('ST1_resume:'):]
    d0_ops = re.findall(r'^\s+(\w+(?:\.[bwl])?)\s+[^;\n]*\bd0\b', resume, re.M)
    wide = [op for op in d0_ops if not op.endswith('.b')]
    check(bool(d0_ops) and not wide,
          f'{f}: resume touches d0 only with byte operations ({d0_ops})')

# The general ring consumes its end pointer only at init, packing -start.low
# into d1.high and end.low into d2.high; resume has no persistent bound register.
ring_src = (K68 / FILES[1]).read_text()
ring_init = instruction_text(
    ring_src[ring_src.index('ST1_init:'):ring_src.index('ST1_resume:')])
check(bool(re.search(
      r'moveq\s+#0,d1\nsub\.w\s+a1,d1\nswap\s+d1\n'
      r'moveq\s+#-1,d2\nmove\.w\s+d3,d2\nswap\s+d2', ring_init)),
      'general ring init packs -start.low/end.low into the state highs')

# Counted wrap packs the same start identity but stores runtime N rather than
# end.low, and deliberately contains no destination-room clamp or auto-wrap.
wrap_src = (K68 / 'ST1_wrap.S').read_text()
wrap_init = instruction_text(
    wrap_src[wrap_src.index('ST1_init:'):wrap_src.index('ST1_resume:')])
check(bool(re.search(
      r'moveq\s+#0,d1\nsub\.w\s+a1,d1\nswap\s+d1\n'
      r'moveq\s+#-1,d2\nmove\.w\s+d3,d2\nswap\s+d2', wrap_init)),
      'counted wrap init packs -ring_start.low/N into the state highs')
wrap_code = instruction_text(wrap_src)
check('short_room:' not in wrap_src and 'wrap_a1:' not in wrap_src and
      'room = end.low' not in wrap_src,
      'counted wrap contains no destination bounds or automatic wrap')
check('N mod C = 0' in wrap_src and 'F = N/C' in wrap_src and
      'ceil(O/C)' in wrap_src and 'I is the packed input size' in wrap_src,
      'counted wrap states its I/O/N/C caller contract')
check('HAS NO DONE STATE' in wrap_src and 'never make another decode call' in wrap_src,
      'counted wrap warns that T is the only completion control')
check(bool(re.search(
      r'move\.l\s+d2,d5\nclr\.w\s+d5\nswap\s+d5\nadda\.l\s+d5,a2',
      wrap_code)),
      'counted wrap zero-extends runtime N for wrapped match sources')
check(not re.search(r'\d+-byte word-aligned context', readme),
      'README promises no context block')

# Both ABIs expose the same compact, gap-free scratch set.
for f in FILES:
    src = (K68 / f).read_text()
    header = src[:src.index('TRUSTED INPUT ONLY')]
    clobbers = re.search(r'CLOBBERED\s+d3\.w\s+d4\.l\s+d5\.l[\s\S]{0,80}\ba2\.l',
                         header)
    check(bool(clobbers), f'{f}: names d3/d4/d5/a2 as its clobbered set')

# The calling sequences in the README are code a reader will copy, so they have
# to use the registers the decoders actually use.
for block in re.findall(r'```\n(        lea     stream.*?)```', readme, re.S):
    check('bsr     ST1_resume' in block, 'README example calls ST1_resume')
    check('tst.w   d1' in block, 'README example tests remaining/result in d1')
    check(re.search(r'moveq   #\d+,d3', block), 'README example passes the budget in d3')
    check('tst.w   d0' not in block, 'README example does not test the old return register')

# 13. the operation-length contract, stated identically in both headers and
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

# Timing data is generated from the current decoder/compressor/harness inputs.
# This cheap audit path does not invoke Unicorn or Hatari: it verifies the
# recorded content fingerprint and both exact generated README blocks.  The
# full cycle trace remains available as cycle_model.py --check.
timing_audit = subprocess.run(
    [sys.executable, str(K68 / 'test' / 'emu' / 'cycle_model.py'), '--audit'],
    capture_output=True, text=True)
check(timing_audit.returncode == 0,
      'cycle/tick tables match current inputs and generated docs'
      + (f' ({timing_audit.stdout.strip()})' if timing_audit.stdout.strip() else ''))

# 15. the trusted-input boundary is stated where a caller will see it
for f in FILES:
    check('TRUSTED INPUT ONLY' in (K68 / f).read_text(), f'{f}: states trusted-input-only')
check('### Trusted input only' in readme, 'README has the trusted-input section')

print(f'PASS {len(ok)}')
for m in bad:
    print(f'  FAIL {m}')
sys.exit(1 if bad else 0)
