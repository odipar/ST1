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
    UC_M68K_REG_D7, UC_M68K_REG_PC,
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
    _, symbols = cycle_model.parse_listing(listing)
    return binary.read_bytes(), symbols


def pack(tune: bytes, ring: int, chunk: int) -> bytes:
    """Runs the real packer, cached on the tune and shape."""
    if not CLASSES.exists():
        raise SystemExit('target/classes is missing; run `mvn compile` first')
    SCRATCH.mkdir(exist_ok=True)
    key = hashlib.sha1(tune).hexdigest()[:12]
    cached = SCRATCH / f'{key}-n{ring}-c{chunk}.yx6'
    if not cached.exists():
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / 'tune.ym'
            source.write_bytes(tune)
            subprocess.run(['java', '-ea', '-cp', str(CLASSES), 'org.yx6.Yx6', '-f',
                            f'-n{ring}', f'-c{chunk}', str(source), str(cached)],
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
        return self.uc.reg_read(UC_M68K_REG_D0)

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
    fixed = 32 + gen_ym.PLAY_REGISTERS * 32          # YX6_FIXED
    return fixed + gen_ym.PLAY_REGISTERS * ring


def run_shape(frames: int, ring: int, chunk: int, label: str) -> str:
    source = gen_ym.registers(frames)
    packed = pack(gen_ym.ym6_file(frames, source), ring, chunk)
    expected = gen_ym.expected_writes(frames, source)

    player = Player(packed, workspace_size(ring))
    if player.init() != 0:
        return f'{label}: YX6_init rejected the file'

    for frame in range(frames):
        result, writes = player.frame()
        if result != 0:
            return f'{label}: frame {frame} reported the tune as over'
        if writes != expected[frame]:
            return (f'{label}: frame {frame} wrote {writes[:6]}...'
                    f' expected {expected[frame][:6]}...')

    result, writes = player.frame()
    if result != 1 or writes:
        return f'{label}: playing past the end wrote {writes} and returned {result}'

    # A second pass has to be identical: YX6_init is the whole reset.
    if player.init() != 0:
        return f'{label}: re-init rejected the file'
    for frame in range(min(frames, 3 * chunk)):
        _, writes = player.frame()
        if writes != expected[frame]:
            return f'{label}: frame {frame} differs after re-init'
    return ''


def main() -> int:
    shapes = [
        (600, 1024, 16, 'default 1024/16'),
        (600, 256, 16, 'small ring 256/16'),
        (600, 32, 16, 'two-group ring 32/16'),
        (600, 1024, 64, 'long calls 1024/64'),
        (600, 28, 14, 'tightest legal 28/14'),
        (37, 1024, 16, 'shorter than a ring'),
        (16, 1024, 16, 'exactly one group'),
        (9, 1024, 16, 'shorter than one group'),
        (1, 1024, 16, 'a single frame'),
    ]
    if not QUICK:
        shapes.append((4000, 1024, 16, 'four thousand frames'))
        shapes.append((4000, 2048, 32, 'four thousand, 2048/32'))

    failures = 0
    for frames, ring, chunk, label in shapes:
        problem = run_shape(frames, ring, chunk, label)
        if problem:
            print(f'FAIL {problem}')
            failures += 1
        else:
            print(f'OK   {label:24s} ({frames} frames through {ring}-byte rings)')

    print('ALL YX6 PLAYER TESTS PASS' if not failures else f'{failures} FAILURES')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
