; -----------------------------------------------------------------------------
; jx1_68000.S - JX1: rotated-gamma resumable ZX1 decompressor (68000) v0.1
;
; By Robbert van Dalen, based on ZX1 v1.5 by Einar Saukas (data compression
; format, algorithm, and the original C/z80 decompressors). Code and the
; optimization work behind it written by Claude (Anthropic's Claude Code)
; under Robbert's direction. The decompressor can be used freely within
; your own programs, even commercially, as long as your documentation
; indicates that you used ZX1/jx1 (see LICENSE).
;
; A resumable port of the Java Decompressor state machine: jx1_resume
; emits at most one chunk of output per call and picks up mid-op where it
; left off. 324 bytes, one body, no macros, no tables, no self-modifying
; code; runs from ROM, any number of concurrent contexts.
;
; Assumptions, undefined when violated:
;
;   1. no single literal run or match is longer than 32768 bytes
;   2. the chunk size is 1..127
;
; The context must be word-aligned and is 16 bytes.
;
; Calling convention: jx1_init and jx1_resume clobber d0-d5/a0-a2 and leave
; a5 = context untouched; jx1_decompress additionally uses (but restores)
; a5. (d4 carries the op state.)
; -----------------------------------------------------------------------------


; Context block (Java: Decompressor's fields). The first three longwords are
; laid out in movem order d3,a0,a1.
ctx_packed      equ     0               ; .l  d3: lastOffset (high word), remaining (low word)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: output position
ctx_chunk       equ     12              ; .w  chunkSize (X), 1..127 (a word: the
                                        ;     budget is only ever used word-wide,
                                        ;     so the entry loads it as one)
ctx_bits        equ     14              ; .b  bit buffer
ctx_state       equ     15              ; .b  State: $80 START, 0 LITERALS,
ctx_size        equ     16              ;     2 MATCH, $FF DONE - signed, so the
                                        ;     entry dispatches on the load's flags

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = destination, d0.w = chunk size 1..127,
;           a5 = word-aligned context block of ctx_size bytes.
; Java: the Decompressor constructor / reset().
; -----------------------------------------------------------------------------
jx1_init:
        moveq   #1,d3
        swap    d3                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        swap    d0                      ; the last longword is the chunk word,
        move.w  #$8080,d0               ; an empty bit buffer and State.START,
        movea.l d0,a2                   ; so the whole context is four registers
        movem.l d3/a0-a2,(a5)           ; in movem order and one store
        rts

; -----------------------------------------------------------------------------
; jx1_decompress: a0 = compressed data, a1 = destination.
; One-shot convenience; returns with a1 = end of output.
; Java: the static Decompressor.decompress() helpers.
; -----------------------------------------------------------------------------
jx1_decompress:
        move.l  a5,-(sp)
        lea     -ctx_size(sp),sp
        movea.l sp,a5
        moveq   #127,d0                 ; largest chunk a byte allows
        bsr.s   jx1_init
.drain:
        bsr.s   jx1_resume              ; Java: while (resume()) {}
        tst.w   d0
        bne.s   .drain
        lea     ctx_size(sp),sp
        movea.l (sp)+,a5
        rts

; -----------------------------------------------------------------------------
; jx1_resume: a5 = context. Emits at most ctx_chunk output bytes.
; Returns d0 = 0 when the stream is fully processed, 1 when there is more;
; a1 = current end of output. Java: Decompressor.resume().
; -----------------------------------------------------------------------------
entry_special:                          ; the negative states, both rare
        addq.b  #1,d4                   ; DONE ($FF) becomes zero
        beq.s   entry_done
        bra.s   begin_literals          ; START: the stream opens with literals
entry_done:
        lea     -ctx_state(a5),a5       ; keep returning "fully processed"
        moveq   #0,d0
        rts

jx1_resume:
        movem.l (a5)+,d3/a0-a1          ; packed offset/remaining, src, dst
        move.w  (a5)+,d5                ; budget = chunkSize
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_state
        move.b  (a5),d4                 ; op state (Java: switch in next()) -
        bmi.s   entry_special           ; START and DONE are the negative ones
        bra.s   op_body                 ; mid-op: the budget is a whole chunk
                                        ; again, so its guard can be skipped

; get_gamma: interlaced Elias gamma value in d1.w (assumption: fits a word).
; Holds the decompressor's only bit-queue refills: gammas are odd-length,
; transitions are single bits, and the stream opens with a gamma, so
; continuation bits sit at even bit indices and the queue (refilled every
; 8th bit) can only empty on one - data and transition bits are read bare,
; with no refill check. The first continuation bit is peeled (a length-1
; value falls straight through) and the loop is rotated so the continue
; branch is the back-jump: no unconditional bra per pair.
; Java: readInterlacedEliasGamma().
get_gamma:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   gamma_first
        move.b  (a0)+,d2                ; refill; bit groups always open on a
        addx.b  d2,d2                   ; continuation bit (see the note above)
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

begin_literals:                         ; Java: beginLiterals()
        moveq   #0,d4                   ; State.LITERALS
        bsr.s   get_gamma
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched

resume_op:                              ; reached after parsing an op, when the
        tst.w   d5                      ; chunk may already be spent; a call
        beq.w   suspend                 ; resuming mid-op enters at op_body
                                        ; instead and skips this
op_body:                                ; shared for literals and match; d4 = state
        move.w  d3,d0                   ; take_budget: min(remaining, budget),
        cmp.w   d5,d0                   ; subtracted from both (its only site)
        bls.s   budget_fits
        move.w  d5,d0
budget_fits:
        sub.w   d0,d3
        sub.w   d0,d5
        movea.l a0,a2                   ; literals copy straight from the input
        tst.b   d4
        beq.s   source_ready
        movea.l a1,a2                   ; match: destination minus lastOffset
        swap    d3                      ; (Java: readBufferByte(); the destination
        suba.w  d3,a2                   ; is the window, so no ring arithmetic)
        swap    d3
source_ready:                           ; Java: writeByte(...) - n moves total:
        move.w  d0,d1                   ; a partial first pass of n&7 entered
        lsr.w   #3,d1                   ; mid-ladder, then n>>3 full passes off
        and.w   #7,d0                   ; the dbf at ladder_end
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
        tst.b   d4
        bne.s   copied                  ; matches consume no input here;
        movea.l a2,a0                   ; literals do
copied:
        tst.w   d3
        bne.s   suspend                 ; budget spent mid-op
        tst.b   d4                      ; state test BEFORE the bit read: it
        beq.s   literals_transition     ; must not clobber the bit in carry
        add.b   d2,d2                   ; Java: next(), case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        moveq   #2,d4                   ; State.MATCH
        move.b  (a0)+,d3                ; d3.w is already zero: every edge here
                                        ; has just completed an op, and the
                                        ; stale high word is overwritten by the
                                        ; swap/move.w pair at got_offset
        lsr.b   #1,d3                   ; carry = low bit selects the two-byte form
        bcs.s   two_byte
        neg.w   d3                      ; offset = 128 - value/2
        add.w   #128,d3
        bra.s   got_offset
two_byte:
        moveq   #0,d0
        move.b  (a0)+,d0
        lsr.b   #1,d0                   ; d0 = high >> 1, X = high & 1
        addx.w  d3,d3                   ; (low & 254) + (high & 1) in one go
        lsl.w   #8,d0
        add.w   d0,d3                   ; (high>>1)*256 + (low&254) + (high&1)
        neg.w   d3
        add.w   #32512,d3               ; offset = 32512 - that
        ble.s   end_marker              ; offset <= 0 is the end marker
got_offset:
        swap    d3                      ; park the new offset in the high word
        bsr.w   get_gamma               ; (.w: out of short range; BSR is 18
                                        ; cycles at either width)
        addq.w  #1,d1                   ; remaining = gamma + 1
        move.w  d1,d3
        bra.w   resume_op               ; (.w: out of short range; BRA taken
                                        ; costs 10 cycles at either width)

literals_transition:
        add.b   d2,d2                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #2,d4                   ; 0: State.MATCH from last offset
        bsr.w   get_gamma               ; Java: beginMatchFromLastOffset() (.w: same)
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        bra.w   resume_op               ; (.w: same, zero cycle cost)

suspend:                                ; Java: resume() returning true
        move.b  d4,(a5)                 ; the interrupted op's state, verbatim
        move.b  d2,-(a5)                ; bit buffer
        subq.l  #2,a5                   ; skip the chunk word
        movem.l d3/a0-a1,-(a5)          ; stores in layout order, a5 = context base
        moveq   #1,d0                   ; more output pending: call again
        rts

end_marker:                             ; Java: State.DONE (no final flip needed:
        st      (a5)                    ; State.DONE (output is already in place)
        move.b  d2,-(a5)
        subq.l  #2,a5
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts
