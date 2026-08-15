#!/usr/bin/env python3
"""Regenerate and audit the current 68000 cycle and Hatari timing tables.

The ideal-cycle model assembles each decoder, traces the instructions actually
executed under Unicorn's plain 68000 engine, and charges the MC68000 timings.
Hatari data is deliberately never reused automatically: --write requires the
output of a fresh, finite 68k/test/run.sh invocation.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import runpy
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
K68 = REPO / "68k"
TEST = K68 / "test"
DATA_FILE = TEST / "timings.json"
ROOT_README = REPO / "README.md"
TEST_README = TEST / "README.md"
CP = REPO / "target" / "classes"
SCHEMA = 3

NAMES = (
    "text", "wordsoup", "farmatch", "period129", "allsame", "rle32k",
    "maxoffset",
)
ITERATIONS = {
    "text": 400,
    "wordsoup": 30,
    "farmatch": 60,
    "period129": 200,
    "allsame": 200,
    "rle32k": 6,
    "maxoffset": 6,
}

# Exact non-final timed-iteration overhead outside the traced decoder bodies.
# Every value is checked against the corresponding source shape below.  It
# includes the harness's direct-label calls, setup, budget/result loop, and
# outer taken branch.  The final outer BNE is two cycles cheaper.
LINEAR_FIXED = 128
GENERAL_FIXED = 188
EXPECTED_HARNESS_SCOPES = {
    "linear": "4b2357ceda5d66006befec61e00dc17e88b0739f744ccc8745b091e3f2e9b5f5",
    "ring": "12349225ea8f31748e7f01c40e92304d74026933cb201c56c16dfa6edcaaefec",
}


def timing_inputs() -> list[Path]:
    fixed = [
        K68 / "jx1_68000.S",
        K68 / "jx1_68000_ring.S",
        TEST / "gendata.py",
        TEST / "jx1_hatari.S",
        TEST / "jx1_hatari_ring.S",
        TEST / "hatari_util.inc",
        TEST / "run.sh",
        HERE / "cycle_model.py",
        REPO / "pom.xml",
    ]
    return fixed + sorted((REPO / "src" / "main" / "java").rglob("*.java"))


def input_fingerprint() -> str:
    digest = hashlib.sha256()
    for path in timing_inputs():
        relative = path.relative_to(REPO).as_posix().encode()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        content = path.read_bytes()
        digest.update(len(content).to_bytes(8, "big"))
        digest.update(content)
    return digest.hexdigest()


def input_hashes() -> dict[str, str]:
    return {
        path.relative_to(REPO).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in timing_inputs()
    }


def corpora() -> dict[str, bytes]:
    generated = runpy.run_path(str(TEST / "gendata.py"))
    if (generated["RING_SMALL"], generated["RING_FAIR"]) != (256, 1024):
        raise AssertionError("gendata.py timing profiles must remain -m256/-m1024")
    rows = generated["CASES"]
    names = tuple(name for name, _, _ in rows)
    iterations = {name: count for name, _, count in rows}
    if names != NAMES or iterations != ITERATIONS:
        raise AssertionError("gendata.py corpus names or iteration counts changed")
    return {name: data for name, data, _ in rows}


def compress(data: bytes, maximum_offset: int | None) -> bytes:
    if not CP.exists():
        raise SystemExit("target/classes is missing; run `mvn compile` first")
    with tempfile.TemporaryDirectory() as directory:
        source = Path(directory) / "input"
        target = Path(directory) / "output.zx1"
        source.write_bytes(data)
        command = ["java", "-ea", "-cp", str(CP), "org.jx1.Jx1", "-f"]
        if maximum_offset is not None:
            command.append(f"-m{maximum_offset}")
        subprocess.run(command + [str(source), str(target)], check=True,
                       capture_output=True)
        return target.read_bytes()


@dataclass(frozen=True)
class Instruction:
    offset: int
    size: int
    mnemonic: str
    operands: str


def parse_listing(path: Path) -> tuple[dict[int, Instruction], dict[str, int]]:
    instructions: dict[int, Instruction] = {}
    instruction_re = re.compile(
        r"^\s*\d+\s+([0-9A-F]{8})\s+([0-9A-Fx]+)\s+"
        r"(\S+)(?:\s+([^;\s]+))?"
    )
    symbol_re = re.compile(r"^\s*(\S+)\s+([0-9A-F]{16})\s+[atdb]\s*$")
    symbols: dict[str, int] = {}
    for line in path.read_text().splitlines():
        match = instruction_re.match(line)
        if match:
            offset = int(match.group(1), 16)
            encoded = match.group(2)
            instruction = Instruction(
                offset, len(encoded) // 2, match.group(3).lower(),
                (match.group(4) or "").lower(),
            )
            if offset in instructions:
                raise AssertionError(f"duplicate instruction at {offset:#x}")
            instructions[offset] = instruction
            continue
        match = symbol_re.match(line)
        if match:
            symbols[match.group(1)] = int(match.group(2), 16)
    if not instructions:
        raise AssertionError(f"no instructions parsed from {path}")
    return instructions, symbols


CONDITIONALS = {
    "beq", "bne", "bcc", "bcs", "bmi", "bpl", "ble", "bls", "bgt",
    "bge", "blt", "bhi",
}


def fixed_cycles(instruction: Instruction) -> int | None:
    """MC68000 cycles, or None for a conditional branch/DBF."""
    mnemonic = instruction.mnemonic
    root = mnemonic.split(".")[0]
    operands = instruction.operands
    if root in CONDITIONALS or root.startswith("db"):
        return None
    if root == "bra":
        return 10
    if root == "bsr":
        return 18
    if root == "rts":
        return 16
    if root == "jmp" and "(pc," in operands:
        return 14
    if root == "lea" and re.fullmatch(r"[^()]+\(a\d\),a\d", operands):
        return 8
    if root in {"moveq", "swap"}:
        return 4
    if root in {"move", "movea"}:
        source, destination = operands.split(",")
        if re.fullmatch(r"[ad]\d", source) and re.fullmatch(r"[ad]\d", destination):
            return 4
        if (re.fullmatch(r"\(a\d\)\+", source)
                and re.fullmatch(r"d\d", destination)):
            return 12 if mnemonic.endswith(".l") else 8
        if (re.fullmatch(r"\(a\d\)\+", source)
                and re.fullmatch(r"\(a\d\)\+", destination)):
            return 20 if mnemonic.endswith(".l") else 12
        raise KeyError(instruction)
    if root in {"clr", "neg", "tst"} and re.fullmatch(r"d\d", operands):
        return 4
    if root == "addx" and re.fullmatch(r"d\d,d\d", operands):
        return 8 if mnemonic.endswith(".l") else 4
    if root in {"add", "sub", "and", "cmp"}:
        source, destination = operands.split(",")
        if source.startswith("#") and re.fullmatch(r"d\d", destination):
            return 16 if mnemonic.endswith(".l") else 8
        if (re.fullmatch(r"[ad]\d", source)
                and re.fullmatch(r"d\d", destination)):
            return 8 if mnemonic.endswith(".l") else 4
        raise KeyError(instruction)
    if root in {"addq", "subq"} and re.fullmatch(r"#[^,]+,d\d", operands):
        return 8 if mnemonic.endswith(".l") else 4
    if root in {"adda", "suba"}:
        source, destination = operands.split(",")
        if re.fullmatch(r"[ad]\d", source) and re.fullmatch(r"a\d", destination):
            return 8
        raise KeyError(instruction)
    if root in {"lsl", "lsr", "roxr"}:
        match = re.fullmatch(r"#(\d+),d\d", operands)
        if match:
            return 6 + 2 * int(match.group(1))
        raise KeyError(instruction)
    raise KeyError(instruction)


class CycleCounter:
    def __init__(self, emulator, listing: dict[int, Instruction], code_base: int,
                 code_size: int, hook_code: int):
        self.listing = listing
        self.code_base = code_base
        self.cycles = 0
        self.pending: tuple[int, Instruction] | None = None
        emulator.hook_add(hook_code, self._hook, begin=code_base,
                          end=code_base + code_size - 1)

    def _resolve(self, next_address: int) -> None:
        if self.pending is None:
            return
        address, instruction = self.pending
        taken = next_address != address + instruction.size
        if instruction.mnemonic.startswith("db"):
            self.cycles += 10 if taken else 14
        else:
            self.cycles += 10 if taken else (8 if instruction.size == 2 else 12)
        self.pending = None

    def _hook(self, _emulator, address: int, size: int, _data) -> None:
        self._resolve(address)
        offset = address - self.code_base
        instruction = self.listing.get(offset)
        if instruction is None:
            raise AssertionError(f"executed unlisted opcode at {offset:#x}")
        # Unicorn reports two bytes for the 68000's indexed JMP even though
        # its extension word makes the instruction four bytes.  RMAC's fresh
        # listing is authoritative for size and branch fall-through here.
        cycles = fixed_cycles(instruction)
        if cycles is None:
            self.pending = (address, instruction)
        else:
            self.cycles += cycles

    def call_boundary(self) -> None:
        if self.pending is not None:
            raise AssertionError(f"unresolved branch at call boundary: {self.pending}")


def assemble(directory: Path, source: Path):
    stem = source.stem
    binary = directory / f"{stem}.bin"
    listing = directory / f"{stem}.lst"
    command = ["rmac", "-m68000", "-fr", "+o3"]
    command += [f"-l*{listing}", "-o", str(binary), str(source)]
    subprocess.run(command, check=True, capture_output=True)
    instructions, symbols = parse_listing(listing)
    return binary.read_bytes(), instructions, symbols


def make_emulator(binary: bytes, compressed: bytes):
    # Imports are lazy so --fingerprint/--audit stay cheap and cannot invoke
    # Unicorn's host-CPU probe.
    from unicorn import Uc, UC_ARCH_M68K, UC_MODE_BIG_ENDIAN
    from unicorn.m68k_const import UC_CPU_M68K_M68000

    code, src, dst, stack_top, magic = 0x1000, 0x40000, 0x80000, 0xF8000, 0xE0000
    emulator = Uc(UC_ARCH_M68K, UC_MODE_BIG_ENDIAN)
    emulator.ctl_set_cpu_model(UC_CPU_M68K_M68000)
    for base, size in ((code, 0x1000), (src, 0x10000), (dst, 0x20000),
                       (stack_top - 0x4000, 0x8000), (magic, 0x1000)):
        emulator.mem_map(base, size)
    emulator.mem_write(code, binary)
    emulator.mem_write(src, compressed)
    return emulator, code, src, dst, stack_top, magic


def call(emulator, entry: int, stack_top: int, magic: int, pc_register: int,
         a7_register: int) -> None:
    stack = stack_top - 256
    emulator.mem_write(stack, magic.to_bytes(4, "big"))
    emulator.reg_write(a7_register, stack)
    emulator.reg_write(pc_register, entry)
    emulator.emu_start(entry, magic, count=200_000_000)
    if emulator.reg_read(pc_register) != magic:
        raise AssertionError("decoder call did not return")


def trace_decoder(binary: bytes, listing: dict[int, Instruction], symbols: dict[str, int],
                  compressed: bytes, expected: bytes, variant: str, chunk: int,
                  ring_size: int | None = None) -> dict[str, int]:
    from unicorn import UC_HOOK_CODE
    from unicorn.m68k_const import (
        UC_M68K_REG_A0, UC_M68K_REG_A1, UC_M68K_REG_A7,
        UC_M68K_REG_D1, UC_M68K_REG_D3, UC_M68K_REG_PC,
    )

    emulator, code, src, dst, stack_top, magic = make_emulator(binary, compressed)
    counter = CycleCounter(emulator, listing, code, len(binary), UC_HOOK_CODE)
    emulator.reg_write(UC_M68K_REG_A0, src)

    if variant == "linear":
        ring = dst
        ring_end = None
    elif variant == "ring":
        ring = dst + 11
        ring_end = ring + int(ring_size)
    else:
        raise AssertionError(f"unknown decoder variant {variant}")
    emulator.reg_write(UC_M68K_REG_A1, ring)
    if variant == "ring":
        emulator.reg_write(UC_M68K_REG_D3, ring_end)

    call(emulator, code + symbols["jx1_init"], stack_top, magic,
         UC_M68K_REG_PC, UC_M68K_REG_A7)
    counter.call_boundary()

    output = bytearray()
    previous = ring
    calls = 0
    while True:
        calls += 1
        prior = emulator.reg_read(UC_M68K_REG_D3)
        emulator.reg_write(UC_M68K_REG_D3, (prior & 0xFFFF0000) | chunk)
        call(emulator, code + symbols["jx1_resume"], stack_top, magic,
             UC_M68K_REG_PC, UC_M68K_REG_A7)
        counter.call_boundary()
        current = emulator.reg_read(UC_M68K_REG_A1)
        emitted = current - previous
        if not 0 <= emitted <= chunk:
            raise AssertionError(f"{variant}: invalid emission {emitted}")
        output.extend(emulator.mem_read(previous, emitted))
        more = emulator.reg_read(UC_M68K_REG_D1) & 0xFFFF
        if ring_end is not None and current == ring_end:
            previous = ring
        else:
            previous = current
        if more == 0:
            break

    if bytes(output) != expected:
        raise AssertionError(f"{variant}: output mismatch")
    if calls != math.ceil(len(expected) / chunk):
        raise AssertionError(f"{variant}: unexpected call count {calls}")
    if emulator.reg_read(UC_M68K_REG_A0) - src != len(compressed):
        raise AssertionError(f"{variant}: compressed input not consumed exactly")
    return {"internal": counter.cycles, "calls": calls}


def _label(text: str, name: str, start: int = 0) -> int:
    match = re.search(rf"(?m)^{re.escape(name)}", text[start:])
    if match is None:
        raise AssertionError(f"timing harness label not found: {name}")
    return start + match.start()


def _normalized_assembly(text: str) -> str:
    return "\n".join(
        " ".join(line.split(";", 1)[0].split())
        for line in text.splitlines()
        if line.split(";", 1)[0].strip()
    )


def harness_scope_hashes() -> dict[str, str]:
    linear = (TEST / "jx1_hatari.S").read_text()
    ring = (TEST / "jx1_hatari_ring.S").read_text()
    linear_time = _label(linear, "time_case:")
    linear_loop = _label(linear, ".loop:", linear_time)
    linear_elapsed = linear.index("bsr     elapsed", linear_loop)
    linear_scope = (
        linear[_label(linear, "run_resume:"):_label(linear, "run_resume_poison:")]
        + linear[_label(linear, "resume_setup:"):_label(linear, "verify:")]
        + linear[linear_loop:linear_elapsed]
    )
    ring_time = _label(ring, "time_ring:")
    ring_loop = _label(ring, ".loop:", ring_time)
    ring_elapsed = ring.index("bsr     elapsed", ring_loop)
    ring_scope = ring[_label(ring, "ring_init:"):ring_time] + ring[ring_loop:ring_elapsed]
    return {
        "linear": hashlib.sha256(
            _normalized_assembly(linear_scope).encode()).hexdigest(),
        "ring": hashlib.sha256(
            _normalized_assembly(ring_scope).encode()).hexdigest(),
    }


def assert_harness_shapes() -> None:
    current = harness_scope_hashes()
    if current != EXPECTED_HARNESS_SCOPES:
        raise AssertionError(
            "timed caller assembly changed; review its cycle constants and update "
            f"EXPECTED_HARNESS_SCOPES ({current})"
        )


def build_model() -> dict:
    assert_harness_shapes()
    data = corpora()
    streams = {
        "normal": {name: compress(content, None) for name, content in data.items()},
        "m256": {name: compress(content, 256) for name, content in data.items()},
        "m1024": {name: compress(content, 1024) for name, content in data.items()},
    }
    rows: dict[str, dict[str, dict[str, int]]] = {
        "linear": {"m256/16": {}, "m1024/16": {}, "m1024/127": {}},
        "ring": {"256/16": {}, "1024/16": {}},
    }
    binaries: dict[str, dict[str, str | int]] = {}
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        assembled = {}
        for key, source in (
            ("linear", K68 / "jx1_68000.S"),
            ("ring", K68 / "jx1_68000_ring.S"),
        ):
            binary, listing, symbols = assemble(directory, source)
            assembled[key] = (binary, listing, symbols)
            binaries[key] = {
                "bytes": len(binary),
                "sha256": hashlib.sha256(binary).hexdigest(),
            }

        for name in NAMES:
            expected = data[name]
            for chunk in (16, 127):
                binary, listing, symbols = assembled["linear"]
                trace = trace_decoder(binary, listing, symbols,
                                      streams["m1024"][name], expected,
                                      "linear", chunk)
                common = 36 * trace["calls"] - 2
                rows["linear"][f"m1024/{chunk}"][name] = (
                    trace["internal"] + common + LINEAR_FIXED
                )

            binary, listing, symbols = assembled["linear"]
            trace = trace_decoder(binary, listing, symbols,
                                  streams["m256"][name], expected,
                                  "linear", 16)
            rows["linear"]["m256/16"][name] = (
                trace["internal"] + 36 * trace["calls"] - 2 + LINEAR_FIXED
            )

            binary, listing, symbols = assembled["ring"]
            for size, profile in ((256, "m256"), (1024, "m1024")):
                trace = trace_decoder(binary, listing, symbols,
                                      streams[profile][name], expected,
                                      "ring", 16, size)
                rows["ring"][f"{size}/16"][name] = (
                    trace["internal"] + 36 * trace["calls"] - 2 + GENERAL_FIXED
                )

    return {"cycles": rows, "binaries": binaries,
            "streams": {
                profile: {
                    name: {
                        "bytes": len(value),
                        "sha256": hashlib.sha256(value).hexdigest(),
                    }
                    for name, value in profile_streams.items()
                }
                for profile, profile_streams in streams.items()
            },
            "output": {name: len(value) for name, value in data.items()}}


def parse_hatari(text: str, expected_fingerprint: str) -> dict:
    if "BAD" in text:
        raise ValueError("Hatari output contains BAD")
    section: str | None = None
    banners: list[str] = []
    calibration_blocks: dict[int, dict[str, int]] = {}
    ticks = {
        "linear": {"m1024/16": {}, "m1024/127": {}},
        "ring": {"1024/16": {}},
    }
    fingerprints: list[str] = []
    for raw in text.replace("\r", "").splitlines():
        line = raw.strip()
        if line.startswith("TIMING_INPUT "):
            fields = line.split()
            if len(fields) != 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[1]):
                raise ValueError(f"invalid timing fingerprint line: {line}")
            fingerprints.append(fields[1])
        elif line == "JX1 ST TEST":
            section = "linear"
            banners.append(section)
        elif line == "JX1 ST RING TEST":
            section = "ring"
            banners.append(section)
        elif line.startswith("CALIB "):
            fields = line.split()
            if section is None or len(fields) != 3:
                raise ValueError(f"unscoped calibration line: {line}")
            run_index = len(banners) - 1
            if run_index in calibration_blocks:
                raise ValueError(f"duplicate calibration line: {line}")
            calibration_blocks[run_index] = {
                "outer": int(fields[1]), "ticks": int(fields[2])}
            if int(fields[1]) != 12:
                raise ValueError(f"calibration loop count changed: {line}")
        elif line.startswith("T "):
            fields = line.split()
            if section == "linear" and len(fields) == 5:
                _, name, chunk, iterations, value = fields
                key = f"m1024/{chunk}"
                if name not in NAMES or key not in ticks["linear"]:
                    raise ValueError(f"unexpected linear timing row: {line}")
                if name in ticks["linear"][key]:
                    raise ValueError(f"duplicate timing row: {line}")
                ticks["linear"][key][name] = int(value)
                if int(iterations) != ITERATIONS[name]:
                    raise ValueError(f"iteration count changed: {line}")
            elif section == "ring" and len(fields) == 6:
                _, name, size, chunk, iterations, value = fields
                key = f"{size}/{chunk}"
                if name not in NAMES or key not in ticks[section]:
                    raise ValueError(f"unexpected ring timing row: {line}")
                if name in ticks[section][key]:
                    raise ValueError(f"duplicate timing row: {line}")
                ticks[section][key][name] = int(value)
                if int(iterations) != ITERATIONS[name]:
                    raise ValueError(f"iteration count changed: {line}")
            else:
                raise ValueError(f"unrecognized timing line: {line}")
    expected_rows = (
        ticks["linear"]["m1024/16"], ticks["linear"]["m1024/127"],
        ticks["ring"]["1024/16"],
    )
    if any(tuple(row) != NAMES for row in expected_rows):
        raise ValueError("Hatari output is incomplete or corpus order changed")
    if banners != ["linear", "ring"]:
        raise ValueError(f"unexpected Hatari program sequence: {banners}")
    if text.count("DONE") != 2:
        raise ValueError("expected both Hatari executables to reach DONE")
    if tuple(calibration_blocks) != (0, 1):
        raise ValueError("expected two Hatari calibration lines")
    if fingerprints != [expected_fingerprint]:
        raise ValueError(
            "Hatari output was not produced from the current timing inputs"
        )
    calibrations = {
        key: calibration_blocks[index]
        for index, key in enumerate(("linear", "ring"))
    }
    return {"ticks": ticks, "calibration": calibrations,
            "iterations": ITERATIONS}


def percent_change(value: int, baseline: int) -> str:
    change = 100 * (value / baseline - 1)
    prefix = "+" if change > 0 else ""
    return f"{prefix}{change:.1f}%"


def comparison_cell(value: int, baseline: int) -> str:
    return f"{value:,} ({percent_change(value, baseline)})"


def render_root(data: dict) -> str:
    cycles = data["model"]["cycles"]
    lines = [
        f"<!-- Generated by 68k/test/emu/cycle_model.py; inputs {data['fingerprint'][:12]} -->",
        "Fair N=1024, X=16 resume comparison on identical `-m1024` streams.",
        "Linear means `jx1_resume` at X=16, not the one-shot entry. Values",
        "are ideal plain-MC68000 cycles for the decoder plus its required",
        "resume-loop control flow; the ring cell shows its cost versus linear.",
        "",
        "| corpus | linear | general ring |",
        "|---|---:|---:|",
    ]
    for name in NAMES:
        linear = cycles["linear"]["m1024/16"][name]
        lines.append(
            f"| {name} | {linear:,} | "
            f"{comparison_cell(cycles['ring']['1024/16'][name], linear)} |"
        )
    lines += [
        "",
        "The matching hardware measurements, stream-size cost, and regeneration",
        "command are in [68k/test/README.md](68k/test/README.md).",
    ]
    return "\n".join(lines)


def render_test(data: dict) -> str:
    model = data["model"]
    cycles = model["cycles"]
    streams = model["streams"]
    output = model["output"]
    ticks = data["hatari"]["ticks"]
    lines = [
        f"<!-- Generated by emu/cycle_model.py; inputs {data['fingerprint'][:12]} -->",
        "### Fair N=1024, X=16 comparison",
        "",
        "Every decoder receives the exact same `-m1024` bytes. Linear means its",
        "resumable entry at X=16, not the faster one-shot entry. The totals include",
        "the decoder and only the control flow its harness needs to resume and wrap;",
        "application-specific consumption is excluded for both. The ring cells show",
        "the cycle cost relative to same-stream linear.",
        "",
        "| corpus | output | stream | linear | general ring |",
        "|---|---:|---:|---:|---:|",
    ]
    for name in NAMES:
        linear = cycles["linear"]["m1024/16"][name]
        lines.append(
            f"| {name} | {output[name]} | {streams['m1024'][name]['bytes']} | "
            f"{linear:,} | {comparison_cell(cycles['ring']['1024/16'][name], linear)} |"
        )
    lines += [
        "",
        "The model assembles the current sources and charges every executed",
        "instruction using plain-MC68000 timings. Each cell is one non-final",
        "iteration of the harness's timed core: setup, direct-label init/resume",
        "calls, budget/result loop, ring wrapping, and the taken outer branch.",
        "The final iteration is two cycles cheaper, so a complete run is",
        "`iterations × cell - 2`. Tick-edge synchronization, OS interrupts,",
        "wait states, and video-DMA contention are outside the model.",
        "",
        "The same finite `run.sh` pass measured the comparison under cycle-exact",
        "Hatari using the Atari ST's 200 Hz clock. Each value has ±1-tick",
        "resolution; percentages here are",
        "therefore less precise than the exact model above.",
        "",
        "| corpus | repeats | linear ticks | general ring ticks |",
        "|---|---:|---:|---:|",
    ]
    for name in NAMES:
        linear = ticks["linear"]["m1024/16"][name]
        lines.append(
            f"| {name} | {ITERATIONS[name]} | {linear} | "
            f"{comparison_cell(ticks['ring']['1024/16'][name], linear)} |"
        )
    lines += [
        "",
        "### Compressor-window cost",
        "",
        "This is a compressor trade-off, not decoder overhead. Sizes are recorded",
        "separately so they cannot distort either comparison above.",
        "",
        "| corpus | normal | `-m1024` (change) | `-m256` (change) |",
        "|---|---:|---:|---:|",
    ]
    for name in NAMES:
        normal = streams["normal"][name]["bytes"]
        m1024 = streams["m1024"][name]["bytes"]
        m256 = streams["m256"][name]["bytes"]
        lines.append(
            f"| {name} | {normal} | {comparison_cell(m1024, normal)} | "
            f"{comparison_cell(m256, normal)} |"
        )
    lines += [
        "",
        "A tick is 5 ms (40,000 nominal 8 MHz cycles); raw ticks",
        "include interrupt and bus-contention time, while the model does not.",
        "",
        "Regenerate both tables after any decoder, compressor, corpus, model, or",
        "harness change:",
        "",
        "```sh",
        "mvn compile",
        "HATARI=/path/to/hatari TOS=/path/to/tos.img 68k/test/run.sh > /tmp/jx1-hatari.out",
        "python3 68k/test/emu/cycle_model.py --write --hatari-output /tmp/jx1-hatari.out",
        "python3 68k/test/emu/cycle_model.py --check",
        "```",
        "",
        "`audit.py` checks the recorded input fingerprint, so changing any timed",
        "input without regenerating the model and hardware tables fails the normal",
        "documentation audit.",
    ]
    return "\n".join(lines)


def replace_block(path: Path, name: str, body: str) -> None:
    text = path.read_text()
    begin = f"<!-- {name}:begin -->"
    end = f"<!-- {name}:end -->"
    pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.S)
    replacement = begin + "\n" + body.rstrip() + "\n" + end
    updated, count = pattern.subn(replacement, text)
    if count != 1:
        raise SystemExit(f"expected one {name} block in {path}")
    path.write_text(updated)


def docs_match(data: dict, verbose: bool = True) -> bool:
    expected = ((ROOT_README, "68k-timings", render_root(data)),
                (TEST_README, "cycle-timings", render_test(data)))
    good = True
    for path, name, body in expected:
        begin = f"<!-- {name}:begin -->"
        end = f"<!-- {name}:end -->"
        match = re.search(re.escape(begin) + r"\n(.*?)\n" + re.escape(end),
                          path.read_text(), re.S)
        current = match.group(1) if match else None
        if current != body.rstrip():
            good = False
            if verbose:
                print(f"STALE {path.relative_to(REPO)} ({name})")
    return good


def load_data() -> dict:
    if not DATA_FILE.exists():
        raise SystemExit(f"missing {DATA_FILE.relative_to(REPO)}")
    data = json.loads(DATA_FILE.read_text())
    if data.get("schema") != SCHEMA:
        raise SystemExit(
            f"unsupported {DATA_FILE.relative_to(REPO)} schema "
            f"{data.get('schema')!r}; expected {SCHEMA}"
        )
    return data


def audit_only() -> bool:
    data = load_data()
    good = True
    current = input_fingerprint()
    if data.get("fingerprint") != current:
        print("STALE 68k timing inputs changed; run cycle_model.py --write with fresh Hatari output")
        good = False
    if not docs_match(data):
        good = False
    return good


def main() -> None:
    parser = argparse.ArgumentParser()
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--fingerprint", action="store_true")
    action.add_argument("--audit", action="store_true")
    action.add_argument("--check", action="store_true")
    action.add_argument("--write", action="store_true")
    parser.add_argument("--hatari-output", type=Path)
    args = parser.parse_args()

    if args.fingerprint:
        print(input_fingerprint())
        return
    if args.audit:
        raise SystemExit(0 if audit_only() else 1)
    if args.write and args.hatari_output is None:
        parser.error("--write requires --hatari-output from a fresh run.sh pass")

    fingerprint = input_fingerprint()
    if args.check:
        recorded = load_data()
        if recorded.get("fingerprint") != fingerprint:
            raise SystemExit(
                "timing inputs changed; run --write with fresh Hatari output"
            )
        current_model = build_model()
        if current_model != recorded.get("model"):
            raise SystemExit("recorded cycle model differs from a fresh trace")
        if not docs_match(recorded):
            raise SystemExit(1)
        print("PASS current cycle model and timing tables")
        return

    hatari = parse_hatari(args.hatari_output.read_text(errors="replace"), fingerprint)
    model = build_model()
    data = {"schema": SCHEMA, "fingerprint": fingerprint,
            "inputs": input_hashes(),
            "model": model, "hatari": hatari}
    DATA_FILE.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")
    replace_block(ROOT_README, "68k-timings", render_root(data))
    replace_block(TEST_README, "cycle-timings", render_test(data))
    print(f"wrote {DATA_FILE.relative_to(REPO)} and both README timing tables")


if __name__ == "__main__":
    main()
