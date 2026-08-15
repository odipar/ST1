; -----------------------------------------------------------------------------
; jx1_68000_ring_mod.S - JX1: resumable ZX1 decompressor with an aligned,
;                        power-of-two RING BUFFER (68000)
;
; By Robbert van Dalen, based on ZX1 v1.5 by Einar Saukas (data compression
; format, algorithm, and the original C/z80 decompressors). Code written by
; Claude (Anthropic's Claude Code) under Robbert's direction. The
; decompressor can be used freely within your own programs, even
; commercially, as long as your documentation indicates that you used
; ZX1/jx1 (see LICENSE).
;
; This is jx1_68000_ring.S for callers who can promise that one fixed budget X
; divides one assembly-time power-of-two RING_SIZE - a 1024-byte buffer drained
; 16 bytes at a time, say - and can align the buffer to RING_SIZE. X must not
; change between calls. RING_SIZE defaults to 1024; override it with rmac's
; -dRING_SIZE=<N> switch.
;
; Read the general file for what a ring buffer buys you. This version is
; smaller and faster, and spends its stronger promises in three ways:
;
;   - every call but the last emits exactly the budget, never a short block,
;     so a caller wanting fixed-size pieces gets them for free
;   - YOU wrap the write pointer when the buffer fills; this version does not
;   - no ring bounds are passed in registers: the aligned pointer's low bits
;     are its position, and the compiled RING_SIZE supplies the wrap distance
;
; 232 bytes, position-independent, one body: no macros, no tables, no
; self-modifying code. It runs from ROM, and since it keeps nothing in memory,
; a second concurrent stream is just a second set of registers.
;
; -----------------------------------------------------------------------------
; DRAINING. The write pointer never wraps during a call. On a continuing call,
; a zero position means the pointer reached the end, so hand it back wrapped:
;
;       lea     stream,a0
;       lea     ring,a1                 ; RING_SIZE bytes, RING_SIZE-aligned
;       bsr     jx1_init
;   .loop:
;       moveq   #16,d3                  ; fixed X; X must divide RING_SIZE
;       bsr     jx1_resume
;       moveq   #16,d5
;       sub.w   d3,d5                   ; bytes emitted = requested - unspent
;       movea.l a1,a4
;       suba.l  d5,a4                   ; first output byte for this call
;       ; consume [a4 .. a1)
;       tst.w   d1
;       beq.s   .done                   ; final output is drained; no next call
;       move.w  a1,d5
;       and.w   #RING_SIZE-1,d5         ; aligned ring position
;       bne.s   .loop
;       suba.l  #RING_SIZE,a1           ; end -> start; not on the hot path
;       bra.s   .loop
;   .done:
;
; -----------------------------------------------------------------------------
; WHAT THE PROMISES BUY. Because one fixed budget X divides RING_SIZE, the
; distance from the start of the buffer to the write pointer is a multiple of X
; at every entry: it starts at zero, a call leaving d1.w nonzero wrote exactly
; X bytes, and a full buffer starts again at zero. The room left is therefore a
; whole number of budgets and never fewer than one. The destination cannot
; reach the end inside a call, so entry needs no room arithmetic or clamp.
;
; Power-of-two alignment makes the low bits of a1 the destination position.
; Subtracting the offset from that position says whether the source wrapped.
; An unwrapped source is behind the destination and has even more room, so it
; can jump directly to the copy. A wrapped source uses the negative result as
; its room and splits only when necessary. The source is recomputed for every
; segment rather than carried, so resuming a match still costs no extra state.
;
; -----------------------------------------------------------------------------
; THE STATE IS YOUR REGISTERS. There is no context block to allocate, align or
; keep alive; jx1_init seeds three registers and a resume loop leaves all five
; alone between calls:
;
;   a0.l  input position
;   a1.l  write pointer - where the output ends, after every call
;   d0.b  bit queue ($80 is the empty sentinel)
;   d1.w  bytes remaining in the current operation
;   d2.w  signed last offset: negative during LITERALS, positive during MATCH;
;         with d1 = 0, +1 means START and 0 means DONE
;
; The widths are what jx1_resume touches: it never looks above d0's low byte
; or d1/d2's low words, so after init the rest is your business.
;
; Calling convention, in full:
;
;   in and out   a0.l a1.l d0.b      the state; leave it alone between calls
;                d1.w d2.w
;   in           d3.w                this call's budget, spent by the call
;   CLOBBERED    d3.w d4.l d5.l      no value in these survives a call
;                a2.l
;   untouched    d6 d7 a3 a4 a5 a6   and the stack beyond the return address
;
; a2 is the copy source: it follows a0 for literals and is recomputed from a1
; for every match segment. d4 carries the segment length and copy-ladder
; index, and d5 the gamma value and ring-position arithmetic, so treat all
; three scratch registers as gone across a call. d1 itself is the result:
; zero means done, nonzero means more.
; Only d3's low word is spent, but it is spent, not refilled: pass the budget
; again on the next call.
;
; A finished stream keeps leaving d1.w = 0 however often you poll it.
;
; -----------------------------------------------------------------------------
; ASSUMPTIONS. Undefined behaviour when violated, because nothing checks them:
;
;   1. no single literal run or match is longer than 65535 bytes - an
;      operation's length lives in a word. Compress with jx1 -l65535, which
;      splits any longer match; a stream compressed without it can exceed the
;      limit, and would decode short here with no error
;   2. the budget in d3.w is 1..65535 and is the same fixed X on every call
;   3. RING_SIZE is an assembly-time power of two in 1..32768, and the buffer
;      starts at an address aligned to RING_SIZE. The assembler rejects other
;      sizes. The format's offsets stop at 32512, so 32768 covers all of them
;   4. no back-reference offset exceeds RING_SIZE, which is what compressing
;      with jx1 -m<RING_SIZE> guarantees
;   5. X DIVIDES RING_SIZE. Everything above rests on the fixed-X, alignment,
;      power-of-two and divisibility promises. Violating any of them can read
;      or write beyond the ring
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

; Assembly-time configuration. rmac command-line definitions take precedence,
; for example: rmac -dRING_SIZE=256 ... jx1_68000_ring_mod.S
        .if     !(^^defined RING_SIZE)
RING_SIZE      equ     1024
        .endif
        .if     RING_SIZE < 1
        .error  "RING_SIZE must be a power of two in 1..32768"
        .endif
        .if     RING_SIZE > 32768
        .error  "RING_SIZE must be a power of two in 1..32768"
        .endif
        .if     RING_SIZE & (RING_SIZE-1)
        .error  "RING_SIZE must be a power of two in 1..32768"
        .endif
RING_MASK      equ     RING_SIZE-1

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4).
; There is no one-shot entry: a bounded buffer has to be drained by the
; caller, so every stream is decompressed through the resume loop.
                bra.w   jx1_init
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = ring buffer.
; Java: the Decompressor constructor / reset(). Seeds d0/d1/d2, the three
; state registers that are not pointers; writes nothing to memory.
; -----------------------------------------------------------------------------
jx1_init:
        moveq   #1,d2                   ; lastOffset = INITIAL_OFFSET
        moveq   #0,d1                   ; remaining = 0
        moveq   #-128,d0                ; an empty bit queue: $80 is the sentinel
        rts

entry_special:                          ; d1 = 0: only START or DONE survives a call
        tst.w   d2                      ; START has the initial +1 offset; DONE is 0
        bne.w   begin_literals
entry_done:
        rts                             ; d1 = 0: keep returning "fully processed"

; -----------------------------------------------------------------------------
; jx1_resume: a0/a1/d0/d1/d2 = the state, d3.w = this call's budget.
; No bounds are passed: RING_SIZE is compiled in and a1's ring is aligned to
; it. Emits at most d3 bytes. Returns d1.w = 0 when the stream is fully
; processed, nonzero when there is more. Everything between a1's previous and
; new values is fresh output. On a continuing call, position zero means a1
; reached the end; wrap it back by subtracting RING_SIZE before the next call.
; a2 is scratch; a3-a6 are untouched.
; Java: Decompressor.resume().
; -----------------------------------------------------------------------------
jx1_resume:
        tst.w   d1                      ; zero only survives a call for START
        beq.s   entry_special           ; or DONE; an active op has bytes left;
                                        ; a mid-op resume falls straight into
                                        ; the segment body, because a suspend
                                        ; only ever happens with remaining >= 1
                                        ; and the budget is fresh again
segment:                                ; d1 remaining >= 1, d3 budget >= 1
        move.w  d1,d4                   ; n = min(remaining, budget)
        cmp.w   d3,d4
        bls.s   budget_fits
        move.w  d3,d4
budget_fits:
        tst.w   d2                      ; negative lastOffset means LITERALS
        bmi.s   literal_source


; -----------------------------------------------------------------------------
; resume_op: the segment loop, shared by literals and matches (sign of d2).
; Only a match source running into the end of the buffer can split a copy;
; the destination never can, so literals always copy in one pass.
; -----------------------------------------------------------------------------
        movea.l a1,a2                   ; raw source = dst - lastOffset
        suba.w  d2,a2
        move.w  a1,d5
        and.w   #RING_MASK,d5           ; destination position in aligned ring
        sub.w   d2,d5                   ; minus offset; carry means it wrapped
        bcc.s   copy                    ; unwrapped source cannot hit the end
                                        ; before the destination does
        neg.w   d5                      ; wrapped: room = offset - position
        .if     RING_SIZE = 32768
        suba.w  #$8000,a2               ; subtracting -32768 adds 32768 safely
        .else
        adda.w  #RING_SIZE,a2           ; raw source + N, back into the ring
        .endif
        cmp.w   d4,d5                   ; word, as above: the room is at most N
        bcc.s   copy
        move.w  d5,d4                   ; this segment stops at the wrap
        bra.s   copy
literal_source:
        movea.l a0,a2                   ; literals copy straight from the input
copy:                                   ; Java: writeByte(...) - n moves total:
        sub.w   d4,d1                   ; a partial first pass of n&7 entered
        sub.w   d4,d3                   ; mid-ladder, then n>>3 full passes off
        move.w  d4,d5                   ; the dbf at ladder_end
        lsr.w   #3,d5
        and.w   #7,d4
        add.w   d4,d4
        neg.w   d4                      ; index = -2*(n&7)
        jmp     ladder_end(pc,d4.w)     ; pc-relative dispatch, no base register
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
        dbf     d5,ladder               ; full 8-move passes for big copies
        tst.w   d2
        bpl.s   resume_op               ; matches consume no input here;
        movea.l a2,a0                   ; literals do

resume_op:                              ; the loop guards live here, below the
        tst.w   d1                      ; copy, so a call entering mid-op skips
        beq.s   transition              ; them: op complete, parse the next one
        tst.w   d3
        bne.s   segment                 ; budget left: the source wrapped, so
                                        ; take another segment of the same op.
                                        ; Spent is the common case, so it is the
                                        ; one that costs nothing to reach
suspend_more:                           ; Java: resume() returning true
        rts                             ; d1 <> 0: more output pending. The state
                                        ; is already where it lives - in
                                        ; the caller's registers

; get_gamma: interlaced Elias gamma value in d5.w (assumption: fits a word).
; Holds the decompressor's only bit-queue refills: gammas are odd-length,
; transitions are single bits, and the stream opens with a gamma, so
; continuation bits sit at even bit indices and the queue (refilled every
; 8th bit) can only empty on one - data and transition bits are read bare,
; with no refill check. The first continuation bit is peeled (a length-1
; value falls straight through) and the loop is rotated so the continue
; branch is the back-jump: no unconditional bra per pair.
; Java: readInterlacedEliasGamma().
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
        rts
gamma_refill:                           ; both sites want the same thing of a
        move.b  (a0)+,d0                ; refilled queue - carry set means
        addx.b  d0,d0                   ; another pair follows - so they share
        bcs.s   gamma_loop              ; one block, and duplicating this tail
        rts                             ; costs nothing over branching back

begin_literals:                         ; Java: beginLiterals()
        neg.w   d2                      ; negative lastOffset = State.LITERALS
        bsr.s   get_gamma
        move.w  d5,d1                   ; remaining = gamma; lastOffset untouched
        bra.s   resume_op

transition:                             ; remaining == 0: parse the next block
        tst.w   d2                      ; header. State test BEFORE the bit
        bmi.s   literals_transition     ; read: it must not clobber the carry
        add.b   d0,d0                   ; Java: next(), case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        move.b  (a0)+,d1                ; d1.w is already zero: every edge here
                                        ; has just completed an op. Its upper
                                        ; word is outside the state and ignored
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
        move.w  d1,d2                   ; the new lastOffset. Same four cycles a
                                        ; swap cost, and now the match source
                                        ; needs no swaps at all
        bsr.s   get_gamma               ; (.w: out of short range; BSR is 18
                                        ; cycles at either width)
        addq.w  #1,d5                   ; remaining = gamma + 1
        move.w  d5,d1
        bra.s   resume_op               ; (.w: out of short range; BRA taken
                                        ; costs 10 cycles at either width)

literals_transition:
        neg.w   d2                      ; positive lastOffset = State.MATCH;
                                        ; both successors of a literal run are
                                        ; matches, so flip it before the bare
                                        ; bit read below
        add.b   d0,d0                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        bsr.s   get_gamma               ; Java: beginMatchFromLastOffset() (.w: same)
        move.w  d5,d1                   ; remaining = gamma; lastOffset untouched
        bra.s   resume_op               ; (.w: same, zero cycle cost)

end_marker:                             ; Java: State.DONE; the decoded marker
        clr.w   d1                      ; remains in d1, so normalize DONE as
        clr.w   d2                      ; d1/d2 = 0 for repeat polling. Output ends
        rts                             ; in a1, as after any other call
