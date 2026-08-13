; -----------------------------------------------------------------------------
; jx1_68000_opt_x16.S - the combo tuned for chunk size 16, plus a batched
;                       resume API (plain 68000, RAM code, self-modifying)
;
; Three rounds on top of jx1_68000_opt_combo.S (all measured at X = 16 with
; the corrected cycle model; see 68k/OPTIMIZATIONS.md):
;
; Round 1 - 32-step copy ladders in both bodies: every chunk-16 copy becomes
;   a pure partial entry with zero dbf passes (fill32's insight). +2.2-3.2%
;   on copy-touched corpora.
;
; Round 2 - context shaves: the chunk is a word field (one move.w load kills
;   the moveq #0 zero-extension) and the write-only state byte is gone - the
;   patched entry_bra IS the state. Cumulative +1.6-6.3% over the combo.
;
; Round 3 - jx1_resume_n (jump table slot base+12): processes up to k chunks
;   in ONE call, keeping every register live between chunks; the caller's
;   per-chunk work runs as a callback. Between chunks the boundary costs a
;   subq/bne, a jsr (a6) round trip and a budget refresh (~60 cycles)
;   instead of a full suspend+entry (~150): measured +27.0-30.6% over opt7
;   at X = 16 with k = 4..8, across every corpus. The plain jx1_resume is
;   the same code with k = 1 (it pays one subq/bne per call).
;
;   jx1_resume_n: a5 = context, d6.w = chunk count k >= 1, a6 = callback.
;   The callback runs BETWEEN chunks (k-1 times per full batch; the caller
;   sees the batch end via the return value; no callback when the stream
;   ends). It may clobber d0/d1/d5/a2-a4 and must preserve
;   d2/d3/d6/d7/a0/a1/a5/a6. d4 is never touched by the decompressor:
;   it belongs to the caller across all calls and callbacks.
;
; Round 4 - the two-byte offset decode moved next to its table: the lookup
;   is base-register-free again (add.w gtab(pc,d0.w)). +0.63% word-soup,
;   +0.44% text.
;
; Round 5 - full-chunk continuation fast path: at a chunk boundary the
;   budget is chunk BY CONSTRUCTION, so the lit_cont/match_cont blocks
;   replace take_budget with one compare - a partial final chunk computes
;   n = remaining, budget = chunk - n directly (12 cycles cheaper than the
;   general path), and a full chunk loads the init-patched constants
;   (ladder passes = chunk>>5, index = -2*(chunk&31)) and jumps straight
;   at the ladder, skipping clamp and dispatch arithmetic (~42 cycles per
;   continued chunk). In-batch boundaries fall in after the callback; call
;   re-entries arrive via the patched entry_bra. +5-10% on copy-dominated
;   corpora, batched word-soup neutral; the one cost is plain-resume
;   word-soup -1.05%.
;
; Inherited from the combo: smc3's split literals/match bodies (op type in
; the program counter, suspend-patched entry bra.w, match source via a
; patched lea holding -lastOffset), woven per-body gammas with a d0 length
; seed, the folded take_budget gate (remaining >= 1 invariant), a direct
; (a0)+ literals ladder, and the 256-word offset table (-offset =
; (L & 254) + G[H]).
;
; Measured at chunk 16 vs jx1_68000_opt7.S:
;   plain resume:     +15.9% .. +19.3%
;   batched k = 4:    +27.5% .. +34.9%
;   batched k = 8:    +28.8% .. +37.8%   (all six corpora positive)
;
; SMC caveats (by construction): code must live in RAM; SINGLE ACTIVE
; CONTEXT (jx1_init re-arms all patched defaults, so sequential streams are
; fine); plain 68000; prefetch-safe (entry_bra is patched only by code that
; returns first; match_lea's word is written a whole gamma parse before it
; can execute; the fast-path constants are patched only in jx1_init);
; position-independent (patches via lea (pc)).
;
; Same assumptions as jx1_68000_opt.S, undefined when violated:
;
;   1. no single literal run or match is longer than 32768 bytes
;   2. the chunk size is 1..127
;
; The context must be word-aligned and is 16 bytes.
;
; Calling convention: jx1_init and jx1_resume/jx1_resume_n clobber
; d0-d3/d5-d7/a0-a2 (d4 untouched) and leave a5 = context untouched;
; jx1_decompress additionally uses (but restores) a5.
; -----------------------------------------------------------------------------

ctx_packed      equ     0               ; .l  d3: -lastOffset (high word, diagnostic), remaining (low)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: output position
ctx_chunk       equ     12              ; .w  chunkSize (X), 1..127 (word: one load)
ctx_bits        equ     14              ; .b  bit buffer
ctx_pad         equ     15              ; .b  unused (the patched entry_bra IS the state)
ctx_size        equ     16
ctx_alloc       equ     16

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8/12).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume
                bra.w   jx1_resume_n

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = destination, d0.b = chunk size 1..127,
;           a5 = word-aligned context block of ctx_size bytes.
; (Re)establishes ALL patched defaults: entry -> begin_literals, lastOffset 1.
; -----------------------------------------------------------------------------
jx1_init:
        move.l  a0,ctx_src(a5)
        move.l  a1,ctx_dst(a5)
        and.w   #127,d0                 ; store the chunk as a clean word
        move.w  d0,ctx_chunk(a5)
        moveq   #1,d1
        swap    d1                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        move.l  d1,ctx_packed(a5)
        move.b  #$80,ctx_bits(a5)       ; empty bit buffer (sentinel only)
        lea     entry_bra+2(pc),a1      ; SMC: next resume call opens the stream
        move.w  #begin_literals-entry_bra-2,(a1)
        lea     match_lea+2(pc),a1      ; SMC: match source = -INITIAL_OFFSET
        move.w  #-1,(a1)
        move.w  d0,d1                   ; SMC: the full-chunk fast-path constants
        and.w   #31,d1                  ; (chunk is fixed per stream, so the
        add.w   d1,d1                   ; ladder entry for a whole-chunk copy
        neg.w   d1                      ; is precomputable): index = -2*(chunk&31)
        lsr.w   #5,d0                   ; and full ladder passes = chunk>>5
        lea     fast_idx_l+2(pc),a1
        move.w  d1,(a1)
        lea     fast_idx_m+2(pc),a1
        move.w  d1,(a1)
        lea     fast_pass_l+1(pc),a1    ; the moveq immediates (low bytes)
        move.b  d0,(a1)
        lea     fast_pass_m+1(pc),a1
        move.b  d0,(a1)
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
; jx1_resume:   a5 = context. Emits at most ctx_chunk output bytes; returns
;               d0 = 0 when fully processed, 1 when there is more.
; jx1_resume_n: a5 = context, d6.w = chunk count k >= 1, a6 = callback.
;               Emits up to k chunks in one call, keeping all state in
;               registers between them; jsr (a6) runs BETWEEN chunks (k-1
;               times per full batch - the caller sees the batch end via the
;               return). The callback may clobber d0/d1/d5/a2-a4 and must
;               preserve d2/d3/d6/d7/a0/a1/a5/a6; d4 is never touched by the
;               decompressor, so it is entirely the caller's. No callback
;               runs when the stream ends (the call returns 0 instead).
; -----------------------------------------------------------------------------
jx1_resume:
        moveq   #1,d6                   ; plain call = a batch of one
                                        ; (a6 is never used at k = 1)
jx1_resume_n:
        movem.l (a5)+,d3/a0-a1          ; packed offset/remaining, src, dst
        move.w  (a5)+,d5                ; budget = chunkSize (one word load)
        move.w  d5,d7                   ; chunk kept for between-chunk refresh
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_pad
entry_bra:
        bra.w   begin_literals          ; SMC: displacement word is the state

done_state:                             ; entry_bra target after end_marker
        lea     -ctx_pad(a5),a5         ; keep returning "fully processed"
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
lit_calc:                               ; boundary partials re-enter here
        move.w  d0,d1
        lsr.w   #5,d1                   ; a 32-step ladder: every chunk-16 copy
        and.w   #31,d0                  ; is a pure partial entry, zero dbf
        add.w   d0,d0                   ; passes (fill32's measured insight)
        neg.w   d0                      ; index = -2*(n&31)
lit_go:                                 ; boundary fulls: d0/d1/d5 pre-set
        jmp     lit_end(pc,d0.w)
lit_ladder:
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
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

suspend_lit:                            ; chunk boundary while in literals
        subq.w  #1,d6
        bne.s   more_chunks_lit         ; batch not exhausted: stay in registers
        lea     entry_bra+2(pc),a2      ; SMC: resume straight into lit_cont
        move.w  #lit_cont-entry_bra-2,(a2)
        move.b  d2,-(a5)                ; bit buffer (no state byte: entry_bra is
        subq.l  #2,a5                   ; the state); skip the chunk word
        movem.l d3/a0-a1,-(a5)          ; stores in layout order, a5 = context base
        moveq   #1,d0                   ; more output pending: call again
        rts
more_chunks_lit:
        jsr     (a6)                    ; the caller's between-chunk work
lit_cont:                               ; mid-literals continuation: in-batch
        move.w  d3,d0                   ; boundaries fall in, call re-entries
        sub.w   d7,d3                   ; arrive via the patched entry_bra.
        bcc.s   lit_full                ; budget == chunk here by construction,
        clr.w   d3                      ; so this REPLACES take_budget: partial
        move.w  d7,d5                   ; means the op's last chunk - n =
        sub.w   d0,d5                   ; remaining, budget = chunk - n, done
        bra.w   lit_calc
lit_full:                               ; a whole chunk pending: n = chunk is
        moveq   #0,d5                   ; a stream constant, so the dispatch
fast_pass_l:                            ; values are precomputed -
        moveq   #0,d1                   ; SMC: ladder passes = chunk>>5
fast_idx_l:
        move.w  #0,d0                   ; SMC: ladder index = -2*(chunk&31)
        bra.w   lit_go

; ------------------------------- offset decode ------------------------------
new_offset:                             ; d3.w is provably 0 here (the dead
        move.b  (a0)+,d3                ; moveq of earlier variants is gone);
        lsr.b   #1,d3                   ; carry = low bit selects the form
        bcs.w   two_byte                ; (.w: the block lives next to its table
                                        ; so the lookup needs no base register)
        sub.w   #128,d3                 ; -offset = value/2 - 128 (never >= 0)
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
match_calc:                             ; boundary partials re-enter here
        move.w  d0,d1
        lsr.w   #5,d1                   ; a 32-step ladder: every chunk-16 copy
        and.w   #31,d0                  ; is a pure partial entry, zero dbf
        add.w   d0,d0                   ; passes (fill32's measured insight)
        neg.w   d0                      ; index = -2*(n&31)
match_go:                               ; boundary fulls: d0/d1/d5 pre-set
match_lea:
        lea     -1(a1),a2               ; SMC: extension word = -lastOffset,
                                        ; patched at got_offset / jx1_init
        jmp     match_end(pc,d0.w)
match_ladder:
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
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

suspend_match:                          ; chunk boundary while in a match
        subq.w  #1,d6
        bne.s   more_chunks_match       ; batch not exhausted: stay in registers
        lea     entry_bra+2(pc),a2      ; SMC: resume straight into match_cont
        move.w  #match_cont-entry_bra-2,(a2)
        move.b  d2,-(a5)                ; bit buffer
        subq.l  #2,a5                   ; skip the chunk word
        movem.l d3/a0-a1,-(a5)          ; stores in layout order, a5 = context base
        moveq   #1,d0                   ; more output pending: call again
        rts
more_chunks_match:
        jsr     (a6)                    ; the caller's between-chunk work
match_cont:                             ; mid-match continuation: in-batch
        move.w  d3,d0                   ; boundaries fall in, call re-entries
        sub.w   d7,d3                   ; arrive via the patched entry_bra.
        bcc.s   match_full              ; budget == chunk here by construction,
        clr.w   d3                      ; so this REPLACES take_budget: partial
        move.w  d7,d5                   ; means the op's last chunk - n =
        sub.w   d0,d5                   ; remaining, budget = chunk - n, done
        bra.w   match_calc
match_full:                             ; a whole chunk pending: n = chunk is
        moveq   #0,d5                   ; a stream constant, so the dispatch
fast_pass_m:                            ; values are precomputed -
        moveq   #0,d1                   ; SMC: ladder passes = chunk>>5
fast_idx_m:
        move.w  #0,d0                   ; SMC: ladder index = -2*(chunk&31)
        bra.w   match_go

end_marker:                             ; State.DONE
        lea     entry_bra+2(pc),a2      ; SMC: every later call returns 0 via
        move.w  #done_state-entry_bra-2,(a2) ; done_state
        move.b  d2,-(a5)
        subq.l  #2,a5
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts

two_byte:                               ; placed next to gtab: add.w reaches the
        add.b   d3,d3                   ; table pc-relatively, no lea needed
        moveq   #0,d0
        move.b  (a0)+,d0                ; high byte indexes G (a 256-word table):
        add.w   d0,d0                   ; -offset = (low & 254) + G[high]
        add.w   gtab(pc,d0.w),d3
        bge.w   end_marker              ; -offset >= 0 is the end marker (.w)
        bra.w   got_offset              ; (.w: back to the offset patch)

; G[H] = (H>>1)*256 + (H&1) - 32512, so that -offset = (L & 254) + G[H].
        even
gtab:
H       set     0
        rept    256
        dc.w    (H>>1)*256+(H&1)-32512
H       set     H+1
        endr
