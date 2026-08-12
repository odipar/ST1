; -----------------------------------------------------------------------------
; jx1_68000.S - resumable ZX1 decompressor for the Motorola 68000
;
; Port of the Java state machine in src/main/java/org/jx1/Decompressor.java
; (jx1), itself a port of dzx1.c from https://github.com/einar-saukas/ZX1 by
; Einar Saukas. 68000 coding style inspired by the z80 decompressors in
; c/zx1/z80 and by unzx0_68000.S by Emmanuel Marty
; (https://github.com/emmanuel-marty/unzx0_68000).
;
; Size-optimized and 68000-clean; position independent; plain address-register
; addressing only (no indexed modes). Back-references read straight from the
; destination, which plays the role of the Java ring buffer. There are no
; validation checks: like the Java version with assertions disabled, behavior
; on malformed data is undefined.
;
; The resumable state lives in a 22-byte context block (Java: the Decompressor
; fields). jx1_resume produces at most ctx_chunk output bytes per call
; (Java: resume() with chunkSize) and returns d0=0 once the stream is fully
; processed, else d0=1. Like the Java version it parses ahead after spending
; the budget, so the call emitting the final byte already returns 0.
;
; Resuming costs a fixed ~335 cycles per call; at ctx_chunk = 16 that is 20%
; to 70% over straight-line decompression, depending on how copy-dominated
; the data is. A later performance-optimized version can reduce it.
;
; Calling convention: jx1_init and jx1_resume clobber d0-d5/a0-a2 and leave
; a5 = context untouched; jx1_decompress additionally uses (but restores) a5.
; -----------------------------------------------------------------------------

; Context block (Java: Decompressor's fields). The first four longwords are
; laid out in movem order d3,d4,a0,a1.
ctx_offset      equ     0               ; .l  d3: lastOffset
ctx_remain      equ     4               ; .l  d4: remaining (bytes left in the current op)
ctx_src         equ     8               ; .l  a0: input position  (inputIndex/bit reader)
ctx_dst         equ     12              ; .l  a1: output position
ctx_chunk       equ     16              ; .l  chunkSize (X)
ctx_bits        equ     20              ; .b  bit buffer   (bitValue/bitMask)
ctx_state       equ     21              ; .b  State: 0 START, 1 LITERALS, 2 MATCH, 3 DONE
ctx_size        equ     22

; Jump table, so callers can use base+0/4/8 when linking flat binaries.
                bra.w   jx1_init
                bra.w   jx1_decompress
                bra.w   jx1_resume

; -----------------------------------------------------------------------------
; jx1_init: a0 = compressed data, a1 = destination, d0.l = chunk size X >= 1,
;            a5 = context block of ctx_size bytes.
; Java: the Decompressor constructor / reset().
; -----------------------------------------------------------------------------
jx1_init:
        move.l  a0,ctx_src(a5)
        move.l  a1,ctx_dst(a5)
        move.l  d0,ctx_chunk(a5)
        moveq   #1,d1                   ; lastOffset = INITIAL_OFFSET
        move.l  d1,ctx_offset(a5)
        clr.l   ctx_remain(a5)
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
        lea     -ctx_size(sp),sp
        movea.l sp,a5
        move.l  #$7fffffff,d0           ; budget covers any stream
        bsr     jx1_init
.drain:                                 ; Java: while (resume()) {}
        bsr     jx1_resume
        tst.w   d0                      ; resume returns moveq 0/1, so a word test suffices
        bne     .drain
        lea     ctx_size(sp),sp
        movea.l (sp)+,a5
        rts

; -----------------------------------------------------------------------------
; jx1_resume: a5 = context. Emits at most ctx_chunk output bytes.
; Returns d0 = 0 when the stream is fully processed, 1 when there is more;
; a1 = current end of output. Java: Decompressor.resume().
; -----------------------------------------------------------------------------
jx1_resume:
        movem.l (a5),d3-d4/a0-a1        ; lastOffset, remaining, src, dst
        move.b  ctx_bits(a5),d2
        move.l  ctx_chunk(a5),d5        ; budget = chunkSize
        move.b  ctx_state(a5),d0        ; dispatch on State (Java: switch in next())
        beq     .begin_literals         ; START
        subq.b  #1,d0
        beq     .resume_literals        ; LITERALS, mid-copy
        subq.b  #1,d0
        beq     .resume_match           ; MATCH, mid-copy
        moveq   #0,d0                   ; DONE: keep returning "fully processed"
        rts

.begin_literals:                        ; Java: beginLiterals()
        bsr     get_gamma
        move.l  d1,d4                   ; remaining = gamma
.resume_literals:
        bsr     take_budget
        beq     .suspend_literals
.copy_literals:                         ; Java: writeByte(readByte())
        move.b  (a0)+,(a1)+
        subq.l  #1,d0
        bne     .copy_literals
        tst.l   d4
        bne     .suspend_literals       ; budget spent mid-op
        bsr     get_bit                 ; Java: next(), case LITERALS
        bcc     .last_offset
.new_offset:                            ; Java: beginMatchFromNewOffset() / readOffset()
        moveq   #0,d3
        move.b  (a0)+,d3
        lsr.b   #1,d3                   ; carry = low bit selects the two-byte form
        bcs     .two_byte
        neg.w   d3                      ; offset = 128 - value/2
        add.w   #128,d3
        bra     .match_length
.two_byte:
        add.b   d3,d3                   ; low & 254
        moveq   #0,d0
        move.b  (a0)+,d0
        lsr.b   #1,d0                   ; d0 = high >> 1, carry = high & 1
        bcc     .no_carry
        addq.w  #1,d3
.no_carry:
        lsl.w   #8,d0
        add.w   d0,d3                   ; (high>>1)*256 + (low&254) + (high&1)
        neg.w   d3
        add.w   #32512,d3               ; offset = 32512 - that
        ble     .end_marker             ; offset <= 0 is the end marker
.match_length:
        bsr     get_gamma
        addq.l  #1,d1                   ; remaining = gamma + 1
        move.l  d1,d4
        bra     .resume_match
.last_offset:                           ; Java: beginMatchFromLastOffset()
        bsr     get_gamma
        move.l  d1,d4                   ; remaining = gamma
.resume_match:
        bsr     take_budget
        beq     .suspend_match
        movea.l a1,a2                   ; Java: readBufferByte(); the destination
        suba.w  d3,a2                   ; is the window, so no ring arithmetic
.copy_match:
        move.b  (a2)+,(a1)+
        subq.l  #1,d0
        bne     .copy_match
        tst.l   d4
        bne     .suspend_match
        bsr     get_bit                 ; Java: next(), case MATCH
        bcc     .begin_literals
        bra     .new_offset

.suspend_literals:                      ; Java: resume() returning true
        moveq   #1,d0                   ; State.LITERALS
        bra     .suspend
.suspend_match:
        moveq   #2,d0                   ; State.MATCH
.suspend:
        move.b  d0,ctx_state(a5)
        movem.l d3-d4/a0-a1,(a5)
        move.b  d2,ctx_bits(a5)
        moveq   #1,d0                   ; more output pending: call again
        rts

.end_marker:                            ; Java: State.DONE (no final flip needed:
        moveq   #3,d0                   ; output is already in place)
        move.b  d0,ctx_state(a5)
        movem.l d3-d4/a0-a1,(a5)
        moveq   #0,d0                   ; fully processed
        rts

; -----------------------------------------------------------------------------
; take_budget: d0 = min(remaining, budget), subtracted from both; Z set if 0.
; The op-granular equivalent of resume()'s per-byte budget bookkeeping.
; -----------------------------------------------------------------------------
take_budget:
        move.l  d4,d0
        cmp.l   d5,d0
        bls     .fits
        move.l  d5,d0
.fits:
        sub.l   d0,d4
        sub.l   d0,d5
        tst.l   d0
        rts

; -----------------------------------------------------------------------------
; get_bit: next bit in carry (and X). d2 holds the buffer with a sentinel one,
; refilled from (a0)+. Java: readBit()/readByte().
; -----------------------------------------------------------------------------
get_bit:
        add.b   d2,d2
        bne     .have_bit
        move.b  (a0)+,d2
        addx.b  d2,d2                   ; shift in the sentinel, bit out in carry
.have_bit:
        rts

; -----------------------------------------------------------------------------
; get_gamma: interlaced Elias gamma value in d1.l.
; Java: readInterlacedEliasGamma().
; -----------------------------------------------------------------------------
get_gamma:
        moveq   #1,d1
.next_bit:
        bsr     get_bit
        bcc     .got_value              ; continuation 0: done
        bsr     get_bit
        addx.l  d1,d1                   ; value = value*2 + data bit
        bra     .next_bit
.got_value:
        rts
