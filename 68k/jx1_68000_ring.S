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
; jx1_68000.S writes to a linear destination and reads matches out of it, so
; the output IS the window and memory use grows with the output. This variant
; is the port of the Java Decompressor's ring buffer: output streams through
; a caller-supplied buffer of N bytes and memory use is bounded by N, not by
; the output. A buffer of N bytes supports back-references up to exactly N
; (compress with -mN).
;
; Instead of the Java flip() callback, jx1_resume reports a full buffer in
; its return value: 0 = done, 1 = more output, 2 = more output AND the buffer
; just wrapped. On a 2 the caller must consume the buffer before calling
; again - the decompressor is about to overwrite it from the start.
;
; The copy engine is unchanged: rather than testing for a wrap per byte, each
; pass copies a segment that provably cannot wrap,
;
;       n = min(remaining, budget, end - dst, end - src)
;
; and the pointers are wrapped between segments, so the rolled-out ladder
; runs exactly as it does in jx1_68000.S. A ring costs a clamp per segment,
; not a test per byte. Matches are not slowed down by the wrap either: the
; source is recomputed from the destination for each segment (source =
; dst - offset, + N when that falls below the buffer), never carried.
;
; Measured, and deliberately NOT specialised: restricting the buffer and the
; chunk to powers of two lets the destination clamp be dropped entirely (X
; then divides N, so the buffer end can only fall on a chunk boundary, never
; inside a copy). That was built and measured at +4.1-4.5% - not worth a
; second file and a divisibility rule the caller must honour. Wrapping the
; source by masking instead of comparing, which powers of two also allow,
; measured SLOWER on a 68000: and.l (8) plus lea 0(An,Dn.l) (12) costs more
; than the compare and rarely-taken branch it replaces (a not-taken Bcc is 8).
;
; Assumptions, undefined when violated:
;
;   1. no single literal run or match is longer than 32768 bytes
;   2. the chunk size is 1..127
;   3. no back-reference offset exceeds the ring buffer size N
;
; The context must be word-aligned and is 23 bytes (24 with padding).
;
; Calling convention: jx1_init and jx1_resume clobber d0-d5/a0-a5 and leave
; a5 = context untouched. (d4 carries the op state.)
; -----------------------------------------------------------------------------

; Context block (Java: Decompressor's fields). The first five longwords are
; laid out in movem order d3,a0,a1,a3,a4.
ctx_packed      equ     0               ; .l  d3: lastOffset (high word), remaining (low word)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: write position (Java: bufferIndex)
ctx_start       equ     12              ; .l  a3: ring buffer start
ctx_end         equ     16              ; .l  a4: ring buffer end (start + N)
ctx_chunk       equ     20              ; .b  chunkSize (X), 1..127
ctx_bits        equ     21              ; .b  bit buffer
ctx_state       equ     22              ; .b  State: 0 START, 1 LITERALS, 2 MATCH, 3 DONE
ctx_size        equ     23
ctx_alloc       equ     24              ; ctx_size rounded up to keep sp even

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4).
; There is no one-shot entry: a bounded buffer has to be drained by the
; caller, so every stream is decompressed through the resume loop.
                bra.w   jx1_init
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = ring buffer, d0.b = chunk size 1..127,
;           d1.l = ring buffer size N, a5 = word-aligned context of ctx_size.
; Java: the Decompressor constructor / reset().
; -----------------------------------------------------------------------------
jx1_init:
        move.l  a0,ctx_src(a5)
        move.l  a1,ctx_dst(a5)
        move.l  a1,ctx_start(a5)
        add.l   a1,d1                   ; end = start + N
        move.l  d1,ctx_end(a5)
        move.b  d0,ctx_chunk(a5)
        moveq   #1,d1
        swap    d1                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        move.l  d1,ctx_packed(a5)
        move.b  #$80,ctx_bits(a5)       ; empty bit buffer (sentinel only)
        clr.b   ctx_state(a5)           ; State.START
        rts

; -----------------------------------------------------------------------------
; jx1_resume: a5 = context. Emits at most ctx_chunk output bytes, and stops
; early when the ring buffer fills. Returns
;   d0 = 0  the stream is fully processed; the bytes written since the
;           caller's last drain are [last drain .. a1)
;   d0 = 1  more output pending, chunk budget spent
;   d0 = 2  more output pending, AND the buffer wrapped: everything up to the
;           end of the buffer is valid and must be consumed now, because the
;           next call starts writing at the buffer's first byte again
;           (Java: flip(buffer, length))
; Java: Decompressor.resume().
; -----------------------------------------------------------------------------
jx1_resume:
        movem.l (a5)+,d3/a0-a1/a3-a4    ; packed offset/remaining, src, dst,
        moveq   #0,d5                   ; ring start, ring end
        move.b  (a5)+,d5                ; budget = chunkSize
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_state
        move.b  (a5),d4                 ; op state (Java: switch in next())
        beq.s   begin_literals          ; START: the stream opens with literals
        cmp.b   #3,d4
        bne.s   resume_op               ; LITERALS or MATCH, mid-op
        lea     -ctx_state(a5),a5       ; DONE: keep returning "fully processed"
        moveq   #0,d0
        rts

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
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   gamma_first
        move.b  (a0)+,d2                ; refill; bit groups always open on a
        addx.b  d2,d2                   ; continuation bit (see the note above)
gamma_first:
        bcc.s   gamma_done              ; 0: value is 1, straight through
gamma_loop:
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + data bit
        add.b   d2,d2                   ; next continuation bit (refill site)
        bne.s   gamma_have
        move.b  (a0)+,d2
        addx.b  d2,d2
gamma_have:
        bcs.s   gamma_loop              ; 1: another pair; the continue branch
gamma_done:                             ; doubles as the loop jump
        rts

begin_literals:                         ; Java: beginLiterals()
        moveq   #1,d4                   ; State.LITERALS
        bsr.s   get_gamma
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched

; -----------------------------------------------------------------------------
; resume_op: the segment loop, shared by literals and matches (d4 = state).
; Each pass copies as many bytes as provably fit without wrapping either
; pointer, so the ladder below needs no bounds test at all.
; -----------------------------------------------------------------------------
resume_op:
        tst.w   d3
        beq.s   transition              ; op already complete: only reachable
                                        ; when a flip landed on its last byte
        tst.w   d5
        beq.w   suspend_more            ; budget spent: hand control back
        move.w  d3,d0                   ; n = min(remaining, budget)
        cmp.w   d5,d0
        bls.s   budget_fits
        move.w  d5,d0
budget_fits:
        move.l  a4,d1
        sub.l   a1,d1                   ; room before the ring end (>= 1)
        cmp.l   d0,d1
        bcc.s   dst_fits
        move.w  d1,d0                   ; this segment stops at the wrap
dst_fits:
        cmp.b   #1,d4
        beq.s   literal_source
        movea.l a1,a2                   ; match: source = dst - lastOffset,
        swap    d3                      ; brought back into the buffer if it
        suba.w  d3,a2                   ; falls below the start (Java:
        swap    d3                      ; readBufferByte()'s index wrap).
        cmpa.l  a3,a2                   ; Recomputed per segment, so a wrapped
        bcc.s   source_ready            ; source needs no extra bookkeeping;
        suba.l  a3,a2                   ; a2 == end is unreachable, since that
        adda.l  a4,a2                   ; needs dst - offset == start, which
source_ready:                           ; takes the branch above instead.
        move.l  a4,d1
        sub.l   a2,d1                   ; room before the source wraps (>= 1)
        cmp.l   d0,d1
        bcc.s   copy
        move.w  d1,d0
        bra.s   copy
literal_source:
        movea.l a0,a2                   ; literals copy straight from the input
copy:                                   ; Java: writeByte(...) - n moves total:
        sub.w   d0,d3                   ; a partial first pass of n&7 entered
        sub.w   d0,d5                   ; mid-ladder, then n>>3 full passes off
        move.w  d0,d1                   ; the dbf at ladder_end
        lsr.w   #3,d1
        and.w   #7,d0
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
        cmp.b   #1,d4
        bne.s   wrap_test               ; matches consume no input here;
        movea.l a2,a0                   ; literals do
wrap_test:
        cmpa.l  a4,a1
        bne.s   resume_op               ; still inside the buffer: next segment
        movea.l a3,a1                   ; the buffer is full: wrap and tell the
        moveq   #2,d0                   ; caller to consume it before we
        bra.s   suspend                 ; overwrite it (Java: flip())

transition:                             ; remaining == 0: parse the next block
        cmp.b   #1,d4                   ; header. State test BEFORE the bit
        beq.s   literals_transition     ; read: cmp must not clobber the carry
        add.b   d2,d2                   ; Java: next(), case MATCH (bare read)
        bcc.w   begin_literals          ; 0: literals; 1: falls into new offset
                                        ; (.w: the segment loop pushed it out of
                                        ; short range; taken Bcc costs 10 either way)

new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        moveq   #2,d4                   ; State.MATCH
        moveq   #0,d3                   ; old offset and remaining are both dead here
        move.b  (a0)+,d3
        lsr.b   #1,d3                   ; carry = low bit selects the two-byte form
        bcs.s   two_byte
        neg.w   d3                      ; offset = 128 - value/2
        add.w   #128,d3
        bra.s   got_offset
two_byte:
        add.b   d3,d3                   ; low & 254
        moveq   #0,d0
        move.b  (a0)+,d0
        lsr.b   #1,d0                   ; d0 = high >> 1, carry = high & 1
        bcc.s   no_carry
        addq.w  #1,d3
no_carry:
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
        add.b   d2,d2                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #2,d4                   ; 0: State.MATCH from last offset
        bsr.w   get_gamma               ; Java: beginMatchFromLastOffset() (.w: same)
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        bra.w   resume_op               ; (.w: same, zero cycle cost)

suspend_more:                           ; Java: resume() returning true
        moveq   #1,d0                   ; more output pending: call again
suspend:                                ; d0 = the caller's return code
        move.b  d4,(a5)                 ; the interrupted op's state, verbatim
        move.b  d2,-(a5)                ; bit buffer
        lea     -9(a5),a5               ; skip the chunk byte and the two ring
        movem.l d3/a0-a1,-(a5)          ; bounds (never change), then store in
        rts                             ; layout order, a5 = context base

end_marker:                             ; Java: State.DONE - the caller drains
        moveq   #3,d0                   ; whatever is left below a1
        move.b  d0,(a5)
        move.b  d2,-(a5)
        lea     -9(a5),a5
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts
