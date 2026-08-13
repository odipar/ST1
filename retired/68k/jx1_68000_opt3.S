; -----------------------------------------------------------------------------
; jx1_68000_opt3.S - control-flow-optimized resumable ZX1 decompressor (68000)
;
; jx1_68000_opt2.S restructured in the style of Einar Saukas' z80
; dzx1_standard.asm (c/zx1/z80) and Emmanuel Marty's unzx0_68000.S
; (https://github.com/emmanuel-marty/unzx0_68000), so that neither get_bit
; nor take_budget needs to be a subroutine or a macro:
;
; * The ONLY bit-queue refill in the whole decompressor sits inside
;   get_gamma's continuation-bit read. Gamma data bits and the transition
;   bits are a bare add.b d2,d2, because a ZX1 stream can never run the
;   queue empty there: every gamma is an odd number of bits (continuation/
;   data pairs plus the closing 0), transitions are one bit, and the stream
;   opens with a gamma - so continuation bits always sit at even bit
;   indices, data/transition bits at odd ones, and refills happen every
;   8th bit. The z80 original relies on the same invariant.
;
; * take_budget exists once: the literals and match paths share one
;   resume_op body (budget accounting, copy loop, suspend), discriminated
;   by the live op state kept in d4 (1 LITERALS, 2 MATCH), which is also
;   exactly the byte the suspend path stores into the context.
;
; Same assumptions as jx1_68000_opt.S, undefined when violated:
;
;   1. no single literal run or match is longer than 32768 bytes
;   2. the chunk size is 1..127
;
; Measured at chunks 16 and 127: 1-28% fewer cycles than jx1_68000_opt2.S
; (biggest on parse-heavy data) and 1-7% behind jx1_68000_opt2_m.S - between
; the two, at 284 bytes with no duplicated code. At very small chunks (1..8)
; the shared-body discrimination costs more than the bare reads save on
; barely-compressible data: up to ~2% slower than opt2, up to ~15% behind
; opt2_m.
;
; The context must be word-aligned and is 15 bytes (16 with padding).
;
; Calling convention: jx1_init and jx1_resume clobber d0-d5/a0-a2 and leave
; a5 = context untouched; jx1_decompress additionally uses (but restores)
; a5. (Unlike opt2/opt2_m, d4 is clobbered: it carries the op state.)
; -----------------------------------------------------------------------------

; Context block (Java: Decompressor's fields). The first three longwords are
; laid out in movem order d3,a0,a1.
ctx_packed      equ     0               ; .l  d3: lastOffset (high word), remaining (low word)
ctx_src         equ     4               ; .l  a0: input position
ctx_dst         equ     8               ; .l  a1: output position
ctx_chunk       equ     12              ; .b  chunkSize (X), 1..127
ctx_bits        equ     13              ; .b  bit buffer
ctx_state       equ     14              ; .b  State: 0 START, 1 LITERALS, 2 MATCH, 3 DONE
ctx_size        equ     15
ctx_alloc       equ     16              ; ctx_size rounded up to keep sp even

; Jump table: intentionally bra.w so the slots stay 4 bytes (base+0/4/8).
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = destination, d0.b = chunk size 1..127,
;           a5 = word-aligned context block of ctx_size bytes.
; Java: the Decompressor constructor / reset().
; -----------------------------------------------------------------------------
jx1_init:
        move.l  a0,ctx_src(a5)
        move.l  a1,ctx_dst(a5)
        move.b  d0,ctx_chunk(a5)
        moveq   #1,d1
        swap    d1                      ; lastOffset = INITIAL_OFFSET, remaining = 0
        move.l  d1,ctx_packed(a5)
        move.b  #$80,ctx_bits(a5)       ; empty bit buffer (sentinel only)
        clr.b   ctx_state(a5)           ; State.START
        rts

; -----------------------------------------------------------------------------
; jx1_decompress: a0 = compressed data, a1 = destination.
; One-shot convenience; returns with a1 = end of output.
; Java: the static Decompressor.decompress() helpers.
; -----------------------------------------------------------------------------
jx1_decompress:
        move.l  a5,-(sp)
        lea     -ctx_alloc(sp),sp
        movea.l sp,a5
        moveq   #127,d0                 ; largest chunk a byte allows
        bsr.s   jx1_init
.drain:
        bsr.s   jx1_resume              ; Java: while (resume()) {}
        tst.w   d0
        bne.s   .drain
        lea     ctx_alloc(sp),sp
        movea.l (sp)+,a5
        rts

; -----------------------------------------------------------------------------
; jx1_resume: a5 = context. Emits at most ctx_chunk output bytes.
; Returns d0 = 0 when the stream is fully processed, 1 when there is more;
; a1 = current end of output. Java: Decompressor.resume().
; -----------------------------------------------------------------------------
jx1_resume:
        movem.l (a5)+,d3/a0-a1          ; packed offset/remaining, src, dst
        moveq   #0,d5
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
; Holds the decompressor's only bit-queue refill. Java: readInterlacedEliasGamma().
get_gamma:
        moveq   #1,d1
gamma_loop:
        add.b   d2,d2                   ; continuation bit: the only refill site
        bne.s   gamma_have
        move.b  (a0)+,d2                ; refill; ZX1 bit groups always open on a
        addx.b  d2,d2                   ; continuation bit (see header)
gamma_have:
        bcc.s   gamma_done              ; 0: value complete
        add.b   d2,d2                   ; data bit: never a refill
        addx.w  d1,d1                   ; value = value*2 + data bit
        bra.s   gamma_loop
gamma_done:
        rts

begin_literals:                         ; Java: beginLiterals()
        moveq   #1,d4                   ; State.LITERALS
        bsr.s   get_gamma
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched

resume_op:                              ; shared for literals and match; d4 = state
        move.w  d3,d0                   ; take_budget: min(remaining, budget),
        cmp.w   d5,d0                   ; subtracted from both (its only site)
        bls.s   budget_fits
        move.w  d5,d0
budget_fits:
        sub.w   d0,d3
        sub.w   d0,d5
        tst.w   d0
        beq.s   suspend                 ; budget exhausted before this op
        movea.l a0,a2                   ; literals copy straight from the input
        cmp.b   #1,d4
        beq.s   source_ready
        movea.l a1,a2                   ; match: destination minus lastOffset
        swap    d3                      ; (Java: readBufferByte(); the destination
        suba.w  d3,a2                   ; is the window, so no ring arithmetic)
        swap    d3
source_ready:
        subq.w  #1,d0                   ; dbf counts n-1..0
copy_op:
        move.b  (a2)+,(a1)+             ; Java: writeByte(...)
        dbf     d0,copy_op
        cmp.b   #1,d4
        bne.s   copied                  ; matches consume no input here;
        movea.l a2,a0                   ; literals do
copied:
        tst.w   d3
        bne.s   suspend                 ; budget spent mid-op
        cmp.b   #1,d4                   ; state test BEFORE the bit read: cmp
        beq.s   literals_transition     ; must not clobber the bit in carry
        add.b   d2,d2                   ; Java: next(), case MATCH (bare read)
        bcc.s   begin_literals          ; 0: literals; 1: falls into new offset

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
        bra.s   resume_op

literals_transition:
        add.b   d2,d2                   ; Java: next(), case LITERALS (bare read)
        bcs.s   new_offset              ; 1: new offset
        moveq   #2,d4                   ; 0: State.MATCH from last offset
        bsr.w   get_gamma               ; Java: beginMatchFromLastOffset() (.w: same)
        move.w  d1,d3                   ; remaining = gamma; lastOffset untouched
        bra.w   resume_op               ; (.w: out of short range; BRA taken
                                        ; costs 10 cycles at either width)

suspend:                                ; Java: resume() returning true
        move.b  d4,(a5)                 ; the interrupted op's state, verbatim
        move.b  d2,-(a5)                ; bit buffer
        subq.l  #1,a5                   ; skip ctx_chunk
        movem.l d3/a0-a1,-(a5)          ; stores in layout order, a5 = context base
        moveq   #1,d0                   ; more output pending: call again
        rts

end_marker:                             ; Java: State.DONE (no final flip needed:
        moveq   #3,d0                   ; output is already in place)
        move.b  d0,(a5)
        move.b  d2,-(a5)
        subq.l  #1,a5
        movem.l d3/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts
