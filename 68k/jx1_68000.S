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
; left off. 242 bytes, one body, no macros, no tables, no self-modifying
; code; runs from ROM, any number of concurrent contexts.
;
;
; Once a stream is finished the context holds only its state byte: the final
; call stops writing the other fields back, because nothing reads them again.
; A finished stream keeps returning 0, and the end of the output is in a1.
; TRUSTED INPUT ONLY. Nothing here is validated: not the stream, not the end
; of the input, not the destination, not the parameters. A malformed or
; hostile stream can read and write arbitrary memory, an offset beyond the
; history produced so far reads whatever is there, and a chunk size of zero
; never advances an operation, so a caller's drain loop spins forever. That is
; the deliberate price of a decompressor this size. For data you did not
; produce yourself, validate the stream and its decompressed length before
; calling in, or decompress it somewhere it cannot do harm.
;
; Assumptions, undefined when violated:
;
;   1. no single literal run or match is longer than 65535 bytes - the
;      length lives in a word. Compress with jx1 -l65535, which splits any
;      longer match; a plain stream can exceed it and would decode short here
;   2. the budget d5.w is 1..65535 - a call emits at most that many
;      bytes. It is a parameter, not state: pass it on every call
;
; There is no context block: a0/a1/d2/d3/d4 ARE the state, and a resume loop
; simply leaves them alone between calls.
;
; Calling convention: a0/a1/d2/d3/d4 in and out, d5.w the budget in; d0 = the
; return code; d1 and a2 are scratch. Everything else - d6/d7, a3-a6 - is
; untouched, including the stack beyond the return address.
; -----------------------------------------------------------------------------


; The decompressor's whole state lives in the caller's registers - there is no
; context block at all. Across a resume loop the caller leaves these alone;
; jx1_init sets the three that are not pointers.
;
;   a0  input position
;   a1  write pointer
;   d2  bit queue ($80 is the sentinel; only the low byte is used)
;   d3  lastOffset (high word) | remaining (low word)
;   d4  op state: $80 START, 0 LITERALS, 2 MATCH, $FF DONE - signed, so the
;       entry dispatches on the flags a tst.b already sets (low byte only)

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = destination. Seeds d2/d3/d4, the three
;           state registers that are not pointers; writes nothing to memory.
; Java: the Decompressor constructor / reset().
; -----------------------------------------------------------------------------
jx1_init:
        moveq   #1,d3
        swap    d3                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        moveq   #-128,d2                ; an empty bit queue: $80 is the sentinel
        move.b  d2,d4                   ; State.START, which is the same $80
        rts

; -----------------------------------------------------------------------------
; jx1_decompress: a0 = compressed data, a1 = destination.
; One-shot convenience; returns with a1 = end of output.
; Java: the static Decompressor.decompress() helpers.
; -----------------------------------------------------------------------------
jx1_decompress:
        bsr.s   jx1_init
.drain:
        moveq   #-1,d5                  ; budget = 65535 per call: a one-shot has
                                        ; no reason to hand control back, so a
                                        ; 32K output is one call, not 252
        bsr.s   jx1_resume              ; Java: while (resume()) {}
        tst.w   d0
        bne.s   .drain
        rts

; -----------------------------------------------------------------------------
; jx1_resume: a0/a1/d2/d3/d4 = the state, d5.w = this call's budget. Emits at
; most d5 output bytes. Returns d0 = 0 when the stream is fully processed, 1
; when there is more; the state registers come back updated, which is exactly
; what the next call takes in. Java: Decompressor.resume().
; -----------------------------------------------------------------------------
entry_special:                          ; the negative states, both rare
        add.b   d4,d4                   ; START ($80) doubles to zero; DONE
        beq.s   begin_literals          ; ($FF) does not, so it falls through
entry_done:
        moveq   #0,d0                   ; keep returning "fully processed"
        rts

jx1_resume:
        tst.b   d4                      ; op state (Java: switch in next()) -
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
        add.b   d2,d2                   ; first continuation bit
        beq.s   gamma_refill            ; the queue empties on one bit in eight,
        bcc.s   gamma_done              ; so the refill is out of line and this
gamma_loop:                             ; branch is the one normally not taken
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + bit
        add.b   d2,d2                   ; continuation bit
        beq.s   gamma_refill
        bcs.s   gamma_loop              ; 1: another pair; the continue branch
gamma_done:                             ; doubles as the loop jump
        rts
gamma_refill:                           ; both sites want the same thing of a
        move.b  (a0)+,d2                ; refilled queue - carry set means
        addx.b  d2,d2                   ; another pair follows - so they share
        bcs.s   gamma_loop              ; one block, and duplicating this tail
        rts                             ; costs nothing over branching back

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
        moveq   #2,d4                   ; State.MATCH: both successors of a
                                        ; literal run are matches, and the
                                        ; assignment has to precede the bare
                                        ; read below - a moveq between the add
                                        ; and the bcs would destroy the carry.
                                        ; (A match reaching new_offset already
                                        ; holds 2, so that path needs none.)
        add.b   d2,d2                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        bsr.w   get_gamma               ; Java: beginMatchFromLastOffset() (.w: same)
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        bra.w   resume_op               ; (.w: same, zero cycle cost)

suspend:                                ; Java: resume() returning true
        moveq   #1,d0                   ; more output pending: call again. The
        rts                             ; state is already where it lives - in
                                        ; the caller's registers

end_marker:                             ; Java: State.DONE (no final flip needed:
        st      d4                      ; State.DONE; the end of the output is
        moveq   #0,d0                   ; in a1, as after any other call
        rts
