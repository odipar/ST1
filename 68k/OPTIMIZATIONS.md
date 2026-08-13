# 68k optimization exploration (opt7 baseline)

A themed, measured search for optimizations beyond `jx1_68000_opt7.S` (324 bytes),
run as six parallel prototype efforts. Every variant below **assembled, passed the
13-case differential harness at chunks 16/1/7/127 and the even/odd-destination
alignment audit, and was cycle-measured under emulation** against opt7 on six
corpora (word-soup = parse-heavy, text, far-match, all-same, max-offset = barely
compressible, rle-32k) at chunks 16 and 127. Nothing here is estimated unless
explicitly marked as cycle math.

Method and tooling: vasm assembly, Unicorn 68000 emulation, a per-instruction
cycle model built from the vasm listing (M68000UM timings, branch takenness
resolved dynamically), differential testing against Java-compressed streams.

## Where opt7 spends its cycles

| region | word-soup X127 | text X127 | rle X127 | rle/text X16 |
|---|---|---|---|---|
| copy ladder | 32% | 63% | 86% | 42-49% |
| gamma | 21% | 11% | ~0% | 6% |
| offset-decode | 20% | 6% | ~0% | - |
| take_budget+source-select | 14% | 7% | 4% | 14% |
| entry+dispatch+suspend | 1% | 3+11% | 8% | 24-30% |

## Cycle-model corrections discovered during this work

The stock rig undercounted three things (all corrected in the agents' local
models before any number below was reported; the opt7 baseline is unaffected):

* any instruction with a `d8(pc,Xn)` source EA: real cost = op + 10 (e.g.
  `move.w d8(pc,Xn),Dn` = 14, `add.w` = 14, `move.l` = 18; M68000UM Table 8-2)
* `subi.w #imm,Dn` = 8 (not 4)
* not-taken `Bcc.w` = 12 (the model says 8); both opt7 and the variants have
  exactly one hot not-taken `.w` branch, so deltas are fair, and variants that
  replaced it with `.s` are slightly better on real silicon than reported

## Percentages below

Positive = fewer cycles than opt7. Corpus columns: ws = word-soup, txt = text,
fm = far-match, as = all-same, mo = max-offset, rle = rle-32k; 16/127 = chunk.

## Flow re-plumbing

State re-encoding, context reordering, take_budget gate folding, gamma de-subroutining, per-state copy engines.

| variant | bytes | verdict | ws16 | ws127 | txt16 | txt127 | fm16 | fm127 | as16 | as127 | mo16 | mo127 | rle16 | rle127 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| wc1 | 316 | win | +6.8 | +6.3 | +5.4 | +3.2 | +5.0 | +1.5 | +5.0 | +1.5 | +5.2 | +1.8 | +5.0 | +1.4 |
| wc2 | 308 | win | +10.7 | +11.3 | +6.5 | +5.2 | +5.1 | +1.7 | +5.1 | +1.8 | +5.4 | +2.1 | +5.0 | +1.4 |
| wc3 | 326 | win | +14.3 | +14.8 | +9.7 | +7.1 | +8.0 | +2.5 | +8.0 | +2.7 | +9.4 | +3.4 | +7.9 | +2.2 |

**wc1: state/flow re-plumb** (316 bytes, win): Four independent re-plumbings of opt7, gamma and ladder untouched. (1) Op state re-encoded 0=LITERALS/2=MATCH/$80=START/$FF=DONE: all three cmp.b #1,d4 (8) become tst.b d4 (4), and entry dispatch collapses to one bmi on the state load's own flags. (2) Context tail reordered to state@12/bits@13/chunk@14 (src/dst stay 4/8): entry reads state first with fresh flags, suspend stores via two pure pre-decrements, killing the subq.l #1,a5 (-8/suspend). (3) take_budget exploits the invariant remaining>=1 at resume_op: only the clamped path can yield d0=0, so tst.w d0 dies and the fits-path drops both test and branch (-12 per within-budget pass). (4) The two post-copy d4 tests (a0-sync and transition dispatch) merge into one tst.b fork with duplicated 3-word suspend checks (-22/-20 per completed literal/match op).

**wc2: wc1 + gamma woven into the flow** (308 bytes, win): All of wc1, plus: every get_gamma call site continues to resume_op, so gamma stops being a subroutine and its body falls through into resume_op via a shared tail (add.w d0,d1 / move.w d1,d3). The +1 that match-from-new-offset needs becomes a caller-seeded d0 (moveq #0 or #1), which also absorbs the move.w d1,d3 all three callers duplicated. Net -26 cycles per gamma (bsr 18 + rts 16 die, seed+tail add 8 appear); begin_literals falls into gamma with zero branches, the other two sites pay one taken bra (width-free 10). 16 bytes smaller than opt7.

**wc3: wc2 + per-state copy engines** (326 bytes, win): All of wc2, plus the copy path forks per op state after the shared pass-size computation: literals get their own 8-step ladder reading (a0)+ directly, so the movea.l a0,a2 staging, the post-copy movea.l a2,a0 sync, and the post-copy discrimination all die; matches keep the a2 ladder with the offset subtraction inside their fork. One tst.b d4 per pass is the only remaining state test. The #7 pass mask preloads into d7 once per call (and.w d7,d0 = 4 vs and.w #7 = 8 per pass). -26 (literals) / -20 (match) cycles per copy pass over wc2, for ~30 bytes of second ladder (+2 bytes vs opt7 total). d7 added to the clobber list.

### Insights and negative results

* Seed (b) rejected analytically: keeping the match source a2 alive across suspends by growing the context and extending both movems to d3/a0-a2 costs +8 entry +8 suspend = +16 on EVERY call, but saves at most movea.l a1,a2 + swap/suba/swap = 20 cycles, and only on calls that re-enter a suspended MATCH (at most one per call; zero when the suspended op is literals). At X=16 roughly half of re-entries are literals, so expected saving < 10/call vs a certain 16/call cost; at X=127 suspends are rare so both terms vanish. Strictly worse everywhere.
* Shadowing lastOffset unpacked in d6 to kill the two swaps around suba.w (save 8 per match source-select) costs +8/call to unpack (move.l d3,d6; swap d6) and +4 per new offset to keep the shadow coherent. At X=16 with ~1 match pass per call it is a wash, and wc3's per-state fork already moved the whole trio off the literals path, shrinking the remaining exposure to ~1% of total cycles. Not prototyped.
* Only one block can fall through into resume_op. Entry (1x/call), begin_literals, and the gamma tail all want it; gamma continues into resume_op once per op (~3x/call at X=16, ~20x/call at X=127 parse-heavy) so gamma wins the fall-in, begin_literals wins the fall-in to gamma, and entry pays one taken bra.s (10 cycles, width-free). Giving entry the fall-in instead would cost 10 per gamma = ~200/call on word-soup X=127.
* The tst.w d0 elimination in take_budget rests on a provable invariant: remaining >= 1 at every resume_op entry (gammas are >= 1, new-offset remaining = gamma+1, the pre-op suspend site branches before the subs so it stores remaining untouched, and the mid-op site requires d3 != 0). Hence d0 = min(remaining, budget) is zero only via the clamped move.w d5,d0, whose own flags feed beq - the fits path drops test AND branch (-12/pass, the dominant per-pass win at X=127).
* Context byte order is a suspend-path resource: with state@12/bits@13/chunk@14 the entry reads state first (its move.b flags feed a single bmi - no tst, no cmp.b #3) and suspend becomes two pure pre-decrements plus movem, killing subq.l #1,a5. The alternative orderings all force either an explicit tst.b at entry or a hole-skip at suspend; opt7's order (chunk,bits,state) is the unique worst case for suspend. Note the two rare states must be the negative encodings and stay distinguishable after one add.b d4,d4 ($80->0 vs $FF->$FE).
* Model caveat (applies equally to both sides of the comparison): the cycle harness charges not-taken conditionals 8 regardless of width, but real silicon charges 12 for a not-taken Bcc.w. Both opt7 and the variants have exactly one hot not-taken .w branch (beq.w suspend on the clamped budget path), so the reported deltas are fair, but absolute counts flatter both by 4 cycles per clamped pass.
* Attribution from the measured ladder wc1->wc2->wc3 on word-soup X=127: plumbing (state encoding + entry/suspend + take_budget + merged post-copy) = +6.3%, de-subroutining gamma = +5.0 points more, per-state copy engines = +3.5 points more. On copy-dominated rle-32k X=127 the total stays ~+2% because 86% of cycles are the untouched ladder; at X=16 every corpus gains 5-8% mostly from the -16/call fixed entry+suspend cost plus -12 per clamped pass.

## Per-call fixed overhead: threaded dispatch

Targets entry+dispatch+suspend (24-30% of cycles at chunk 16). The context stores a code displacement instead of a state byte; dispatch becomes one pc-indexed jmp.

| variant | bytes | verdict | ws16 | ws127 | txt16 | txt127 | fm16 | fm127 | as16 | as127 | mo16 | mo127 | rle16 | rle127 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| v1_threaded | 318 | win | +4.1 | +3.0 | +4.5 | +1.5 | +4.9 | +1.3 | +4.8 | +1.2 | +4.4 | +1.3 | +5.0 | +1.4 |
| v2_threaded_fold | 316 | win | +6.1 | +5.0 | +5.5 | +2.5 | +5.6 | +1.6 | +5.6 | +1.5 | +5.2 | +1.6 | +5.7 | +1.6 |
| v3_threaded_split | 350 | win | +6.9 | +5.2 | +8.0 | +2.9 | +8.8 | +2.4 | +8.7 | +2.3 | +8.7 | +2.5 | +8.9 | +2.5 |

**v1_threaded** (318 bytes, win): Threaded state (seed a): the context stores a code-displacement word (relative to resume_op) instead of a state byte, and jx1_resume dispatches with a single jmp resume_op(pc,d4.w), eliminating the beq/cmp/bne compare chain (entry 90 -> 74 cycles mid-op). d4 carries the displacement through the op so suspend still stores it verbatim: MATCH = 0 lands on resume_op itself, LITERALS = -2 lands on a hoisted movea.l a0,a2 prefix, START/DONE get their own targets. The 0-encoding turns the three cmp.b #1,d4 state tests into tst.w d4 (-4 each) and matches skip the movea. Context: chunk widened to a word at 12 (kills moveq #0,d5), disp word at 14, bits at 16.

**v2_threaded_fold** (316 bytes, win): V1 plus the suspend gate folded into take_budget (seed c): remaining (d3) is provably >= 1 whenever resume_op runs, so min(remaining,budget) can only be 0 on the clip branch with budget = 0. The tst.w d0 / beq.w suspend pair therefore moves behind the clip's move.w d5,d0 (which sets Z for free), cutting the common take_budget path from 34 to 22 cycles per op with zero cost anywhere. Two bytes smaller than V1 and 8 smaller than opt7.

**v3_threaded_split** (350 bytes, win): V2 plus specialized mid-op re-entries and a minimal-load context layout. A resumed op always has remaining >= 1 and budget = chunk >= 1, so the threaded dispatch lands on per-state blocks r_lit/r_match (jmp base = r_match keeps MATCH = 0) that run a gate-less take_budget with the state select pre-folded; the generic resume_op serves only ops started inside a call. Context: disp word at 12, bit buffer widened to a word at 14 (queue in the low byte, dead pad rides in d2 bits 8-15), read-only chunk on top at 16 - entry becomes movem + three sequential move.w (a5)+ + jmp (74 cycles) and suspend two predecrement word stores + movem (68 cycles, subq gone). Costs +26 bytes over opt7.

### Insights and negative results

* Register folding via movem (seed b) is arithmetically a wash on 68000: movem.l costs 12+8n load, and move.w (a5)+ costs 8, so every register folded past the mandatory d3/a0-a1 trio saves nothing before unpack cost. Concretely: loading a packed chunk:disp long into a spare address register at offset 12 (movem.l (a5)+,d3/a0-a1/a3 = 44) plus unpack (move.l a3,d4 = 4; move.l a3,d5 + swap d5 = 8) plus the bits load (8) totals 64 cycles vs 60 for opt7-style discrete loads - a 4-cycle LOSS before even paying to repack at suspend. The winning form of (b) is keeping every load at 8 cycles: three sequential move.w (a5)+ behind the movem, with the bit queue widened to a word whose pad byte rides in d2's unused bits 8-15 (nothing reads them; suspend stores the whole word back). That got entry to 74 = 36+8+8+8+14 and suspend to 68 = 8+8+32+4+16, both structural minimums given the ABI.
* Byte-packing bits+disp into ONE context word fails: the displacement must reach jmp's index as a sign-extended word, and the bit queue must sit in d2's LOW byte for add.b d2,d2. Whichever field gets the high byte needs extraction - lsr/asr #8 is 6+2*8 = 22 cycles, and the ext.w route (disp in low byte, ext.w d4 = 4) forces the bits into the high byte where the queue can't live. 68000 byte extraction always costs at least as much as the single 8-cycle load it would eliminate.
* jmp (An) threading (store an absolute resume address, computed pc-relatively at suspend, loaded via a 4-register movem, dispatch with jmp (a3) = 8 vs jmp d8(pc,Xn) = 14) was evaluated and rejected analytically: entry would drop to 68 (44 movem + 8 bits + 8 chunk + 8 jmp) and suspend stays 68 (the address store folds into the movem: 8+40 = 48 vs 8+8+32 = 48), a net -6 per call - but the body's three state tests still need d4, so every op start must maintain BOTH d4 (moveq, 4) and a3 (lea r_x(pc),a3, 8): +8 per fresh op. At X=16 parse-heavy data starts 2-4 ops per call (+16..32 vs -6) and at X=127 dozens - a clear loss everywhere.
* take_budget suspend-gate fold (V1->V2, the (c) seed): d3 >= 1 is an invariant at resume_op (a fresh literal gamma is >= 1, a match is gamma+1 >= 2, and both suspend sites require d3 > 0), so min(d3,d5) = 0 can only happen when the clip branch fires with d5 = 0. Moving beq.w suspend behind the clip's move.w d5,d0 (which sets Z for free) cuts the common bls-taken path from 34 to 22 cycles per op and even the suspend path from 38 to 26. Measured V1->V2: word-soup X=127 +3.0%->+5.0%, X=16 +4.1%->+6.1%; it also shrinks the binary by 2 bytes. The same invariant is what lets V3's specialized mid-op landings drop the gate entirely (budget = chunk >= 1 and remaining >= 1 on every re-entry, so min >= 1).
* Specialized per-state re-entry blocks (V2->V3) pay mostly on copy-dominated data where nearly every call resumes a match: r_match skips the state select (12) and the gate branch, r_lit additionally pre-folds its movea; each costs a bra.s (10) into the shared ladder dispatch, deliberately placed so the generic fresh-op path keeps its fall-through (a layout where specialized entries fall through instead would move the 10-cycle bra onto every fresh op start and regress X=127). Measured V2->V3: rle-32k X=16 +5.7%->+8.9%, far-match +5.6%->+8.8%, but word-soup X=127 only +5.0%->+5.2%. Costs +34 bytes.
* The threaded entry is free even where it doesn't help: START dispatch is 74 cycles in both designs (opt7's beq.s falls out of the first compare), and the DONE re-poll never appears in the cycle measurements (the harness loop stops at the call that hits end_marker), so done_stub cost is correctness-only. One design property to note: a threaded context stores code displacements, so a suspended context is resumable only against the same code image layout - opt7's byte-state context was layout-independent. ctx_src/ctx_dst stay at 4/8 in all variants; alloc stays 18 (even).
* Attribution honesty: V1's gain is not pure entry threading. Threading removes 16 cycles per mid-op call, but choosing MATCH = displacement 0 also turns the three 8-cycle cmp.b #1,d4 state tests into 4-cycle tst.w d4 and lets the match path skip the hoisted movea.l a0,a2 - roughly 8-16 cycles per OP, which is why V1 already shows +1.2-3.0% at X=127 where entry overhead itself is only 1-4% of cycles.

## Copy engine: RLE fills and aligned tiers

Targets the copy ladder (32-86% of cycles). RLE register fills for offsets 1-2 (~3.3 c/b), an aligned `move.l` tier (~5.3 c/b), and ladder-length experiments.

| variant | bytes | verdict | ws16 | ws127 | txt16 | txt127 | fm16 | fm127 | as16 | as127 | mo16 | mo127 | rle16 | rle127 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| v1 rlefill | 442 | mixed | -6.1 | -8.8 | -10.1 | -4.1 | -7.8 | +41.8 | -7.6 | +48.5 | -8.7 | -2.6 | -7.5 | +51.6 |
| v2 filltier | 530 | mixed | -1.6 | -2.1 | -7.4 | +23.7 | -5.6 | +47.9 | -5.1 | +49.1 | -9.6 | +16.8 | -5.4 | +52.2 |
| v3 fill32 | 564 | win | -1.6 | -0.6 | +0.5 | +23.5 | +1.3 | +47.8 | +1.3 | +49.0 | +1.3 | +17.7 | +1.4 | +52.1 |

**v1 rlefill (fill only, bulk gate n>=8)** (442 bytes, mixed): opt7 plus an RLE register fill for offset-1/2 matches: the existing dispatch lsr.w #3 sets Z when n<8, so a bne.s gates a bulk path for free (smalls pay one not-taken branch, 8 cycles). Fills write 2-3 head bytes so the last two output bytes are the repeating pattern (offset 1 doubles the byte, offset 2 is 2-periodic by definition), read the pattern word back with move.w -2(a1), replicate to a longword, and store through an 8-step move.l d1,(a1)+ ladder with the same pc-relative partial dispatch (~3.3 c/b vs 13.3). Fill decision is re-derived from d3's high word each resume_op pass, so suspended fills re-enter correctly.

**v2 filltier (fill + aligned move.l tier, 16-ladder, gate n>=16)** (530 bytes, mixed): Adds an aligned move.l copy tier for bulk literals and matches: equal src/dst parity plus a head byte when a1 is odd, then an 8-step move.l (a2)+,(a1)+ ladder (~5.3 c/b) with word/byte tail. The byte ladder grows to 16 steps so lsr.w #4's Z flag gates bulk at n>=16 for free. The parity gate subsumes opt4's explicit offset>=4 overlap check: fills intercept offsets 1-2 and offset 3 is odd, hence mixed parity. Flips text/max-offset X=127 to wins but every chunk-16 continuation op (exactly n=16) enters bulk where fill/tier only break even, so X=16 regresses.

**v3 fill32 (fill + tier, 32-ladder, gate n>=32) - RECOMMENDED** (564 bytes, win): Same fill+tier engine as v2 but the byte ladder grows to 32 steps so lsr.w #5's Z flag gates bulk at n>=32, keeping all chunk-16 traffic out of the bulk machinery entirely. Bonus: 16-byte chunks become pure partial-entry ladder copies with zero dbf passes, which more than pays back the +12/op gate tax on copy-dominated X=16 data (hence the positive X=16 numbers). Near-strict improvement over opt7; only word-soup (many sub-8-byte ops that pay the gate and never use bulk) stays slightly negative.

### Insights and negative results

* Bulk-gate threshold must exceed the common chunk size, not the technique's cycle breakeven. Fill/tier breakeven is n~13-16, but at X=16 every continuation chunk of a long op is exactly n=16 and those dominate copy-heavy streams: measured tier@16 aligned costs ~+36 and misaligned bounce ~+64 vs the plain ladder (v2 max-offset X=16 -9.6%, rle-32k X=16 -5.4%). Raising the gate to n>=32 (v3) turned every X=16 corpus positive or ~flat while keeping the X=127 wins - at X=127 all long-op chunks are n=127 so nothing was lost.
* Free n-threshold gating: match the byte-ladder length to the gate so the dispatch shift's Z flag IS the gate (8-ladder/lsr#3, 16-ladder/lsr#4, 32-ladder/lsr#5). Small copies pay only one not-taken branch (8 cycles) plus 2 cycles per extra shift bit; an explicit compare would cost 12-16. The bne targets a bra.w trampoline in the dead space between the dispatch jmp and the ladder (bulk ops pay +10, amortized over >=32 bytes) because the bulk block itself is out of bcc.s range.
* The parity gate subsumes opt4's explicit offset>=4 overlap check once RLE fills own offsets 1-2: offset 3 is odd, and any odd offset gives src/dst mixed parity, so every match that reaches the aligned move.l ladder has an even offset >= 4 (each longword read touches only finalized bytes). Saves ~20 cycles of gating per bulk match vs opt4's engine.
* A 32-step byte ladder is a win on its own at chunk 16: n=16 copies become a pure partial entry with zero dbf passes (dbf overhead falls from 1.25 to 0.31 c/b, ~-20 cycles per 16-byte chunk), which is where v3's +1.3-1.4% X=16 on copy-dominated corpora comes from despite the +12/op gate tax. The 32-bit-entry jmp d8(pc,Xn) displacement (~70 bytes to ladder_end) still fits the 8-bit index range.
* RLE fill pattern can be rebuilt from memory instead of shifted into a register: after 2 head bytes (3 if a1 odd) the last two output bytes are provably the repeating pattern for offsets 1 AND 2, so move.w -2(a1),d1 + 3-move word-to-long replicate (24 cycles) beats the lsl.w #8 byte-replicate route (38+ cycles) and self-handles resumability since it re-derives everything from d3's offset and the already-written output.
* Negative result - fill without a tier (v1) is a bad trade on mixed data: non-fill bulk ops pay a ~48-58 cycle round trip through the checks (10 gate + 10 trampoline + 8 cmp.b + 8-20 offset extract + 10 bounce) and get nothing, costing -4..-10% on text/word-soup/max-offset. A bulk path is only worth entering if nearly every visitor gets a payoff (v2/v3's tier gives literals and even-offset matches one).
* Negative result, cycle math only - movem literal copies: movem.l (a2)+,regs + movem.l regs,(a1) with r registers is (12+8r)+(8+8r) cycles per 4r bytes plus ~8 for lea to advance a1, i.e. ~5.5-6.0 c/b with the 5-6 free registers (d1/d6/d7/a3/a4/a6), no better than the 8-step move.l (a2)+,(a1)+ ladder at 5.3 c/b (20c/4B + 10c dbf per 32B), while clobbering more registers and needing both pointers even. Not prototyped.
* Negative result, cycle math only - implementing the fill by promoting offset 1/2 to offset 4 and reusing the copy tier (write 4-5 head bytes, set a2=a1-4) would save ~30 code bytes but runs at 5 c/b (every long store rereads memory) vs 3.3 c/b for the register fill: at n=127 that is ~+235 cycles per chunk, ~15% of the whole rle-32k X=127 call. Rejected.
* Negative result, cycle math only - a zero-tax gate that routes bulk detection through the ladder's dbf branch target (smalls fall through the dbf exit unchanged, cost 0) makes sub-8-byte ops free but mid ops (8-31 bytes) pay ~+26 (threshold subq/bpl/addq + re-entry + final bra.w) vs v3's -8..+12, and the post-partial remainder is only 8-aligned until the tier's alignment head byte breaks it, reintroducing tail handling. Computed as a wash against v3 on word-soup's mix; not prototyped. Word-soup's residual -1.6%/-0.6% (ops mostly <8 bytes paying +12 and never using bulk) appears irreducible within this structure.
* Honesty note on the cycle model: I avoided cmp.w #imm in all hot paths (the model prices cmp.w at 4 even for immediates; real cmpi.w is 8) by using moveq+cmp.w Dn,Dn, so no model extension was needed and no variant benefits from the undercount. All other mnemonics used (btst 10, jmp d8(pc,Xn) 14, lsr.w #n 6+2n, move.l Dn,(An)+ 12, move.l (An)+,(An)+ 20) match M68000UM timings in the harness model.

## Offset decoding via LUT

Targets the new-offset decode (20% of word-soup cycles). A 256-word table F[H] = 32512-(H>>1)*256-(H&1) collapses the two-byte-form arithmetic to one indexed add.

| variant | bytes | verdict | ws16 | ws127 | txt16 | txt127 | fm16 | fm127 | as16 | as127 | mo16 | mo127 | rle16 | rle127 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| lut1_htab | 828 | win | +2.3 | +3.0 | +0.2 | +0.4 | +0.1 | +0.1 | +0.1 | +0.2 | +0.1 | +0.1 | +0.0 | +0.0 |
| lut2_offpath | 836 | win | +3.7 | +4.8 | +0.7 | +1.2 | +0.1 | +0.2 | +0.1 | +0.3 | +0.1 | +0.1 | +0.0 | +0.0 |
| lut3_ldisp | 1346 | mixed | +2.9 | +3.8 | +0.5 | +1.0 | +0.1 | +0.1 | +0.1 | +0.2 | +0.1 | +0.1 | +0.0 | +0.0 |

**lut1_htab** (828 bytes, win): Minimal drop-in: the two-byte offset tail (lsr/bcc/addq/lsl#8/add/neg/add.w#) is replaced by a 256-entry word LUT F[H] = 32512-(H>>1)*256-(H&1), fetched with a base-register-free pc-indexed add (add.w offtab(pc,d0.w),d3), so offset = F[H]-(L&254) in one add. The end-marker test folds into the same add: F[254]=0 and F[255]=-1 are the only entries <= 254, so 'ble end_marker' fires exactly when opt7's arithmetic did, for every (L,H) - byte-exact by construction. Two-byte decode drops from 112-118 to 88 cycles; one-byte path untouched; code shrinks 8 bytes, table adds 512.

**lut2_offpath** (836 bytes, win): lut1 plus three independently-correct offset-path refinements: (1) drop the dead 'moveq #0,d3' at new_offset (both entries fall through 'tst.w d3 / bne.s suspend', so d3.w is provably 0; the dying lastOffset in the high word never leaks because got_offset's swap puts it under move.w d1,d3) - -4 cycles/offset; (2) move the copy-ladder dispatch index from d0 to free d6 (moveq #7,d6 / and.w d0,d6 costs exactly what andi.w #7,d0 did), so d0.w still holds take_budget's count 1..127 at new_offset and the H fetch needs no 'moveq #0,d0' - -4 cycles/two-byte; (3) duplicate the 14-byte got_offset tail into the one-byte path, deleting its bra.s - -10 cycles/one-byte. Net per decode vs opt7: one-byte 54->40, two-byte 112-118->72. New clobber: d6 (documented in header). Best variant; strictly dominates lut1 and lut3 on every corpus/chunk line.

**lut3_ldisp** (1346 bytes, mixed): Seed idea (b) measured: one 256-entry interleaved stride-4 table indexed by the LOW byte, move.w ltab(pc,4L) returns either the finished one-byte offset (positive) or the negative partial -(L&254)-1, whose sign replaces the lsr-carry as form dispatch; the two-byte form adds F[H]+1 from the interleaved second column (interleaving keeps both columns within one d8 pc reach). Built on lut2's other refinements so the diff isolates the dispatch scheme. Beats opt7 everywhere but is strictly dominated by lut2: the 14-cycle table read + extra stride add.w lose to the 8-cycle lsr dispatch (one-byte 42 vs 40, two-byte 82 vs 72), at +510 bytes.

### Insights and negative results

* CYCLE MODEL FIX (required for honest numbers): the stock evalvariant.py silently times add.w/move.w with a d8(pc,Xn) source as 4/8 cycles (it only special-cases immediates); the real 68000 cost is 14 (op 4 + EA 10, M68000UM Table 8-2). I copied it to /private/tmp/claude-504/-Users-rapido-git-jx1/a5bf6f8d-751d-49c3-a8b8-16656573dd92/scratchpad/evalvariant_lut.py, inserting an early '(pc,' block ahead of the generic rules (move.b/move.w/add.w/sub.w/cmp.w/and.w/or.w/eor.w=14, move.l=18, add.l/sub.l/cmp.l=20, lea=12, jmp=14, raise on anything else pc-indexed). The opt7 baseline is unchanged (its jmp (pc,Xn) was already 14): stock and fixed both report opt7 word-soup X=127 = 174384. Under the stock model lut1 would have claimed +3.9% word-soup/X127 instead of the true +3.0% - 1510 phantom cycles (151 pc-indexed adds x 10). All reported numbers use the corrected model.
* Seed (b) (single L-indexed dispatch table) is measurably WORSE than lsr-carry dispatch + H-table: lut3 vs lut2 on word-soup X=127 is 167826 vs 166054, 1772 cycles apart, matching the predicted 131x2 + 150x10 = 1762. The table read (14) can't beat lsr.b #1 (8) as a dispatcher, and the stride-4 interleave (needed to keep both columns within one d8 pc-displacement) costs an extra add.w per lookup.
* A one-byte-offset LUT can never pay: move.w d8(pc,Xn) is 14 cycles plus index formation, while opt7's neg.w/add.w #128 arithmetic is 12. Verified variants of this idea (128-word table indexed by L&254, or by L after lsr) all lose >= 6 cycles per one-byte offset.
* Seed (c) branchless no-table disproven analytically: offset = 32512 - 128H + 127(H&1) - (L&254) replaces the lsl.w #8 (22) + bcc/addq (~11 avg) with lsl.w #7 (20) plus extra flag plumbing - saves at most ~10 of the ~35 the LUT saves. The move.b (a0)+,-(sp)/move.w (sp)+ high-byte trick is 20 cycles plus an 8-cycle and.w to kill the garbage low byte, also a loss.
* Pre-swapped long-entry table (storing F[H]<<16, add.l ...(pc,d0.w) to skip got_offset's swap) loses: add.l d8(pc,Xn) is 20 vs add.w 14+swap 4, and the L-part needs its own extra swap - 56 vs 50 effective cycles. 1KB table for a slowdown.
* Half-size table is a size knob, not a speed win: 128 words indexed by H&254 (handling H&1 via subx.w with a zeroed register before the index add.b clobbers X) costs +16 cycles vs lut1's two-byte path to save 256 table bytes.
* Keeping a dedicated zero register (d7=0) to skip 'moveq #0,d0' before the H fetch fails: add.w d7,d7 dirties bit 8 of the index register, and re-clearing costs exactly the moveq. The working alternative (lut2) is moving the ladder dispatch index to d6 so d0 still holds take_budget's count 1..127 - high byte already clear, genuinely free since moveq #7,d6/and.w d0,d6 costs the same 8 cycles as andi.w #7,d0.
* 'moveq #0,d3' at new_offset is dead in opt7 itself (back-ports with no LUT): both entry paths fall through 'tst.w d3 / bne.s suspend', so d3.w = 0; the old lastOffset in d3's high word never leaks because got_offset's swap drops it into the low word that move.w d1,d3 overwrites. -4 cycles per new-offset decode, -2 bytes.
* Branch-sense flip (making two_byte the fall-through) is noise: measured form frequencies word-soup 131 one-byte vs 150 two-byte, so flipping saves 2x150 - 2x131 = 38 cycles across the whole corpus. Not prototyped.
* Offset-form census (why gains concentrate on word-soup): word-soup 131 one-byte/150 two-byte new offsets, text 4/0, far-match 0/1, max-offset 3/17, all-same 0/0, rle-32k 0/0. The 20%-of-cycles profile bucket is word-soup-specific; on copy-dominated corpora the theme's ceiling is the ~0.1% from the removed moveqs.
* The cycle accounting validates end-to-end: lut1's word-soup X=127 gain 5288 ~ 150 two-byte x ~35; lut2's 8330 ~ 150x35 + 131x14 + 150x8 = 8322 - the per-site math predicts corpus totals to within 10 cycles.
* Layout constraint for merging with other variants: the base-register-free 'add.w offtab(pc,d0.w),d3' needs the table base within +127 bytes of the instruction's extension word (currently ~62: only got_offset tail, literals_transition, suspend, end_marker sit between). If merged code pushes new_offset further from the section end, either keep the offset path last before the tables or fall back to lea+indexed at +8 cycles per two-byte offset.

## Gamma decoding via LUT

Targets gamma parsing (16-21% of parse-heavy cycles). Byte-indexed lookup tables decoding whole small gammas.

| variant | bytes | verdict | ws16 | ws127 | txt16 | txt127 | fm16 | fm127 | as16 | as127 | mo16 | mo127 | rle16 | rle127 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| g_t0 | 870 | win | +1.5 | +2.0 | +1.0 | +1.9 | +0.2 | +0.4 | -0.1 | -0.2 | +0.1 | +0.1 | -0.0 | -0.0 |
| g_t0h | 624 | win | +1.3 | +1.7 | +0.9 | +1.6 | +0.2 | +0.4 | -0.0 | -0.1 | +0.1 | +0.1 | -0.0 | -0.0 |
| g_t0r | 874 | win | +1.7 | +2.2 | +1.1 | +2.0 | +0.2 | +0.5 | -0.1 | -0.1 | +0.1 | +0.2 | -0.0 | -0.0 |

**g_t0: byte-indexed gamma LUT on refill-aligned gamma starts** (870 bytes, win): opt7 plus one 512-byte table T0 of interleaved (value, queue-after) byte pairs indexed by 2*raw-byte. When get_gamma's peeled first continuation bit finds the queue empty (the gamma starts on a byte boundary - 26% of word-soup gammas), the whole fresh byte is decoded in two pc-relative indexed move.b lookups (hit: 70 cycles flat for any value 1..15 vs 66/98/130 bitwise for k=1/2/3). The 16 all-continuation bytes (gamma >= 9 bits) store a partial value 16+raw4 in the queue slot; the big path resumes bitwise at the next byte, which the opt3 invariant guarantees opens on the gamma's next continuation bit. get_gamma is relocated to the end of the code so d8(pc,Xn) reaches T0 with no base register and zero per-call setup; queue-resident starts and mid-gamma refills stay bitwise (measured distributions make queue-indexed LUTs a loss).

**g_t0h: half-size (256-byte) table with value-1 short-circuit** (624 bytes, win): Same as g_t0 but the table only covers bytes with bit 7 set: bpl short-circuits value-1 gammas (byte < $80) into a 12-cycle queue rebuild (+14 vs opt7 instead of the full path's +32, halving the stream-opener regression on all-same/rle-32k), and the index 2b-256 falls out of a byte-wrapping add.b for free. Costs one extra not-taken bpl (8 cycles) on every k>=1 lookup, giving back ~600 of g_t0's ~3500-cycle word-soup win in exchange for 246 bytes. The size-optimized point on the curve.

**g_t0r: g_t0 + out-of-line mid-gamma refill (best overall)** (874 bytes, win): g_t0 with the pair loop's continuation read rotated the same way as the peel: the mid-gamma refill moves out of line behind a beq, so the common non-refill read pays a not-taken beq (8) instead of a taken bne (10), while the refill path pays +2 (refills hit at most 1 in 4 continuation reads). The addx sentinel insertion still works out of line because Bcc leaves X untouched. Strictly the best cycle counts of the three on every corpus with meaningful gamma traffic; the residual -0.1% on all-same/rle-32k is the stream-opening value-1 gamma taking the LUT path (12-20 absolute cycles).

### Insights and negative results

* Measured gamma distributions (Python re-decoder over the six corpora) overturn the seed's premise: on word-soup (the only gamma-heavy corpus, 289 gammas) value-1 gammas are 0%, k=2..3 data-bit pairs dominate (216/289, values 4..15), and post-peel queue occupancy at gamma start is uniform over {1,3,5,7} bits (parity invariant: gammas start at even bit index). Average occupancy ~4 bits vs average gamma length 5-7 bits means any queue-indexed full-decode LUT misses ~60% of the time.
* Queue-indexed full-decode LUT (the seed idea, priced at its cheapest: peel + two 256-entry tables via lea'd base regs, hit=60 cycles vs bitwise 56/88/120 for k=1/2/3, miss=+26 restart-bitwise): joint (occupancy x k) cycle math on word-soup gives +1500..+3600 cycles LOSS (hit rate 40% standalone, only 23% residual once refill-aligned starts are handled separately: hits 49/214, +3622 cycles). The no-peel variant (52-cycle hit covering value 1..15) is worse: miss overhead +36 on 77% of gammas gives ~+7500. Not prototyped - the same cost model predicted the winning variant's measured cycles within ~15%.
* Refill-aligned gamma starts are the one LUT sweet spot: 26% of word-soup gammas begin with an empty queue (the peeled continuation bit triggers the refill), so the raw input byte indexes the table directly - occupancy is always 7 bits, gammas of <=7 bits (values 1..15) always complete, and misses (the 16 bytes with b&$AA==$AA, i.e. 4 continuation bits set) are exactly the >=9-bit gammas, which get a free 4-pair head start (partial value 16+raw stored in the miss entry's queue slot) instead of a restart.
* Table-base setup cost is a trap at small chunks: lea-ing two table bases per resume call costs 16 cycles x 138 calls = +2208 cycles on word-soup at X=16, exceeding the entire LUT saving (~3500). Solved by relocating get_gamma to the end of the code and addressing the table with move.b d8(pc,Xn),Dn (14 cycles, no base register, zero per-call cost); this forces interleaved (value,queue) byte pairs at stride 2 since d8 is +/-127 and a second 256-byte table would be out of range.
* Partial-progress/resumable multi-lookup gamma designs die on field extraction, not on the idea: the combine identities v=(v-1)<<k+v' and v=v<<k|raw are cheap, but unpacking (k,raw) from a table byte costs ~26-40 cycles (move+lsr.b #4=14, and.w #imm=8, variable lsl.w=6+2k) - about one bitwise pair (32). A continuation lookup prices at ~95-100 cycles vs 28 (k2=0) / ~58 (k2=1) bitwise, and k2<=1 dominates spill remainders. Loses everywhere it was supposed to help.
* Fast-forwarding full-continuation middle bytes (b&$AA==$AA lets v=v<<4|raw with a FIXED shift, no extraction: ~88-100 cycles per 4 pairs vs ~148 bitwise) only benefits gammas spanning >=2.5 bytes (k>=8). Only max-offset has them in numbers (~25 gammas of k=9..11, ~30 such bytes, ~-1400 cycles = -0.25% on that corpus, ~0 elsewhere) while adding a peek-test to every normal mid-refill. Evaluated analytically, not worth the code.
* Branch-rotation micro-win (measured as v3 minus v1): putting the bit-queue refill out of line behind beq (not-taken 8 on the common path) instead of opt7's taken bne (10) saves 2 cycles per non-refill continuation read and costs +2 per refill; refills hit at most 1 in 4 continuation reads (byte boundaries are every 8th bit, continuation bits every 2nd). Word-soup X=127: -372 cycles; positive on every corpus with gammas.
* Honest residual regression in all variants: every ZX1 stream opens with a literal-length gamma on an empty queue, and when that gamma is value 1 (all-same, rle-32k, ~half of max-offset's) the LUT path costs 70 cycles vs opt7's 38. That is the entire -0.0/-0.1% on all-same/rle-32k (12-20 absolute cycles). A bpl short-circuit (variant 2) halves it to +14 but adds 8 cycles to every k>=1 lookup, costing word-soup ~590 cycles - only worth it in the size-optimized variant.
* Cycle-model extension (disclosed): evalvariant.py's model had no rule for move.b d8(pc,Xn),Dn and would have priced it 8-12 cycles; evalvariant2.py (same directory) adds the correct 14 (4 + 10 EA calc, M68000UM Table 8-1/8-4). All reported numbers use the corrected, conservative model.

## Self-modifying code (plain 68000, RAM-resident, single active context)

Requested explicitly. SMC pays only where the patched word is read many times
between writes; the reuse hierarchy found: entry dispatch target (read every
call) > match offset in a patched `lea` extension word (read every match entry,
written once per new offset) >> the copy-ladder index (changes every copy:
never patch it). All variants keep `jx1_init` as the reset point for patched
defaults, so sequential streams work; interleaving two live contexts does not.
Prefetch safety (the 68000 prefetches 2 words; Unicorn does not model this) was
enforced by construction: every patch site stores into words only reachable via
a later call or >10 instructions downstream.

| variant | bytes | verdict | ws16 | ws127 | txt16 | txt127 | fm16 | fm127 | as16 | as127 | mo16 | mo127 | rle16 | rle127 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| smc1_entry | 344 | win | +1.3 | +0.2 | +1.9 | -0.3 | +2.7 | +0.6 | +2.6 | +0.3 | +2.9 | +0.7 | +2.8 | +0.8 |
| smc2_lea | 350 | win | +2.1 | +0.3 | +3.5 | -0.2 | +4.7 | +1.1 | +4.6 | +0.8 | +2.9 | +0.8 | +5.0 | +1.4 |
| smc3_split | 400 | win | +11.9 | +11.4 | +9.3 | +5.1 | +8.8 | +2.6 | +8.8 | +2.6 | +7.2 | +2.5 | +8.9 | +2.5 |

**smc1_entry (idea a: patched resume dispatch)** (344 bytes, win): opt7 with the entry state dispatch (load ctx_state + beq/cmp/bne chain, 26 cycles per mid-op call) replaced by 'entry_bra: bra.w <target>' whose displacement word is the state. Key discovery: because LITERALS and MATCH share resume_op, suspend's patch target is CONSTANT, so suspend patches NOTHING - only jx1_init (-> first_entry stub), the stub itself (-> resume_op, runs once), and end_marker (-> done_state) write the word. Steady state saves 16 cycles per resume call at zero recurring patch cost; total one-time overhead ~60 cycles per stream, which is exactly the -28-cycle (-0.3%) line on the 3-call text/X=127 case. +1.3-2.9% at chunk 16.

*Caveats:* Code must be in RAM. SINGLE ACTIVE CONTEXT ONLY (the dispatch target lives in code; ctx_state is still written for ABI/debug but never read; interleaving two contexts' resume calls breaks both - jx1_init re-establishes the patched default, so sequential streams are fine). Plain 68000 only: 68010 loop mode and 68020+ caches do not see stores into the instruction stream. Prefetch-safe by construction: all three patch sites store into an instruction only reachable via a LATER call (init/end_marker return first; first_entry patches the branch behind itself), never into the 2-word window after the store; Unicorn cannot verify this, it was enforced by layout. Bounded ~60-cycle one-time cost makes very short streams at large chunks marginally slower (the one negative line).

**smc2_lea (idea a + idea b: patched match-source lea)** (350 bytes, win): smc1_entry plus the match copy source as 'match_lea: lea <disp>(a1),a2' whose extension word holds -lastOffset, patched once per NEW offset at got_offset (16 cycles) and reset to -1 by jx1_init; the per-match-entry movea.l/swap/suba.w/swap (20 cycles inside a 40-cycle select path) shrinks to an 8-cycle lea: -12 per match resume_op entry, so break-even is ~1.3 uses per offset and every from-last match or mid-match resume is pure profit. The offset decode computes -offset directly (sub.w #128 / sub.w #32512 replacing neg+add pairs, -4 cycles per offset; end-marker test flips to bge). Biggest gains where matches resume often (rle-32k +5.0%, far-match/all-same +4.6-4.7% at X=16).

*Caveats:* All smc1_entry caveats, plus: lastOffset now lives in the lea extension word (single-context restriction now covers data state, not just dispatch); ctx_packed's high word holds -lastOffset and is diagnostic-only (nothing reads it back). Prefetch: match_lea+2 is stored at got_offset, >10 instructions (through bsr get_gamma and take_budget) before match_lea can execute - far beyond the 2-word prefetch window. Measured with a locally extended cycle model (sub.w #imm costed at 8 per M68000UM instead of the stock model's 4) so the sub.w rewrite is not flattered; opt7 baseline numbers are unaffected (it has no immediate sub.w). Same bounded one-time overhead as smc1 (text/X=127 -0.2% line).

**smc3_split (idea d: op type = program counter, suspend-patched dispatch)** (400 bytes, win): The maximal design: duplicates resume_op into separate literals and match bodies (own take_budget, ladder, suspend), so the op type is encoded in the PC and ALL THREE cmp.b #1,d4 tests (source select, copy_done, transition) plus the entry chain and all d4 maintenance vanish - d4 is no longer touched at all. The only stored op type is the entry_bra displacement, patched by whichever suspend runs (suspend_lit -> lit_resume, suspend_match -> match_resume, 20 cycles per call vs 24 saved at entry), by init (-> begin_literals) and by end_marker (-> done_state). Includes the smc2 patched match_lea and negated offset decode; the new-offset path now falls straight into the match body (one bra.w fewer per new-offset op). Net: -4 fixed cycles per call plus ~34-70 cycles per op with no per-op patch cost. +7.2-11.9% at chunk 16, +2.5-11.4% at 127; word-soup (parse-heavy) +11.9/+11.4%.

*Caveats:* Code must be in RAM; SINGLE ACTIVE CONTEXT ONLY - both the resume target and lastOffset live in the code words, jx1_init re-establishes all patched defaults for sequential streams; ctx_state is write-only (ABI/debug); ctx_packed high word is diagnostic-only (-lastOffset). Plain 68000 only (68010 loop mode / 68020+ caches break it). Prefetch-safe by construction: entry_bra is patched only by code that returns to the caller (next possible execution of the patched word is the next call); match_lea+2 is written >10 instructions before match_lea can execute. +76 bytes over opt7's 324 (the duplicated take_budget/ladder/suspend). Cycle model honesty cuts BOTH ways here: measured with the sub.w #imm=8 fix, and the stock model undercounts opt7's hot beq.w suspend when not taken (modeled 8, real 12) while smc3 uses beq.s (real 8) - so the real-hardware margin should be slightly LARGER than reported.

### Insights and negative results

* Where SMC pays on the 68000: only when the patched word is read many times between writes. The reuse hierarchy found here: entry dispatch target (written at stream lifecycle events or once per call, read every call), match offset (written once per new offset, read every match entry - ZX1's from-last-offset op exists precisely because offsets repeat), vs the copy-ladder index (changes every copy: never patch it).
* Idea (a) refined: in a shared-body design (opt7's resume_op serves both LITERALS and MATCH), suspend's resume target is CONSTANT, so the steady state needs ZERO patch writes - only init/first-call/end patch, ~60 cycles one-time, 16 cycles saved per call. In the split-body design the target varies (lit_resume vs match_resume) and each suspend pays a 20-cycle lea(pc)+move.w patch against 24 saved at entry.
* Patch at SUSPEND, not at op begin: the resume target is consumed once per call, so writing it once per call (suspend) is optimal; patching at op begin would cost 20 cycles per op - at chunk 127 word-soup that is ~25 ops per call, ~500 cycles/call of patching to save the same 24. Measured consequence: smc3 keeps its +11% word-soup gain even at X=127.
* The real winner is not the patched branch itself but what it enables: splitting the lit/match bodies makes the op type live in the program counter, deleting all three cmp.b #1,d4 tests (18/16/18 cycles per op), the d4 loads/moveqs, and the entry chain. SMC only has to carry the op type across the suspend/resume boundary - one patched displacement word. That is idea (d) subsuming idea (a): +7.2-11.9% for +76 bytes.
* Idea (b) math (patched 'lea disp(a1),a2' with disp=-lastOffset): match source select drops 40->28 cycles per entry (shared body) or 20->8 (split body); patch costs 16 cycles once per NEW offset (lea pc + move.w d3,(a2), with the offset decode rewritten to produce -offset directly via sub.w #128/#32512, itself 4 cycles cheaper than opt7's neg+add). Break-even ~1.3 uses per offset; every from-last match and every mid-match resume is profit. Best case rle-32k X=16: +5.0% standalone.
* Idea (c) REFUTED with math, both ways. Patched-bra ladder dispatch: computing the displacement byte (and.w #7 8, add 4, add.b #base 8) plus lea site(pc) 8 + move.b 8 + bra.s 10 = 46-50 cycles vs the existing and/add/neg/jmp = 30; the patched value (n&7) changes every copy so there is no amortization, AND the store would sit 1-2 instructions before the branch it patches - exactly the 68000 prefetch violation, requiring padding that makes it slower still. The reuse angle (n&7 = chunk&7 constant across full-budget calls, RLE): a guard 'cmp.b (aX),d0 / beq' costs 18+ on top of the 20-cycle compute before reaching the 10-cycle bra - still >30. Even non-SMC caching (jump target in a3, jmp (a3)=8 vs jmp d8(pc,Xn)=14) needs and.w#7(8)+cmp(4)+bne(8) = 20 of guards to save 6. The pc-indexed jmp is already the right primitive.
* Patched budget immediate REFUTED: moveq #0,d5 + move.b (a5)+,d5 = 12 cycles AND advances a5 for free as part of the context walk; any patched 'move.w #chunk,d5' (8) forces an explicit a5 adjustment (addq.l #2 = 8) or d16(a5) addressing for the remaining context bytes (12 vs 8 each) - every arrangement is >= 16 cycles, plus a patch in init. Post-increment context walking beats immediates.
* Cycle-model honesty notes: (1) the stock model costs sub.w #imm,Dn at 4; M68000UM says 8 (SUBI.W) - I evaluated smc2/smc3 with a locally extended copy (evalvariant_smc.py, one added line) so the neg+add->sub.w rewrite is not flattered; opt7 contains no immediate sub.w so the baseline is unchanged (verified smc1 produces identical numbers under both models). (2) The model scores all not-taken Bcc at 8, but Bcc.w not-taken is really 12: this flatters opt7's hot beq.w suspend, so smc3 (which uses beq.s throughout) should beat opt7 on real silicon by slightly MORE than reported.
* Unicorn/QEMU executes the SMC correctly (TB invalidation on code-page writes) but has NO prefetch model, so prefetch safety was enforced by construction, not by test: every entry_bra patch site returns to the caller before the patched word can be fetched (infinite distance), and match_lea+2 is written >10 instructions upstream of its execution; all patched words are word-aligned instruction extension words reached via lea (pc), keeping the code position-independent.
* All three variants keep the context ABI (ctx_src at +4, ctx_dst at +8, 15-byte block), pass the 13-case differential harness at chunks 16/1/7/127 and the even/odd-destination alignment audit, and keep jx1_init as the reset point for all patched defaults - the cost of migrating state into code is the documented single-active-context restriction (and RAM-resident, plain-68000-only code); smc3 additionally frees d4 entirely (no longer clobbered).

## Outcome

Focus is chunk 16, so the copy-engine winner (fill32: +47-52% on RLE-ish data
at chunk 127 but built around a bulk gate at n>=32) was **dropped from the
implementation set** - its design is preserved above for a future big-chunk
variant. The six X=16-relevant variants live in this directory as
`jx1_68000_opt_<variant>.S`:

| file | source variant |
|---|---|
| `jx1_68000_opt_wc3.S` | wildcard wc3 |
| `jx1_68000_opt_threaded.S` | fixed-overhead v3_threaded_split |
| `jx1_68000_opt_smc2.S` | smc2_lea |
| `jx1_68000_opt_smc3.S` | smc3_split |
| `jx1_68000_opt_offlut.S` | offset-lut lut2_offpath |
| `jx1_68000_opt_gammalut.S` | gamma-lut g_t0r |
| `jx1_68000_opt_combo.S` | combination (see its header) |

## Round 2: X = 16 focus (jx1_68000_opt_x16.S)

Three quick inline rounds on top of the combo, each measured at chunk 16
before proceeding (corrected cycle model; percentages vs the previous step):

**Round 1 - 32-step copy ladders** (+2.2-3.2% on copy-touched corpora, ~0 on
word-soup): with a 32-step ladder every chunk-16 copy is a pure partial entry
- zero dbf passes (the dispatch pays lsr.w #5 instead of #3, +4 cycles per
copy, overwhelmed by the -20-and-more per 16-byte block). fill32's insight
applied without any of its bulk machinery.

**Round 2 - context shaves** (cumulative +1.6-6.3% over the combo): the chunk
becomes a word field (one move.w (a5)+ load, killing the moveq #0 zero
extension), and the write-only state byte disappears entirely - the patched
entry_bra IS the state, so both suspends drop a byte store and the end path
drops two instructions.

**Round 3 - batched resume** (the headline): jx1_resume_n (jump-table slot
base+12; d6.w = chunk count k, a6 = callback) processes up to k chunks per
call with every register staying live between chunks; the between-chunk
boundary costs ~60 cycles (subq/bne + jsr round trip + budget refresh from
d7) instead of the ~150-cycle suspend+entry round trip. The callback runs
between chunks (k-1 times per full batch), may clobber d0/d1/d5/a2-a4, must
preserve d2/d3/d6/d7/a0/a1/a5/a6; d4 belongs entirely to the caller. The
plain jx1_resume is the same code at k = 1 and pays one subq/bne per call.

Measured at chunk 16 against opt7:

| corpus | x16 plain | batched k=4 | batched k=8 |
|---|---|---|---|
| word-soup | +19.7% | +27.0% | +28.2% |
| text | +13.5% | +27.0% | +29.3% |
| far-match | +11.8% | +27.7% | +30.3% |
| all-same | +11.9% | +27.8% | +30.3% |
| max-offset | +11.0% | +27.3% | +29.9% |
| rle-32k | +11.8% | +28.0% | +30.6% |

1034 bytes (522 code + 512 table). Correctness: the 13-case differential
harness at chunks 16/1/7/127 on the plain path, the even/odd-destination
alignment audit, and a dedicated batched-API check (k = 2/4/8 at chunk 16 on
all 13 corpora: byte-identical output, exact per-batch emission, call counts,
d4 preservation through calls and callbacks).

## Round 3: the chunk-aligned format (negative result)

The shelved idea "a format where no op crosses a chunk boundary kills
take_budget entirely" was implemented end to end and measured. Verdict: **it
does not beat opt_x16 at X = 16** - kept as a working format variant and as
the record of why.

**Format** (`CompressorChunked.java` / `DecompressorChunked.java` /
`jx1_68000_chunked.S`): ZX1 op encodings; no op crosses a multiple-of-chunk
output boundary; each later chunk opens with a boundary code - `0` literals,
`11` from-last spanning the whole chunk with implied length (no gamma - two
bits per chunk for boundary-split long matches), `100` partial from-last,
`101` new-offset/end. Chunk bit-counts stay even, so the refill invariant
survives (the second boundary bit sits on a refill-exposed even index and is
the one checked read outside gammas). The encoder is greedy (hash chains),
not optimal. The 68k decoder (1006 bytes) has no take_budget, no mid-op
state, and its suspend patch fires once per stream (the smc1 pattern).

**Measured, same original data, chunk 16** (cycles to decompress; positive
would mean chunked is faster than opt_x16):

| corpus | k=8 | k=1 | size std/chunked |
|---|---|---|---|
| word-soup | -4.7% | -2.5% | 818 / 986 |
| text | -4.6% | -0.7% | 28 / 35 |
| far-match | -6.0% | -1.3% | 212 / 267 |
| all-same | -4.1% | +0.2% | 6 / 21 |
| max-offset | -41.1% | -29.1% | 32589 / 34978 |
| rle-32k | -4.6% | -0.1% | 7 / 505 |

**Why it loses:** opt_x16's mid-op continuation at a chunk boundary costs
almost nothing beyond the shared batch handler, while the chunked format
pays a boundary code plus an op (re)dispatch there, and its per-op
take_budget saving (~22 cycles) does not cover that. The first iteration
(without code `11`) lost 33-48% on copy data because every boundary-split
match piece re-parsed a gamma; code `11` recovered nearly all of that (and
cut rle-32k's stream from 3003 to 505 bytes) but parity is the ceiling. The
max-offset outlier is mostly the greedy parser emitting many marginal
two-byte matches that the optimal parser would reject.

**What it is still good for:** the simplest possible resumable decoder (no
budget clamp, no op state across calls), strictly deterministic per-chunk
work, and a ~20-25% ratio cost on typical data (RLE remains its worst case:
505 bytes vs 7). Verified: Java round-trips at chunks 8/16/32/127, per-call
emission, a grammar-aware refill-invariant checker, and the 68k against the
Java oracle on all 13 corpora at k = 1/4/8 with d4 preservation.

## Round 4: decode-cost-aware parsing, RLE fills at X=16, table layout

**OptimizerDcaw (kept, with a scientific finding).** `OptimizerDcaw.java` runs
the standard optimal-parse DP with each op scored as
`(bits << 8) + lambda * decodeCycles(op)`, using the 68k decoders'
parse-variant cycle costs (per-op dispatch, gamma, offset decode; per-byte
copy cycles drop out). A corrector pass rewrites the chain with true bit
counts, so it feeds the stock `Compressor` and produces fully
format-compatible streams; `lambda = 0` reproduces the bit-optimal sizes
exactly. The finding: **the bit-optimal ZX1 parse is already nearly
decode-optimal** - lambda 4..24 changes almost nothing, and beyond that every
~1% of decode speed costs ~2-2.6% of size (word-soup: +4.6% cycles for +11.7%
size at lambda 48; lambda 64 degenerates toward literals: +33% cycles for
+133% size). Bits and decoder cycles correlate too strongly for a free lunch;
the knob exists for callers who value decode speed over size.

**RLE word fills at X = 16 (negative result, reverted).** A match-body fill
for offsets 1-2 (pattern latched from the two freshly written output bytes,
parked in an address register, stored through a word ladder at ~4.6 c/b) was
implemented, verified - the even/odd alignment audit caught a real parity bug
in the first version - and measured: **slower everywhere** (rle-32k -2.6%,
word-soup -5.6%, text -8.2%). With the 32-step byte ladder already running a
flat ~12 c/b with zero dbf passes for n <= 16, the fill's margin at chunk-16
block sizes (~15 cycles) cannot pay for a gate on every match block. Fills
need blocks >= 32 (consistent with fill32); the parity-gate techniques are
recorded here for that future case.

**two_byte next to gtab (kept).** Relocating the two-byte offset decode to
sit before the table restores the base-register-free
`add.w gtab(pc,d0.w),d3` (the entry rides the existing bcs, only the return
pays a bra.w): +0.63% word-soup, +0.44% text, ~0 elsewhere, no size change.

## Round 5: the full-chunk continuation fast path (x16)

Profile arithmetic after Round 4: a long op that spans chunks pays, at EVERY
boundary, a budget refresh + re-entry branch (14), the folded take_budget
(28), and the ladder dispatch arithmetic + indexed jmp (50; the `lsr.w #5`
alone is 16) - ~90+ cycles of pure bookkeeping per 16 copied bytes. But at a
chunk boundary the budget is `chunk` *by construction*, so the general
min/clamp/dispatch collapses into two trivial cases:

* **partial** (`remaining < chunk`): the op ends inside this chunk, so
  n = remaining, remaining' = 0, budget' = chunk - n - three moves replace
  take_budget entirely, then jump to the existing dispatch arithmetic;
* **full** (`remaining >= chunk`): n = chunk, which is a *stream constant* -
  jx1_init precomputes the ladder pass count (`chunk >> 5`, patched into a
  `moveq` immediate) and the ladder entry index (`-2*(chunk & 31)`, patched
  into a `move.w` immediate), so the whole clamp + dispatch pipeline is
  skipped: budget' = 0, load the two constants, jump straight at the ladder.

Both flavors live in new `lit_cont`/`match_cont` blocks: in-batch boundaries
fall into them after the `jsr (a6)` callback, and call re-entries arrive via
the patched `entry_bra` (suspend now targets the cont blocks). Fresh ops
parsed mid-chunk never touch the check. The match-source `lea` moved after
the dispatch arithmetic so the full path reuses the one SMC-patched
`match_lea` - no second patch site, no tax on `got_offset`.

**The regression that shaped the design:** the first version put a
check-then-branch *in front of* the unchanged take_budget path, taxing every
partial boundary +18 cycles - word-soup (parse-heavy, nearly all partials)
measured -1.9..-2.9%. Restructured so the boundary check *replaces*
take_budget, partials come out 12 cycles CHEAPER than Round 4 and fulls keep
-42: word-soup went from -2.9% to neutral-positive on the batched path.

Measured A/B vs the Round-4 x16 at chunk 16 (plain / k=4 / k=8):

| corpus | plain | k=4 | k=8 |
|---|---|---|---|
| word-soup | -1.05% | +0.01% | +0.21% |
| text | +3.01% | +5.72% | +6.29% |
| far-match | +5.32% | +9.04% | +9.82% |
| all-same | +5.03% | +8.66% | +9.43% |
| max-offset | +5.50% | +9.32% | +10.11% |
| rle-32k | +5.65% | +9.53% | +10.33% |

The one honest cost: plain-resume word-soup -1.05% (each per-call re-entry
pays +12 on a partial, and parse-heavy streams are nearly all partials);
every batched cell is >= 0. New totals vs opt7 at chunk 16: plain
**+15.9..+19.3%**, k=4 **+27.5..+34.9%**, k=8 **+28.8..+37.8%**. Size
1034 -> 1114 bytes; context and ABI unchanged. Verified: 13-case harness at
chunks 16/1/7/127, batched API at k=2/4/8 with d4-preservation checks, and
the even/odd destination alignment audit.
