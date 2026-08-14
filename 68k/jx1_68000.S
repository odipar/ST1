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
; Decompresses a jx1/ZX1 stream into a linear buffer, a bounded number of
; bytes at a time: jx1_resume emits at most the budget you give it and picks
; up mid-operation where it left off, so a caller can interleave its own work
; - drawing a frame, filling a sound buffer - between calls. jx1_decompress
; does the whole stream in one go.
;
; Matches are copied from the destination itself, so the output buffer is the
; match window and must hold everything decompressed so far. Use
; jx1_68000_ring.S to decompress into memory bounded by a ring buffer instead.
;
; 238 bytes, position-independent, one body: no macros, no tables, no
; self-modifying code. It runs from ROM, and since it keeps nothing in memory,
; a second concurrent stream is just a second set of registers.
;
; -----------------------------------------------------------------------------
; THE STATE IS YOUR REGISTERS. There is no context block to allocate, align or
; keep alive; jx1_init seeds four registers and a resume loop leaves all six
; alone between calls:
;
;   a0  input position
;   a1  write pointer - where the output ends, after every call
;   d0  bit queue (only the low byte is used; $80 is the empty sentinel)
;   d1  bytes remaining in the current operation (low word)
;   d2  operation state: $80 START, 0 LITERALS, 2 MATCH, $FF DONE. Signed on
;       purpose, so the entry dispatches on the flags a tst.b already sets
;   d3  offset of the current match, and of the last one, which the format
;       lets a later match reuse
;
; Calling convention, in full:
;
;   in and out   a0 a1 d0 d1 d2 d3   the state; leave it alone between calls
;   in           d4.w                this call's budget, spent by the call
;   out          d5                  0 = fully processed, 1 = more to come
;   CLOBBERED    d4 d5 d6 a4         no value in these survives a call
;   untouched    d7 a2 a3 a5 a6      and the stack beyond the return address
;
; d5 and d6 are working registers throughout - d5 carries the segment length
; and the copy-ladder index, d6 the gamma value - so treat both as gone across
; a call; d5 is merely the last thing written to it. d4 comes back spent, not
; refilled: pass it again on the next call.
;
; A finished stream keeps returning 0 however often you poll it.
;
; -----------------------------------------------------------------------------
; ASSUMPTIONS. Undefined behaviour when violated, because nothing checks them:
;
;   1. no single literal run or match is longer than 65535 bytes - an
;      operation's length lives in a word. Compress with jx1 -l65535, which
;      splits any longer match; a stream compressed without it can exceed the
;      limit, and would decode short here with no error
;   2. the budget in d4.w is 1..65535
;
; TRUSTED INPUT ONLY. Nothing here is validated: not the stream, not the end
; of the input, not the destination, not the parameters. A malformed or
; hostile stream can read and write arbitrary memory, an offset reaching back
; further than the output produced so far reads whatever is there, and a
; budget of zero never advances an operation, so a caller's drain loop spins
; forever. That is the deliberate price of a decompressor this size. For data
; you did not produce yourself, validate the stream and its decompressed
; length before calling in, or decompress it somewhere it cannot do harm.
; -----------------------------------------------------------------------------

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = destination. Seeds d0/d1/d2/d3, the
;           four state registers that are not pointers. Writes no memory.
; Java: the Decompressor constructor / reset().
; -----------------------------------------------------------------------------
jx1_init:
        moveq   #1,d3                   ; lastOffset = INITIAL_OFFSET
        moveq   #0,d1                   ; remaining = 0
        moveq   #-128,d0                ; an empty bit queue: $80 is the sentinel
        move.b  d0,d2                   ; State.START, which is the same $80
        rts

; -----------------------------------------------------------------------------
; jx1_decompress: a0 = compressed data, a1 = destination.
; One-shot convenience; returns with a1 = end of output.
; Java: the static Decompressor.decompress() helpers.
; -----------------------------------------------------------------------------
jx1_decompress:
        bsr.s   jx1_init
.drain:
        moveq   #-1,d4                  ; budget = 65535 per call: a one-shot has
                                        ; no reason to hand control back, so a
                                        ; 32K output is one call, not 252
        bsr.s   jx1_resume              ; Java: while (resume()) {}
        tst.w   d5
        bne.s   .drain
        rts

; -----------------------------------------------------------------------------
; jx1_resume: a0/a1/d0/d1/d2/d3 = the state, d4.w = this call's budget.
; Emits at most d4 bytes. Returns d5 = 0 when the stream is fully processed,
; 1 when there is more. The state registers come back updated, which is
; exactly what the next call takes in, and a1 is the end of the output.
; Java: Decompressor.resume().
;
; The two rare states are handled just above the entry so that the branch to
; them is a short one; jx1_resume itself is the label below them.
; -----------------------------------------------------------------------------
entry_special:                          ; the negative states, both rare
        add.b   d2,d2                   ; START ($80) doubles to zero; DONE
        beq.s   begin_literals          ; ($FF) does not, so it falls through
entry_done:
        moveq   #0,d5                   ; keep returning "fully processed"
        rts

jx1_resume:
        tst.b   d2                      ; op state (Java: switch in next()) -
        bmi.s   entry_special           ; START and DONE are the negative ones
        bra.s   op_body                 ; mid-op: the budget is fresh, so the
                                        ; loop guard below the copy can be
                                        ; skipped on the way in

; get_gamma: interlaced Elias gamma value in d6.w (assumption: fits a word).
; Holds the decompressor's only bit-queue refills: gammas are odd-length,
; transitions are single bits, and the stream opens with a gamma, so
; continuation bits sit at even bit indices and the queue (refilled every
; 8th bit) can only empty on one - data and transition bits are read bare,
; with no refill check. The first continuation bit is peeled (a length-1
; value falls straight through) and the loop is rotated so the continue
; branch is the back-jump: no unconditional bra per pair.
; Java: readInterlacedEliasGamma().
get_gamma:
        moveq   #1,d6
        add.b   d0,d0                   ; first continuation bit
        beq.s   gamma_refill            ; the queue empties on one bit in eight,
        bcc.s   gamma_done              ; so the refill is out of line and this
gamma_loop:                             ; branch is the one normally not taken
        add.b   d0,d0                   ; data bit: never a refill
        addx.w  d6,d6                   ; value = value*2 + bit
        add.b   d0,d0                   ; continuation bit
        beq.s   gamma_refill
        bcs.s   gamma_loop              ; 1: another pair; the continue branch
gamma_done:                             ; doubles as the loop jump
        rts
gamma_refill:                           ; both sites want the same thing of a
        move.b  (a0)+,d0                ; refilled queue - carry set means
        addx.b  d0,d0                   ; another pair follows - so they share
        bcs.s   gamma_loop              ; one block, and duplicating this tail
        rts                             ; costs nothing over branching back

begin_literals:                         ; Java: beginLiterals()
        moveq   #0,d2                   ; State.LITERALS
        bsr.s   get_gamma
        move.w  d6,d1                   ; remaining = gamma; lastOffset untouched

resume_op:                              ; reached after parsing an op, when the
        tst.w   d4                      ; budget may already be spent; a call
        beq.w   suspend                 ; resuming mid-op enters at op_body
                                        ; instead and skips this
op_body:                                ; shared for literals and match; d2 = state
        move.w  d1,d5                   ; take_budget: min(remaining, budget),
        cmp.w   d4,d5                   ; subtracted from both (its only site)
        bls.s   budget_fits
        move.w  d4,d5
budget_fits:
        sub.w   d5,d1
        sub.w   d5,d4
        movea.l a0,a4                   ; literals copy straight from the input
        tst.b   d2
        beq.s   source_ready
        movea.l a1,a4                   ; match: destination minus lastOffset
        suba.w  d3,a4                   ; (Java: readBufferByte(); the destination
                                        ; is the window, so no ring arithmetic)
source_ready:                           ; Java: writeByte(...) - n moves total:
        move.w  d5,d6                   ; a partial first pass of n&7 entered
        lsr.w   #3,d6                   ; mid-ladder, then n>>3 full passes off
        and.w   #7,d5                   ; the dbf at ladder_end
        add.w   d5,d5
        neg.w   d5                      ; index = -2*(n&7)
        jmp     ladder_end(pc,d5.w)     ; pc-relative dispatch, no base register
ladder:
        move.b  (a4)+,(a1)+             ; 8 fully rolled-out byte moves; entry
        move.b  (a4)+,(a1)+             ; at ladder_end-2k copies exactly k
        move.b  (a4)+,(a1)+
        move.b  (a4)+,(a1)+
        move.b  (a4)+,(a1)+
        move.b  (a4)+,(a1)+
        move.b  (a4)+,(a1)+
        move.b  (a4)+,(a1)+
ladder_end:
        dbf     d6,ladder               ; full 8-move passes for big copies
copy_done:
        tst.b   d2
        bne.s   copied                  ; matches consume no input here;
        movea.l a4,a0                   ; literals do
copied:
        tst.w   d1
        bne.s   suspend                 ; budget spent mid-op
        tst.b   d2                      ; state test BEFORE the bit read: it
        beq.s   literals_transition     ; must not clobber the bit in carry
        add.b   d0,d0                   ; Java: next(), case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        move.b  (a0)+,d1                ; d1.w is already zero: every edge here
                                        ; has just completed an op, and the
                                        ; stale high word is overwritten by the
                                        ; swap/move.w pair at got_offset
        lsr.b   #1,d1                   ; carry = low bit selects the two-byte form
        bcs.s   two_byte
        neg.w   d1                      ; offset = 128 - value/2
        add.w   #128,d1
        bra.s   got_offset
two_byte:
        moveq   #0,d5
        move.b  (a0)+,d5
        lsr.b   #1,d5                   ; d5 = high >> 1, X = high & 1
        addx.w  d1,d1                   ; (low & 254) + (high & 1) in one go
        lsl.w   #8,d5
        add.w   d5,d1                   ; (high>>1)*256 + (low&254) + (high&1)
        neg.w   d1
        add.w   #32512,d1               ; offset = 32512 - that
        ble.s   end_marker              ; offset <= 0 is the end marker
got_offset:
        move.w  d1,d3                   ; the new lastOffset. Same four cycles a
                                        ; swap cost, and now the match source
                                        ; needs no swaps at all
        bsr.w   get_gamma               ; (.w: out of short range; BSR is 18
                                        ; cycles at either width)
        addq.w  #1,d6                   ; remaining = gamma + 1
        move.w  d6,d1
        bra.w   resume_op               ; (.w: out of short range; BRA taken
                                        ; costs 10 cycles at either width)

literals_transition:
        moveq   #2,d2                   ; State.MATCH: both successors of a
                                        ; literal run are matches, and the
                                        ; assignment has to precede the bare
                                        ; read below - a moveq between the add
                                        ; and the bcs would destroy the carry.
                                        ; (A match reaching new_offset already
                                        ; holds 2, so that path needs none.)
        add.b   d0,d0                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        bsr.w   get_gamma               ; Java: beginMatchFromLastOffset() (.w: same)
        move.w  d6,d1                   ; remaining = gamma; lastOffset untouched
        bra.w   resume_op               ; (.w: same, zero cycle cost)

suspend:                                ; Java: resume() returning true
        moveq   #1,d5                   ; more output pending: call again. The
        rts                             ; state is already where it lives - in
                                        ; the caller's registers

end_marker:                             ; Java: State.DONE (no final flip needed:
        st      d2                      ; State.DONE; the end of the output is
        moveq   #0,d5                   ; in a1, as after any other call
        rts
