; -----------------------------------------------------------------------------
; lut2_offpath.S - lut1_htab.S (the F[H] offset LUT) plus three offset-path
; refinements, each independently correct:
;
; * moveq #0,d3 at new_offset is dead: both entries (match-transition
;   fall-through and literals_transition's bcs) sit after the copied-block's
;   "tst.w d3 / bne.s suspend", so d3.w is provably 0 already.  -4 cycles on
;   EVERY new-offset decode, and d3's high word (the dying lastOffset) never
;   leaks: got_offset's swap moves it to the low word, which move.w d1,d3
;   overwrites.  (This one back-ports to opt7 with no LUT at all.)
;
; * the copy-ladder dispatch index moves from d0 to the free d6
;   (moveq #7,d6 / and.w d0,d6 costs exactly what andi.w #7,d0 did), so d0.w
;   still holds take_budget's count 1..127 at new_offset - its high byte is
;   already clear and the H fetch needs no moveq #0,d0.  -4 cycles per
;   two-byte offset, 0 elsewhere.
;
; * the 14-byte got_offset tail (swap/bsr/addq/move/bra) is duplicated into
;   the one-byte path, deleting its bra.s: -10 cycles per one-byte offset.
;
; Per new-offset decode vs opt7: one-byte 54 -> 40 cycles, two-byte 112-118
; -> 72 cycles.  Byte-exact by construction (same arithmetic, same end-marker
; fold as lut1).
;
; Same assumptions as jx1_68000_opt.S, undefined when violated:
;
;   1. no single literal run or match is longer than 32768 bytes
;   2. the chunk size is 1..127
;
; 836 bytes total (324 bytes of code+8, 512 bytes of table).
;
; The context must be word-aligned and is 15 bytes (16 with padding).
;
; Calling convention: jx1_init and jx1_resume clobber d0-d6/a0-a2 (d6 is NEW
; vs opt7: it carries the ladder dispatch index) and leave a5 = context
; untouched; jx1_decompress additionally uses (but restores) a5.  (As in
; opt3, d4 carries the op state.)
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
; Holds the decompressor's only bit-queue refills. The first continuation
; bit is peeled, and the loop is rotated so the continue branch is the
; back-jump: no unconditional bra per pair. Java: readInterlacedEliasGamma().
get_gamma:
        moveq   #1,d1
        add.b   d2,d2                   ; first continuation bit (refill site)
        bne.s   gamma_first
        move.b  (a0)+,d2                ; refill; ZX1 bit groups always open on a
        addx.b  d2,d2                   ; continuation bit (see jx1_68000_opt3.S)
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

resume_op:                              ; shared for literals and match; d4 = state
        move.w  d3,d0                   ; take_budget: min(remaining, budget),
        cmp.w   d5,d0                   ; subtracted from both (its only site)
        bls.s   budget_fits
        move.w  d5,d0
budget_fits:
        sub.w   d0,d3
        sub.w   d0,d5
        tst.w   d0
        beq.w   suspend                 ; budget exhausted before this op
                                        ; (.w: out of short range; taken Bcc
                                        ; costs 10 cycles at either width)
        movea.l a0,a2                   ; literals copy straight from the input
        cmp.b   #1,d4
        beq.s   source_ready
        movea.l a1,a2                   ; match: destination minus lastOffset
        swap    d3                      ; (Java: readBufferByte(); the destination
        suba.w  d3,a2                   ; is the window, so no ring arithmetic)
        swap    d3
source_ready:                           ; Java: writeByte(...) - n moves total:
        move.w  d0,d1                   ; a partial first pass of n&7 entered
        lsr.w   #3,d1                   ; mid-ladder, then n>>3 full passes off
        moveq   #7,d6                   ; the dbf at ladder_end.  The dispatch
        and.w   d0,d6                   ; index lives in d6 so d0 keeps the
        add.w   d6,d6                   ; count 1..127: its high byte is clear
        neg.w   d6                      ; for new_offset's table index.
        jmp     ladder_end(pc,d6.w)     ; index = -2*(n&7)
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
copy_done:
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
        move.b  (a0)+,d3                ; d3.w = 0 here: both entries fell
        lsr.b   #1,d3                   ; through "tst.w d3 / bne.s suspend".
        bcs.s   two_byte                ; carry = low bit: two-byte form
        neg.w   d3                      ; offset = 128 - value/2
        add.w   #128,d3
        swap    d3                      ; own copy of the got_offset tail:
        bsr.w   get_gamma               ; no bra.s (.w: out of short range;
        addq.w  #1,d1                   ; BSR is 18 cycles at either width)
        move.w  d1,d3                   ; remaining = gamma + 1
        bra.w   resume_op
two_byte:
        add.b   d3,d3                   ; low & 254
        neg.w   d3                      ; -(low&254); high word = dying lastOffset
        move.b  (a0)+,d0                ; high byte H; d0.w was take_budget's
        add.w   d0,d0                   ; count 1..127, so bits 8-15 are clear
        add.w   offtab(pc,d0.w),d3      ; offset = F[H] - (low&254)
        ble.s   end_marker              ; offset <= 0 is the end marker
                                        ; (F[254]=0, F[255]=-1; all other
                                        ; entries >= 255 > any low&254)
got_offset:
        swap    d3                      ; park the new offset in the high word
        bsr.w   get_gamma               ; (.w: out of short range)
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

; F[H] = 32512 - (H>>1)*256 - (H&1), H = 0..255. offset = F[H] - (L&254).
; F[254] = 0 and F[255] = -1 encode the end marker (the only entries <= 254).
        even
offtab:
        dc.w    32512,32511,32256,32255,32000,31999,31744,31743
        dc.w    31488,31487,31232,31231,30976,30975,30720,30719
        dc.w    30464,30463,30208,30207,29952,29951,29696,29695
        dc.w    29440,29439,29184,29183,28928,28927,28672,28671
        dc.w    28416,28415,28160,28159,27904,27903,27648,27647
        dc.w    27392,27391,27136,27135,26880,26879,26624,26623
        dc.w    26368,26367,26112,26111,25856,25855,25600,25599
        dc.w    25344,25343,25088,25087,24832,24831,24576,24575
        dc.w    24320,24319,24064,24063,23808,23807,23552,23551
        dc.w    23296,23295,23040,23039,22784,22783,22528,22527
        dc.w    22272,22271,22016,22015,21760,21759,21504,21503
        dc.w    21248,21247,20992,20991,20736,20735,20480,20479
        dc.w    20224,20223,19968,19967,19712,19711,19456,19455
        dc.w    19200,19199,18944,18943,18688,18687,18432,18431
        dc.w    18176,18175,17920,17919,17664,17663,17408,17407
        dc.w    17152,17151,16896,16895,16640,16639,16384,16383
        dc.w    16128,16127,15872,15871,15616,15615,15360,15359
        dc.w    15104,15103,14848,14847,14592,14591,14336,14335
        dc.w    14080,14079,13824,13823,13568,13567,13312,13311
        dc.w    13056,13055,12800,12799,12544,12543,12288,12287
        dc.w    12032,12031,11776,11775,11520,11519,11264,11263
        dc.w    11008,11007,10752,10751,10496,10495,10240,10239
        dc.w    9984,9983,9728,9727,9472,9471,9216,9215
        dc.w    8960,8959,8704,8703,8448,8447,8192,8191
        dc.w    7936,7935,7680,7679,7424,7423,7168,7167
        dc.w    6912,6911,6656,6655,6400,6399,6144,6143
        dc.w    5888,5887,5632,5631,5376,5375,5120,5119
        dc.w    4864,4863,4608,4607,4352,4351,4096,4095
        dc.w    3840,3839,3584,3583,3328,3327,3072,3071
        dc.w    2816,2815,2560,2559,2304,2303,2048,2047
        dc.w    1792,1791,1536,1535,1280,1279,1024,1023
        dc.w    768,767,512,511,256,255,0,-1
