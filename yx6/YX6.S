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
; v0.2 plays the fourteen standard sound registers, and loops. The YM6 special
; effects - SID voice, digidrum, sinus-SID, sync-buzzer - are not played, and
; the yx6 packer has already masked their bits out of the register values.
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
; LOOPING. A ZX1 stream can only be restarted from its beginning, so the packer
; splits every register at the loop frame L: an intro stream for frames [0, L)
; and a loop stream for [L, O). When a register's section runs out mid-refill
; the player starts its loop stream over - a fresh decoder writing on into the
; same ring - so the rings always hold one continuous sequence of values and
; the read side never learns that anything happened. Nothing requires L to fall
; on a group boundary: a refill that straddles the split simply decodes two
; pieces. A tune that loops from frame 0 has no intro streams at all.
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
;       bsr     YX6_play                ; d0 = 0 played, 1 wrapped, -1 ended
;       ...
;       bsr     YX6_stop                ; silence the three voices
;
; The workspace holds the player's own fields, the fourteen decoder states and
; the fourteen rings, so its size depends on the ring size in the file:
;
;   YX6_SIZE = YX6_FIXED + 14 * N       ; 496 + 14 * N bytes
;
; For the default 1024-byte rings that is 14832 bytes. A program that knows N
; at build time can reserve it with
;
;       ds.b    YX6_FIXED+(YX6_STREAMS*1024)
;
; where the parentheses matter: rmac evaluates expressions left to right.
;
; CALLS AND REGISTERS
;
;   YX6_init   in   a0 = .yx6 file, a1 = workspace
;              out  d0 = 0 accepted, -1 not a v2 yx6 file with 14 streams
;   YX6_play   in   a0 = workspace
;              out  d0 = 0 played a frame
;                   d0 = 1 played a frame, and that frame ended the tune: the
;                          next one is the loop frame L
;                   d0 = -1 the tune is over and nothing was written, which
;                          only a tune packed with -o can report
;   YX6_stop   in   -
;   CLOBBERED  d0-d5, a0-a3. d6, d7 and a4-a6 survive, as with ST1.
;
; YX6_play writes to the sound chip at $FFFF8800, so it must run in supervisor
; mode - which a VBL handler already does. It masks interrupts around the
; fourteen writes, because selecting a register and writing it are two bus
; cycles and TOS's own handlers use the chip too. Beyond that it performs no
; side effect: no interrupt setup, no memory allocation, nothing outside the
; workspace.
;
; ASSUMPTIONS (unchecked beyond the magic, version and stream count):
;
;   1. the file comes from the yx6 packer, which enforces C >= 14, N mod C = 0,
;      N >= 2C and offsets that stay inside the ring
;   2. the workspace is at an even address and large enough for the file's N
;   3. YX6_play is called once per frame and never after it returns -1.
;      Calling it again is harmless - it returns -1 and writes nothing - which
;      is what keeps ST1_wrap's "never call the decoder again" rule intact
;   4. a looping tune plays for as long as you keep calling: d0 = 1 marks each
;      time round, and YX6_init is only needed to start again from frame 0
; -----------------------------------------------------------------------------

YX6_STREAMS     equ     14              ; R0..R13; R14/R15 are I/O ports
YX6_STATE_SIZE  equ     32              ; per stream, so the index is a shift

; Workspace layout. Counters that a frame touches are kept in the form the
; frame wants them in: a pointer to walk, and a countdown to test against zero.
YX6_CURSOR      equ     0               ; long  this frame's byte in ring 0
YX6_LEFTFR      equ     4               ; long  frames before the tune ends
YX6_NEXT        equ     8               ; long  values decoded so far
YX6_RINGEND     equ     12              ; long  one past ring 0, where it wraps
YX6_RINGS       equ     16              ; long  base of the ring area
YX6_FILE        equ     20              ; long  the .yx6 file
YX6_TOTAL       equ     24              ; long  O, the tune length in frames
YX6_LOOPLEN     equ     28              ; long  O - L, zero when it does not loop
YX6_LOOP        equ     32              ; long  L, read at init to split sections
YX6_N           equ     36              ; word  ring size N
YX6_C           equ     38              ; word  values per call C
YX6_SLOT        equ     40              ; word  refill slot, 0..C-1
YX6_INDEX       equ     42              ; word  stream index, during init only
YX6_LOOPS       equ     44              ; word  nonzero when the tune loops
YX6_STATE       equ     48              ; 14 decoder states
; rmac evaluates left to right, so the parentheses here are load-bearing:
; without them this reads as (YX6_STATE+YX6_STREAMS)*YX6_STATE_SIZE.
YX6_FIXED       equ     YX6_STATE+(YX6_STREAMS*YX6_STATE_SIZE)

; One saved ST1_wrap state, plus the ring bounds the wrap check needs. The
; first four longs are in movem order - d1, d2, then a0, a1 - so the whole
; decoder state loads and stores in one instruction each.
YS_D1           equ     0               ; long  d1, -ring.low : remaining
YS_D2           equ     4               ; long  d2, N : signed offset
YS_INPUT        equ     8               ; long  a0, input position
YS_WRITE        equ     12              ; long  a1, write pointer
YS_QUEUE        equ     16              ; byte  d0, bit queue
YS_START        equ     20              ; long  this stream's ring
YS_END          equ     24              ; long  one past its last byte
YS_LEFT         equ     28              ; long  values left in the current section
; The movem block starts at the top of the state, so the two movems address it
; as plain (a2) - see the note where they are used.

; The .yx6 header, as written by the packer.
YH_MAGIC        equ     0
YH_VERSION      equ     4
YH_FLAGS        equ     6
YH_FRAMES       equ     8
YH_PLAYER_HZ    equ     12
YH_STREAM_COUNT equ     14
YH_RING         equ     16
YH_CHUNK        equ     18
YH_LOOP         equ     20
YH_CLOCK        equ     24
YH_INTRO_TABLE  equ     28              ; 14 offsets: the frames before the loop
YH_LOOP_TABLE   equ     84              ; 14 offsets: the frames from L on

YX6_MAGIC       equ     $59583621       ; 'YX6!'
YX6_VERSION     equ     2
YX6_FLAG_LOOPS  equ     1               ; header flag: the tune loops
YX6_PSG         equ     $FFFF8800       ; select/read at +0, write at +2
YX6_NO_ENV      equ     $FF             ; R13 value meaning "leave it alone"
YX6_PORTS       equ     $C0             ; R7 bits the ST needs as outputs
YX6_MIXER       equ     7
YX6_ENVELOPE    equ     13

; -----------------------------------------------------------------------------
; YX6_WRITE: send one register's value straight from its ring to the sound
; chip, then step a1 on to the next register's ring.
;
; Two moves and an add, with the register number assembled in as an immediate:
; nothing is tested, nothing is counted, and the value never passes through a
; data register. Registers 7 and 13 need their values touched, so they are
; written out of line rather than through this macro.
;
; Skipping a register whose value has not changed was measured and dropped: a
; sound-chip access on an ST costs about 1.5 cycles more than a RAM one, so the
; compare that would save the write costs about as much as the write.
; -----------------------------------------------------------------------------
        .macro YX6_WRITE number
        move.b  #\number,(a2)           ; select
        move.b  (a1),2(a2)              ; and write
        adda.l  d3,a1
        .endm

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
        move.l  YH_LOOP(a0),YX6_LOOP(a3)
        move.w  YH_RING(a0),YX6_N(a3)
        move.w  YH_CHUNK(a0),YX6_C(a3)
        move.w  YH_FLAGS(a0),d0
        and.w   #YX6_FLAG_LOOPS,d0
        move.w  d0,YX6_LOOPS(a3)
        move.l  YH_FRAMES(a0),YX6_LEFTFR(a3)
        clr.w   YX6_SLOT(a3)
        lea     YX6_FIXED(a3),a1        ; the rings follow the decoder states
        move.l  a1,YX6_RINGS(a3)
        move.l  a1,YX6_CURSOR(a3)       ; frame 0 is the first byte of ring 0
        moveq   #0,d0
        move.w  YH_RING(a0),d0
        add.l   a1,d0
        move.l  d0,YX6_RINGEND(a3)      ; where the cursor goes back to the top

        move.l  YX6_TOTAL(a3),d0        ; the loop section is O - L frames long,
        sub.l   YX6_LOOP(a3),d0         ; and empty when the tune plays once
        tst.w   YX6_LOOPS(a3)
        bne.s   .loop_length
        moveq   #0,d0
.loop_length:
        move.l  d0,YX6_LOOPLEN(a3)

        moveq   #0,d1                   ; the first group is C values, or the
        move.w  YX6_C(a3),d1            ; whole tune when that is shorter and
        tst.w   YX6_LOOPS(a3)           ; there is no loop to carry on into
        bne.s   .first_group
        move.l  YX6_TOTAL(a3),d0
        cmp.l   d1,d0
        bcc.s   .first_group
        move.l  d0,d1
.first_group:
        move.l  d1,YX6_NEXT(a3)         ; values decoded once init is done

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
        move.l  a1,YS_WRITE(a2)
        move.l  a1,d0
        add.l   d3,d0
        move.l  d0,YS_END(a2)

; A tune that loops from frame 0 has no intro streams, so its registers start
; on the loop section - which is then the whole tune. The load of L comes last
; because it is the branch condition: a move to a data register writes the
; flags, so the earlier order - the table constant moved after L - always
; chose the intro table, and a loop-from-0 tune leaned on the fill's
; section-exhausted path to recover. That worked, by accident: YS_LEFT came
; out zero and ST1_init reads no stream data, so the bogus setup was replaced
; before anything decoded. Choose the right table outright instead.
        move.w  #YH_INTRO_TABLE,d4
        move.l  YX6_LOOP(a3),d0
        bne.s   .section                ; L != 0: the intro covers [0, L)
        move.w  #YH_LOOP_TABLE,d4
        move.l  YX6_LOOPLEN(a3),d0
.section:
        move.l  d0,YS_LEFT(a2)          ; values before this stream runs out

        move.w  YX6_INDEX(a3),d0
        lsl.w   #2,d0                   ; the tables hold long offsets
        add.w   d4,d0
        movea.l YX6_FILE(a3),a0
        move.l  0(a0,d0.w),d0
        adda.l  d0,a0                   ; the packed stream itself
        bsr     ST1_init

        move.w  YX6_INDEX(a3),d3        ; a2 was scratch for the decoder
        lsl.w   #5,d3
        lea     YX6_STATE(a3,d3.w),a2
        move.l  a0,YS_INPUT(a2)
        move.b  d0,YS_QUEUE(a2)
        move.l  d1,YS_D1(a2)
        move.l  d2,YS_D2(a2)

        move.w  YX6_INDEX(a3),d0        ; and its first group
        lsl.w   #5,d0
        move.w  YX6_NEXT+2(a3),d3       ; C, or fewer: both fit a word
        bsr     YX6_fill
        addq.w  #1,YX6_INDEX(a3)
        cmp.w   #YX6_STREAMS,YX6_INDEX(a3)
        bne     .stream

        moveq   #0,d0
        rts
.rejected:
        moveq   #-1,d0
        rts

; -----------------------------------------------------------------------------
; YX6_fill: d0.w = stream index * YX6_STATE_SIZE, d3.w = values wanted.
; Produces exactly that many values for one register, crossing into the loop
; section - and around it again - as often as it takes. Straddling matters even
; for one group: nothing says the loop frame falls on a group boundary.
; -----------------------------------------------------------------------------
YX6_fill:
        movem.l d6-d7,-(sp)             ; two registers that survive a decoder
        lea     YX6_STATE(a3,d0.w),a2   ; call, which its own state needs
        move.l  a2,d6
        moveq   #0,d7
        move.w  d3,d7                   ; values still wanted
.piece:
        move.l  YS_LEFT(a2),d0
        bne.s   .section
        bsr     YX6_start_loop          ; this section ran out: go round again
        move.l  YS_LEFT(a2),d0
        beq.s   .done                   ; nothing to go round to; do not hang
.section:
        cmp.l   d7,d0
        bcs.s   .piece_size
        move.l  d7,d0                   ; the section covers all that is wanted
.piece_size:
        sub.l   d0,YS_LEFT(a2)
        sub.l   d0,d7
        move.w  d0,d3                   ; a piece is at most C, so it fits a word

; (a2) written out rather than YS_STATE(a2): with +o3 rmac folds a zero
; displacement away on movem but keeps the addressing mode, and emits the
; instruction without its extension word. The next word becomes the
; displacement and the code runs off into nothing.
        movem.l (a2),d1-d2/a0-a1
        move.b  YS_QUEUE(a2),d0
        bsr     ST1_resume
        movea.l d6,a2
        cmpa.l  YS_END(a2),a1           ; YX6_save, inlined: this is the hot path
        bne.s   .stored
        movea.l YS_START(a2),a1         ; the call landed on the ring end
.stored:
        movem.l d1-d2/a0-a1,(a2)
        move.b  d0,YS_QUEUE(a2)
        tst.l   d7
        bne.s   .piece
.done:
        movem.l (sp)+,d6-d7
        rts

; -----------------------------------------------------------------------------
; YX6_start_loop: a2 = state block. Starts this register's loop stream over -
; a fresh decoder, reading from the top of the loop section, still writing
; where the last one stopped. ST1_init wants the ring start so that its packed
; metadata comes out right; the write pointer is restored from the block, which
; is why it is stored rather than held in a register.
; -----------------------------------------------------------------------------
YX6_start_loop:
        move.l  a2,d0
        sub.l   a3,d0
        sub.w   #YX6_STATE,d0
        lsr.w   #3,d0                   ; k * 32 becomes k * 4, a table index
        movea.l YX6_FILE(a3),a0
        move.l  YH_LOOP_TABLE(a0,d0.w),d0
        beq.s   .no_loop                ; this tune has no loop section
        adda.l  d0,a0
        movea.l YS_START(a2),a1
        moveq   #0,d3
        move.w  YX6_N(a3),d3
        bsr     ST1_init
        move.l  a0,YS_INPUT(a2)
        move.b  d0,YS_QUEUE(a2)
        move.l  d1,YS_D1(a2)
        move.l  d2,YS_D2(a2)
        move.l  YX6_LOOPLEN(a3),YS_LEFT(a2)
.no_loop:
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
        tst.l   YX6_LEFTFR(a3)
        bne.s   .frame
        moveq   #-1,d0                  ; past the last frame of a tune that
        rts                             ; does not loop: write nothing

.frame:                                 ; the same offset in all fourteen rings
        movea.l YX6_CURSOR(a3),a1
        moveq   #0,d3
        move.w  YX6_N(a3),d3            ; one ring to the next
        lea     YX6_PSG,a2

; Selecting a register and writing it are two bus cycles. An interrupt that
; uses the sound chip in between - TOS has several, its floppy motor timeout
; among them - would leave this write going to whatever register it selected,
; so the burst runs masked. Cheap: about 24 cycles for the whole frame.
        move.w  sr,-(sp)
        ori.w   #$0700,sr

        YX6_WRITE 0                     ; channel A period, fine and coarse
        YX6_WRITE 1
        YX6_WRITE 2                     ; channel B
        YX6_WRITE 3
        YX6_WRITE 4                     ; channel C
        YX6_WRITE 5
        YX6_WRITE 6                     ; noise period

        move.b  #YX6_MIXER,(a2)         ; R7 also carries the ST's I/O port
        move.b  (a1),d1                 ; directions, which port A needs kept
        or.b    #YX6_PORTS,d1           ; as outputs for the floppy select
        move.b  d1,2(a2)
        adda.l  d3,a1

        YX6_WRITE 8                     ; the three volumes
        YX6_WRITE 9
        YX6_WRITE 10
        YX6_WRITE 11                    ; envelope period
        YX6_WRITE 12

        move.b  (a1),d1                 ; R13 restarts the envelope whenever it
        cmp.b   #YX6_NO_ENV,d1          ; is written, so $FF means leave it be
        beq.s   .envelope_held
        move.b  #YX6_ENVELOPE,(a2)
        move.b  d1,2(a2)
.envelope_held:
        move.w  (sp)+,sr

; Refill the register whose turn it is. Slots 14..C-1 exist when C is larger
; than the register count; they simply have nothing to do.
        move.w  YX6_SLOT(a3),d0
        cmp.w   #YX6_STREAMS,d0
        bcc.s   .advance
        moveq   #0,d3
        move.w  YX6_C(a3),d3            ; a whole group
        tst.w   YX6_LOOPS(a3)
        bne.s   .refill                 ; a looping tune never runs out
        move.l  YX6_TOTAL(a3),d1
        sub.l   YX6_NEXT(a3),d1         ; values still packed
        ble.s   .advance                ; all decoded: never call ST1 again
        cmp.l   d3,d1
        bcc.s   .refill
        move.l  d1,d3                   ; the last group is a short one
.refill:
        lsl.w   #5,d0
        bsr     YX6_fill

.advance:
        addq.l  #1,YX6_CURSOR(a3)       ; one byte along every ring
        move.l  YX6_CURSOR(a3),d0
        cmp.l   YX6_RINGEND(a3),d0
        bcs.s   .cursor_ready
        move.l  YX6_RINGS(a3),YX6_CURSOR(a3)
.cursor_ready:
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

; The rings hold the tune as one continuous sequence, so reaching the end of
; the last frame simply means the next values in them are the loop section's.
; The countdown follows: it reloads with the loop section's length.
        subq.l  #1,YX6_LEFTFR(a3)
        bne.s   .played
        tst.w   YX6_LOOPS(a3)
        beq.s   .played                 ; zero and no loop: the next call ends
        move.l  YX6_LOOPLEN(a3),YX6_LEFTFR(a3)
        moveq   #1,d0                   ; played, and wrapped to the loop point
        rts
.played:
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
