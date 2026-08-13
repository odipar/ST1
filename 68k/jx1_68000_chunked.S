; -----------------------------------------------------------------------------
; jx1_68000_chunked.S - decompressor for the chunk-aligned ZX1 variant
;                       (plain 68000, RAM code, self-modifying)
;
; Decodes streams produced by org.jx1.CompressorChunked: no op ever crosses a
; multiple-of-chunkSize output boundary, so this decoder has NO take_budget,
; NO mid-op state and NO clamp - the budget decrements once per op, and every
; suspend happens at a chunk boundary. The dispatch patch is written exactly
; once per stream (the boundary is the only mid-stream resume target), the
; smc1 pattern from 68k/OPTIMIZATIONS.md.
;
; Chunk grammar (see CompressorChunked.java): the first chunk opens with
; literals; every later chunk opens with a boundary code - 0 literals,
; 100 from-last match, 101 new-offset match (or the end marker). Both code
; lengths are odd, so gammas stay even-bit-aligned and the bare bit reads
; below stay refill-free, EXCEPT the middle boundary bit, which sits on a
; refill-exposed even index and is read with the checked pattern. In-chunk
; grammar and op encodings are ZX1's.
;
; Inherits from opt_x16/combo: split literals/match copy paths with woven
; gammas (match gamma takes a d0 length seed: 0 from-last, 1 new-offset),
; 32-step ladders, the patched match-source lea, and the 256-word offset
; table. The batched jx1_resume_n (slot base+12) works as in opt_x16 but a
; between-chunk boundary costs only the subq/bne + jsr + budget refresh -
; there is no op state at all to re-enter.
;
; SMC caveats (by construction): RAM code; SINGLE ACTIVE CONTEXT (jx1_init
; re-arms the patched defaults); plain 68000; prefetch-safe (entry_bra is
; patched by code that returns or by first_chunk patching the word behind
; itself; match_lea's word is written a whole gamma parse ahead of use).
;
; Assumptions, undefined when violated: the stream really is chunk-aligned
; with the SAME chunk size passed to jx1_init (1..127), and no op exceeds
; 32768 bytes (guaranteed by chunk <= 127 anyway).
;
; The context must be word-aligned and is 16 bytes.
;
; Calling convention: jx1_init and jx1_resume/jx1_resume_n clobber
; d0-d3/d5-d7/a0-a2 (d4 untouched) and leave a5 = context untouched;
; jx1_decompress additionally uses (but restores) a5.
; -----------------------------------------------------------------------------

ctx_diag        equ     0               ; .l  scratch slot (movem companion of d3)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: output position
ctx_chunk       equ     12              ; .w  chunkSize (X), 1..127
ctx_bits        equ     14              ; .b  bit buffer
ctx_pad         equ     15              ; .b  unused
ctx_size        equ     16
ctx_alloc       equ     16

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8/12).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume
                bra.w   jx1_resume_n

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = destination, d0.b = chunk size 1..127
;           (MUST match the size the stream was compressed with), a5 = context.
; -----------------------------------------------------------------------------
jx1_init:
        move.l  a0,ctx_src(a5)
        move.l  a1,ctx_dst(a5)
        and.w   #127,d0                 ; store the chunk as a clean word
        move.w  d0,ctx_chunk(a5)
        move.b  #$80,ctx_bits(a5)       ; empty bit buffer (sentinel only)
        lea     entry_bra+2(pc),a1      ; SMC: next resume call opens the stream
        move.w  #first_chunk-entry_bra-2,(a1)
        lea     match_lea+2(pc),a1      ; SMC: match source = -INITIAL_OFFSET
        move.w  #-1,(a1)
        rts

; -----------------------------------------------------------------------------
; jx1_decompress: a0 = compressed data, a1 = destination, d0.b = chunk size.
; One-shot convenience; returns with a1 = end of output.
; -----------------------------------------------------------------------------
jx1_decompress:
        move.l  a5,-(sp)
        lea     -ctx_alloc(sp),sp
        movea.l sp,a5
        bsr.s   jx1_init
.drain:
        bsr.s   jx1_resume
        tst.w   d0
        bne.s   .drain
        lea     ctx_alloc(sp),sp
        movea.l (sp)+,a5
        rts

; -----------------------------------------------------------------------------
; jx1_resume:   a5 = context. Emits one chunk; d0 = 0 once fully processed.
; jx1_resume_n: a5 = context, d6.w = chunk count k >= 1, a6 = callback run
;               between chunks (may clobber d0/d1/d5/a2-a4; must preserve
;               d2/d3/d6/d7/a0/a1/a5/a6; d4 is the caller's throughout).
; -----------------------------------------------------------------------------
jx1_resume:
        moveq   #1,d6                   ; plain call = a batch of one
jx1_resume_n:
        movem.l (a5)+,d3/a0-a1          ; scratch, src, dst
        move.w  (a5)+,d5                ; budget = chunkSize
        move.w  d5,d7                   ; chunk kept for between-chunk refresh
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_pad
entry_bra:
        bra.w   first_chunk             ; SMC: patched once to chunk_boundary

done_state:                             ; entry_bra target after end_marker
        lea     -ctx_pad(a5),a5         ; keep returning "fully processed"
        moveq   #0,d0
        rts

first_chunk:                            ; runs once: the stream opens with
        lea     entry_bra+2(pc),a2      ; literals; every later resume enters
        move.w  #chunk_boundary-entry_bra-2,(a2)  ; at the boundary decode
        bra.s   begin_literals

chunk_boundary:                         ; boundary code: 0 / 11 / 100 / 101
        add.b   d2,d2                   ; first bit: bare (odd bit index)
        bcc.s   begin_literals          ; 0: the chunk opens with literals
        add.b   d2,d2                   ; second bit: refill-exposed even index,
        bne.s   boundary_mid            ; so it gets the checked read
        move.b  (a0)+,d2
        addx.b  d2,d2
boundary_mid:
        bcs.s   full_chunk              ; 11: from-last spanning the whole chunk
        add.b   d2,d2                   ; third bit: bare again
        bcs.w   new_offset              ; 101: new-offset match (or end marker)
                                        ; (.w: out of short range; taken Bcc
                                        ; costs 10 cycles at either width)
        moveq   #0,d0                   ; 100: from-last match, length seed 0
        bra.w   match_gamma             ; (.w: same, zero cycle cost)

full_chunk:                             ; implied length: the remaining budget -
        move.w  d5,d0                   ; no gamma at all; the copy lands in
        sub.w   d0,d5                   ; chunk_done via the zeroed budget
        bra.w   match_lea               ; (.w: out of short range)

; ------------------------------- literals op --------------------------------
; begin_literals IS the literals gamma; its tail falls into the copy.
begin_literals:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   lgamma_first
        move.b  (a0)+,d2
        addx.b  d2,d2
lgamma_first:
        bcc.s   lgamma_done             ; 0: value is 1, straight through
lgamma_loop:
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1
        add.b   d2,d2                   ; next continuation bit (refill site)
        bne.s   lgamma_have
        move.b  (a0)+,d2
        addx.b  d2,d2
lgamma_have:
        bcs.s   lgamma_loop
lgamma_done:
        sub.w   d1,d5                   ; budget -= length (once per op; the
        move.w  d1,d0                   ; format caps ops at the chunk)
        lsr.w   #5,d1                   ; full 32-move passes
        and.w   #31,d0
        add.w   d0,d0
        neg.w   d0                      ; index = -2*(n&31)
        jmp     lit_end(pc,d0.w)
lit_ladder:
        move.b  (a0)+,(a1)+             ; 32 rolled-out moves, straight from
        move.b  (a0)+,(a1)+             ; the input: chunk-16 copies are pure
        move.b  (a0)+,(a1)+             ; partial entries with zero dbf passes
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
        move.b  (a0)+,(a1)+
lit_end:
        dbf     d1,lit_ladder
        tst.w   d5
        beq.s   chunk_done              ; chunk complete
        add.b   d2,d2                   ; after-literals transition (bare)
        bcs.s   new_offset              ; 1: new offset
        moveq   #0,d0                   ; 0: from-last match, length seed 0
        bra.w   match_gamma             ; (.w: same)

chunk_done:                             ; a chunk boundary
        subq.w  #1,d6
        bne.s   more_chunks             ; batch not exhausted: stay in registers
        move.b  d2,-(a5)                ; bit buffer (entry_bra already points
        subq.l  #2,a5                   ; at chunk_boundary); skip the chunk word
        movem.l d3/a0-a1,-(a5)
        moveq   #1,d0                   ; more output pending: call again
        rts
more_chunks:
        jsr     (a6)                    ; the caller's between-chunk work
        move.w  d7,d5                   ; fresh budget
        bra.w   chunk_boundary          ; (.w: same)

; ------------------------------- offset decode ------------------------------
new_offset:
        moveq   #0,d3
        move.b  (a0)+,d3
        lsr.b   #1,d3                   ; carry = low bit selects the form
        bcs.s   two_byte
        sub.w   #128,d3                 ; -offset = value/2 - 128 (never >= 0)
        bra.s   got_offset
two_byte:
        add.b   d3,d3                   ; low & 254
        moveq   #0,d0
        move.b  (a0)+,d0                ; high byte indexes G (a 256-word table):
        add.w   d0,d0                   ; -offset = (low & 254) + G[high]
        lea     gtab(pc),a2
        add.w   0(a2,d0.w),d3
        bge.w   end_marker              ; -offset >= 0 is the end marker (.w)
got_offset:
        lea     match_lea+2(pc),a2      ; SMC: source displacement = -offset;
        move.w  d3,(a2)                 ; a whole gamma parse runs before
        moveq   #1,d0                   ; match_lea executes; length seed 1
                                        ; falls into the match gamma

; match_gamma: gamma + d0 seed; its tail falls into the match copy.
match_gamma:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   mgamma_first
        move.b  (a0)+,d2
        addx.b  d2,d2
mgamma_first:
        bcc.s   mgamma_done
mgamma_loop:
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1
        add.b   d2,d2                   ; next continuation bit (refill site)
        bne.s   mgamma_have
        move.b  (a0)+,d2
        addx.b  d2,d2
mgamma_have:
        bcs.s   mgamma_loop
mgamma_done:
        add.w   d1,d0                   ; length = gamma + seed
        sub.w   d0,d5                   ; budget -= length
match_lea:
        lea     -1(a1),a2               ; SMC: extension word = -lastOffset
        move.w  d0,d1
        lsr.w   #5,d1                   ; full 32-move passes
        and.w   #31,d0
        add.w   d0,d0
        neg.w   d0                      ; index = -2*(n&31)
        jmp     match_end(pc,d0.w)
match_ladder:
        move.b  (a2)+,(a1)+             ; 32 rolled-out moves
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
        move.b  (a2)+,(a1)+
match_end:
        dbf     d1,match_ladder
        tst.w   d5
        beq.w   chunk_done              ; chunk complete (.w: out of short range)
        add.b   d2,d2                   ; after-match transition (bare)
        bcs.w   new_offset              ; 1: new offset (.w: out of short range)
        bra.w   begin_literals          ; 0: literals (.w: same)

end_marker:
        lea     entry_bra+2(pc),a2      ; SMC: every later call returns 0
        move.w  #done_state-entry_bra-2,(a2)
        move.b  d2,-(a5)
        subq.l  #2,a5
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts

; G[H] = (H>>1)*256 + (H&1) - 32512, so that -offset = (L & 254) + G[H].
        even
gtab:
H       set     0
        rept    256
        dc.w    (H>>1)*256+(H&1)-32512
H       set     H+1
        endr
