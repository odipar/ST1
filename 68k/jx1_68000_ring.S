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
; 266 bytes, position-independent, one body: no macros, no tables, no
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
;       lea     ring+N,a3               ; caller keeps the end for draining
;       move.l  a3,d3                   ; init takes it transiently
;       bsr     jx1_init
;   .loop:
;       move.l  a1,-(sp)                ; first output byte for this call
;       moveq   #16,d3                  ; at most 16 bytes from this call
;       bsr     jx1_resume
;       movea.l (sp)+,a2                ; a2 is already caller-clobbered
;       ; consume [a2 .. a1)
;       cmpa.l  a3,a1                   ; buffer full?
;       bne.s   .more
;       lea     ring,a1                 ; this cursor-saving loop must wrap
;   .more:                              ; before it saves a1 again
;       tst.w   d1
;       bne.s   .loop
;
; jx1_68000_ring_mod.S is a smaller, faster version of this file when N is a
; compile-time power of two, the buffer base is aligned to N, and one fixed
; budget X divides N.
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
; source is recomputed from the destination position and the offset for each
; segment rather than carried. N in d1.high and end.low in d2.high are enough
; to identify a wrap without a bound register; a wrapped raw source comes back
; into the ring by adding N. The low-word identity position = N + destination
; - end works across 64 KB boundaries, and the following unsigned offset
; subtraction supplies the wrap decision for every N up to 65535.
;
; What is left of the ring is one clamp per call and at most one clamp per
; match segment: work per CALL and per MATCH, never per byte.
;
; -----------------------------------------------------------------------------
; THE STATE IS YOUR REGISTERS. There is no context block to allocate, align or
; keep alive; jx1_init seeds three registers and a resume loop leaves all five
; alone between calls:
;
;   a0.l  input position
;   a1.l  write pointer - where the output ends, after every call
;   d0.b  bit queue ($80 is the empty sentinel)
;   d1.l  ring size N in the high word, bytes remaining in the low word
;   d2.l  end.low in the high word, signed last offset in the low word;
;         the offset is negative during LITERALS, positive during MATCH;
;         with d1.w = 0, +1 means START and 0 means DONE
;
; The common state layout is a0/a1/d0.b/d1.w/d2.w, exactly as in the other
; decoders. This general ring also uses d1.high and d2.high as persistent ring
; metadata; only the upper 24 bits of d0 remain the caller's after init.
;
; Calling convention, in full:
;
;   in and out   a0.l a1.l d0.b      the state; leave it alone between calls
;                d1.l d2.l
;   init in      d3.l                one-past-end; packed by jx1_init
;   resume in    d3.w                this call's budget, spent by the call
;   CLOBBERED    d3.w d4.l d5.l      no value in these survives a call
;                a2.l
;   untouched    d6 d7 a3 a4 a5 a6   and the stack beyond the return address
;
; d4 and d5 are working registers throughout - d4 carries the gamma seed,
; segment length and full-pass counter, while d5 carries the gamma value,
; copy-ladder index and room arithmetic - so treat both as gone across a call.
; d1.w itself is the result: zero means done, nonzero means more; d1 as a whole
; is never zero because its high word is N.
; Only d3's low word is spent, but it is spent, not refilled: pass the budget
; again on the next call.
;
; A finished stream keeps leaving d1.w = 0 however often you poll it; d2.w is
; also zero, while both high words retain the packed ring metadata.
;
; -----------------------------------------------------------------------------
; ASSUMPTIONS. Undefined behaviour when violated, because nothing checks them:
;
;   1. no single literal run or match is longer than 65535 bytes - an
;      operation's length lives in a word. Compress with jx1 -l65535, which
;      splits any longer match; a stream compressed without it can exceed the
;      limit, and would decode short here with no error
;   2. the budget in d3.w is 1..65535
;   3. the ring buffer size N is 1..65535. The format's offsets stop at 32512,
;      so a larger ring could never be referenced anyway
;   4. no back-reference offset exceeds N, which is what compressing with
;      -mN guarantees
;   5. at jx1_init, a1 is the first ring byte and d3 is one past the last;
;      their difference is N. After init, keep all five state registers in
;      full - including the packed high words - intact between resume calls
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
; jx1_init: a0 = compressed data, a1 = first ring byte, d3 = one-past-end.
; Java: the Decompressor constructor / reset(). Seeds d0/d1/d2, deriving N
; from d3-a1. N and end.low are packed above the word-sized common state;
; writes nothing to memory.
; -----------------------------------------------------------------------------
jx1_init:
        move.l  d3,d1                   ; N = end - start, packed in d1.high
        sub.l   a1,d1
        swap    d1                      ; and remaining = 0 in d1.low
        moveq   #0,d2
        move.w  d3,d2                   ; end.low lives above lastOffset
        swap    d2
        addq.w  #1,d2                   ; lastOffset = INITIAL_OFFSET
        moveq   #-128,d0                ; an empty bit queue: $80 is the sentinel
        rts

entry_special:                          ; d1.w = 0: only START or DONE survives a call
        tst.w   d2                      ; START has the initial +1 offset; DONE is 0
        bne.w   begin_literals
entry_done:
        rts                             ; d1.w = 0: keep returning "fully processed"

; -----------------------------------------------------------------------------
; jx1_resume: a0/a1/d0/d1/d2 = the state and d3.w = this call's budget.
; Emits at most d3 bytes, and at most as many as fit before the end of the
; buffer. Returns d1.w = 0 when the stream is fully processed, nonzero when
; there is more. a1 is the caller's cue: everything between its previous value
; and its new one is fresh output, and a1 reaching the known end means full.
; Hand a1 straight back either way: this entry subtracts N to wrap a full
; buffer itself, at the start of the next call.
; Java: Decompressor.resume().
; -----------------------------------------------------------------------------
jx1_resume:
        move.l  d2,d5
        swap    d5                      ; room = end.low - destination.low
        sub.w   a1,d5                   ; exact because the room is <= 65535
        bne.s   have_room
        move.l  d1,d5                   ; the buffer was filled by the previous
        clr.w   d5                      ; call and the caller has drained it:
        swap    d5                      ; zero-extend N from d1.high, subtract
        suba.l  d5,a1                   ; it to wrap, and leave room = N
have_room:
        cmp.w   d3,d5                   ; budget = min(budget, room), so the
        bcc.s   budget_set              ; destination cannot reach the end of
        move.w  d5,d3                   ; the buffer inside this call - only
budget_set:                             ; exactly as the budget runs out. Word:
                                        ; the room is at most N <= 65535, so
                                        ; this cannot read the caller's junk in
                                        ; the upper words of d5 or d3
        tst.w   d1                      ; zero only survives a call for START
        beq.s   entry_special           ; or DONE; an active op has bytes left;
                                        ; a mid-op resume falls straight into
                                        ; the segment body, because a suspend
                                        ; only ever happens with remaining >= 1
                                        ; and the budget was just refilled
segment:                                ; d1.w remaining >= 1, d3 budget >= 1
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
        move.l  d1,d5
        swap    d5                      ; d5.w = N
        add.w   a1,d5
        swap    d2                      ; d2.w = end.low, temporarily
        sub.w   d2,d5                   ; d5.w = destination position
        swap    d2                      ; restore lastOffset before using it
        sub.w   d2,d5                   ; minus offset; carry means it wrapped
        bcc.s   copy                    ; unwrapped source is behind dst, so it
                                        ; cannot reach the end before dst does
        neg.w   d5                      ; wrapped: room = offset - position
        cmp.w   d4,d5                   ; word, as above: the room is at most N
        bcc.s   source_wrapped
        move.w  d5,d4                   ; this segment stops at the wrap
source_wrapped:
        move.l  d1,d5                   ; raw source + zero-extended N brings it
        clr.w   d5                      ; back into the ring at any 32-bit address
        swap    d5
        adda.l  d5,a2
        bra.s   copy
literal_source:
        movea.l a0,a2                   ; literals copy straight from the input
copy:                                   ; Java: writeByte(...) - n moves total:
        sub.w   d4,d1                   ; consume n from the operation
        sub.w   d4,d3                   ; and from this call's budget
        moveq   #7,d5                   ; d5 = n&7 for the partial first pass;
        and.w   d4,d5                   ; register AND is cheaper than ANDI
        lsr.w   #3,d4                   ; d4 = n>>3 full passes for the dbf
        add.w   d5,d5
        neg.w   d5                      ; index = -2*(n&7)
        jmp     ladder_end(pc,d5.w)     ; pc-relative dispatch, no base register
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
        dbf     d4,ladder               ; full 8-move passes for big copies
        tst.w   d2
        bpl.s   resume_op               ; matches consume no input here;
        movea.l a2,a0                   ; literals do

resume_op:                              ; the loop guards live here, below the
        tst.w   d1                      ; copy, so a call entering mid-op skips
        beq.s   transition              ; them: op complete, parse the next one
resume_fresh:                           ; gamma completion proves d1.w >= 1
        tst.w   d3
        bne.s   segment                 ; budget left: the source wrapped, so
                                        ; take another segment of the same op.
                                        ; Spent is the common case, so it is the
                                        ; one that costs nothing to reach

suspend_more:                           ; Java: resume() returning true
        rts                             ; d1.w <> 0: more output pending. The state
                                        ; is already where it lives - in
                                        ; the caller's registers


begin_literals:                         ; Java: beginLiterals()
        neg.w   d2                      ; negative lastOffset = State.LITERALS
        moveq   #0,d4                   ; remaining = gamma + 0; fall through

; get_gamma: interlaced Elias gamma value in d5.w (assumption: fits a word),
; entered with d4.w = 0 normally or 1 for a new-offset match. Its shared tail
; installs remaining and skips resume_op's now-proven d1.w test.
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
        add.w   d4,d5                   ; +1 only for a new-offset match
        move.w  d5,d1                   ; remaining = gamma + caller seed
        bra.s   resume_fresh
gamma_refill:                           ; queue-empty continuations share one
        move.b  (a0)+,d0                ; refill; carry set means another pair
        addx.b  d0,d0                   ; follows, otherwise finish the gamma
        bcs.s   gamma_loop
        bra.s   gamma_done

transition:                             ; remaining == 0: parse the next block
        tst.w   d2                      ; header. State test BEFORE the bit
        bmi.s   literals_transition     ; read: it must not clobber the carry
        add.b   d0,d0                   ; Java: next(), case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        move.b  (a0)+,d1                ; d1.w is already zero: every edge here
                                        ; has just completed an op. Byte/word
                                        ; operations preserve N in d1.high
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
        move.w  d1,d2                   ; the new lastOffset stays directly in
                                        ; d2.w; the match-path swaps reach only
                                        ; the packed end.low above it
        moveq   #1,d4                   ; new-offset match: remaining = gamma+1
        bra.s   get_gamma

literals_transition:
        neg.w   d2                      ; positive lastOffset = State.MATCH;
                                        ; both successors of a literal run are
                                        ; matches, so flip it before the bare
                                        ; bit read below
        add.b   d0,d0                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #0,d4                   ; from-last match: remaining = gamma
        bra.s   get_gamma               ; Java: beginMatchFromLastOffset()

end_marker:                             ; Java: State.DONE; the decoded marker
        clr.w   d1                      ; remains in d1, so normalize DONE as
        clr.w   d2                      ; low d1/d2 = 0 for repeat polling. Output
                                        ; ends in a1; both high words remain
        rts
