#!/usr/bin/env python3
"""Operation-length boundaries: the one thing the corpora cannot reach.

The 68k decoders hold `remaining` in a word and accumulate gamma values in
d1.w, so a single literal run or match has a representable maximum. The
compressor's corpora never produce an operation near it - the largest is
32000 bytes - so this script hand-authors streams with one operation of an
exact length, which is the only way to sit on the boundary.

Every stream is validated against the Java decompressor first: if the
reference cannot decode it, the stream is wrong and no 68k result from it
means anything.

Usage: boundaries.py [--verbose]
"""
import subprocess
import sys
import tempfile
from pathlib import Path

VERBOSE = '--verbose' in sys.argv or '-v' in sys.argv
sys.argv = [sys.argv[0]]                      # test68k reads argv for its binary
sys.path.insert(0, str(Path(__file__).resolve().parent))
import test68k as t                                                    # noqa: E402
from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN               # noqa: E402
from unicorn.m68k_const import (UC_CPU_M68K_M68000,                    # noqa: E402
                                UC_M68K_REG_A0, UC_M68K_REG_A1,
                                UC_M68K_REG_D1, UC_M68K_REG_D2,
                                UC_M68K_REG_D3)


def make_emu(stream):
    """Like test68k.make_emu, but the input area holds a 64 KB literal run."""
    uc = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
    uc.ctl_set_cpu_model(UC_CPU_M68K_M68000)
    for base, size in ((t.CODE, 0x1000), (t.CTX, 0x1000), (t.SRC, 0x20000),
                       (t.DST, 0x20000), (t.STACK_TOP - 0x4000, 0x8000),
                       (t.MAGIC, 0x1000)):
        uc.mem_map(base, size)
    uc.mem_write(t.CODE, bytes(t.BIN))
    uc.mem_write(t.SRC, stream)
    return uc

# The contract these tests pin. A single operation carries its length as one
# interlaced Elias gamma value, decoded into a word, so lengths above this
# cannot be represented - see LIMITS below for what each operation actually
# encodes.
MAX_OP = 65535


class Writer:
    """The bit/byte layout of Compressor.java, mirrored exactly."""

    def __init__(self):
        self.out = bytearray()
        self.mask = 0
        self.bit_index = 0

    def byte(self, value):
        self.out.append(value & 0xFF)

    def bit(self, value):
        if self.mask == 0:
            self.mask = 128
            self.bit_index = len(self.out)
            self.byte(0)
        if value:
            self.out[self.bit_index] |= self.mask
        self.mask >>= 1

    def gamma(self, value):
        assert value >= 1, value
        i = (1 << (value.bit_length() - 1)) >> 1
        while i:
            self.bit(1)
            self.bit(value & i)
            i >>= 1
        self.bit(0)

    def end(self):
        self.bit(1)             # a new-offset match whose offset is the end
        self.byte(255)          # marker
        self.byte(255)
        return bytes(self.out)


def literal_stream(length):
    """One opening literal run of exactly `length` bytes."""
    w = Writer()
    w.gamma(length)                             # the stream opens with a literal,
    payload = bytes((i * 7 + 11) & 0xFF for i in range(length))
    for b in payload:                           # so it carries no leading bit
        w.byte(b)
    return w.end(), payload


def new_match_stream(length):
    """A one-byte literal, then a new-offset match of exactly `length`."""
    w = Writer()
    w.gamma(1)
    w.byte(ord('Q'))
    w.bit(1)                                    # new offset
    w.byte(256 - 1 * 2)                         # offset 1, the one-byte form
    w.gamma(length - 1)                         # new-offset matches encode L-1
    return w.end(), b'Q' * (1 + length)


def last_match_stream(length):
    """A one-byte literal, then a last-offset match of exactly `length`.

    The format alternates: after a literal run a 0 bit is a match at the last
    offset, which here is still INITIAL_OFFSET = 1. (After a *match* the same
    0 bit means literals instead, which is what makes this the only place a
    last-offset match can be reached in two operations.)
    """
    w = Writer()
    w.gamma(1)
    w.byte(ord('Q'))
    w.bit(0)                                    # last offset, length as gamma
    w.gamma(length)
    return w.end(), b'Q' * (1 + length)


# What each operation's gamma encodes, and therefore where it overflows a word.
LIMITS = {
    'literal':    (literal_stream,    'gamma(L)'),
    'new-match':  (new_match_stream,  'gamma(L-1), decoder adds 1'),
    'last-match': (last_match_stream, 'gamma(L)'),
}
LENGTHS = [32767, 32768, 32769, 65534, 65535, 65536, 65537]


def java_decompress(stream):
    """The reference. Returns None when Java itself rejects the stream.

    Cached like the compressed streams, and keyed the same way, so a recompiled
    Java side regenerates every reference rather than being checked against
    itself from before the change.
    """
    import hashlib
    key = t.CACHE / f'{t.COMPRESSOR}-ref-{hashlib.sha1(stream).hexdigest()[:16]}.bin'
    if key.exists():
        return key.read_bytes() or None
    with tempfile.TemporaryDirectory() as d:
        src, dst = Path(d, 'in.zx1'), Path(d, 'out.bin')
        src.write_bytes(stream)
        r = subprocess.run(['java', '-ea', '-cp', t.CP, 'org.jx1.Djx1', '-f',
                            str(src), str(dst)], capture_output=True, text=True)
        out = dst.read_bytes() if r.returncode == 0 and dst.exists() else b''
    t.CACHE.mkdir(exist_ok=True)
    key.write_bytes(out)
    return out or None


def run_linear(stream, chunk=None):
    uc = make_emu(stream)
    uc.reg_write(UC_M68K_REG_A0, t.SRC)
    uc.reg_write(UC_M68K_REG_A1, t.DST)
    if chunk is None:
        t.call(uc, t.CODE + 4)                                  # jx1_decompress
        return bytes(uc.mem_read(t.DST, uc.reg_read(UC_M68K_REG_A1) - t.DST))
    t.call(uc, t.CODE)
    t.seed_word_state_highs(uc)
    calls = 0
    while True:
        uc.reg_write(UC_M68K_REG_D3, 0xBEEF0000 | chunk)
        more = t.call(uc, t.CODE + 8)
        t.assert_word_state_highs(uc)
        if more == 0:
            break
        calls += 1
        assert calls < 200000, 'resume loop does not terminate'
    end = uc.reg_read(UC_M68K_REG_A1)      # not a context: DONE is encoded in
    return bytes(uc.mem_read(t.DST, end - t.DST))   # the state registers


def run_ring(stream, n, chunk, ring=t.DST, caller_wrap=True):
    uc = make_emu(stream)
    uc.reg_write(UC_M68K_REG_A0, t.SRC)
    uc.reg_write(UC_M68K_REG_A1, ring)
    uc.reg_write(UC_M68K_REG_D3, ring + n)       # transient init bound
    t.call(uc, t.CODE)
    assert uc.reg_read(UC_M68K_REG_D1) >> 16 == ((-ring) & 0xFFFF), \
        'packed -start.low was not initialized'
    assert uc.reg_read(UC_M68K_REG_D2) >> 16 == ((ring + n) & 0xFFFF), \
        'packed end.low was not initialized'
    out, prev, calls = bytearray(), ring, 0
    while True:
        uc.reg_write(UC_M68K_REG_D3, 0xBEEF0000 | chunk)
        more = t.call(uc, t.CODE + 4)
        dst = uc.reg_read(UC_M68K_REG_A1)
        out += uc.mem_read(prev, dst - prev)
        assert uc.reg_read(UC_M68K_REG_D1) >> 16 == ((-ring) & 0xFFFF), \
            'packed -start.low changed'
        assert uc.reg_read(UC_M68K_REG_D2) >> 16 == ((ring + n) & 0xFFFF), \
            'packed end.low changed'
        if dst == ring + n:
            if caller_wrap:
                uc.reg_write(UC_M68K_REG_A1, ring)
            prev = ring
        else:
            prev = dst
        calls += 1
        assert calls < 200000, 'resume loop does not terminate'
        if more == 0:
            return bytes(out)


def check_crossing_general_ring():
    """Pin the hardest low-word position case in the general ring.

    N=65535 with packed -start.low deliberately crosses a 64-K address
    boundary, and the 65536-byte output fills the ring once before copying the
    final byte after caller wrap.
    """
    stream, expected = new_match_stream(MAX_OP)
    ring = t.DST + 0x8001
    assert (ring >> 16) != ((ring + MAX_OP) >> 16)
    if java_decompress(stream) != expected:
        print('BAD STREAM general ring 64-K crossing: Java reference mismatch')
        return 1
    t.BIN = t._binary('jx1_68000_ring.bin')
    for caller_wrap in (True, False):
        try:
            got = run_ring(stream, MAX_OP, 32768, ring=ring,
                           caller_wrap=caller_wrap)
        except Exception as e:
            mode = 'caller' if caller_wrap else 'decoder'
            print(f'FAIL general ring 64-K crossing ({mode}-wrap): '
                  f'{type(e).__name__}: {e}')
            return 1
        if got != expected:
            mode = 'caller' if caller_wrap else 'decoder'
            print(f'FAIL general ring 64-K crossing ({mode}-wrap): '
                  f'{len(got)} bytes, expected {len(expected)}')
            return 1
    if VERBOSE:
        print('  general ring N=65535 across 64-K boundary: both wrap modes correct')
    return 0


# The largest chunk the contract allows, because these outputs are up to 65537
# bytes: what matters here is that an operation survives being carried across
# calls, not how many calls that takes - chunk 16 would be 4096 emulated calls
# per case and eight times the runtime for the same property.
DECODERS = [
    ('jx1_68000.bin',          lambda s: run_linear(s)),
    ('jx1_68000.bin',          lambda s: run_linear(s, 127)),
    ('jx1_68000_ring.bin',     lambda s: run_ring(s, 1024, 127)),
]
NAMES = ['linear one-shot', 'linear X=127', 'ring 1024/127']


def jx1_compress(data, flags):
    """The compressor's own -lN mode; returns None when it refuses the input.

    Cached like every other stream here: these inputs are 70-100 KB of one
    repeated byte, which is the shape optimal parsing is slowest on.
    """
    import hashlib
    key = t.CACHE / (f'{t.COMPRESSOR}-cap{"".join(flags).replace("-", "_")}-'
                     f'{hashlib.sha1(data).hexdigest()[:16]}.zx1')
    if key.exists():
        return key.read_bytes() or None
    with tempfile.TemporaryDirectory() as d:
        src, dst = Path(d, 'in.bin'), Path(d, 'out.zx1')
        src.write_bytes(data)
        r = subprocess.run(['java', '-ea', '-cp', t.CP, 'org.jx1.Jx1', '-f'] + flags
                           + [str(src), str(dst)], capture_output=True, text=True)
        out = dst.read_bytes() if r.returncode == 0 else b''
    t.CACHE.mkdir(exist_ok=True)
    key.write_bytes(out)
    return out or None


# Inputs whose optimal parse contains an operation the 68k cannot represent.
# Compressed with -l65535 they must become 68k-safe; without it they must not,
# which is the whole reason the flag exists.
CAPPED = [
    ('one 69999-byte match', b'Q' * 70000, ['-m1']),
    ('two capped matches',   b'Q' * 100000, ['-m1']),
    ('capped, tiny ops',     b'Q' * 70000, ['-m1', '-l1000']),
]


def check_capped_mode():
    """-l65535 makes streams the plain mode cannot express on a 68000."""
    failures = 0
    t.BIN = t._binary('jx1_68000.bin')
    for name, data, flags in CAPPED:
        capped = flags if any(f.startswith('-l') for f in flags) else flags + ['-l65535']
        stream = jx1_compress(data, capped)
        if stream is None:
            print(f'FAIL {name}: the compressor refused {" ".join(capped)}')
            failures += 1
            continue
        got = run_linear(stream)
        if got != data:
            print(f'FAIL {name}: {" ".join(capped)} produced {len(got)} bytes, '
                  f'expected {len(data)}')
            failures += 1
        elif VERBOSE:
            print(f'  {name:22s} {" ".join(capped):18s}: {len(data)} bytes, '
                  f'{len(stream)}-byte stream, decodes')
        if not any(f.startswith('-l') for f in flags):        # and the same input
            plain = jx1_compress(data, flags)                 # without the cap is
            if plain is not None and run_linear(plain) == data:  # expected to break
                print(f'FAIL {name}: {" ".join(flags)} decoded correctly, so the '
                      f'cap is no longer testing anything')
                failures += 1
    return failures


def main():
    failures, rows = 0, []
    for op, (build, encoding) in LIMITS.items():
        for length in LENGTHS:
            stream, expected = build(length)
            reference = java_decompress(stream)
            if reference != expected:                 # our encoder, not the 68k
                print(f'BAD STREAM {op} L={length}: Java says '
                      f'{len(reference) if reference else "reject"}, '
                      f'expected {len(expected)}')
                failures += 1
                continue
            for (binary, run), name in zip(DECODERS, NAMES):
                t.BIN = t._binary(binary)
                try:
                    got = run(stream)
                    ok = got == expected
                    detail = f'{len(got)} bytes'
                except Exception as e:               # a runaway or a bad read
                    ok, detail = False, f'{type(e).__name__}: {e}'
                within = length <= MAX_OP
                if ok != within:
                    print(f'FAIL {op:11s} L={length:6d} {name:17s}: '
                          f'{"truncated" if within else "unexpectedly decoded"} '
                          f'({detail})')
                    failures += 1
                elif VERBOSE:
                    print(f'  {op:11s} L={length:6d} {name:17s}: '
                          f'{"decodes" if ok else "refuses (as documented)"}')
            rows.append((op, length, encoding))
    failures += check_crossing_general_ring()
    failures += check_capped_mode()
    kept = sorted({l for _, l, _ in rows if l <= MAX_OP})
    print(f'{"ALL BOUNDARY TESTS PASS" if not failures else f"{failures} FAILURES"}'
          f' - operations up to {MAX_OP} decode identically on all three paths '
          f'({len(LIMITS)} operation kinds x {len(LENGTHS)} lengths, '
          f'{max(kept)} the largest representable; {len(CAPPED)} capped-mode '
          f'streams; general N=65535 64-K crossing)')
    return 1 if failures else 0


if __name__ == '__main__':
    sys.exit(main())
