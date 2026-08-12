; -----------------------------------------------------------------------------
; jx1_68000_opt_combo.S - combination of the measured exploration winners
;                         (plain 68000, RAM code, self-modifying)
;
; Composes, on the jx1_68000_opt7.S baseline (see 68k/OPTIMIZATIONS.md for the
; full exploration record):
;
; * smc3: split literals/match bodies so the op type IS the program counter
;   (no d4, no state tests anywhere); resume dispatch is a bra.w whose
;   displacement word is patched by suspend/init/end (SMC); the match copy
;   source is a patched 'lea <-lastOffset>(a1),a2' written once per NEW
;   offset; the offset decode produces -offset directly.
; * wc2/wc3: gamma de-subroutined and woven into the flow - each body has its
;   own gamma whose tail FALLS INTO the body (no bsr/rts, no landing bra);
;   the match gamma absorbs the new-offset '+1' via a caller seed in d0
;   (from-last seeds 0, new-offset seeds 1). The literals ladder reads (a0)+
;   directly, killing the a2 staging and the post-copy a0 sync.
; * wc1/v2: take_budget suspend gate folded behind the clamp - remaining >= 1
;   is invariant at both resume entries, so min(remaining,budget) = 0 only on
;   the clamped path, whose own move.w d5,d0 sets Z for free: the fits path
;   runs test-free and branch-free.
; * lut2: the two-byte offset arithmetic collapses to one table access:
;   -offset = (L & 254) + G[H] with G[H] = (H>>1)*256 + (H&1) - 32512 (a
;   256-word pc-relative table; the end marker falls out as -offset >= 0).
;   The dead 'moveq #0,d3' at new_offset is gone (d3.w is provably 0 there).
;   The one-byte form keeps its 12-cycle arithmetic (proven cheaper than any
;   lookup).
;
; The gamma-LUT variant (jx1_68000_opt_gammalut.S) is deliberately NOT folded
; in: its refill-aligned table conflicts with the woven gamma structure and
; measured only +1.7-2.2% standalone on one corpus.
;
; SMC caveats (by construction): code must live in RAM; SINGLE ACTIVE CONTEXT
; (the resume target and lastOffset live in code words; jx1_init re-arms all
; patched defaults, so sequential streams are fine); plain 68000 (later CPUs
; cache instructions); prefetch-safe (entry_bra is patched only by code that
; returns first; match_lea's word is written a whole gamma parse before
; match_lea can execute); position-independent (patches via lea (pc)).
;
; Same assumptions as jx1_68000_opt.S, undefined when violated:
;
;   1. no single literal run or match is longer than 32768 bytes
;   2. the chunk size is 1..127
;
; Measured against jx1_68000_opt7.S (cycle model with corrected indexed-EA
; and subi timings): word-soup +20.6% / +22.3% (chunk 16/127), text +12.1% /
; +9.2%, far-match +9.8% / +3.2%, all-same +9.9% / +3.5%, max-offset +9.6% /
; +3.7%, rle-32k +9.6% / +2.7% - all positive. 918 bytes (406 code + 512
; table).
;
; The context must be word-aligned and is 15 bytes (16 with padding).
;
; Calling convention: jx1_init and jx1_resume clobber d0-d3/d5/a0-a2 (d4 is
; untouched) and leave a5 = context untouched; jx1_decompress additionally
; uses (but restores) a5.
; -----------------------------------------------------------------------------

ctx_packed      equ     0               ; .l  d3: -lastOffset (high word, diagnostic), remaining (low)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: output position
ctx_chunk       equ     12              ; .b  chunkSize (X), 1..127
ctx_bits        equ     13              ; .b  bit buffer
ctx_state       equ     14              ; .b  State: 0 START, 1 LITERALS, 2 MATCH, 3 DONE (write-only)
ctx_size        equ     15
ctx_alloc       equ     16              ; ctx_size rounded up to keep sp even

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = destination, d0.b = chunk size 1..127,
;           a5 = word-aligned context block of ctx_size bytes.
; (Re)establishes ALL patched defaults: entry -> begin_literals, lastOffset 1.
; -----------------------------------------------------------------------------
jx1_init:
        move.l  a0,ctx_src(a5)
        move.l  a1,ctx_dst(a5)
        move.b  d0,ctx_chunk(a5)
        moveq   #1,d1
        swap    d1                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        move.l  d1,ctx_packed(a5)
        move.b  #$80,ctx_bits(a5)       ; empty bit buffer (sentinel only)
        clr.b   ctx_state(a5)           ; State.START (write-only, ABI/debug)
        lea     entry_bra+2(pc),a1      ; SMC: next resume call opens the stream
        move.w  #begin_literals-entry_bra-2,(a1)
        lea     match_lea+2(pc),a1      ; SMC: match source = -INITIAL_OFFSET
        move.w  #-1,(a1)
        rts

; -----------------------------------------------------------------------------
; jx1_decompress: a0 = compressed data, a1 = destination.
; One-shot convenience; returns with a1 = end of output.
; -----------------------------------------------------------------------------
jx1_decompress:
        move.l  a5,-(sp)
        lea     -ctx_alloc(sp),sp
        movea.l sp,a5
        moveq   #127,d0                 ; largest chunk a byte allows
        bsr.s   jx1_init
.drain:
        bsr.s   jx1_resume              ; Java: while (resume()) {}
        tst.w   d0
        bne.s   .drain
        lea     ctx_alloc(sp),sp
        movea.l (sp)+,a5
        rts

; -----------------------------------------------------------------------------
; jx1_resume: a5 = context. Emits at most ctx_chunk output bytes.
; Returns d0 = 0 when the stream is fully processed, 1 when there is more;
; a1 = current end of output. The dispatch is one patched bra.w; ctx_state
; is never read.
; -----------------------------------------------------------------------------
jx1_resume:
        movem.l (a5)+,d3/a0-a1          ; packed offset/remaining, src, dst
        moveq   #0,d5
        move.b  (a5)+,d5                ; budget = chunkSize
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_state
entry_bra:
        bra.w   begin_literals          ; SMC: displacement word is the state

done_state:                             ; entry_bra target after end_marker
        lea     -ctx_state(a5),a5       ; keep returning "fully processed"
        moveq   #0,d0
        rts

; ------------------------------- literals body ------------------------------
; begin_literals IS the literals gamma; its tail falls into lit_resume.
begin_literals:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   lgamma_first
        move.b  (a0)+,d2                ; refill; ZX1 bit groups always open on a
        addx.b  d2,d2                   ; continuation bit (see jx1_68000_opt3.S)
lgamma_first:
        bcc.s   lgamma_done             ; 0: value is 1, straight through
lgamma_loop:
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + data bit
        add.b   d2,d2                   ; next continuation bit (refill site)
        bne.s   lgamma_have
        move.b  (a0)+,d2
        addx.b  d2,d2
lgamma_have:
        bcs.s   lgamma_loop             ; 1: another pair
lgamma_done:
        move.w  d1,d3                   ; remaining = gamma; falls into the body

lit_resume:                             ; entry_bra target while mid-literals
        move.w  d3,d0                   ; take_budget: min(remaining, budget);
        cmp.w   d5,d0                   ; remaining >= 1 here, so zero is only
        bls.s   .fits                   ; possible on the clamped path -
        move.w  d5,d0                   ; whose move sets Z for free
        beq.s   suspend_lit             ; budget exhausted before this op
.fits:
        sub.w   d0,d3
        sub.w   d0,d5
        move.w  d0,d1
        lsr.w   #3,d1
        and.w   #7,d0
        add.w   d0,d0
        neg.w   d0                      ; index = -2*(n&7)
        jmp     lit_end(pc,d0.w)
lit_ladder:
        move.b  (a0)+,(a1)+             ; literals copy straight from the input:
        move.b  (a0)+,(a1)+             ; no a2 staging, no a0 sync afterwards
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
lit_end:
        dbf     d1,lit_ladder           ; full 8-move passes for big copies
        tst.w   d3
        bne.s   suspend_lit             ; budget spent mid-op
        add.b   d2,d2                   ; transition (bare read, opt3 invariant)
        bcs.s   new_offset              ; 1: new offset
        moveq   #0,d0                   ; 0: match from last offset - match_lea
        bra.s   match_gamma             ; still holds -lastOffset; length seed 0

suspend_lit:                            ; interrupted mid-literals
        lea     entry_bra+2(pc),a2      ; SMC: resume straight into lit_resume
        move.w  #lit_resume-entry_bra-2,(a2)
        moveq   #1,d0                   ; State.LITERALS, also the return value
        move.b  d0,(a5)                 ; (ABI/debug only; never read back)
        move.b  d2,-(a5)                ; bit buffer
        subq.l  #1,a5                   ; skip ctx_chunk
        movem.l d3/a0-a1,-(a5)          ; stores in layout order, a5 = context base
        rts                             ; d0 = 1: more output pending

; ------------------------------- offset decode ------------------------------
new_offset:                             ; d3.w is provably 0 here (the dead
        move.b  (a0)+,d3                ; moveq of earlier variants is gone);
        lsr.b   #1,d3                   ; carry = low bit selects the form
        bcs.s   two_byte
        sub.w   #128,d3                 ; -offset = value/2 - 128 (never >= 0)
        bra.s   got_offset
two_byte:
        add.b   d3,d3                   ; low & 254
        moveq   #0,d0
        move.b  (a0)+,d0                ; high byte indexes G (a 256-word table):
        add.w   d0,d0                   ; -offset = (low & 254) + G[high]
        lea     gtab(pc),a2
        add.w   0(a2,d0.w),d3
        bge.w   end_marker              ; -offset >= 0 is the end marker
                                        ; (.w: out of short range; taken Bcc
                                        ; costs 10 cycles at either width)
got_offset:
        lea     match_lea+2(pc),a2      ; SMC: source displacement = -offset;
        move.w  d3,(a2)                 ; a whole gamma parse runs before
        swap    d3                      ; match_lea can execute (prefetch-safe);
        moveq   #1,d0                   ; park -lastOffset, length seed 1
                                        ; falls into the match gamma

; match_gamma: gamma + d0 seed; its tail falls into the match body.
match_gamma:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   mgamma_first
        move.b  (a0)+,d2
        addx.b  d2,d2
mgamma_first:
        bcc.s   mgamma_done             ; 0: value is 1, straight through
mgamma_loop:
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + data bit
        add.b   d2,d2                   ; next continuation bit (refill site)
        bne.s   mgamma_have
        move.b  (a0)+,d2
        addx.b  d2,d2
mgamma_have:
        bcs.s   mgamma_loop             ; 1: another pair
mgamma_done:
        add.w   d0,d1                   ; + seed (1 for new offsets, 0 for last)
        move.w  d1,d3                   ; remaining; falls into the body

; -------------------------------- match body --------------------------------
match_resume:                           ; entry_bra target while mid-match
        move.w  d3,d0                   ; take_budget, folded as in lit_resume
        cmp.w   d5,d0
        bls.s   .fits
        move.w  d5,d0
        beq.s   suspend_match           ; budget exhausted before this op
.fits:
        sub.w   d0,d3
        sub.w   d0,d5
match_lea:
        lea     -1(a1),a2               ; SMC: extension word = -lastOffset,
                                        ; patched at got_offset / jx1_init
        move.w  d0,d1
        lsr.w   #3,d1
        and.w   #7,d0
        add.w   d0,d0
        neg.w   d0                      ; index = -2*(n&7)
        jmp     match_end(pc,d0.w)
match_ladder:
        move.b  (a2)+,(a1)+             ; 8 fully rolled-out byte moves; entry
        move.b  (a2)+,(a1)+             ; at match_end-2k copies exactly k
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
match_end:
        dbf     d1,match_ladder         ; full 8-move passes for big copies
        tst.w   d3
        bne.s   suspend_match           ; budget spent mid-op
        add.b   d2,d2                   ; transition (bare read, opt3 invariant)
        bcs.w   new_offset              ; 1: new offset
        bra.w   begin_literals          ; 0: literals

suspend_match:                          ; interrupted mid-match
        lea     entry_bra+2(pc),a2      ; SMC: resume straight into match_resume
        move.w  #match_resume-entry_bra-2,(a2)
        move.b  #2,(a5)                 ; State.MATCH (ABI/debug only)
        move.b  d2,-(a5)                ; bit buffer
        subq.l  #1,a5                   ; skip ctx_chunk
        movem.l d3/a0-a1,-(a5)          ; stores in layout order, a5 = context base
        moveq   #1,d0                   ; more output pending: call again
        rts

end_marker:                             ; State.DONE
        lea     entry_bra+2(pc),a2      ; SMC: every later call returns 0 via
        move.w  #done_state-entry_bra-2,(a2) ; done_state
        moveq   #3,d0
        move.b  d0,(a5)
        move.b  d2,-(a5)
        subq.l  #1,a5
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts

; G[H] = (H>>1)*256 + (H&1) - 32512, so that -offset = (L & 254) + G[H].
        even
gtab:
H       set     0
        rept    256
        dc.w    (H>>1)*256+(H&1)-32512
H       set     H+1
        endr
