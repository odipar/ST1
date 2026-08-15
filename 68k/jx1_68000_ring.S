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
; Resumable decode through a caller-supplied N-byte ring. Memory is bounded by
; N and every back-reference must fit it; for N below 32512, compress with -mN.
;
; 252 bytes, position-independent, one body: no macros, no tables, no
; self-modifying code. It runs from ROM, and since it keeps nothing in memory,
; a second concurrent stream is just a second set of registers.
;
; -----------------------------------------------------------------------------
; DRAINING. A call emits at most its budget and the room before the ring end;
; a1 therefore never wraps within a call. Consume [old a1 .. new a1), wrap a1
; after it reaches the end, then resume:
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
; jx1_68000_ring_mod.S applies when N is a compile-time power of two, the base
; is aligned to N, and one fixed budget X divides N.
;
; -----------------------------------------------------------------------------
; RING BOUNDS. Entry clamps the budget to the destination room, so a1 reaches
; the end only as the call's budget expires; the next entry wraps it. A match
; source crossing the end splits the copy, and is recomputed for each segment.
; N in d1.high and end.low in d2.high replace bound registers. The low-word
; identity position = N + destination - end is exact across 64-K boundaries;
; adding -offset sets carry for an unwrapped source; otherwise adding N
; restores it. Bounds work is per call and per match segment, never per byte.
;
; -----------------------------------------------------------------------------
; THE STATE IS YOUR REGISTERS. jx1_init seeds it; preserve all five between
; calls except for the documented a1 ring wrap:
;
;   a0.l  input position
;   a1.l  write pointer - where the output ends, after every call
;   d0.b  bit queue ($80 is the empty sentinel)
;   d1.l  ring size N in the high word, bytes remaining in the low word
;   d2.l  end.low in the high word, signed offset/state in the low word;
;         +lastOffset during LITERALS, -lastOffset during MATCH;
;         with d1.w = 0, -1 means START and 0 means DONE
;
; The common state is a0/a1/d0.b/d1.w/d2.w. This general ring also keeps
; persistent metadata in d1.high/d2.high; only d0's upper 24 bits are caller-owned.
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
; d4 is gamma/offset scratch and the copy count; d5 is position, room and ladder
; scratch. d1.w is the result (zero = done),
; while d1.high remains N. Refill d3.w before each call. Repeated DONE polls
; keep d1.w/d2.w zero and retain both metadata high words.
;
; -----------------------------------------------------------------------------
; ASSUMPTIONS (unchecked; violating them is undefined behaviour):
;
;   1. no single literal run or match is longer than 65535 bytes - an
;      operation length is a word; compress with jx1 -l65535
;   2. the budget in d3.w is 1..65535
;   3. the ring buffer size N is 1..65535. The format's offsets stop at 32512,
;      so a larger ring could never be referenced anyway
;   4. no back-reference offset exceeds N. For N below 32512, compress with
;      -mN; rings of at least 32512 bytes cover the format's full offset range
;   5. at jx1_init, a1 is the first ring byte and d3 is one past the last;
;      their difference is N. Preserve the state after init except for the
;      documented a1 wrap; always preserve the packed high words
;
; TRUSTED INPUT ONLY. Stream, bounds, destination and parameters are not
; validated. Malformed data can read or write arbitrary memory; an offset can
; read unwritten ring data, and a zero budget makes no progress. Validate
; untrusted streams and decompressed lengths first, or decode them in an
; isolated memory region.
; -----------------------------------------------------------------------------

; Jump table: bra.w keeps 4-byte slots (base+0/4). A bounded ring has no
; one-shot entry; the caller drains it through jx1_resume.
                bra.w   jx1_init
                bra.w   jx1_resume

; jx1_init: a0 = compressed data, a1 = first ring byte, d3 = one-past-end.
; Derives N = d3-a1 and packs N/end.low above the common state; writes no memory.
; Java: the Decompressor constructor / reset().
jx1_init:
        move.l  d3,d1                   ; N = end - start, packed in d1.high
        sub.l   a1,d1
        swap    d1                      ; and remaining = 0 in d1.low
        moveq   #-1,d2
        move.w  d3,d2                   ; end.low lives above lastOffset
        swap    d2                      ; -lastOffset = -INITIAL_OFFSET
        moveq   #-128,d0                ; an empty bit queue: $80 is the sentinel
        rts

; jx1_resume: a0/a1/d0/d1/d2 = the state and d3.w = this call's budget.
; Emits no more than the budget or destination room. d1.w = 0 means done;
; [old a1 .. new a1) is fresh output. After draining at the end, either wrap
; a1 explicitly or let the next entry wrap it.
; Java: Decompressor.resume().
jx1_resume:
        move.l  d2,d5
        swap    d5                      ; room = end.low - destination.low
        sub.w   a1,d5                   ; exact because the room is <= 65535
        bne.s   have_room
        move.l  d1,d5                   ; previous call filled the drained ring
        clr.w   d5
        swap    d5                      ; zero-extend N
        suba.l  d5,a1                   ; wrap a1; leave room = N
have_room:
        cmp.w   d3,d5                   ; budget = min(budget, room)
        bcc.s   budget_set
        move.w  d5,d3
budget_set:                             ; word clamp ignores upper d3/d5 junk
        tst.w   d1                      ; zero identifies START or DONE
        beq.s   entry_special           ; START/DONE; active ops have remaining
segment:                                ; d1.w remaining >= 1, d3 budget >= 1
        move.w  d1,d4                   ; n = min(remaining, budget)
        cmp.w   d3,d4
        bls.s   budget_fits
        move.w  d3,d4
budget_fits:
        tst.w   d2                      ; positive lastOffset means LITERALS
        bpl.s   literal_source
; MATCH: derive the source and clamp a segment that crosses the ring end.
        movea.l a1,a2                   ; raw source = dst + -lastOffset
        adda.w  d2,a2
        move.l  d1,d5
        swap    d5                      ; d5.w = N
        add.w   a1,d5
        swap    d2                      ; d2.w = end.low, temporarily
        sub.w   d2,d5                   ; d5.w = destination position
        swap    d2                      ; restore lastOffset before using it
        add.w   d2,d5                   ; add -offset; carry means unwrapped
        bcs.s   copy                    ; unwrapped source cannot cross before dst
        neg.w   d5                      ; wrapped: room = offset - position
        cmp.w   d4,d5                   ; word, as above: the room is at most N
        bcc.s   source_wrapped
        move.w  d5,d4                   ; this segment stops at the wrap
source_wrapped:
        move.l  d1,d5                   ; add zero-extended N at any 32-bit address
        clr.w   d5
        swap    d5
        adda.l  d5,a2
        bra.s   copy
literal_source:
        movea.l a0,a2                   ; literals copy straight from the input
copy:                                   ; Java: writeByte(...) - n moves total:
        sub.w   d4,d1                   ; consume n from the operation
        sub.w   d4,d3                   ; and from this call's budget
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
        tst.w   d2
        bmi.s   match_copied             ; matches consume no input here
        movea.l a2,a0                   ; literals do
        tst.w   d1
        bne.s   resume_return            ; literals can stop only on the budget

literals_transition:
        neg.w   d2                      ; both successors are State.MATCH
        add.b   d0,d0                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #0,d4                   ; from-last match: remaining = gamma
        bra.s   get_gamma               ; Java: beginMatchFromLastOffset()

match_copied:
        tst.w   d1
        beq.s   match_transition
resume_fresh:                           ; gamma or a split match may continue
        tst.w   d3
        bne.s   segment                 ; budget remains: start/continue a segment

resume_return:                          ; return the current d1.w result
        rts                             ; zero = DONE; nonzero = more output

entry_special:                          ; d1.w = 0: only START or DONE survives a call
        tst.w   d2                      ; START has -1; DONE is zero
        beq.s   resume_return

begin_literals:                         ; Java: beginLiterals()
        neg.w   d2                      ; positive lastOffset = State.LITERALS
        moveq   #0,d4                   ; remaining = gamma + 0; fall through

; get_gamma: interlaced Elias gamma in d1.w; d4.w is the 0/1 length seed.
; Gammas are odd-length and the stream starts with one, so the queue can empty
; only on a continuation bit; data and transition reads need no refill check.
; The first continuation is peeled and bcs is the loop edge.
; Java: readInterlacedEliasGamma().
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
        bra.s   resume_fresh
gamma_refill:                           ; queue-empty continuations share one
        move.b  (a0)+,d0                ; refill; carry set means another pair
        addx.b  d0,d0                   ; follows, otherwise finish the gamma
        bcs.s   gamma_loop
        bra.s   gamma_done

match_transition:                       ; remaining == 0: parse after a match
        add.b   d0,d0                   ; Java: next(), case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        clr.w   d2                      ; replace the old offset; keep end.low above
        move.b  (a0)+,d2
        lsr.b   #1,d2                   ; carry = low bit selects the two-byte form
        bcs.s   two_byte
        sub.w   #128,d2                 ; -offset = value/2 - 128
        bra.s   got_offset
two_byte:
        moveq   #0,d4
        move.b  (a0)+,d4
        lsr.b   #1,d4                   ; d4 = high >> 1, X = high & 1
        addx.w  d2,d2                   ; (low & 254) + (high & 1) in one go
        lsl.w   #8,d4
        add.w   d4,d2                   ; (high>>1)*256 + (low&254) + (high&1)
        sub.w   #32512,d2               ; -offset = decoded value - 32512
        bpl.s   end_marker              ; nonnegative is the end marker
got_offset:
        moveq   #1,d4                   ; new-offset match: remaining = gamma+1
        bra.s   get_gamma

end_marker:                             ; Java: State.DONE
        clr.w   d2                      ; d1.w is already zero; keep metadata highs
        rts
