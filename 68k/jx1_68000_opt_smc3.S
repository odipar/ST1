; -----------------------------------------------------------------------------
; smc3_split.S - split-body decompressor, op type IS the program counter
;                (plain 68000, RAM code, self-modifying)
;
; The shared resume_op body of opt7 exists so one copy of take_budget/ladder/
; suspend can serve literals and matches, discriminated by d4 = ctx_state -
; three cmp.b #1,d4 tests per op (source select, copy_done, transition), plus
; the beq/cmp/bne entry dispatch. This variant DUPLICATES the body instead:
; a literals body and a match body, so the op type is encoded in the program
; counter and every d4 test disappears (d4 is no longer touched at all).
;
; The one place that still needs a stored op type is the resume entry: it is
;       entry_bra: bra.w <target>       ; displacement word rewritten by SMC
; patched by whoever RETURNS to the caller:
;   - jx1_init       -> begin_literals   (the stream opens with literals)
;   - suspend_lit    -> lit_resume       \  the interrupted body patches its
;   - suspend_match  -> match_resume     /  own resume address, 20 cycles
;   - end_marker     -> done_state
; so the entry pays a flat 10-cycle bra.w and never reads ctx_state (the
; byte is still written at suspend for ABI/debugging).
;
; The match body's copy source is the patched 'lea <disp>(a1),a2' of
; smc2_lea.S: the extension word holds -lastOffset, written once per NEW
; offset (jx1_init resets it to -1); from-last matches and mid-match resumes
; pay only the 8-cycle lea. The offset decode computes -offset directly
; (sub.w instead of neg+add, 4 cycles cheaper); ctx_packed's high word
; holds -lastOffset and is diagnostic-only.
;
; Cycle accounting vs opt7, steady state:
;   per call: entry -24 (no state chain, no d4 load), suspend +20 (patch) = -4
;   per literal op: -18 source select, -16 copy_done, -8 transition, -4 d4
;   per match op:   -32 source select, -18 copy_done, -16 transition, -4 d4,
;                   +16 patch per NEW offset only
;   per mid-op resume call: the source-select/copy_done savings repeat
;
; SMC caveats (all by construction):
;   * code must live in RAM (three words are written at run time)
;   * SINGLE ACTIVE CONTEXT ONLY: the resume target and lastOffset live in
;     the code, so interleaving resume calls on two contexts clobbers them;
;     jx1_init re-establishes all patched defaults for sequential streams
;   * plain 68000 only: 68010 loop mode and 68020+ instruction caches do
;     not see stores into the instruction stream
;   * prefetch-safe: entry_bra is patched only by code that returns to the
;     caller (next possible execution is the NEXT call); match_lea+2 is
;     stored at got_offset, >10 instructions before match_lea can execute,
;     far beyond the 68000's 2-word prefetch window
;   * position-independent: patch addresses are computed with lea (pc)
;
; Same assumptions as jx1_68000_opt.S, undefined when violated:
;
;   1. no single literal run or match is longer than 32768 bytes
;   2. the chunk size is 1..127
;
;
; The context must be word-aligned and is 15 bytes (16 with padding).
;
; Calling convention: jx1_init and jx1_resume clobber d0-d5/a0-a2 and leave
; a5 = context untouched; jx1_decompress additionally uses (but restores)
; a5. (d4 is NOT touched: the op type lives in the program counter.)
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

; get_gamma: interlaced Elias gamma value in d1.w (assumption: fits a word).
; Identical to opt7.
get_gamma:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   gamma_first
        move.b  (a0)+,d2                ; refill; ZX1 bit groups always open on a
        addx.b  d2,d2                   ; continuation bit (see jx1_68000_opt3.S)
gamma_first:
        bcc.s   gamma_done              ; 0: value is 1, straight through
gamma_loop:
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + data bit
        add.b   d2,d2                   ; next continuation bit (refill site)
        bne.s   gamma_have
        move.b  (a0)+,d2
        addx.b  d2,d2
gamma_have:
        bcs.s   gamma_loop              ; 1: another pair; the continue branch
gamma_done:                             ; doubles as the loop jump
        rts

; ------------------------------- literals body ------------------------------
begin_literals:                         ; Java: beginLiterals()
        bsr.s   get_gamma
        move.w  d1,d3                   ; remaining = gamma

lit_resume:                             ; entry_bra target while mid-literals
        move.w  d3,d0                   ; take_budget: min(remaining, budget)
        cmp.w   d5,d0
        bls.s   .fits
        move.w  d5,d0
.fits:
        sub.w   d0,d3
        sub.w   d0,d5
        tst.w   d0
        beq.s   suspend_lit             ; budget exhausted before this op
        movea.l a0,a2                   ; literals copy straight from the input
        move.w  d0,d1
        lsr.w   #3,d1
        and.w   #7,d0
        add.w   d0,d0
        neg.w   d0                      ; index = -2*(n&7)
        jmp     lit_end(pc,d0.w)
lit_ladder:
        move.b  (a2)+,(a1)+             ; 8 fully rolled-out byte moves; entry
        move.b  (a2)+,(a1)+             ; at lit_end-2k copies exactly k
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
lit_end:
        dbf     d1,lit_ladder           ; full 8-move passes for big copies
        movea.l a2,a0                   ; literals consume input
        tst.w   d3
        bne.s   suspend_lit             ; budget spent mid-op
        add.b   d2,d2                   ; transition (bare read, opt3 invariant)
        bcs.s   new_offset              ; 1: new offset
        bsr.s   get_gamma               ; 0: match from last offset - match_lea
        move.w  d1,d3                   ; still holds -lastOffset; remaining = gamma
        bra.w   match_resume

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
new_offset:                             ; computes -offset directly (the lea
        moveq   #0,d3                   ; extension word wants it negated)
        move.b  (a0)+,d3
        lsr.b   #1,d3                   ; carry = low bit selects the two-byte form
        bcs.s   two_byte
        sub.w   #128,d3                 ; -offset = value/2 - 128 (never >= 0)
        bra.s   got_offset
two_byte:
        add.b   d3,d3                   ; low & 254
        moveq   #0,d0
        move.b  (a0)+,d0
        lsr.b   #1,d0                   ; d0 = high >> 1, carry = high & 1
        bcc.s   no_carry
        addq.w  #1,d3
no_carry:
        lsl.w   #8,d0
        add.w   d0,d3                   ; (high>>1)*256 + (low&254) + (high&1)
        sub.w   #32512,d3               ; -offset = that - 32512
        bge.s   end_marker              ; -offset >= 0 is the end marker
got_offset:
        lea     match_lea+2(pc),a2      ; SMC: source displacement = -offset;
        move.w  d3,(a2)                 ; match_lea executes >10 instructions
        swap    d3                      ; from here (prefetch-safe); park
        bsr.w   get_gamma               ; -lastOffset in d3's high word
        addq.w  #1,d1                   ; remaining = gamma + 1
        move.w  d1,d3                   ; falls into the match body

; -------------------------------- match body --------------------------------
match_resume:                           ; entry_bra target while mid-match
        move.w  d3,d0                   ; take_budget: min(remaining, budget)
        cmp.w   d5,d0
        bls.s   .fits
        move.w  d5,d0
.fits:
        sub.w   d0,d3
        sub.w   d0,d5
        tst.w   d0
        beq.s   suspend_match           ; budget exhausted before this op
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
        bcs.s   new_offset              ; 1: new offset
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
