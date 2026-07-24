#!/usr/bin/env python3
"""Build and validate strict media/H.264 seed packets for the M1 worker."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import pathlib
import re
import sys
from typing import Any, Iterable


SCHEMA = "chromium-media-h264-seed-packet-v1"
TARGET = "media_h264_decoder_fuzzer"
GENERATOR_SCHEMA = "bounded-h264-nal-mutation-v1"
H264_EXPLICIT = re.compile(
    r"\b(?:h[\s._-]?264|avc(?:1|c)?|annex[\s._-]?b|"
    r"h264decoder|h264parser)\b",
    re.I,
)
H264_STRUCTURAL = re.compile(
    r"\b(?:nalu?|sequence parameter set|picture parameter set|"
    r"sps|pps|idr|slice header|reference picture list)\b",
    re.I,
)
MEDIA = re.compile(
    r"\b(?:media|video|codec|decoder|decode|bitstream|parser|accelerated video)\b",
    re.I,
)
SECURITY_RELEVANT = re.compile(
    r"\b(?:use.?after.?free|uaf|out.?of.?bounds|oob|overflow|underflow|"
    r"bounds|integer|wraparound|truncat|size|offset|lifetime|dangling|"
    r"type.?confusion|sanitiz|crash|invalid|malformed|check)\b",
    re.I,
)
FIX_WORD = re.compile(
    r"\b(?:fix|prevent|avoid|reject|validate|check|clamp|guard|overflow|"
    r"underflow|bounds|crash|uaf|sanitiz|invalid|malformed)\b",
    re.I,
)
NEGATIVE_ONLY = re.compile(
    r"\b(?:v8|wasm|maglev|turbofan|turboshaft|webgpu|dawn|wgsl|"
    r"d3d11|d3d12|angle|webgl)\b",
    re.I,
)


def compact(value: Any, limit: int = 1600) -> str:
    if value is None:
        return ""
    if not isinstance(value, str):
        value = json.dumps(value, ensure_ascii=False, sort_keys=True)
    return re.sub(r"\s+", " ", value).strip()[:limit]


def canonical_hash(value: Any) -> str:
    encoded = json.dumps(
        value, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def read_seen(path: pathlib.Path) -> set[str]:
    try:
        return {
            line.split("\t", 1)[0]
            for line in path.read_text(encoding="utf-8", errors="replace").splitlines()
            if line.strip()
        }
    except OSError:
        return set()


def read_failures(path: pathlib.Path) -> dict[str, int]:
    failures: dict[str, int] = {}
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return failures
    for line in lines:
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        try:
            failures[parts[0]] = max(failures.get(parts[0], 0), int(parts[1]))
        except ValueError:
            continue
    return failures


def h264_relevant(text: str) -> bool:
    explicit = bool(H264_EXPLICIT.search(text))
    structural_media = bool(H264_STRUCTURAL.search(text) and MEDIA.search(text))
    if not (explicit or structural_media):
        return False
    if NEGATIVE_ONLY.search(text) and not MEDIA.search(text):
        return False
    return True


def issue_route(stub: dict[str, Any]) -> tuple[int, str] | None:
    fields = (
        "issue_id",
        "component",
        "bug_class",
        "title",
        "dedupe_key",
        "collection_reason",
        "technical_details",
        "labels",
        "matched_queries",
    )
    text = "\n".join(compact(stub.get(field), 2600) for field in fields)
    if not h264_relevant(text):
        return None
    score = int(stub.get("priority_score") or 0)
    score += 12 if H264_EXPLICIT.search(text) else 7
    score += 8 if SECURITY_RELEVANT.search(text) else 0
    component = compact(stub.get("component"), 200)
    score += 4 if MEDIA.search(component) else 0
    mechanism = (
        "Mutate an existing admitted Annex-B H.264 seed around NAL payload "
        "boundaries using bounded deterministic edits. Preserve start codes and "
        "exercise SPS/PPS/slice parsing and H264Decoder state transitions."
    )
    return score, mechanism


def commit_route(record: dict[str, Any]) -> tuple[int, str] | None:
    subject = compact(record.get("subject") or record.get("message"), 500)
    message = compact(record.get("message"), 2400)
    paths = compact(record.get("paths"), 1200)
    text = "\n".join((subject, message, paths))
    if subject.lower().startswith("roll ") or not h264_relevant(text) or not FIX_WORD.search(text):
        return None
    score = 12
    score += 8 if SECURITY_RELEVANT.search(text) else 0
    score += 4 if re.search(r"media/(?:gpu|video)", paths, re.I) else 0
    mechanism = (
        "Generate bounded deterministic NAL mutations derived from an admitted "
        "H.264 corpus seed, emphasizing the parser/decoder condition named by "
        "this current fix. Do not synthesize an unconstrained bitstream."
    )
    return score, mechanism


def make_packet(
    *,
    source_kind: str,
    source_id: str,
    source_url: str,
    title: str,
    component: str,
    bug_class: str,
    details: str,
    mechanism: str,
    priority_score: int,
    created_at: str | None = None,
) -> dict[str, Any]:
    identity = {
        "schema": SCHEMA,
        "source_kind": source_kind,
        "source_id": source_id,
        "target": TARGET,
        "generator_schema": GENERATOR_SCHEMA,
    }
    packet_id = canonical_hash(identity)
    return {
        "schema": SCHEMA,
        "packet_id": packet_id,
        "created_at": created_at
        or dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "source": {
            "kind": source_kind,
            "id": source_id,
            "url": source_url,
            "title": title,
            "component": component,
            "bug_class": bug_class,
            "details": details,
        },
        "routing": {
            "target": TARGET,
            "platform": "macos-arm64",
            "mechanism": mechanism,
            "priority_score": priority_score,
        },
        "generator": {
            "schema": GENERATOR_SCHEMA,
            "candidate_count": 4,
            "max_input_bytes": 4096,
            "base": "existing-admitted-corpus",
        },
        "auto_promote": False,
        "human_triage_required": True,
    }


def validation_errors(packet: Any) -> list[str]:
    errors: list[str] = []
    if not isinstance(packet, dict):
        return ["packet-not-object"]
    if packet.get("schema") != SCHEMA:
        errors.append("schema")
    packet_id = packet.get("packet_id")
    if not isinstance(packet_id, str) or not re.fullmatch(r"[0-9a-f]{64}", packet_id):
        errors.append("packet_id")
    source = packet.get("source")
    if not isinstance(source, dict):
        errors.append("source")
        source = {}
    for field in ("kind", "id", "title"):
        if not isinstance(source.get(field), str) or not source.get(field):
            errors.append(f"source.{field}")
    if source.get("kind") not in {"issue_corpus", "fresh_fix", "manual"}:
        errors.append("source.kind")
    routing = packet.get("routing")
    if not isinstance(routing, dict):
        errors.append("routing")
        routing = {}
    if routing.get("target") != TARGET:
        errors.append("routing.target")
    mechanism = routing.get("mechanism")
    if not isinstance(mechanism, str) or not mechanism:
        errors.append("routing.mechanism")
    generator = packet.get("generator")
    if not isinstance(generator, dict):
        errors.append("generator")
        generator = {}
    if generator.get("schema") != GENERATOR_SCHEMA:
        errors.append("generator.schema")
    if generator.get("base") != "existing-admitted-corpus":
        errors.append("generator.base")
    candidate_count = generator.get("candidate_count")
    if not isinstance(candidate_count, int) or not 1 <= candidate_count <= 8:
        errors.append("generator.candidate_count")
    max_bytes = generator.get("max_input_bytes")
    if not isinstance(max_bytes, int) or not 64 <= max_bytes <= 4096:
        errors.append("generator.max_input_bytes")
    if packet.get("auto_promote") is not False:
        errors.append("auto_promote")
    if packet.get("human_triage_required") is not True:
        errors.append("human_triage_required")
    if not errors:
        identity = {
            "schema": SCHEMA,
            "source_kind": source["kind"],
            "source_id": source["id"],
            "target": routing["target"],
            "generator_schema": generator["schema"],
        }
        if canonical_hash(identity) != packet_id:
            errors.append("packet_id_mismatch")
    return errors


def write_packets(
    records: Iterable[tuple[dict[str, Any], int, str]],
    *,
    kind: str,
    outbox: pathlib.Path,
    manifest: pathlib.Path,
    seen: set[str],
    failures: dict[str, int],
    max_retry: int,
    limit: int,
) -> int:
    outbox.mkdir(parents=True, exist_ok=True)
    selected: list[tuple[int, str, dict[str, Any]]] = []
    for record, score, mechanism in records:
        if kind == "issue_corpus":
            source_id = compact(record.get("issue_id"), 120)
            source_url = compact(
                record.get("issue_url") or record.get("url"), 300
            )
            if not source_url and source_id:
                source_url = f"https://issues.chromium.org/issues/{source_id}"
            title = compact(record.get("title"), 400)
            component = compact(record.get("component"), 200) or "unknown"
            bug_class = compact(record.get("bug_class"), 160) or "unclassified"
            details = compact(record.get("technical_details"), 2000)
        else:
            source_id = compact(record.get("commit"), 120)
            source_url = compact(record.get("url"), 300)
            title = compact(record.get("subject") or record.get("message"), 400)
            component = compact(record.get("component"), 200) or "media"
            bug_class = "fresh_fix"
            details = compact(record.get("message"), 2000)
        if not source_id or not title:
            continue
        packet = make_packet(
            source_kind=kind,
            source_id=source_id,
            source_url=source_url,
            title=title,
            component=component,
            bug_class=bug_class,
            details=details,
            mechanism=mechanism,
            priority_score=score,
        )
        packet_id = packet["packet_id"]
        if packet_id in seen or failures.get(packet_id, 0) >= max_retry:
            continue
        selected.append((score, source_id, packet))
    selected.sort(key=lambda row: (row[0], row[1]), reverse=True)
    rows: list[str] = []
    for score, source_id, packet in selected[:limit]:
        packet_id = packet["packet_id"]
        path = outbox / f"{packet_id}.json"
        path.write_text(
            json.dumps(packet, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        rows.append(
            "\t".join(
                (
                    str(path),
                    packet_id,
                    kind,
                    source_id.replace("\t", " "),
                    compact(packet["source"]["title"], 160).replace("\t", " "),
                )
            )
        )
        print(
            f"[media-seed] candidate kind={kind} id={source_id} "
            f"score={score} packet={packet_id[:16]}"
        )
    manifest.write_text("\n".join(rows) + ("\n" if rows else ""), encoding="utf-8")
    return len(rows)


def issue_records(queue_root: pathlib.Path, lookback_days: int, max_age: int):
    paths = list(queue_root.glob("20??-??-??/*.json"))
    days: list[dt.date] = []
    for path in paths:
        try:
            days.append(dt.date.fromisoformat(path.parent.name))
        except ValueError:
            continue
    latest = max(days) if days else dt.date.today()
    if days and (dt.date.today() - latest).days > max_age:
        raise RuntimeError(
            f"STALE-QUEUE latest_day={latest.isoformat()} "
            f"age_days={(dt.date.today() - latest).days} max_age_days={max_age}"
        )
    minimum = latest - dt.timedelta(days=max(0, lookback_days - 1))
    records = []
    for path in sorted(paths):
        try:
            day = dt.date.fromisoformat(path.parent.name)
            value = json.loads(path.read_text(encoding="utf-8", errors="replace"))
        except (ValueError, OSError, json.JSONDecodeError):
            continue
        if day < minimum or not isinstance(value, dict):
            continue
        routed = issue_route(value)
        if routed:
            records.append((value, routed[0], routed[1]))
    return records, len(paths), latest


def command_issues(args: argparse.Namespace) -> int:
    try:
        records, scanned, latest = issue_records(
            args.queue_root, args.lookback_days, args.max_queue_age_days
        )
    except RuntimeError as error:
        print(f"[media-seed] {error}", file=sys.stderr)
        return 3
    count = write_packets(
        records,
        kind="issue_corpus",
        outbox=args.outbox,
        manifest=args.manifest,
        seen=read_seen(args.seen),
        failures=read_failures(args.failures),
        max_retry=args.max_retry,
        limit=args.max_per_run,
    )
    print(
        f"[media-seed] scanned={scanned} routed={len(records)} "
        f"selected={count} latest_day={latest.isoformat()}"
    )
    return 0


def command_commits(args: argparse.Namespace) -> int:
    records = []
    for line in args.input.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(value, dict):
            continue
        routed = commit_route(value)
        if routed:
            records.append((value, routed[0], routed[1]))
    count = write_packets(
        records,
        kind="fresh_fix",
        outbox=args.outbox,
        manifest=args.manifest,
        seen=read_seen(args.seen),
        failures=read_failures(args.failures),
        max_retry=args.max_retry,
        limit=args.max_per_run,
    )
    print(
        f"[media-seed] scanned={sum(1 for _ in args.input.open())} "
        f"routed={len(records)} selected={count}"
    )
    return 0


def command_validate(args: argparse.Namespace) -> int:
    try:
        packet = json.loads(args.packet.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        print(f"invalid packet: {error}", file=sys.stderr)
        return 2
    errors = validation_errors(packet)
    if errors:
        print("invalid packet: " + ",".join(errors), file=sys.stderr)
        return 2
    print(packet["packet_id"])
    return 0


def command_manual(args: argparse.Namespace) -> int:
    packet = make_packet(
        source_kind="manual",
        source_id=args.source_id,
        source_url="",
        title=args.title,
        component="Chromium Media",
        bug_class="operational_smoke",
        details="",
        mechanism=args.mechanism,
        priority_score=0,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        json.dumps(packet, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(packet["packet_id"])
    return 0


def common_selection(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--outbox", type=pathlib.Path, required=True)
    parser.add_argument("--manifest", type=pathlib.Path, required=True)
    parser.add_argument("--seen", type=pathlib.Path, required=True)
    parser.add_argument("--failures", type=pathlib.Path, required=True)
    parser.add_argument("--max-per-run", type=int, default=2)
    parser.add_argument("--max-retry", type=int, default=3)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    issues = sub.add_parser("issues")
    common_selection(issues)
    issues.add_argument("--queue-root", type=pathlib.Path, required=True)
    issues.add_argument("--lookback-days", type=int, default=7)
    issues.add_argument("--max-queue-age-days", type=int, default=1)
    issues.set_defaults(func=command_issues)
    commits = sub.add_parser("commits")
    common_selection(commits)
    commits.add_argument("--input", type=pathlib.Path, required=True)
    commits.set_defaults(func=command_commits)
    validate = sub.add_parser("validate")
    validate.add_argument("packet", type=pathlib.Path)
    validate.set_defaults(func=command_validate)
    manual = sub.add_parser("manual")
    manual.add_argument("--source-id", required=True)
    manual.add_argument("--title", required=True)
    manual.add_argument("--mechanism", required=True)
    manual.add_argument("--output", type=pathlib.Path, required=True)
    manual.set_defaults(func=command_manual)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
