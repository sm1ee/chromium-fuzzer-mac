import importlib.util
import json
import pathlib
import subprocess
import tempfile
import unittest


REPO_ROOT = pathlib.Path(__file__).parents[1]
ROUTER_PATH = REPO_ROOT / "tools" / "media_seed_router.py"
MUTATOR_PATH = REPO_ROOT / "m1-worker" / "bin" / "h264-seed-mutator.py"


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


router = load_module("media_seed_router", ROUTER_PATH)
mutator = load_module("h264_seed_mutator", MUTATOR_PATH)


class MediaSeedPipelineTest(unittest.TestCase):
    def test_issue_routing_is_strictly_h264_media(self):
        relevant = {
            "issue_id": "h264-oob",
            "component": "Media>Video",
            "title": "H.264 SPS bounds regression",
            "technical_details": "H264Decoder accepts a malformed NAL unit size",
        }
        structural = {
            "issue_id": "pps-media",
            "component": "Media",
            "title": "Video decoder rejects malformed picture parameter set",
        }
        unrelated_gpu = {
            "issue_id": "angle-oob",
            "component": "GPU",
            "title": "ANGLE D3D11 texture bounds regression",
        }
        unrelated_v8 = {
            "issue_id": "wasm-oob",
            "component": "V8",
            "title": "Wasm ArrayBuffer out of bounds",
        }
        self.assertIsNotNone(router.issue_route(relevant))
        self.assertIsNotNone(router.issue_route(structural))
        self.assertIsNone(router.issue_route(unrelated_gpu))
        self.assertIsNone(router.issue_route(unrelated_v8))

    def test_fresh_fix_requires_h264_and_fix_language(self):
        self.assertIsNotNone(
            router.commit_route(
                {
                    "subject": "H264: Fix out of bounds SPS parsing",
                    "message": "Validate SPS length before decode",
                    "paths": "media/gpu",
                }
            )
        )
        self.assertIsNone(
            router.commit_route(
                {
                    "subject": "H264: Add decoder metrics",
                    "message": "Record a new histogram",
                    "paths": "media/gpu",
                }
            )
        )
        self.assertIsNone(
            router.commit_route(
                {
                    "subject": "VP9: Fix out of bounds parsing",
                    "message": "Validate frame size",
                    "paths": "media/gpu",
                }
            )
        )

    def test_packet_contract_matches_worker_and_mutation_is_deterministic(self):
        packet = router.make_packet(
            source_kind="manual",
            source_id="test-1",
            source_url="",
            title="H264 parser boundary smoke",
            component="Media",
            bug_class="test",
            details="",
            mechanism="bounded NAL mutation",
            priority_score=1,
            created_at="2026-07-24T00:00:00Z",
        )
        self.assertEqual(router.validation_errors(packet), [])
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            packet_path = root / "packet.json"
            corpus = root / "corpus"
            first = root / "first"
            second = root / "second"
            corpus.mkdir()
            packet_path.write_text(json.dumps(packet), encoding="utf-8")
            base = (
                b"\x00\x00\x00\x01\x67\x64\x00\x1f"
                b"\x00\x00\x00\x01\x68\xee\x3c\x80"
                b"\x00\x00\x00\x01\x65\x88\x84\x21" * 32
            )
            (corpus / "base.h264").write_bytes(base)
            loaded = mutator.load_packet(packet_path)
            first_paths = mutator.make_candidates(loaded, corpus, first)
            second_paths = mutator.make_candidates(loaded, corpus, second)
            self.assertEqual(len(first_paths), 4)
            self.assertEqual(
                [path.read_bytes() for path in first_paths],
                [path.read_bytes() for path in second_paths],
            )
            for path in first_paths:
                self.assertGreater(path.stat().st_size, 0)
                self.assertLessEqual(path.stat().st_size, 4096)
            metadata = json.loads((first / "generation.json").read_text())
            self.assertFalse(metadata["auto_promote"])

    def test_packet_tampering_fails_closed(self):
        packet = router.make_packet(
            source_kind="issue_corpus",
            source_id="123",
            source_url="",
            title="H264 test",
            component="Media",
            bug_class="oob",
            details="",
            mechanism="bounded mutation",
            priority_score=1,
        )
        packet["source"]["id"] = "124"
        self.assertIn("packet_id_mismatch", router.validation_errors(packet))

    def test_manual_cli_builds_a_valid_smoke_packet(self):
        with tempfile.TemporaryDirectory() as temp:
            output = pathlib.Path(temp) / "manual.json"
            subprocess.run(
                [
                    "python3",
                    str(ROUTER_PATH),
                    "manual",
                    "--source-id",
                    "deployment-smoke",
                    "--title",
                    "H264 admission smoke",
                    "--mechanism",
                    "bounded deterministic NAL mutation",
                    "--output",
                    str(output),
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            packet = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(router.validation_errors(packet), [])
            self.assertEqual(packet["source"]["kind"], "manual")


if __name__ == "__main__":
    unittest.main()
