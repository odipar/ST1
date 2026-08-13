; -----------------------------------------------------------------------------
; smc2_lea.S - smc1_entry + SELF-MODIFYING match source (plain 68000, RAM code)
;
; Two patched words instead of one:
;
;  1. entry_bra (as in smc1_entry.S): the resume dispatch is a bra.w whose
;     displacement is patched by jx1_init / first_entry / end_marker; suspend
;     patches nothing. 16 cycles saved per mid-op resume call.
;
;  2. match_lea: the match copy source used to be recomputed on EVERY match
;     entry as a1 - lastOffset (movea.l/swap/suba.w/swap, 20 cycles). Now it
;     is 'lea <disp>(a1),a2' whose extension word holds -lastOffset, patched
;     ONCE when a new offset is parsed (and set to -1, the initial offset, by
;     jx1_init). From-last-offset matches and mid-match resumes pay only the
;     8-cycle lea: 12 cycles saved per match entry against +16 once per new
;     offset - ZX1 reuses offsets by design, so break-even is ~1.3 uses.
;
; The offset decode also flips sign convention: it computes -offset directly
; (sub.w #128 / sub.w #32512 instead of neg+add), saving 4 cycles per offset;
; the end-marker test becomes bge. ctx_packed's high word therefore now holds
; -lastOffset after the first new offset (it is diagnostic-only: nothing
; reads it back; the live copy is the lea extension word).
;
; SMC caveats (all by construction):
;   * code must live in RAM (two words are written at run time)
;   * SINGLE ACTIVE CONTEXT ONLY: dispatch target and lastOffset live in the
;     code; interleaving two contexts clobbers both. jx1_init re-establishes
;     both patched defaults, so sequential streams are fine.
;   * plain 68000 only: 68010 loop mode / 68020+ caches don't see the stores
;   * prefetch-safe: entry_bra is only patched from code reached in a LATER
;     call; match_lea+2 is stored at got_offset, >10 instructions (through
;     get_gamma and take_budget) before match_lea can execute, far beyond
;     the 2-word prefetch window
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
; a5. (As in opt3, d4 carries the op state.)
; -----------------------------------------------------------------------------


ctx_packed      equ     0               ; .l  d3: -lastOffset (high word, diagnostic), remaining (low)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: output position
ctx_chunk       equ     12              ; .b  chunkSize (X), 1..127
ctx_bits        equ     13              ; .b  bit buffer
ctx_state       equ     14              ; .b  State: 0 START, 1 LITERALS, 2 MATCH, 3 DONE
ctx_size        equ     15
ctx_alloc       equ     16              ; ctx_size rounded up to keep sp even

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = destination, d0.b = chunk size 1..127,
;           a5 = word-aligned context block of ctx_size bytes.
; (Re)establishes BOTH patched defaults: entry -> first_entry, lastOffset = 1.
; -----------------------------------------------------------------------------
jx1_init:
        move.l  a0,ctx_src(a5)
        move.l  a1,ctx_dst(a5)
        move.b  d0,ctx_chunk(a5)
        moveq   #1,d1
        swap    d1                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        move.l  d1,ctx_packed(a5)
        move.b  #$80,ctx_bits(a5)       ; empty bit buffer (sentinel only)
        clr.b   ctx_state(a5)           ; State.START (kept for ABI/debug)
        lea     entry_bra+2(pc),a1      ; SMC: next resume call opens the stream
        move.w  #first_entry-entry_bra-2,(a1)
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
; a1 = current end of output.
; -----------------------------------------------------------------------------
jx1_resume:
        movem.l (a5)+,d3/a0-a1          ; packed offset/remaining, src, dst
        moveq   #0,d5
        move.b  (a5)+,d5                ; budget = chunkSize
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_state
        move.b  (a5),d4                 ; op state (resume_op still discriminates)
entry_bra:
        bra.w   first_entry             ; SMC: displacement word is the state

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

first_entry:                            ; entry_bra target after jx1_init: runs
        lea     entry_bra+2(pc),a2      ; once, then every call resumes mid-op
        move.w  #resume_op-entry_bra-2,(a2)
begin_literals:                         ; Java: beginLiterals()
        moveq   #1,d4                   ; State.LITERALS
        bsr.s   get_gamma
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched

resume_op:                              ; shared for literals and match; d4 = state
        move.w  d3,d0                   ; take_budget: min(remaining, budget),
        cmp.w   d5,d0                   ; subtracted from both (its only site)
        bls.s   budget_fits
        move.w  d5,d0
budget_fits:
        sub.w   d0,d3
        sub.w   d0,d5
        tst.w   d0
        beq.w   suspend                 ; budget exhausted before this op
        movea.l a0,a2                   ; literals copy straight from the input
        cmp.b   #1,d4
        beq.s   source_ready
match_lea:
        lea     -1(a1),a2               ; SMC: extension word = -lastOffset,
                                        ; patched at got_offset / jx1_init
source_ready:                           ; n moves total: partial first pass of
        move.w  d0,d1                   ; n&7 entered mid-ladder, then n>>3 full
        lsr.w   #3,d1                   ; passes off the dbf at ladder_end
        and.w   #7,d0
        add.w   d0,d0
        neg.w   d0                      ; index = -2*(n&7)
        jmp     ladder_end(pc,d0.w)     ; pc-relative dispatch, no base register
ladder:
        move.b  (a2)+,(a1)+             ; 8 fully rolled-out byte moves; entry
        move.b  (a2)+,(a1)+             ; at ladder_end-2k copies exactly k
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
        move.b  (a2)+,(a1)+
ladder_end:
        dbf     d1,ladder               ; full 8-move passes for big copies
copy_done:
        cmp.b   #1,d4
        bne.s   copied                  ; matches consume no input here;
        movea.l a2,a0                   ; literals do
copied:
        tst.w   d3
        bne.s   suspend                 ; budget spent mid-op
        cmp.b   #1,d4                   ; state test BEFORE the bit read: cmp
        beq.s   literals_transition     ; must not clobber the bit in carry
        add.b   d2,d2                   ; case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:                             ; computes -offset directly (the lea
        moveq   #2,d4                   ; extension word wants it negated)
        moveq   #0,d3
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
        move.w  d1,d3
        bra.w   resume_op

literals_transition:
        add.b   d2,d2                   ; case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #2,d4                   ; 0: State.MATCH from last offset:
        bsr.w   get_gamma               ; match_lea still holds -lastOffset
        move.w  d1,d3                   ; remaining = gamma
        bra.w   resume_op

suspend:                                ; resume() returning true: NO patch
        move.b  d4,(a5)                 ; needed, mid-op resumes share resume_op
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
