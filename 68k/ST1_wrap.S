; -----------------------------------------------------------------------------
; ST1_wrap.S - ST1: counted-wrap ZX1 ring decompressor for the Atari ST (68000)
;
; By Robbert van Dalen, based on ZX1 v1.5 by Einar Saukas (data compression
; format, algorithm, and the original C/z80 decompressors). Adapted by OpenAI
; Codex from ST1_ring.S, written by Claude (Anthropic's Claude Code), under
; Robbert's direction. The decompressor can be used freely within your own
; programs, even commercially, as long as your documentation indicates that
; you used ZX1 through ST1 (see LICENSE).
;
; !!! WARNING: ST1_wrap HAS NO DONE STATE !!!
; The caller must know the exact O, make exactly T = ceil(O/C) decode calls,
; and never call ST1_resume again. Unlike ST1.S and ST1_ring.S, no register is
; a supported completion result; an extra call continues beyond the end of the
; stream with undefined results.
;
; This variant streams through an N-byte ring without checking its destination
; bounds. The caller requests a fixed C-byte chunk, where N mod C = 0, and
; resets a1 to the ring start after F = N/C full calls. Knowing the output size
; O gives T = O/C calls when O mod C = 0. I is the packed input size. I and O
; belong to the caller; only N and each call's budget are passed to this
; decoder.
;
; Unlike linear ST1, this decoder still wraps match sources and splits a copy
; whose source reaches the ring end. Counting calls replaces only destination
; bounds handling. N is supplied at run time and the ring may have any address.
;
; 222 bytes, position-independent, one body: no macros, no tables, no
; self-modifying code. Since it keeps nothing in memory, a second concurrent
; stream is just a second set of registers.
;
; -----------------------------------------------------------------------------
; DRAINING. Every non-final call emits exactly C bytes. Consume its returned
; span before that part of the ring is reused. After every F = N/C full calls,
; a1 equals ring+N; reset it to ring before the next live call. The decoder does
; not check or perform this destination wrap.
;
; C=16 caller: d5.l = O and d6.w = N. N mod 16 must be zero and the O/N
; quotient must fit a word. Only O/N needs DIVU; if N is also a power of two,
; that can be a shift and mask as well.
;
;       moveq   #0,d4
;       move.w  d6,d4
;       lsr.w   #4,d4                  ; d4.w = F = N/16
;       subq.w  #1,d4
;       movea.l d4,a4                  ; preserved F-1
;       divu.w  d6,d5                  ; d5.high = O mod N, d5.w = O/N
;       move.l  d5,d7                  ; preserved remainder/full-ring count
;
;       lea     stream,a0              ; I packed bytes
;       lea     ring,a1                ; N output bytes
;       movea.l a1,a3                  ; preserved ring start
;       move.w  d6,d3                  ; init: N
;       bsr     ST1_init
;
;       tst.w   d7                     ; any complete rings?
;       beq.s   .tail_size
;       subq.w  #1,d7                  ; outer DBF count = O/N-1
;   .full_ring:
;       move.w  a4,d6                  ; inner DBF count = N/16-1
;   .chunk:
;       move.l  a1,-(sp)                ; start of this returned span
;       moveq   #16,d3                 ; resume: C
;       bsr     ST1_resume
;       movea.l (sp)+,a2
;       ; consume [a2 .. a1)
;       dbf     d6,.chunk
;       dbf     d7,.next_ring
;       bra.s   .tail_size
;   .next_ring:
;       movea.l a3,a1                   ; caller performs the wrap
;       bra.s   .full_ring
;
;   .tail_size:
;       swap    d7                      ; R = O mod N
;       tst.w   d7
;       beq.s   .done
;       movea.l a3,a1                   ; wrap before the partial ring
;       moveq   #0,d6
;       move.w  d7,d6
;       add.l   #15,d6
;       lsr.l   #4,d6                  ; ceil(R/16)
;       subq.w  #1,d6
;   .tail:
;       move.l  a1,-(sp)
;       moveq   #16,d3                 ; final call may return less than C
;       bsr     ST1_resume
;       movea.l (sp)+,a2
;       ; consume [a2 .. a1)
;       dbf     d6,.tail
;   .done:                              ; never call the decoder again
;
; -----------------------------------------------------------------------------
; THE STATE IS YOUR REGISTERS. ST1_init seeds it; preserve all five between
; calls except for the required caller wrap of a1:
;
;   a0.l  input position
;   a1.l  write pointer - where the output ends, after every call
;   d0.b  bit queue ($80 is the empty sentinel)
;   d1.l  -ring_start.low in the high word, bytes remaining in the low word
;   d2.l  N in the high word, signed offset/state in the low word;
;         +lastOffset during LITERALS and -lastOffset during MATCH
;
; Calling convention, in full:
;
;   in and out   a0.l a1.l d0.b      the state; leave it alone between calls
;                d1.l d2.l
;   init in      d3.w                ring size N
;   resume in    d3.w                this call's budget C, spent by the call
;   CLOBBERED    d3.w d4.l d5.l      no value in these survives a call
;                a2.l
;   untouched    d6 d7 a3 a4 a5 a6   and the stack beyond the return address
;
; d4 is gamma/offset scratch and the copy count; d5 is position, source room,
; N and ladder scratch. d1.w/d2.w are internal state, not a completion result;
; the metadata high words remain unchanged. Refill d3.w before each call.
;
; -----------------------------------------------------------------------------
; ASSUMPTIONS (unchecked; violating them is undefined behaviour):
;
;   1. no single literal run or match is longer than 65535 bytes - an
;      operation length is a word; compress with jx1/nx1 -l65535
;   2. the budget in d3.w is 1..65535: 1 <= C <= N, C stays fixed except for
;      an optional shorter final call, and N mod C = 0
;   3. after every F = N/C full calls, the caller resets a1 from ring+N to
;      ring before another live call. No call may cross the destination end
;   4. no back-reference offset exceeds N. For N below 32512, compress with
;      -mN; rings of at least 32512 bytes cover the format's full offset range
;   5. at ST1_init, a1 is the first ring byte and d3.w is N. Preserve the state
;      after init except for the documented a1 wrap; preserve both high words
;   6. O is exact. Make T = ceil(O/C) calls and never make another decode call;
;      the final budget may be O-(T-1)*C instead of C
;
; TRUSTED INPUT ONLY. Stream, bounds, destination, I, O, N, C and the call
; counts are not validated. A wrong value can read or write arbitrary memory;
; an offset can read unwritten ring data, a zero budget makes no progress, and
; a call after T has no DONE guard. Validate inputs first or decode in
; isolation.
; -----------------------------------------------------------------------------

; Jump table: bra.w keeps 4-byte slots (base+0/4). A counted ring has no
; one-shot entry; the caller drains it through ST1_resume.
                bra.w   ST1_init
                bra.w   ST1_resume

; ST1_init: a0 = packed input, a1 = first ring byte, d3.w = N.
; Packs -ring_start.low/N above the common state; writes no memory.
; Java: the Decompressor constructor / reset().
ST1_init:
        moveq   #0,d1
        sub.w   a1,d1                   ; -ring_start.low, exact modulo 65536
        swap    d1                      ; pack it high; remaining = 0
        moveq   #-1,d2
        move.w  d3,d2                   ; N lives above lastOffset
        swap    d2                      ; -lastOffset = -INITIAL_OFFSET
        moveq   #-128,d0                ; an empty bit queue: $80 is the sentinel
        rts

source_wrapped:
        move.l  d2,d5
        clr.w   d5
        swap    d5                      ; zero-extend N from d2.high
        adda.l  d5,a2                   ; raw source + N, back into the ring
        bra.s   copy

; ST1_resume: a0/a1/d0/d1/d2 = state and d3.w = this call's budget.
; Continuing calls emit d3 bytes; the final call may be shorter. The caller
; knows the final span from O; [old a1 .. new a1) is fresh output.
ST1_resume:
        tst.w   d1                      ; only the first legal call has zero
        beq.s   begin_literals
        move.w  d3,d4                   ; seed n from the nonzero budget
segment:                                ; d1.w remaining >= 1, d3 budget >= 1
        cmp.w   d1,d4                   ; n = min(budget, remaining)
        bls.s   budget_fits
        move.w  d1,d4
budget_fits:
        tst.w   d2                      ; positive lastOffset means LITERALS
        bpl.s   literal_source
; MATCH: derive the source and split a segment that crosses the ring end.
        movea.l a1,a2                   ; raw source = dst + -lastOffset
        adda.w  d2,a2
        move.l  d1,d5
        swap    d5                      ; d5.w = -ring_start.low
        add.w   a1,d5                   ; d5.w = destination position
        add.w   d2,d5                   ; add -offset; carry means unwrapped
        bcs.s   copy                    ; unwrapped source cannot cross before dst
        neg.w   d5                      ; wrapped: room = offset - position
        cmp.w   d4,d5                   ; source bytes before the ring end
        bcc.s   source_wrapped
        move.w  d5,d4                   ; stop this segment at the source wrap
        bra.s   source_wrapped
literal_source:
        movea.l a0,a2                   ; literals copy straight from the input
copy:                                   ; Java: writeByte(...) - n moves total:
        sub.w   d4,d1                   ; consume n from the operation
        sub.w   d4,d3                   ; and from this call's budget
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
        tst.w   d2
        bmi.s   match_copied             ; matches consume no input here
        movea.l a2,a0                   ; literals do
        tst.w   d1
        bne.s   resume_return            ; literals stop only on the budget

literals_transition:
        add.b   d0,d0                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        neg.w   d2                      ; from-last reuses the negated offset
        bra.s   gamma_seed0             ; Java: beginMatchFromLastOffset()

match_copied:
        tst.w   d1
        beq.s   match_transition
resume_fresh:                           ; gamma or a split match may continue
        move.w  d3,d4                   ; test budget and seed the next segment
        bne.s   segment                 ; budget remains: start/continue a segment

resume_return:
        rts

begin_literals:                         ; Java: beginLiterals()
        neg.w   d2                      ; positive lastOffset = State.LITERALS
gamma_seed0:
        moveq   #0,d4                   ; remaining = gamma + 0; fall through

; get_gamma: interlaced Elias gamma in d1.w; d4.w is the 0/1 length seed.
; Gammas are odd-length and the stream starts with one, so the queue can empty
; only on a continuation bit; data and transition reads need no refill check.
get_gamma:
        addq.w  #1,d1
        add.b   d0,d0                   ; first continuation bit
        beq.s   gamma_refill
        bcc.s   gamma_done
gamma_loop:
        add.b   d0,d0                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + bit
        add.b   d0,d0                   ; continuation bit
        beq.s   gamma_refill
        bcs.s   gamma_loop
gamma_done:
        add.w   d4,d1                   ; +1 only for a new-offset match
        bra.s   resume_fresh
gamma_refill:
        move.b  (a0)+,d0
        addx.b  d0,d0
        bcs.s   gamma_loop
        bra.s   gamma_done

match_transition:                       ; remaining == 0: parse after a match
        add.b   d0,d0
        bcc.s   begin_literals

new_offset:                             ; Java: beginMatchFromNewOffset/readOffset
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
        bpl.s   resume_return            ; final marker; caller stops after T
got_offset:
        move.w  d4,d2                   ; install -lastOffset; preserve d2.high
        moveq   #1,d4                   ; new-offset match: remaining = gamma+1
        bra.s   get_gamma
