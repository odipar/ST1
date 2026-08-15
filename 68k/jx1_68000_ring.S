; -----------------------------------------------------------------------------
; jx1_68000_ring.S - JX1: resumable ZX1 decompressor with a RING BUFFER (68000)
;
; By Robbert van Dalen, based on ZX1 v1.5 by Einar Saukas (data compression
; format, algorithm, and the original C/z80 decompressors). Code written by
; Claude (Anthropic's Claude Code) under Robbert's direction. The
; decompressor can be used freely within your own programs, even
; commercially, as long as your documentation indicates that you used
; ZX1/jx1 (see LICENSE).
;
; Decompresses a jx1/ZX1 stream through a ring buffer you supply, so the
; memory it needs is bounded by the buffer and not by the size of the output:
; 32 KB of output can pass through 256 bytes of RAM. A buffer of N bytes can
; only serve back-references up to N, so compress the stream with -mN.
;
; 246 bytes, position-independent, one body: no macros, no tables, no
; self-modifying code. It runs from ROM, and since it keeps nothing in memory,
; a second concurrent stream is just a second set of registers.
;
; -----------------------------------------------------------------------------
; DRAINING. Each call emits at most the budget you give it, and at most as
; much as fits before the end of the buffer, so the write pointer never wraps
; during a call: a full buffer simply shows up as a1 reaching the end bound.
; You consume what the call produced and carry on - there is no callback to
; write, and no third return code to handle:
;
;       lea     stream,a0
;       lea     ring,a1                 ; N bytes, any alignment
;       bsr     jx1_init
;       lea     ring,a2                 ; the bounds are yours to hold: you
;       lea     ring+N,a3               ; need them to drain anyway
;   .loop:
;       move.l  a1,-(sp)                ; first output byte for this call
;       moveq   #16,d4                  ; at most 16 bytes from this call
;       bsr     jx1_resume
;       movea.l (sp)+,a4                ; a4 is already caller-clobbered
;       ; consume [a4 .. a1)
;       cmpa.l  a3,a1                   ; buffer full?
;       bne.s   .more
;       movea.l a2,a1                   ; this cursor-saving loop must wrap
;   .more:                              ; before it saves a1 again
;       tst.w   d1
;       bne.s   .loop
;
; jx1_68000_ring_mod.S is a smaller, faster version of this file for callers
; that can promise one fixed budget X divides N.
;
; -----------------------------------------------------------------------------
; HOW THE RING COSTS SO LITTLE. Two choices do the work.
;
; THE BUDGET CARRIES THE RING. The entry clamps this call's budget to the room
; left in the buffer, so the destination cannot reach the end inside a call -
; only exactly as the budget runs out. No copy needs a destination bounds
; test, and the buffer is wrapped once, at the next entry, where the room is
; being computed anyway.
;
; A MATCH SOURCE THAT WOULD RUN OFF THE END SPLITS THE COPY instead of testing
; each byte, so the rolled-out copy ladder needs no bounds test either. The
; source is recomputed from the destination for each segment (source =
; dst - offset, plus N when that falls below the buffer) rather than carried,
; which also makes resuming a match cost nothing extra.
;
; What is left of the ring is one clamp per call and one clamp per match
; segment: work per CALL and per MATCH, never per byte.
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
;   d3.w  signed last offset: negative during LITERALS, positive during MATCH;
;         with d1 = 0, +1 means START and 0 means DONE
;
; The widths are what jx1_resume touches: it never looks above d0's low byte
; or d1/d3's low words, so after init the rest is your business.
;
; Calling convention, in full:
;
;   in and out   a0.l a1.l d0.b      the state; leave it alone between calls
;                d1.w d3.w
;   in           a2.l a3.l           ring bounds: first byte, and one past the
;                                    last. Read-only, and come back unchanged
;   in           d4.w                this call's budget, spent by the call
;   CLOBBERED    d4.w d5.l d6.l      no value in these survives a call
;                a4.l
;   untouched    d2 d7 a5 a6         and the stack beyond the return address
;
; d5 and d6 are working registers throughout - d5 carries the segment length
; and the copy-ladder index, d6 the gamma value and the room arithmetic - so
; treat both as gone across a call. d1 itself is the result: zero means done,
; nonzero means more.
; Only d4's low word is spent, but it is spent, not refilled: pass the budget
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
;   2. the budget in d4.w is 1..65535
;   3. the ring buffer size N is 1..65535. The format's offsets stop at 32512,
;      so a larger ring could never be referenced anyway
;   4. no back-reference offset exceeds N, which is what compressing with
;      -mN guarantees
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

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4).
; There is no one-shot entry: a bounded buffer has to be drained by the
; caller, so every stream is decompressed through the resume loop.
                bra.w   jx1_init
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = ring buffer.
; Java: the Decompressor constructor / reset(). Seeds d0/d1/d3, the three
; state registers that are not pointers; writes nothing to memory.
; -----------------------------------------------------------------------------
jx1_init:
        moveq   #1,d3                   ; lastOffset = INITIAL_OFFSET
        moveq   #0,d1                   ; remaining = 0
        moveq   #-128,d0                ; an empty bit queue: $80 is the sentinel
        rts

entry_special:                          ; d1 = 0: only START or DONE survives a call
        tst.w   d3                      ; START has the initial +1 offset; DONE is 0
        bne.w   begin_literals
entry_done:
        rts                             ; d1 = 0: keep returning "fully processed"

; -----------------------------------------------------------------------------
; jx1_resume: a0/a1/d0/d1/d3 = the state, d4.w = this call's budget,
;             a2/a3 = the ring buffer's first byte and one past its last.
;             a2/a3 are read-only and come back unchanged.
; Emits at most d4 bytes, and at most as many as fit before the end of the
; buffer. Returns d1.w = 0 when the stream is fully processed, nonzero when
; there is more. a1 is the caller's cue: everything between its previous value and its
; new one is fresh output, and a1 reaching a3 means the buffer is full.
; Hand a1 straight back either way: this entry wraps a full buffer to a2
; itself, at the start of the next call.
; Java: Decompressor.resume().
; -----------------------------------------------------------------------------
jx1_resume:
        move.l  a3,d6
        sub.l   a1,d6                   ; room before the end of the buffer
        bne.s   have_room
        movea.l a2,a1                   ; the buffer was filled by the previous
        move.l  a3,d6                   ; call and the caller has drained it:
        sub.l   a2,d6                   ; wrap, and the room is the whole ring
have_room:
        cmp.w   d4,d6                   ; budget = min(budget, room), so the
        bcc.s   budget_set              ; destination cannot reach the end of
        move.w  d6,d4                   ; the buffer inside this call - only
budget_set:                             ; exactly as the budget runs out. Word:
                                        ; the room is at most N <= 65535, so
                                        ; this cannot read the caller's junk in
                                        ; the upper words of d6 or d4
        tst.w   d1                      ; zero only survives a call for START
        beq.s   entry_special           ; or DONE; an active op has bytes left;
                                        ; a mid-op resume falls straight into
                                        ; the segment body, because a suspend
                                        ; only ever happens with remaining >= 1
                                        ; and the budget was just refilled
segment:                                ; d1 remaining >= 1, d4 budget >= 1
        move.w  d1,d5                   ; n = min(remaining, budget)
        cmp.w   d4,d5
        bls.s   budget_fits
        move.w  d4,d5
budget_fits:
        tst.w   d3                      ; negative lastOffset means LITERALS
        bmi.s   literal_source


; -----------------------------------------------------------------------------
; resume_op: the segment loop, shared by literals and matches (sign of d3).
; Only a match source running into the end of the buffer can split a copy;
; the destination never can, so literals always copy in one pass.
; -----------------------------------------------------------------------------
        movea.l a1,a4                   ; match: source = dst - lastOffset,
        suba.w  d3,a4                   ; brought back into the buffer if it
                                        ; falls below the start (Java:
                                        ; readBufferByte()'s index wrap)
        cmpa.l  a2,a4
        bcc.s   source_ready
        suba.l  a2,a4
        adda.l  a3,a4
source_ready:
        move.l  a3,d6
        sub.l   a4,d6                   ; room before the source wraps (>= 1)
        cmp.w   d5,d6                   ; word, as above: the room is at most N
        bcc.s   copy
        move.w  d6,d5                   ; this segment stops at the wrap
        bra.s   copy
literal_source:
        movea.l a0,a4                   ; literals copy straight from the input
copy:                                   ; Java: writeByte(...) - n moves total:
        sub.w   d5,d1                   ; a partial first pass of n&7 entered
        sub.w   d5,d4                   ; mid-ladder, then n>>3 full passes off
        move.w  d5,d6                   ; the dbf at ladder_end
        lsr.w   #3,d6
        and.w   #7,d5
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
        tst.w   d3
        bpl.s   resume_op               ; matches consume no input here;
        movea.l a4,a0                   ; literals do

resume_op:                              ; the loop guards live here, below the
        tst.w   d1                      ; copy, so a call entering mid-op skips
        beq.s   transition              ; them: op complete, parse the next one
        tst.w   d4
        bne.s   segment                 ; budget left: the source wrapped, so
                                        ; take another segment of the same op.
                                        ; Spent is the common case, so it is the
                                        ; one that costs nothing to reach

suspend_more:                           ; Java: resume() returning true
        rts                             ; d1 <> 0: more output pending. The state
                                        ; is already where it lives - in
                                        ; the caller's registers


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
        neg.w   d3                      ; negative lastOffset = State.LITERALS
        bsr.s   get_gamma
        move.w  d6,d1                   ; remaining = gamma; lastOffset untouched
        bra.s   resume_op

transition:                             ; remaining == 0: parse the next block
        tst.w   d3                      ; header. State test BEFORE the bit
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
        bsr.s   get_gamma               ; (.w: out of short range; BSR is 18
                                        ; cycles at either width)
        addq.w  #1,d6                   ; remaining = gamma + 1
        move.w  d6,d1
        bra.s   resume_op               ; (.w: out of short range; BRA taken
                                        ; costs 10 cycles at either width)

literals_transition:
        neg.w   d3                      ; positive lastOffset = State.MATCH;
                                        ; both successors of a literal run are
                                        ; matches, so flip it before the bare
                                        ; bit read below
        add.b   d0,d0                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        bsr.s   get_gamma               ; Java: beginMatchFromLastOffset() (.w: same)
        move.w  d6,d1                   ; remaining = gamma; lastOffset untouched
        bra.s   resume_op               ; (.w: same, zero cycle cost)

end_marker:                             ; Java: State.DONE; the decoded marker
        clr.w   d1                      ; remains in d1, so normalize DONE as
        clr.w   d3                      ; d1/d3 = 0 for repeat polling. Output ends
        rts                             ; in a1, as after any other call
