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
; Use this variant with a RING_SIZE-aligned, assembly-time power-of-two ring and
; one fixed budget X that divides RING_SIZE. X must not change between calls.
; RING_SIZE defaults to 1024; override it with rmac's -dRING_SIZE=<N> switch.
;
; Every continuing call emits exactly X bytes. The caller wraps a1 after a full
; ring; the decompressor receives no ring bounds because a1's low bits give its
; position and the compiled RING_SIZE gives the wrap distance.
;
; 200 bytes, position-independent, one body: no macros, no tables, no
; self-modifying code. It runs from ROM, and since it keeps nothing in memory,
; a second concurrent stream is just a second set of registers.
;
; DRAINING. The write pointer cannot wrap during a call. If a continuing call
; ends at position zero, wrap a1 before the next call:
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
;       suba.l  d5,a4                   ; consume [a4 .. a1)
;       tst.w   d1
;       beq.s   .done                   ; final output is drained; no next call
;       move.w  a1,d5
;       and.w   #RING_SIZE-1,d5         ; aligned ring position
;       bne.s   .loop
;       suba.l  #RING_SIZE,a1           ; end -> start
;       bra.s   .loop
;   .done:
;
; WHY NO BOUNDS. Since X divides RING_SIZE, every call-entry position (after
; wrapping end to start) is an X multiple and its remaining destination room is
; a positive multiple of X, hence at least X. A continuing call emits X and the
; final call emits no more, so the destination cannot cross the end. Alignment
; makes a1&RING_MASK the position. Adding -offset sets carry for an unwrapped
; match source; only the no-carry case can reach the end first, with room
; offset-position. The source is recomputed for each segment, so suspension
; needs no source state.
;
; STATE AND ABI. These five registers are the complete persistent state:
;
;   a0.l  input position
;   a1.l  write pointer, immediately after the output produced so far
;   d0.b  bit queue ($80 is the empty sentinel)
;   d1.w  bytes remaining in the current operation
;   d2.w  signed offset/state: +lastOffset during LITERALS, -lastOffset during
;         MATCH; with d1 = 0, -1 means START and 0 means DONE
;
; jx1_resume never accesses above d0's low byte or d1/d2's low words; after
; init, their upper bits remain caller-owned.
;
;   in and out   a0.l a1.l d0.b      persistent state
;                d1.w d2.w
;   in           d3.w                this call's budget, spent by the call
;   CLOBBERED    d3.w d4.l d5.l      no value in these survives a call
;                a2.l
;   untouched    d6 d7 a3 a4 a5 a6   and the stack beyond the return address
;
; a2 is the literal or recomputed match source. d4 is gamma/offset scratch and
; the copy count; d5 is position, room, offset and ladder scratch. d1.w is
; also the result: zero means done, nonzero means more.
; Pass X in d3.w again on every call; completed streams keep returning d1.w=0.
;
; ASSUMPTIONS. Undefined behaviour when violated, because nothing checks them:
;
;   1. no single literal run or match is longer than 65535 bytes - an
;      operation's length lives in a word. Compress with jx1 -l65535, which
;      splits longer matches; exceeding the limit makes decoding undefined
;   2. the budget in d3.w is 1..65535 and is the same fixed X on every call
;   3. RING_SIZE is an assembly-time power of two in 1..32768, and the buffer
;      starts at an address aligned to RING_SIZE. The assembler rejects other
;      sizes; 32768 covers the format's maximum offset of 32512
;   4. no back-reference offset exceeds RING_SIZE. Below 32768, compress with
;      jx1 -m<RING_SIZE>; 32768 covers the full 32512-byte format range
;   5. X DIVIDES RING_SIZE. Violating the fixed-X, alignment, power-of-two or
;      divisibility promises can read or write beyond the ring
;
; TRUSTED INPUT ONLY. The stream, input end, destination and parameters are not
; validated. Malformed data or invalid pointers/parameters can access arbitrary
; memory; an in-range offset beyond produced output reads stale ring bytes.
; Budget zero makes a drain loop spin forever. Validate untrusted data and its
; decompressed length, or decompress it in isolation.
; -----------------------------------------------------------------------------

; Assembly-time configuration; e.g. rmac -dRING_SIZE=256 ...
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

; Fixed 4-byte jump-table slots (base+0/4); bounded output has no one-shot entry.
                bra.w   jx1_init
                bra.w   jx1_resume

; jx1_init: a0 = compressed data, a1 = ring buffer.
; Java: the Decompressor constructor / reset(). Seeds d0/d1/d2; writes no memory.
jx1_init:
        moveq   #-1,d2                  ; -lastOffset = -INITIAL_OFFSET
        moveq   #0,d1                   ; remaining = 0
        moveq   #-128,d0                ; an empty bit queue: $80 is the sentinel
        rts

; jx1_resume: a0/a1/d0/d1/d2 = the state, d3.w = this call's budget.
; Emits at most d3 bytes; d1.w is zero when done. The advance in a1 is fresh
; output. Before continuing from position zero, subtract RING_SIZE from a1.
; Java: Decompressor.resume().
jx1_resume:
        tst.w   d1                      ; zero survives only for START or DONE
        beq.s   entry_special           ; suspended operations have d1 >= 1
        move.w  d3,d4                   ; seed n from the nonzero budget
segment:                                ; d1 remaining >= 1, d3 budget >= 1
        cmp.w   d1,d4                   ; n = min(budget, remaining)
        bls.s   budget_fits
        move.w  d1,d4
budget_fits:
        tst.w   d2                      ; positive lastOffset means LITERALS
        bpl.s   literal_source
; Match source = destination-offset. Only a wrapped source can split a segment;
; literals and unwrapped sources reach copy directly.
        movea.l a1,a2                   ; raw source = dst + -lastOffset
        adda.w  d2,a2
        move.w  a1,d5
        and.w   #RING_MASK,d5           ; destination position in aligned ring
        add.w   d2,d5                   ; add -offset; carry means unwrapped
        bcs.s   copy                    ; unwrapped source cannot end first
        neg.w   d5                      ; wrapped: room = offset - position
        .if     RING_SIZE = 32768
        suba.w  #$8000,a2               ; subtracting -32768 adds 32768 safely
        .else
        lea     RING_SIZE(a2),a2         ; raw source + N, back into the ring
        .endif
        cmp.w   d4,d5                   ; word, as above: the room is at most N
        bcc.s   copy
        move.w  d5,d4                   ; this segment stops at the wrap
        bra.s   copy
literal_source:
        movea.l a0,a2                   ; literals copy straight from the input
copy:                                   ; Java: writeByte(...) - n moves total:
        sub.w   d4,d1                   ; consume n from the operation
        sub.w   d4,d3                   ; and from this call's budget
        moveq   #7,d5                   ; d5 = n&7 for the partial first pass
        and.w   d4,d5                   ; isolate the partial-pass count
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
        bmi.s   match_copied             ; matches consume no input here
        movea.l a2,a0                   ; literals do
        tst.w   d1
        bne.s   resume_return            ; literals can stop only on the budget

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
        bne.s   segment                 ; budget left: continue the current op
resume_return:                          ; return the current d1.w result
        rts                             ; zero = DONE; nonzero = more output

entry_special:                          ; d1 = 0: only START or DONE survives a call
        tst.w   d2                      ; START has -1; DONE is zero
        beq.s   resume_return

begin_literals:                         ; Java: beginLiterals()
        neg.w   d2                      ; positive lastOffset = State.LITERALS
gamma_seed0:
        moveq   #0,d4                   ; remaining = gamma + 0; fall through

; Java: readInterlacedEliasGamma(). Decode d1.w with d4.w = 0, or 1 for a
; new-offset match; the shared tail installs remaining and skips its proven
; nonzero test. Gammas are odd-length and the stream opens with one, so only
; continuation reads can empty the queue; data and transition reads stay bare.
; Test the first continuation before gamma_loop; the loop consumes bit pairs.
get_gamma:
        addq.w  #1,d1
        add.b   d0,d0                   ; first continuation bit
        beq.s   gamma_refill            ; refill when continuation empties queue
        bcc.s   gamma_done              ; zero continuation ends the value
gamma_loop:                             ; continuation was one
        add.b   d0,d0                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + bit
        add.b   d0,d0                   ; continuation bit
        beq.s   gamma_refill
        bcs.s   gamma_loop              ; 1: another bit pair
gamma_done:                             ; d1 holds the decoded gamma
        add.w   d4,d1                   ; +1 only for a new-offset match
        bra.s   resume_fresh
gamma_refill:                           ; refill a continuation read
        move.b  (a0)+,d0                ; reload the bit queue
        addx.b  d0,d0                   ; carry set means another pair
        bcs.s   gamma_loop
        bra.s   gamma_done

match_transition:                       ; remaining == 0: parse after a match
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
        bra.s   get_gamma

end_marker:                             ; Java: State.DONE; the decoded marker
        clr.w   d2                      ; d1.w is already zero; normalize DONE
        rts                             ; in a1, as after any other call
