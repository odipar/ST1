#!/usr/bin/env python3
"""Synthetic YM6 tunes, so the tests need no distributable chiptune.

The generated registers behave like real chip data - tones that hold and step,
volumes that decay, an envelope that is usually "unchanged" - and every YM6
effect bit is set in the registers that carry them, so the packer's masking has
something to remove and the player has something to get wrong.

    python3 gen_ym.py [out.ym] [frames]

Importable too: registers(), masked(), ym6_file() and expected_writes().
"""
import sys

YM_REGISTERS = 16               # R0..R15 in the file
PLAY_REGISTERS = 14             # R0..R13 reach the chip
NO_ENVELOPE_CHANGE = 0xFF       # R13: leave the envelope running
PORT_BITS = 0xC0                # R7 bits the ST player forces back on

# Bits the YM2149 actually uses; everything else in a YM6 frame is effect data.
MASK = (0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F,
        0x3F, 0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F)


class _Random:
    """A tiny LCG: deterministic across Python versions, unlike random.Random."""

    def __init__(self, seed=12345):
        self.state = seed

    def next(self, bound):
        self.state = (self.state * 1103515245 + 12345) & 0x7FFFFFFF
        return (self.state >> 8) % bound


def registers(frames):
    """Raw YM6 register vectors, effect bits and all: registers[r][frame]."""
    random = _Random()
    values = [bytearray(frames) for _ in range(YM_REGISTERS)]
    period = [0, 0, 0]
    volume = [15, 12, 9]
    for frame in range(frames):
        for voice in range(3):
            if frame % (7 + voice * 3) == 0:
                period[voice] = 40 + random.next(3000)
                volume[voice] = 15
            elif volume[voice] > 0 and frame % 4 == 0:
                volume[voice] -= 1
            values[voice * 2][frame] = period[voice] & 0xFF
            values[voice * 2 + 1][frame] = period[voice] >> 8
            values[8 + voice][frame] = volume[voice]
        values[6][frame] = frame % 32
        values[7][frame] = 0x38 | (frame % 8)
        values[11][frame] = (frame * 3) & 0xFF
        values[12][frame] = (frame // 64) & 0xFF
        values[13][frame] = 0x0A if frame % 50 == 0 else NO_ENVELOPE_CHANGE

        values[1][frame] |= 0x30                 # effect 1 type and voice
        values[3][frame] |= 0xC0                 # effect 2 type and voice
        values[6][frame] |= 0xE0                 # effect 1 timer bits
        values[7][frame] |= 0xC0                 # I/O port directions
        values[8][frame] |= 0x20                 # per-voice effect flags
        values[9][frame] |= 0x40
        values[10][frame] |= 0x80
        values[14][frame] = random.next(256)     # effect data, never played
        values[15][frame] = random.next(256)
    return values


def masked(frames, source=None):
    """What a plain YM2149 sees: the fourteen streams the packer writes."""
    values = source if source is not None else registers(frames)
    out = []
    for register in range(PLAY_REGISTERS):
        vector = bytearray(frames)
        for frame in range(frames):
            value = values[register][frame]
            if register == 13 and value == NO_ENVELOPE_CHANGE:
                vector[frame] = NO_ENVELOPE_CHANGE
            else:
                vector[frame] = value & MASK[register]
        out.append(vector)
    return out


def expected_writes(frames, source=None):
    """The (register, value) pairs the player must send, frame by frame.

    R7 gets the ST's port bits back, and R13 is not written at all on a frame
    that says "leave the envelope alone" - writing it would restart it.
    """
    vectors = masked(frames, source)
    per_frame = []
    for frame in range(frames):
        writes = []
        for register in range(PLAY_REGISTERS):
            value = vectors[register][frame]
            if register == 7:
                value |= PORT_BITS
            if register == 13 and value == NO_ENVELOPE_CHANGE:
                continue
            writes.append((register, value))
        per_frame.append(writes)
    return per_frame


def frame_order(frames, loop_frame, count):
    """Which frame of the tune each played frame shows, following the loop.

    A looping tune runs 0, 1, ... O-1, L, L+1, ... O-1, L, ...; one that plays
    once just stops. Pass loop_frame=None for that.
    """
    order = []
    frame = 0
    for _ in range(count):
        order.append(frame)
        frame += 1
        if frame >= frames:
            if loop_frame is None:
                break
            frame = loop_frame
    return order


def chip_states(frames, source=None, loop_frame=None, count=None):
    """What the sound chip must hold after each played frame.

    A player is free to skip writing a register whose value has not changed -
    the chip cannot tell - so state, not the write sequence, is what has to
    match. R13 is the exception: writing it restarts the envelope, so each
    frame also reports whether R13 was written at all, which is observable.
    """
    vectors = masked(frames, source)
    order = frame_order(frames, loop_frame, count if count is not None else frames)
    state = [0] * PLAY_REGISTERS
    history = []
    for frame in order:
        envelope_written = False
        for register in range(PLAY_REGISTERS):
            value = vectors[register][frame]
            if register == 7:
                value |= PORT_BITS
            if register == 13:
                if value == NO_ENVELOPE_CHANGE:
                    continue
                envelope_written = True
            state[register] = value
        history.append((list(state), envelope_written))
    return history


def ym6_file(frames, source=None, interleaved=True, player_hz=50, loop_frame=0):
    """A complete, unpacked YM6! file - what the yx6 packer takes as input."""
    values = source if source is not None else registers(frames)
    out = bytearray()
    out += b'YM6!' + b'LeOnArD!'
    out += frames.to_bytes(4, 'big')
    out += (1 if interleaved else 0).to_bytes(4, 'big')
    out += (0).to_bytes(2, 'big')                    # digidrums
    out += (2000000).to_bytes(4, 'big')              # master clock
    out += player_hz.to_bytes(2, 'big')
    out += loop_frame.to_bytes(4, 'big')
    out += (0).to_bytes(2, 'big')                    # additional data size
    out += b'Synthetic\x00' + b'Test\x00' + b'Generated by gen_ym.py\x00'
    if interleaved:
        for vector in values:
            out += bytes(vector)
    else:
        for frame in range(frames):
            out += bytes(vector[frame] for vector in values)
    out += b'End!'
    return bytes(out)


if __name__ == '__main__':
    path = sys.argv[1] if len(sys.argv) > 1 else 'tune.ym'
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
    data = ym6_file(count)
    with open(path, 'wb') as handle:
        handle.write(data)
    print(f'{path}: YM6! {count} frames at 50 Hz, {len(data)} bytes')
