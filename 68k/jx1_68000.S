; -----------------------------------------------------------------------------
; jx1_68000.S - JX1: resumable ZX1 decompressor for the 68000
;
; By Robbert van Dalen, based on ZX1 v1.5 by Einar Saukas (data compression
; format, algorithm, and the original C/z80 decompressors). Code and the
; optimization work behind it written by Claude (Anthropic's Claude Code)
; under Robbert's direction. The decompressor can be used freely within
; your own programs, even commercially, as long as your documentation
; indicates that you used ZX1/jx1 (see LICENSE).
;
; Resumable decode into a linear buffer: jx1_resume emits at most its budget
; and resumes mid-operation; jx1_decompress drains the stream. The destination
; is the match window and must retain all output. For bounded memory, use
; jx1_68000_ring.S.
;
; 208 bytes, position-independent, one body: no macros, no tables, no
; self-modifying code. It runs from ROM, and since it keeps nothing in memory,
; a second concurrent stream is just a second set of registers.
;
; -----------------------------------------------------------------------------
; THE STATE IS YOUR REGISTERS. jx1_init seeds the non-pointer state; preserve
; all five registers between calls:
;
;   a0.l  input position
;   a1.l  write pointer - where the output ends, after every call
;   d0.b  bit queue ($80 is the empty sentinel)
;   d1.w  bytes remaining in the current operation
;   d2.w  signed offset/state: +lastOffset during LITERALS, -lastOffset during
;         MATCH; with d1 = 0, -1 means START and 0 means DONE
;
; jx1_resume touches only these widths; their upper bits are caller-owned.
;
; Calling convention:
;   in and out   a0.l a1.l d0.b      the state; leave it alone between calls
;                d1.w d2.w
;   in           d3.w                this call's budget, spent by the call
;   CLOBBERED    d3.w d4.l d5.l      no value in these survives a call
;                a2.l
;   untouched    d6 d7 a3 a4 a5 a6   and the stack beyond the return address
;
; d4 is gamma/offset scratch and the copy count; d5 is offset/ladder scratch.
; d1.w is the result (zero = done), and repeated DONE
; polls stay zero. Refill d3.w before each call.
;
; -----------------------------------------------------------------------------
; ASSUMPTIONS (unchecked; violating them is undefined behaviour):
;
;   1. no single literal run or match is longer than 65535 bytes - an
;      operation length is a word; compress with jx1 -l65535
;   2. the budget in d3.w is 1..65535
;
; TRUSTED INPUT ONLY. Stream, bounds, destination and parameters are not
; validated. Malformed data can read or write arbitrary memory; a zero budget
; makes no progress. Validate untrusted streams and decompressed lengths first,
; or decode them in an isolated memory region.
; -----------------------------------------------------------------------------

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume

; jx1_init: a0 = compressed data, a1 = destination; seeds d0/d1/d2.
; Java: the Decompressor constructor / reset().
jx1_init:
        moveq   #-1,d2                  ; -lastOffset = -INITIAL_OFFSET
        moveq   #0,d1                   ; remaining = 0
        moveq   #-128,d0                ; an empty bit queue: $80 is the sentinel
        rts

; jx1_decompress: a0 = compressed data, a1 = destination.
; One-shot convenience; returns with a1 = end of output.
; Java: the static Decompressor.decompress() helpers.
jx1_decompress:
        bsr.s   jx1_init
.drain:
        moveq   #-1,d3                  ; budget = 65535; refill for longer output
        bsr.s   jx1_resume              ; Java: while (resume()) {}
        tst.w   d1
        bne.s   .drain
        rts

; jx1_resume: a0/a1/d0/d1/d2 = the state, d3.w = this call's budget.
; Emits at most d3 bytes; d1.w = 0 means done, otherwise more remains. State
; and a1 return updated for the next call.
; Java: Decompressor.resume().
jx1_resume:
        tst.w   d1                      ; active ops enter the copy body directly
        bne.s   op_body
        tst.w   d2                      ; d1 = 0: START is -1 and DONE is zero
        bne.s   begin_literals
suspend:                                ; DONE or a suspended operation
        rts

; get_gamma: interlaced Elias gamma in d1.w; d4.w is the 0/1 length seed.
; Gammas are odd-length and the stream starts with one, so the queue can empty
; only on a continuation bit; data and transition reads need no refill check.
; The first continuation is peeled and bcs is the loop edge.
; Java: readInterlacedEliasGamma().
gamma_refill:                           ; queue-empty continuations share one
        move.b  (a0)+,d0                ; refill; carry set means another pair
        addx.b  d0,d0                   ; follows, otherwise finish the gamma
        bcs.s   gamma_loop
        bra.s   gamma_done

begin_literals:                         ; Java: beginLiterals()
        neg.w   d2                      ; positive lastOffset = State.LITERALS
gamma_seed0:
        moveq   #0,d4                   ; remaining = gamma + 0; fall through
get_gamma:
        addq.w  #1,d1
        add.b   d0,d0                   ; first continuation bit
        beq.s   gamma_refill            ; the queue empties on one bit in eight,
        bcc.s   gamma_done              ; so the refill is out of line and this
gamma_loop:                             ; branch is the one normally not taken
        add.b   d0,d0                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + bit
        add.b   d0,d0                   ; continuation bit
        beq.s   gamma_refill
        bcs.s   gamma_loop              ; 1: another pair; the continue branch
gamma_done:                             ; doubles as the loop jump
        add.w   d4,d1                   ; +1 only for a new-offset match

resume_op:                              ; reached after parsing an op, when the
        tst.w   d3                      ; budget may already be spent
        beq.s   suspend                 ; mid-op resumes enter at op_body
op_body:                                ; shared; sign(d2) = LITERALS/MATCH
        move.w  d1,d4                   ; take_budget: min(remaining, budget),
        cmp.w   d3,d4                   ; subtracted from both (its only site)
        bls.s   budget_fits
        move.w  d3,d4
budget_fits:
        sub.w   d4,d1
        sub.w   d4,d3
        movea.l a0,a2                   ; literals copy straight from the input
        tst.w   d2
        bpl.s   source_ready
        movea.l a1,a2                   ; match: destination plus -lastOffset
        adda.w  d2,a2                   ; Java: readBufferByte(); a1 is the window
source_ready:                           ; Java: writeByte(...) - n moves total:
        moveq   #15,d5                  ; d5 = n&15, partial-pass dispatch
        and.w   d4,d5
        lsr.w   #4,d4                   ; d4 = n>>4 full passes
        add.w   d5,d5
        neg.w   d5                      ; index = -2*(n&15)
        jmp     ladder_end(pc,d5.w)     ; pc-relative dispatch, no base register
ladder:
        move.b  (a2)+,(a1)+             ; entry at ladder_end-2k copies k bytes
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
ladder_end:
        dbf     d4,ladder               ; full 16-byte passes
copy_done:
        tst.w   d2
        bmi.s   match_copied            ; matches consume no input here
        movea.l a2,a0                   ; literals do
        tst.w   d1
        bne.s   suspend                 ; budget spent mid-op

literals_transition:
        add.b   d0,d0                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        neg.w   d2                      ; from-last reuses the negated offset
        bra.s   gamma_seed0             ; Java: beginMatchFromLastOffset()

match_copied:
        tst.w   d1
        bne.s   resume_return            ; budget spent mid-op; nearby shared RTS
        add.b   d0,d0                   ; Java: next(), case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        move.b  (a0)+,d4                ; DBF left $ffff; transition left X=1
        roxr.b  #1,d4                   ; $ff80 + low/2; carry selects two bytes
        bcc.s   got_offset
two_byte:
        move.b  (a0)+,d5
        roxr.b  #1,d5                   ; $ff80 + high/2; X = high & 1
        addx.w  d4,d4                   ; $ff00 + (low&254) + (high&1)
        addq.b  #2,d5                   ; fold the -32512 bias into the high byte
        lsl.w   #8,d5                   ; stale d5 word-high shifts out
        add.w   d5,d4
        bpl.s   end_marker              ; nonnegative is the end marker
got_offset:
        move.w  d4,d2                   ; install -lastOffset; preserve d2.high
        moveq   #1,d4                   ; new-offset match: remaining = gamma+1
        bra.w   get_gamma               ; taken BRA costs 10 cycles at either width

end_marker:                             ; Java: State.DONE
        clr.w   d2                      ; d1.w is already zero; normalize DONE
resume_return:
        rts                             ; a1 remains the output end
