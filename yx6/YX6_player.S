; -----------------------------------------------------------------------------
; YX6_player.S - a complete TOS program that plays one .yx6 file.
;
; This is what yx6/mkprg.sh assembles around a song: it installs YX6 on the
; VBL, plays the tune - round its loop for as long as it has one - and quits
; on a key press or when a play-once tune ends.
; It is also the smallest worked example of the library's calling convention.
;
; It is not a standalone assembly: the includer supplies the two things that
; depend on the actual song, then includes this file.
;
;       RING_SIZE   equ     1024            ; the ring size in the file header
;               include "YX6_player.S"
;       song:   incbin  "song.yx6"          ; in .data, at an even address
;
; and a `workspace` label is reserved here from RING_SIZE. yx6/mkprg.sh writes
; exactly that wrapper and runs:
;
;       rmac -m68000 -p +o3 -iyx6 -i68k -o SONG.PRG wrapper.S
; -----------------------------------------------------------------------------

GEMDOS      equ     1
Cconws      equ     9
Cconis      equ     11
Mshrink     equ     $4A
XBIOS       equ     14
Supexec     equ     38
VBL_VECTOR  equ     $70

        .text

start:
        move.l  4(sp),a5                        ; the basepage TOS gave us
        lea     stack_top,sp                    ; our own stack, inside our bss
        move.l  12(a5),d0                       ; give back everything past
        add.l   20(a5),d0                       ; text + data + bss
        add.l   28(a5),d0
        add.l   #$100,d0                        ; plus the basepage itself
        move.l  d0,-(sp)
        move.l  a5,-(sp)
        clr.w   -(sp)
        move.w  #Mshrink,-(sp)
        trap    #GEMDOS
        lea     12(sp),sp

        lea     m_banner,a0
        bsr     puts

        lea     song,a0                         ; the packed tune
        lea     workspace,a1
        bsr     YX6_init
        tst.l   d0
        beq.s   .accepted
        lea     m_bad,a0
        bsr     puts
        bra     .quit
.accepted:
        move.l  #install,-(sp)                  ; the VBL vector is supervisor
        move.w  #Supexec,-(sp)                  ; territory
        trap    #XBIOS
        addq.l  #6,sp

        lea     m_playing,a0
        bsr     puts
.wait:
        tst.w   finished                        ; the handler reports the end
        bne.s   .stop
        move.w  #Cconis,-(sp)                   ; any key stops it early
        trap    #GEMDOS
        addq.l  #2,sp
        tst.w   d0
        beq.s   .wait
.stop:
        move.l  #remove,-(sp)
        move.w  #Supexec,-(sp)
        trap    #XBIOS
        addq.l  #6,sp

.quit:
        lea     m_bye,a0
        bsr     puts
        clr.w   -(sp)                           ; Pterm0
        trap    #GEMDOS

; -----------------------------------------------------------------------------
; The VBL handler runs in supervisor mode at 50 Hz, which is exactly what
; YX6_play wants: one call per frame, in order, and never after it reports the
; end. A looping tune never reports one - it returns 1 each time it goes round
; and plays until the key press stops it.
; -----------------------------------------------------------------------------
install:
        move.l  VBL_VECTOR,old_vbl
        move.l  #handler,VBL_VECTOR
        rts

remove:
        move.l  old_vbl,VBL_VECTOR
        bsr     YX6_stop                        ; leave the chip quiet
        rts

handler:
        movem.l d0-d7/a0-a6,-(sp)
        tst.w   finished
        bne.s   .chain
        lea     workspace,a0
        bsr     YX6_play
        tst.l   d0
        bpl.s   .chain                          ; 0 played, 1 went round again
        move.w  #1,finished                     ; -1: a play-once tune ran out
        bsr     YX6_stop
.chain:
        movem.l (sp)+,d0-d7/a0-a6
        move.l  old_vbl,-(sp)
        rts                                     ; on to whoever was there

puts:
        move.l  a0,-(sp)
        move.w  #Cconws,-(sp)
        trap    #GEMDOS
        addq.l  #6,sp
        rts

; ------------------------------------------------------------------ the library
        include "YX6.S"
        include "ST1_wrap.S"

        .data
m_banner:   dc.b    "YX6 player v0.2 - ZX1 streaming through ST1",13,10,0
m_playing:  dc.b    "Playing. Press any key to stop.",13,10,0
m_bad:      dc.b    "Not a v2 yx6 file.",13,10,0
m_bye:      dc.b    "Done.",13,10,0
        even

        .bss
        even
old_vbl:    ds.l    1
finished:   ds.w    1
        even
; The parentheses matter: rmac evaluates expressions strictly left to right.
workspace:  ds.b    YX6_FIXED+(YX6_STREAMS*RING_SIZE)
        even
            ds.b    $1000
stack_top:
