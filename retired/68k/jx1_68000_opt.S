; -----------------------------------------------------------------------------
; jx1_68000_opt.S - performance-optimized resumable ZX1 decompressor (68000)
;
; Same state machine and ABI shape as jx1_68000.S (the port of
; src/main/java/org/jx1/Decompressor.java); see that file for the full story.
; This version trades generality for speed under two data assumptions:
;
;   1. no single literal run or match is longer than 32768 bytes, so lengths
;      fit a word and the copy loops can use dbf
;   2. the chunk size is 1..127, so it fits a byte in the context
;
; Behavior is undefined when the assumptions do not hold (as with malformed
; data; there are no checks). Further tricks: the context is entered with
; movem.l (a5)+ and byte post-increment reads, leaving a5 parked on ctx_state
; so the suspend path can store state/bits with -(a5) and restore a5 to the
; context base for free with the pre-decrement movem; code is arranged so
; every branch except the jump table is explicitly short (bxx.s/bsr.s).
;
; The context must be word-aligned and is 19 bytes (20 with padding).
;
; Calling convention: jx1_init and jx1_resume clobber d0-d5/a0-a2 and leave
; a5 = context untouched; jx1_decompress additionally uses (but restores) a5.
; -----------------------------------------------------------------------------

; Context block (Java: Decompressor's fields). The first four longwords are
; laid out in movem order d3,d4,a0,a1.
ctx_offset      equ     0               ; .l  d3: lastOffset
ctx_remain      equ     4               ; .l  d4: remaining (word used; long for movem)
ctx_src         equ     8               ; .l  a0: input position
ctx_dst         equ     12              ; .l  a1: output position
ctx_chunk       equ     16              ; .b  chunkSize (X), 1..127
ctx_bits        equ     17              ; .b  bit buffer
ctx_state       equ     18              ; .b  State: 0 START, 1 LITERALS, 2 MATCH, 3 DONE
ctx_size        equ     19
ctx_alloc       equ     20              ; ctx_size rounded up to keep sp even

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
        movem.l (a5)+,d3-d4/a0-a1       ; lastOffset, remaining, src, dst
        moveq   #0,d5
        move.b  (a5)+,d5                ; budget = chunkSize
        move.b  (a5)+,d2                ; bit buffer; a5 now parked on ctx_state
        move.b  (a5),d0                 ; dispatch on State (Java: switch in next())
        subq.b  #1,d0
        beq.s   resume_literals         ; LITERALS, mid-copy
        bmi.s   begin_literals          ; START
        subq.b  #1,d0
        beq.s   resume_match            ; MATCH, mid-copy (tightest branch in the
                                        ; file: +124 of +126 max; grows past short
                                        ; range if code is inserted before the body)
        lea     -ctx_state(a5),a5       ; DONE: keep returning "fully processed"
        moveq   #0,d0
        rts

; take_budget: d0.w = min(remaining, budget), subtracted from both; Z if 0.
take_budget:
        move.w  d4,d0
        cmp.w   d5,d0
        bls.s   fits
        move.w  d5,d0
fits:
        sub.w   d0,d4
        sub.w   d0,d5
        tst.w   d0
        rts

; get_bit: next bit in carry (and X); sentinel-buffer trick. Java: readBit().
get_bit:
        add.b   d2,d2
        bne.s   have_bit
        move.b  (a0)+,d2
        addx.b  d2,d2                   ; shift in the sentinel, bit out in carry
have_bit:
        rts

; get_gamma: interlaced Elias gamma value in d1.w (assumption: fits a word).
; Java: readInterlacedEliasGamma().
get_gamma:
        moveq   #1,d1
gamma_bit:
        bsr.s   get_bit
        bcc.s   gamma_done              ; continuation 0: done
        bsr.s   get_bit
        addx.w  d1,d1                   ; value = value*2 + data bit
        bra.s   gamma_bit
gamma_done:
        rts

begin_literals:                         ; Java: beginLiterals()
        bsr.s   get_gamma
        move.w  d1,d4                   ; remaining = gamma
resume_literals:
        bsr.s   take_budget
        beq.s   suspend_literals
        subq.w  #1,d0                   ; dbf counts n-1..0
copy_literals:                          ; Java: writeByte(readByte())
        move.b  (a0)+,(a1)+
        dbf     d0,copy_literals
        tst.w   d4
        bne.s   suspend_literals        ; budget spent mid-op
        bsr.s   get_bit                 ; Java: next(), case LITERALS
        bcc.s   last_offset
new_offset:                             ; Java: beginMatchFromNewOffset() / readOffset()
        moveq   #0,d3
        move.b  (a0)+,d3
        lsr.b   #1,d3                   ; carry = low bit selects the two-byte form
        bcs.s   two_byte
        neg.w   d3                      ; offset = 128 - value/2
        add.w   #128,d3
        bra.s   match_length
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
match_length:
        bsr.s   get_gamma
        addq.w  #1,d1                   ; remaining = gamma + 1
        move.w  d1,d4
        bra.s   resume_match
last_offset:                            ; Java: beginMatchFromLastOffset()
        bsr.s   get_gamma
        move.w  d1,d4                   ; remaining = gamma
resume_match:
        bsr.s   take_budget
        beq.s   suspend_match
        movea.l a1,a2                   ; Java: readBufferByte(); the destination
        suba.w  d3,a2                   ; is the window, so no ring arithmetic
        subq.w  #1,d0
copy_match:
        move.b  (a2)+,(a1)+
        dbf     d0,copy_match
        tst.w   d4
        bne.s   suspend_match
        bsr.s   get_bit                 ; Java: next(), case MATCH
        bcc.s   begin_literals
        bra.s   new_offset

suspend_literals:                       ; Java: resume() returning true
        moveq   #1,d0                   ; State.LITERALS
        bra.s   suspend
suspend_match:
        moveq   #2,d0                   ; State.MATCH
suspend:
        move.b  d0,(a5)                 ; a5 is parked on ctx_state
        move.b  d2,-(a5)                ; bit buffer
        subq.l  #1,a5                   ; skip ctx_chunk
        movem.l d3-d4/a0-a1,-(a5)       ; stores in layout order, a5 = context base
        moveq   #1,d0                   ; more output pending: call again
        rts

end_marker:                             ; Java: State.DONE (no final flip needed:
        moveq   #3,d0                   ; output is already in place)
        move.b  d0,(a5)
        move.b  d2,-(a5)
        subq.l  #1,a5
        movem.l d3-d4/a0-a1,-(a5)
        moveq   #0,d0                   ; fully processed
        rts
