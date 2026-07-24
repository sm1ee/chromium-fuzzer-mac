#!/usr/bin/env python3
"""Validate seed packets and derive bounded deterministic H.264 candidates."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import sys
from typing import Any


SCHEMA = "chromium-media-h264-seed-packet-v1"
TARGET = "media_h264_decoder_fuzzer"
GENERATOR_SCHEMA = "bounded-h264-nal-mutation-v1"


def canonical_hash(value: Any) -> str:
    raw = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(raw).hexdigest()


def load_packet(path: pathlib.Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("packet-not-object")
    source = value.get("source")
    routing = value.get("routing")
    generator = value.get("generator")
    if value.get("schema") != SCHEMA:
        raise ValueError("schema")
    if not isinstance(source, dict):
        raise ValueError("source")
    if source.get("kind") not in {"issue_corpus", "fresh_fix", "manual"}:
        raise ValueError("source.kind")
    for field in ("id", "title"):
        if not isinstance(source.get(field), str) or not source[field]:
            raise ValueError(f"source.{field}")
    if not isinstance(routing, dict) or routing.get("target") != TARGET:
        raise ValueError("routing.target")
    if not isinstance(routing.get("mechanism"), str) or not routing["mechanism"]:
        raise ValueError("routing.mechanism")
    if not isinstance(generator, dict):
        raise ValueError("generator")
    if generator.get("schema") != GENERATOR_SCHEMA:
        raise ValueError("generator.schema")
    if generator.get("base") != "existing-admitted-corpus":
        raise ValueError("generator.base")
    count = generator.get("candidate_count")
    max_bytes = generator.get("max_input_bytes")
    if not isinstance(count, int) or not 1 <= count <= 8:
        raise ValueError("generator.candidate_count")
    if not isinstance(max_bytes, int) or not 64 <= max_bytes <= 4096:
        raise ValueError("generator.max_input_bytes")
    if value.get("auto_promote") is not False:
        raise ValueError("auto_promote")
    if value.get("human_triage_required") is not True:
        raise ValueError("human_triage_required")
    identity = {
        "schema": SCHEMA,
        "source_kind": source["kind"],
        "source_id": source["id"],
        "target": routing["target"],
        "generator_schema": generator["schema"],
    }
    packet_id = value.get("packet_id")
    if not isinstance(packet_id, str) or not re.fullmatch(r"[0-9a-f]{64}", packet_id):
        raise ValueError("packet_id")
    if canonical_hash(identity) != packet_id:
        raise ValueError("packet_id_mismatch")
    return value


def start_codes(data: bytes) -> list[tuple[int, int]]:
    found: list[tuple[int, int]] = []
    index = 0
    while index + 3 <= len(data):
        if data[index : index + 4] == b"\x00\x00\x00\x01":
            found.append((index, 4))
            index += 4
        elif data[index : index + 3] == b"\x00\x00\x01":
            found.append((index, 3))
            index += 3
        else:
            index += 1
    return found


def protected_offsets(data: bytes) -> set[int]:
    protected: set[int] = set()
    for offset, width in start_codes(data):
        protected.update(range(offset, min(len(data), offset + width + 1)))
    return protected


def deterministic_positions(
    data: bytes, protected: set[int], digest: bytes, count: int
) -> list[int]:
    available = [index for index in range(len(data)) if index not in protected]
    if not available:
        return []
    result: list[int] = []
    for index in range(count):
        word = int.from_bytes(digest[(index * 4) % 28 : (index * 4) % 28 + 4], "big")
        result.append(available[word % len(available)])
    return result


def mutate(data: bytes, digest: bytes, variant: int, max_bytes: int) -> bytes:
    source = bytearray(data[:max_bytes])
    if not source:
        return b"\x00\x00\x00\x01\x65\x80"
    protected = protected_offsets(bytes(source))
    positions = deterministic_positions(source, protected, digest, 8)
    if variant % 4 == 0:
        for index, position in enumerate(positions[:4]):
            source[position] ^= 1 << ((digest[index] + index) % 8)
    elif variant % 4 == 1:
        boundary = (0x00, 0xFF, 0x7F, 0x80)
        for index, position in enumerate(positions[:4]):
            source[position] = boundary[index]
    elif variant % 4 == 2:
        codes = start_codes(bytes(source))
        if codes:
            selected = int.from_bytes(digest[:4], "big") % len(codes)
            begin = codes[selected][0]
            end = codes[selected + 1][0] if selected + 1 < len(codes) else len(source)
            unit = bytes(source[begin:end])
            room = max(0, max_bytes - len(source))
            source.extend(unit[:room])
        elif positions:
            position = positions[0]
            span = bytes(source[position : position + min(32, max_bytes - len(source))])
            source[position:position] = span
            del source[max_bytes:]
    else:
        codes = start_codes(bytes(source))
        if len(codes) >= 2:
            selected = int.from_bytes(digest[:4], "big") % (len(codes) - 1)
            begin = codes[selected][0] + codes[selected][1] + 1
            end = codes[selected + 1][0]
            if end > begin:
                width = max(1, min(end - begin, 1 + digest[4] % 32))
                del source[begin : begin + width]
        elif len(source) > 8 and positions:
            begin = positions[0]
            del source[begin : begin + min(16, len(source) - begin)]
    if bytes(source) == data[:max_bytes] and positions:
        source[positions[0]] ^= 0x01
    return bytes(source[:max_bytes])


def corpus_files(root: pathlib.Path) -> list[pathlib.Path]:
    return sorted(
        path
        for path in root.iterdir()
        if path.is_file()
        and not path.name.startswith(".")
        and 0 < path.stat().st_size <= 16 * 1024 * 1024
    )


def make_candidates(
    packet: dict[str, Any], corpus: pathlib.Path, output: pathlib.Path
) -> list[pathlib.Path]:
    seeds = corpus_files(corpus)
    if not seeds:
        raise ValueError("corpus-empty")
    packet_id = packet["packet_id"]
    generator = packet["generator"]
    count = generator["candidate_count"]
    max_bytes = generator["max_input_bytes"]
    selector = int(packet_id[:16], 16)
    output.mkdir(parents=True, exist_ok=True)
    paths: list[pathlib.Path] = []
    metadata: list[dict[str, Any]] = []
    for variant in range(count):
        base_path = seeds[(selector + variant) % len(seeds)]
        base = base_path.read_bytes()
        digest = hashlib.sha256(
            f"{packet_id}:{variant}:{base_path.name}".encode("utf-8")
        ).digest()
        candidate = mutate(base, digest, variant, max_bytes)
        candidate_sha = hashlib.sha256(candidate).hexdigest()
        path = output / f"{packet_id[:16]}-{variant}-{candidate_sha[:16]}.h264"
        path.write_bytes(candidate)
        paths.append(path)
        metadata.append(
            {
                "candidate": path.name,
                "candidate_sha256": candidate_sha,
                "size_bytes": len(candidate),
                "base_file": base_path.name,
                "base_sha256": hashlib.sha256(base).hexdigest(),
                "variant": variant,
            }
        )
    (output / "generation.json").write_text(
        json.dumps(
            {
                "schema": GENERATOR_SCHEMA,
                "packet_id": packet_id,
                "target": TARGET,
                "auto_promote": False,
                "candidates": metadata,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    return paths


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    validate = sub.add_parser("validate")
    validate.add_argument("packet", type=pathlib.Path)
    generate = sub.add_parser("generate")
    generate.add_argument("packet", type=pathlib.Path)
    generate.add_argument("--corpus", type=pathlib.Path, required=True)
    generate.add_argument("--output", type=pathlib.Path, required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        packet = load_packet(args.packet)
        if args.command == "validate":
            print(packet["packet_id"])
            return 0
        paths = make_candidates(packet, args.corpus, args.output)
        for path in paths:
            print(path)
        return 0
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"h264-seed-mutator: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
