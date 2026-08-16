; -----------------------------------------------------------------------------
; YX6.S - streaming YM chiptune player for the plain 68000 (Atari ST)
;
; By Robbert van Dalen. Plays a .yx6 file: fourteen YM2149 register streams,
; each packed as its own ZX1 stream and decoded through its own small ring by
; ST1_wrap.S. Written by Claude (Anthropic's Claude Code) under Robbert's
; direction, based on ZX1 v1.5 by Einar Saukas and inspired by Steve Clarets'
; MinYMiser. Use it freely, including commercially, as long as your
; documentation says you used ZX1 through ST1 (see LICENSE).
;
; v0.1 plays the fourteen standard sound registers. The YM6 special effects -
; SID voice, digidrum, sinus-SID, sync-buzzer - are not played, and the yx6
; packer has already masked their bits out of the register values.
;
; REQUIRES ST1_wrap.S. Include both; the order does not matter. YX6 calls
; ST1_init and ST1_resume by label.
;
; -----------------------------------------------------------------------------
; THE DESIGN, in one paragraph. A tune is O frames long. Each of the fourteen
; registers gets its own ring of N bytes and its own saved decoder state, and
; is decoded C values at a time (C = 16 by default). On every VBL the player
; uses one value from each of the fourteen rings and refills exactly one
; register - register k on the VBL where the frame number modulo C is k. With
; C >= 14 every register is refilled once per C frames, one refill per VBL, so
; the work per frame is flat: fourteen register writes plus one ST1_resume of
; C bytes. Since C divides N and a call never reaches the ring end, ST1_wrap.S
; is the decoder that fits: the player counts the calls itself and wraps the
; write pointer when it lands on the ring end.
;
; -----------------------------------------------------------------------------
; USING IT
;
;       lea     song,a0                 ; the .yx6 file, loaded anywhere
;       lea     workspace,a1            ; even address, YX6_SIZE bytes
;       bsr     YX6_init                ; d0 = 0 when the file was accepted
;       tst.l   d0
;       bne     bad_file
;   vbl:                                ; once per frame, in supervisor mode
;       lea     workspace,a0
;       bsr     YX6_play                ; d0 = 0 playing, 1 when the tune ended
;       ...
;       bsr     YX6_stop                ; silence the three voices
;
; The workspace holds the player's own fields, the fourteen decoder states and
; the fourteen rings, so its size depends on the ring size in the file:
;
;   YX6_SIZE = YX6_FIXED + 14 * N       ; 480 + 14 * N bytes
;
; For the default 1024-byte rings that is 14816 bytes. A program that knows N
; at build time can reserve it with
;
;       ds.b    YX6_FIXED+(YX6_STREAMS*1024)
;
; where the parentheses matter: rmac evaluates expressions left to right.
;
; CALLS AND REGISTERS
;
;   YX6_init   in   a0 = .yx6 file, a1 = workspace
;              out  d0 = 0 accepted, -1 not a v1 yx6 file with 14 streams
;   YX6_play   in   a0 = workspace
;              out  d0 = 0 played a frame, 1 the tune is over (nothing written)
;   YX6_stop   in   -
;   CLOBBERED  d0-d5, a0-a3. d6, d7 and a4-a6 survive, as with ST1.
;
; YX6_play writes to the sound chip at $FFFF8800, so it must run in supervisor
; mode - which a VBL handler already does. It performs no other side effect:
; no interrupt setup, no memory allocation, nothing outside the workspace.
;
; ASSUMPTIONS (unchecked beyond the magic, version and stream count):
;
;   1. the file comes from the yx6 packer, which enforces C >= 14, N mod C = 0,
;      N >= 2C and offsets that stay inside the ring
;   2. the workspace is at an even address and large enough for the file's N
;   3. YX6_play is called once per frame and never after it returns 1. Calling
;      it again is harmless (it returns 1 and writes nothing), which is what
;      keeps ST1_wrap's "never call the decoder again" rule intact
;   4. to play the tune again, call YX6_init again: v0.1 restarts from frame 0
;      rather than from the file's loop frame
; -----------------------------------------------------------------------------

YX6_STREAMS     equ     14              ; R0..R13; R14/R15 are I/O ports
YX6_STATE_SIZE  equ     32              ; per stream, so the index is a shift

; Workspace layout.
YX6_FRAME       equ     0               ; long  frames played so far
YX6_TOTAL       equ     4               ; long  O, the tune length in frames
YX6_NEXT        equ     8               ; long  first value of the next group
YX6_READ        equ     12              ; long  read offset in every ring
YX6_RINGS       equ     16              ; long  base of the ring area
YX6_FILE        equ     20              ; long  the .yx6 file
YX6_N           equ     24              ; word  ring size N
YX6_C           equ     26              ; word  values per call C
YX6_SLOT        equ     28              ; word  refill slot, 0..C-1
YX6_INDEX       equ     30              ; word  stream index, during init only
YX6_STATE       equ     32              ; 14 decoder states
; rmac evaluates left to right, so the parentheses here are load-bearing:
; without them this reads as (YX6_STATE+YX6_STREAMS)*YX6_STATE_SIZE.
YX6_FIXED       equ     YX6_STATE+(YX6_STREAMS*YX6_STATE_SIZE)

; One saved ST1_wrap state, plus the ring bounds the wrap check needs.
YS_INPUT        equ     0               ; long  a0, input position
YS_WRITE        equ     4               ; long  a1, write pointer
YS_D1           equ     8               ; long  d1, -ring.low : remaining
YS_D2           equ     12              ; long  d2, N : signed offset
YS_QUEUE        equ     16              ; byte  d0, bit queue
YS_START        equ     20              ; long  this stream's ring
YS_END          equ     24              ; long  one past its last byte

; The .yx6 header, as written by the packer.
YH_MAGIC        equ     0
YH_VERSION      equ     4
YH_FRAMES       equ     8
YH_PLAYER_HZ    equ     12
YH_STREAM_COUNT equ     14
YH_RING         equ     16
YH_CHUNK        equ     18
YH_LOOP         equ     20
YH_CLOCK        equ     24
YH_TABLE        equ     28              ; 14 stream offsets from the file start

YX6_MAGIC       equ     $59583621       ; 'YX6!'
YX6_VERSION     equ     1
YX6_PSG         equ     $FFFF8800       ; select/read at +0, write at +2
YX6_NO_ENV      equ     $FF             ; R13 value meaning "leave it alone"
YX6_PORTS       equ     $C0             ; R7 bits the ST needs as outputs
YX6_MIXER       equ     7
YX6_ENVELOPE    equ     13

; Jump table: bra.w keeps 4-byte slots for a program that loads YX6 as a blob.
                bra.w   YX6_init
                bra.w   YX6_play
                bra.w   YX6_stop

; -----------------------------------------------------------------------------
; YX6_init: a0 = .yx6 file, a1 = workspace. Sets up fourteen decoders and
; decodes each register's first group, so frame 0 can be played immediately.
; -----------------------------------------------------------------------------
YX6_init:
        movea.l a1,a3                   ; a3 is the workspace throughout
        move.l  a0,YX6_FILE(a3)
        cmp.l   #YX6_MAGIC,YH_MAGIC(a0)
        bne     .rejected
        cmp.w   #YX6_VERSION,YH_VERSION(a0)
        bne     .rejected
        cmp.w   #YX6_STREAMS,YH_STREAM_COUNT(a0)
        bne     .rejected

        move.l  YH_FRAMES(a0),YX6_TOTAL(a3)
        move.w  YH_RING(a0),YX6_N(a3)
        move.w  YH_CHUNK(a0),YX6_C(a3)
        clr.l   YX6_FRAME(a3)
        clr.l   YX6_READ(a3)
        clr.w   YX6_SLOT(a3)
        lea     YX6_FIXED(a3),a1        ; the rings follow the decoder states
        move.l  a1,YX6_RINGS(a3)

        move.l  YX6_TOTAL(a3),d0        ; the first group is min(C, O) values
        moveq   #0,d1
        move.w  YX6_C(a3),d1
        cmp.l   d1,d0
        bcc.s   .first_group
        move.l  d0,d1                   ; a tune shorter than one group
.first_group:
        move.l  d1,YX6_NEXT(a3)         ; decoded so far, and where group 1 starts

        clr.w   YX6_INDEX(a3)           ; the loop counter lives here: every
.stream:                                ; register is state during the calls
        move.w  YX6_INDEX(a3),d0
        lsl.w   #5,d0                   ; * YX6_STATE_SIZE
        lea     YX6_STATE(a3,d0.w),a2
        moveq   #0,d3
        move.w  YX6_N(a3),d3            ; N, also ST1_init's argument
        move.w  YX6_INDEX(a3),d0
        mulu.w  d3,d0                   ; this stream's ring is the k'th
        movea.l YX6_RINGS(a3),a1
        adda.l  d0,a1
        move.l  a1,YS_START(a2)
        move.l  a1,d0
        add.l   d3,d0
        move.l  d0,YS_END(a2)

        move.w  YX6_INDEX(a3),d0
        lsl.w   #2,d0                   ; the stream table holds long offsets
        movea.l YX6_FILE(a3),a0
        move.l  YH_TABLE(a0,d0.w),d0
        adda.l  d0,a0                   ; the packed stream itself
        bsr     ST1_init
        move.w  YX6_NEXT+2(a3),d3       ; min(C, O) fits a word: C <= N
        bsr     ST1_resume

        move.w  YX6_INDEX(a3),d3        ; a2 was scratch for the decoder
        lsl.w   #5,d3
        lea     YX6_STATE(a3,d3.w),a2
        bsr     YX6_save
        addq.w  #1,YX6_INDEX(a3)
        cmp.w   #YX6_STREAMS,YX6_INDEX(a3)
        bne.s   .stream

        moveq   #0,d0
        rts
.rejected:
        moveq   #-1,d0
        rts

; YX6_save: a2 = state block, decoder state in a0/a1/d0/d1/d2. Wraps the write
; pointer when the call landed exactly on the ring end - ST1_wrap leaves that
; to its caller, and the fixed C-byte calls make it the only wrap that happens.
YX6_save:
        cmpa.l  YS_END(a2),a1
        bne.s   .stored
        movea.l YS_START(a2),a1
.stored:
        move.l  a0,YS_INPUT(a2)
        move.l  a1,YS_WRITE(a2)
        move.b  d0,YS_QUEUE(a2)
        move.l  d1,YS_D1(a2)
        move.l  d2,YS_D2(a2)
        rts

; -----------------------------------------------------------------------------
; YX6_play: a0 = workspace. One frame: write fourteen registers, refill one.
; -----------------------------------------------------------------------------
YX6_play:
        movea.l a0,a3
        move.l  YX6_FRAME(a3),d0
        cmp.l   YX6_TOTAL(a3),d0
        bcs.s   .frame
        moveq   #1,d0                   ; past the last frame: write nothing
        rts

.frame:                                 ; the same offset in all fourteen rings
        movea.l YX6_RINGS(a3),a1
        adda.l  YX6_READ(a3),a1
        moveq   #0,d3
        move.w  YX6_N(a3),d3            ; one ring to the next
        lea     YX6_PSG,a2
        moveq   #0,d0                   ; register number
        moveq   #YX6_STREAMS-1,d2
.register:
        move.b  (a1),d1
        cmp.b   #YX6_MIXER,d0
        bne.s   .not_mixer
        or.b    #YX6_PORTS,d1           ; R7: the ST drives both I/O ports
.not_mixer:
        cmp.b   #YX6_ENVELOPE,d0
        bne.s   .write
        cmp.b   #YX6_NO_ENV,d1
        beq.s   .next                   ; writing R13 would restart the envelope
.write:
        move.b  d0,(a2)                 ; select the register
        move.b  d1,2(a2)                ; and write this frame's value
.next:
        adda.l  d3,a1
        addq.b  #1,d0
        dbf     d2,.register

; Refill the register whose turn it is. Slots 14..C-1 exist when C is larger
; than the register count; they simply have nothing to do.
        move.w  YX6_SLOT(a3),d0
        cmp.w   #YX6_STREAMS,d0
        bcc.s   .advance
        move.l  YX6_NEXT(a3),d1
        move.l  YX6_TOTAL(a3),d2
        sub.l   d1,d2                   ; values still packed
        ble.s   .advance                ; all decoded: never call ST1 again
        moveq   #0,d3
        move.w  YX6_C(a3),d3
        cmp.l   d3,d2
        bcc.s   .budget
        move.l  d2,d3                   ; the last group is a short one
.budget:
        lsl.w   #5,d0
        lea     YX6_STATE(a3,d0.w),a2
        move.l  a2,-(sp)                ; the decoder uses a2 as scratch
        movea.l YS_INPUT(a2),a0
        movea.l YS_WRITE(a2),a1
        move.b  YS_QUEUE(a2),d0
        move.l  YS_D1(a2),d1
        move.l  YS_D2(a2),d2
        bsr     ST1_resume
        movea.l (sp)+,a2
        bsr     YX6_save

.advance:
        addq.l  #1,YX6_FRAME(a3)
        moveq   #0,d1
        move.w  YX6_N(a3),d1
        move.l  YX6_READ(a3),d0
        addq.l  #1,d0
        cmp.l   d1,d0
        bcs.s   .read_ready
        moveq   #0,d0                   ; the read offset wraps with the rings
.read_ready:
        move.l  d0,YX6_READ(a3)

        move.w  YX6_SLOT(a3),d0
        addq.w  #1,d0
        cmp.w   YX6_C(a3),d0
        bcs.s   .slot_ready
        moveq   #0,d0                   ; a cycle ended: the groups move on
        moveq   #0,d1
        move.w  YX6_C(a3),d1
        add.l   d1,YX6_NEXT(a3)
.slot_ready:
        move.w  d0,YX6_SLOT(a3)
        moveq   #0,d0
        rts

; -----------------------------------------------------------------------------
; YX6_stop: silence the three voices. Leaves the tone and envelope settings
; alone, so a later YX6_play picks up where it left off.
; -----------------------------------------------------------------------------
YX6_stop:
        lea     YX6_PSG,a0
        moveq   #8,d0                   ; R8, R9, R10 are the voice volumes
.silence:
        move.b  d0,(a0)
        clr.b   2(a0)
        addq.b  #1,d0
        cmp.b   #11,d0
        bne.s   .silence
        rts
