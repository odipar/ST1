#!/usr/bin/env python3
"""Differential test for the YX6 player: does the ST write the right YM frames?

Packs a synthetic tune with the Java yx6 tool, assembles YX6.S together with
ST1_wrap.S, runs the real player under Unicorn as a plain 68000, and captures
every write to the sound chip. The captured (register, value) pairs must match,
frame by frame and in order, what a YM2149 should have received - which the
generator computes independently of both the packer and the player.

    python3 yx6/test/emu/test_yx6.py [--quick]

Needs `mvn compile` for the packer, rmac on PATH, and `pip install unicorn`.
"""
import hashlib
import importlib.util
import re
import subprocess
import sys
import tempfile
from pathlib import Path

from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN, UC_HOOK_MEM_WRITE
from unicorn.m68k_const import (
    UC_CPU_M68K_M68000, UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A2,
    UC_M68K_REG_A3, UC_M68K_REG_A4, UC_M68K_REG_A5, UC_M68K_REG_A6,
    UC_M68K_REG_A7, UC_M68K_REG_D0, UC_M68K_REG_D1, UC_M68K_REG_D2,
    UC_M68K_REG_D3, UC_M68K_REG_D4, UC_M68K_REG_D5, UC_M68K_REG_D6,
    UC_M68K_REG_D7, UC_M68K_REG_PC, UC_M68K_REG_SR,
)

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
YX6 = REPO / 'yx6'
CLASSES = REPO / 'target' / 'classes'
SCRATCH = HERE / '.work'

sys.path.insert(0, str(YX6 / 'test'))
import gen_ym                                                       # noqa: E402

_spec = importlib.util.spec_from_file_location(
    'cycle_model', REPO / '68k' / 'test' / 'emu' / 'cycle_model.py')
cycle_model = importlib.util.module_from_spec(_spec)
sys.modules['cycle_model'] = cycle_model        # its dataclass needs to find itself
_spec.loader.exec_module(cycle_model)

CODE = 0x001000
FILE = 0x010000
WORK = 0x040000
STACK_TOP = 0x090000
MAGIC = 0x0A0000
PSG = 0xFFFF8800
PSG_PAGE = 0xFFFF8000

QUICK = '--quick' in sys.argv

# The player's own contract: these must come back untouched from every call.
PRESERVED = {
    UC_M68K_REG_D6: 0xD6D6D6D6,
    UC_M68K_REG_D7: 0xD7D7D7D7,
    UC_M68K_REG_A4: 0x00A4A400,
    UC_M68K_REG_A5: 0x00A5A500,
    UC_M68K_REG_A6: 0x00A6A600,
}
SCRATCH_REGISTERS = (UC_M68K_REG_D1, UC_M68K_REG_D2, UC_M68K_REG_D3,
                     UC_M68K_REG_D4, UC_M68K_REG_D5, UC_M68K_REG_A2,
                     UC_M68K_REG_A3)


def assemble():
    """YX6.S plus the decoder it calls, as one flat, position-independent blob."""
    SCRATCH.mkdir(exist_ok=True)
    source = SCRATCH / 'link.S'
    source.write_text('        include "YX6.S"\n'
                      '        include "ST1_wrap.S"\n')
    binary = SCRATCH / 'link.bin'
    listing = SCRATCH / 'link.lst'
    command = ['rmac', '-m68000', '-fr', '+o3',
               '-i' + str(YX6), '-i' + str(REPO / '68k'),
               f'-l*{listing}', '-o', str(binary), str(source)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        raise SystemExit(result.stdout + result.stderr)
    return binary.read_bytes(), symbol_table(listing)


def symbol_table(listing: Path) -> dict:
    """Every label in an rmac listing, from its symbol table.

    rmac prints two symbols per line, which is why this does not reuse
    cycle_model.parse_listing: that one takes a whole line per symbol and would
    silently miss half of them - including, on a bad day, YX6_play.
    """
    pattern = re.compile(r'(\S+)\s+([0-9A-F]{16})\s+[atdb]\b')
    symbols = {}
    for line in listing.read_text().splitlines():
        for name, value in pattern.findall(line):
            symbols[name] = int(value, 16)
    for wanted in ('YX6_init', 'YX6_play', 'YX6_stop'):
        if wanted not in symbols:
            raise AssertionError(f'{wanted} missing from the listing')
    return symbols


def pack(tune: bytes, ring: int, chunk: int, loop) -> bytes:
    """Runs the real packer, cached on the tune and the packing options.

    loop is the frame to loop from, or None to pack a tune that plays once.
    """
    if not CLASSES.exists():
        raise SystemExit('target/classes is missing; run `mvn compile` first')
    SCRATCH.mkdir(exist_ok=True)
    option = '-o' if loop is None else f'-l{loop}'
    key = hashlib.sha1(tune).hexdigest()[:12]
    cached = SCRATCH / f'{key}-n{ring}-c{chunk}{option}.yx6'
    if not cached.exists():
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'tune.ym'
            source.write_bytes(tune)
            subprocess.run(['java', '-ea', '-cp', str(CLASSES), 'org.yx6.Yx6', '-f',
                            f'-n{ring}', f'-c{chunk}', option, str(source), str(cached)],
                           check=True, capture_output=True)
    return cached.read_bytes()


class Player:
    """One emulated ST running YX6 over a packed tune."""

    def __init__(self, packed: bytes, workspace_size: int):
        self.uc = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
        self.uc.ctl_set_cpu_model(UC_CPU_M68K_M68000)
        for base, size in ((CODE, 0x4000), (FILE, 0x30000), (WORK, 0x40000),
                           (STACK_TOP - 0x8000, 0x8000), (MAGIC, 0x1000),
                           (PSG_PAGE, 0x1000)):
            self.uc.mem_map(base, size)
        self.binary, self.symbols = assemble()
        self.uc.mem_write(CODE, self.binary)
        # Odd-but-even addresses on purpose: the 68000 needs word alignment,
        # not long alignment, and the player must not assume more.
        self.file = FILE + 2
        self.work = WORK + 2
        self.work_end = self.work + workspace_size
        self.uc.mem_write(self.file, packed)
        self.uc.mem_write(self.work, b'\xA5' * workspace_size)
        self.writes = []
        self.stray = []
        self.uc.hook_add(UC_HOOK_MEM_WRITE, self._watch)

    def _watch(self, uc, access, address, size, value, data):
        if PSG_PAGE <= address < PSG_PAGE + 0x1000:
            self.writes.append((address, value & 0xFF))
        elif not (self.work <= address and address + size <= self.work_end
                  or STACK_TOP - 0x8000 <= address < STACK_TOP):
            self.stray.append((address, size))

    def call(self, entry: str, registers=()):
        stack = STACK_TOP - 256
        self.uc.mem_write(stack, MAGIC.to_bytes(4, 'big'))
        # Supervisor state, interrupts enabled: what a VBL handler runs in, and
        # what the player needs - it touches the sound chip and its own mask.
        # Set before a7, which is a different register in each state.
        self.uc.reg_write(UC_M68K_REG_SR, 0x2000)
        self.uc.reg_write(UC_M68K_REG_A7, stack)
        for register, canary in PRESERVED.items():
            self.uc.reg_write(register, canary)
        for register in SCRATCH_REGISTERS:
            self.uc.reg_write(register, 0xBAD0BAD0)
        for register, value in registers:
            self.uc.reg_write(register, value)
        address = CODE + self.symbols[entry]
        self.uc.emu_start(address, MAGIC, count=50_000_000)
        if self.uc.reg_read(UC_M68K_REG_PC) != MAGIC:
            raise AssertionError(f'{entry} did not return')
        for register, canary in PRESERVED.items():
            if self.uc.reg_read(register) != canary:
                raise AssertionError(f'{entry} clobbered a preserved register')
        if self.stray:
            raise AssertionError('wrote outside the workspace at '
                                 + ', '.join(hex(a) for a, _ in self.stray[:3]))
        result = self.uc.reg_read(UC_M68K_REG_D0)
        return result - (1 << 32) if result >> 31 else result      # d0 is signed

    def init(self):
        return self.call('YX6_init', ((UC_M68K_REG_A0, self.file),
                                      (UC_M68K_REG_A1, self.work)))

    def frame(self):
        """Plays one frame; returns (result, [(register, value), ...])."""
        self.writes.clear()
        result = self.call('YX6_play', ((UC_M68K_REG_A0, self.work),))
        return result, self._decode_writes()

    def _decode_writes(self):
        """Pairs up select/write accesses the way the sound chip sees them."""
        pairs = []
        selected = None
        for address, value in self.writes:
            if address == PSG:
                selected = value
            elif address == PSG + 2:
                if selected is None:
                    raise AssertionError('wrote a value before selecting a register')
                pairs.append((selected, value))
            else:
                raise AssertionError(f'wrote to {address:#x}, not the sound chip')
        return pairs


def workspace_size(ring: int) -> int:
    fixed = 48 + gen_ym.PLAY_REGISTERS * 32          # YX6_FIXED
    return fixed + gen_ym.PLAY_REGISTERS * ring


def apply_writes(state, writes):
    """Feeds captured writes to a model of the chip; reports R13 writes.

    The player may skip a register whose value has not changed, so what has to
    match is the chip's contents. Writing R13 restarts the envelope, though, so
    that one write is an event in its own right.
    """
    envelope_written = False
    for register, value in writes:
        if register >= gen_ym.PLAY_REGISTERS:
            raise AssertionError(f'wrote R{register}, which is an I/O port')
        if register == 13:
            envelope_written = True
        state[register] = value
    return envelope_written


def run_shape(frames: int, ring: int, chunk: int, label: str,
              loop=0, passes: int = 1) -> str:
    """Plays a whole tune (and `passes` times round its loop) and checks it.

    loop is the frame the packed tune loops from, or None for one that plays
    once and stops.
    """
    source = gen_ym.registers(frames)
    packed = pack(gen_ym.ym6_file(frames, source, loop_frame=loop or 0),
                  ring, chunk, loop)
    played = frames if loop is None else frames + passes * (frames - loop)
    expected = gen_ym.chip_states(frames, source, loop, played)

    player = Player(packed, workspace_size(ring))
    if player.init() != 0:
        return f'{label}: YX6_init rejected the file'

    state = [0] * gen_ym.PLAY_REGISTERS
    position = 0                                  # where in the tune we are
    for index in range(played):
        result, writes = player.frame()
        envelope = apply_writes(state, writes)
        wanted, wanted_envelope = expected[index]
        if state != wanted:
            differs = [f'R{r}={state[r]:#04x} want {wanted[r]:#04x}'
                       for r in range(gen_ym.PLAY_REGISTERS) if state[r] != wanted[r]]
            return f'{label}: after frame {index} the chip has ' + ', '.join(differs)
        if envelope != wanted_envelope:
            return (f'{label}: frame {index} {"wrote" if envelope else "skipped"}'
                    f' R13, expected the other')
        position += 1
        # d0 = 1 means "that frame ended the tune, the next one is the loop
        # frame". A tune that plays once never reports it: it reports -1 on the
        # call after its last frame instead.
        wrapped = position >= frames and loop is not None
        if wrapped:
            position = loop
        if result != (1 if wrapped else 0):
            return f'{label}: frame {index} returned {result}, expected {1 if wrapped else 0}'

    if loop is None:
        result, writes = player.frame()
        if result != -1 or writes:
            return f'{label}: past the end it wrote {writes} and returned {result}'

    # Re-initialising is the whole reset: the second pass must be identical.
    if player.init() != 0:
        return f'{label}: re-init rejected the file'
    state = [0] * gen_ym.PLAY_REGISTERS
    for index in range(min(played, 3 * chunk)):
        _, writes = player.frame()
        apply_writes(state, writes)
        if state != expected[index][0]:
            return f'{label}: frame {index} differs after re-init'
    return ''


def main() -> int:
    # frames, ring, chunk, label, loop frame (None = play once), loop passes
    shapes = [
        (600, 1024, 16, 'default 1024/16', 0, 1),
        (600, 1024, 16, 'plays once', None, 0),
        (600, 1024, 16, 'loops from frame 397', 397, 2),
        (600, 256, 16, 'small ring 256/16', 0, 1),
        (600, 32, 16, 'two-group ring 32/16', 128, 1),
        (600, 1024, 64, 'long calls 1024/64', 401, 1),
        (600, 28, 14, 'tightest legal 28/14', 13, 1),
        (37, 1024, 16, 'shorter than a ring', 5, 3),
        (40, 1024, 16, 'loop shorter than a group', 35, 4),
        (16, 1024, 16, 'exactly one group', 0, 2),
        (9, 1024, 16, 'shorter than one group', 0, 3),
        (1, 1024, 16, 'a single frame', 0, 5),
        (1, 1024, 16, 'a single frame, once', None, 0),
    ]
    if not QUICK:
        shapes.append((4000, 1024, 16, 'four thousand frames', 1234, 1))
        shapes.append((4000, 2048, 32, 'four thousand, 2048/32', 0, 1))

    failures = 0
    for frames, ring, chunk, label, loop, passes in shapes:
        problem = run_shape(frames, ring, chunk, label, loop, passes)
        if problem:
            print(f'FAIL {problem}')
            failures += 1
        else:
            where = 'plays once' if loop is None else f'loops at {loop}'
            print(f'OK   {label:26s} ({frames} frames, {ring}-byte rings, {where})')

    print('ALL YX6 PLAYER TESTS PASS' if not failures else f'{failures} FAILURES')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
