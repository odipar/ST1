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
; 220 bytes, position-independent, one body: no macros, no tables, no
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
;   d2.w  signed last offset: negative during LITERALS, positive during MATCH;
;         with d1 = 0, +1 means START and 0 means DONE
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
; d4 is the gamma seed, segment length and full-pass counter; d5 is the gamma
; value and ladder index. d1.w is the result (zero = done), and repeated DONE
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
        moveq   #1,d2                   ; lastOffset = INITIAL_OFFSET
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
; START/DONE sit above the entry to keep its branch short.
entry_special:                          ; d1 = 0: only START or DONE survives a call
        tst.w   d2                      ; START has the initial +1 offset; DONE is 0
        bne.s   begin_literals
entry_done:
        rts                             ; d1 = 0: keep returning "fully processed"

jx1_resume:
        tst.w   d1                      ; zero only survives a call for START
        beq.s   entry_special           ; or DONE; an active op has bytes left
        bra.s   op_body                 ; mid-op with a fresh budget

; get_gamma: interlaced Elias gamma in d5.w; d4.w is the 0/1 length seed.
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
        neg.w   d2                      ; negative lastOffset = State.LITERALS
        moveq   #0,d4                   ; remaining = gamma + 0; fall through
get_gamma:
        moveq   #1,d5
        add.b   d0,d0                   ; first continuation bit
        beq.s   gamma_refill            ; the queue empties on one bit in eight,
        bcc.s   gamma_done              ; so the refill is out of line and this
gamma_loop:                             ; branch is the one normally not taken
        add.b   d0,d0                   ; data bit: never a refill
        addx.w  d5,d5                   ; value = value*2 + bit
        add.b   d0,d0                   ; continuation bit
        beq.s   gamma_refill
        bcs.s   gamma_loop              ; 1: another pair; the continue branch
gamma_done:                             ; doubles as the loop jump
        add.w   d4,d5                   ; +1 only for a new-offset match
        move.w  d5,d1                   ; remaining = gamma + caller seed

resume_op:                              ; reached after parsing an op, when the
        tst.w   d3                      ; budget may already be spent
        beq.w   suspend                 ; mid-op resumes enter at op_body
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
        bmi.s   source_ready
        movea.l a1,a2                   ; match: destination minus lastOffset
        suba.w  d2,a2                   ; Java: readBufferByte(); a1 is the window
source_ready:                           ; Java: writeByte(...) - n moves total:
        moveq   #7,d5                   ; d5 = n&7, partial-pass dispatch
        and.w   d4,d5
        lsr.w   #3,d4                   ; d4 = n>>3 full passes
        add.w   d5,d5
        neg.w   d5                      ; index = -2*(n&7)
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
ladder_end:
        dbf     d4,ladder               ; full eight-byte passes
copy_done:
        tst.w   d2
        bpl.s   copied                  ; matches consume no input here;
        movea.l a2,a0                   ; literals do
copied:
        tst.w   d1
        bne.s   suspend                 ; budget spent mid-op
        tst.w   d2                      ; test state before the bit read
        bmi.s   literals_transition     ; so the read can own carry
        add.b   d0,d0                   ; Java: next(), case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        move.b  (a0)+,d1                ; d1.w is zero; its upper word is caller-owned
        lsr.b   #1,d1                   ; carry = low bit selects the two-byte form
        bcs.s   two_byte
        neg.w   d1                      ; offset = 128 - value/2
        add.w   #128,d1
        bra.s   got_offset
two_byte:
        moveq   #0,d4
        move.b  (a0)+,d4
        lsr.b   #1,d4                   ; d4 = high >> 1, X = high & 1
        addx.w  d1,d1                   ; (low & 254) + (high & 1) in one go
        lsl.w   #8,d4
        add.w   d4,d1                   ; (high>>1)*256 + (low&254) + (high&1)
        neg.w   d1
        add.w   #32512,d1               ; offset = 32512 - that
        ble.s   end_marker              ; offset <= 0 is the end marker
got_offset:
        move.w  d1,d2                   ; lastOffset = decoded offset
        moveq   #1,d4                   ; new-offset match: remaining = gamma+1
        bra.w   get_gamma               ; taken BRA costs 10 cycles at either width

literals_transition:
        neg.w   d2                      ; both successors are State.MATCH
        add.b   d0,d0                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #0,d4                   ; from-last match: remaining = gamma
        bra.w   get_gamma               ; Java: beginMatchFromLastOffset()

suspend:                                ; Java: resume() returning true
        rts                             ; d1 <> 0: more output pending

end_marker:                             ; Java: State.DONE
        clr.w   d1                      ; normalize DONE for repeat polling
        clr.w   d2
        rts                             ; a1 remains the output end
