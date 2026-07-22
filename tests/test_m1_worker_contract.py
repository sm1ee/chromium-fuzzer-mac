import pathlib
import plistlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).parents[1]
PROFILE = REPO_ROOT / "m1-worker"


class M1WorkerContractTest(unittest.TestCase):
    def test_all_shell_files_parse(self):
        scripts = sorted((PROFILE / "bin").glob("*.sh"))
        self.assertGreaterEqual(len(scripts), 8)
        for script in scripts:
            subprocess.run(["bash", "-n", str(script)], check=True)

    def test_locking_scripts_exit_after_signals(self):
        for name in ("build-current.sh", "run-lane.sh", "sync-repo.sh"):
            source = (PROFILE / "bin" / name).read_text(encoding="utf-8")
            self.assertIn("trap cleanup EXIT", source)
            self.assertIn("trap 'exit 130' INT", source)
            self.assertIn("trap 'exit 143' TERM", source)

    def test_worker_paths_are_separate_from_legacy_m4(self):
        config = (PROFILE / "config" / "worker.env").read_text(encoding="utf-8")
        self.assertIn('/Users/smlee/chromium-worker', config)
        self.assertIn('/Users/smlee/chromium-fuzz-data', config)
        self.assertIn('/Users/smlee/chromium-fuzzer-mac', config)
        self.assertNotIn('/Users/bugclaw', config)
        self.assertNotIn('.openclaw', config)

    def test_provenance_fails_closed(self):
        source = (PROFILE / "bin" / "provenance-status.sh").read_text(encoding="utf-8")
        required = (
            'reason="ops_deploy_unattested"',
            'reason="ops_deploy_dirty"',
            'reason="wrong_architecture"',
            'reason="metal_toolchain_missing"',
            'reason="head_mismatch"',
            'reason="source_dirty"',
            'reason="current_tree_ready"',
            'support_only "$support_only"',
            'detection_kpi_eligible "$eligible"',
            'ops_source_head "$ops_source_head"',
            'ops_integrity "$ops_integrity"',
        )
        for marker in required:
            self.assertIn(marker, source)

    def test_runtime_never_auto_promotes(self):
        source = (PROFILE / "bin" / "run-lane.sh").read_text(encoding="utf-8")
        self.assertIn(".current_tree_eligible == 1", source)
        self.assertIn("auto_promote:false", source)
        self.assertIn("ERROR: AddressSanitizer", source)
        self.assertIn("SUMMARY: AddressSanitizer", source)

    def test_command_recording_uses_bash_printf_for_percent_q(self):
        source = (PROFILE / "bin" / "run-lane.sh").read_text(encoding="utf-8")
        self.assertIn("printf '%q '", source)
        self.assertNotIn("/usr/bin/printf '%q '", source)

    def test_repo_sync_is_fetch_ff_only(self):
        source = (PROFILE / "bin" / "sync-repo.sh").read_text(encoding="utf-8")
        self.assertIn("fetch --prune origin main", source)
        self.assertIn("merge --ff-only", source)
        self.assertIn("canonical repository is dirty", source)
        self.assertNotIn("git -C \"$REPO_ROOT\" push", source)
        self.assertNotIn("git -C \"$REPO_ROOT\" commit", source)
        self.assertIn('if [ ! -e "$OPS_ROOT" ]; then', source)
        self.assertIn("previous operations directory preserved", source)

    def test_launch_requires_matching_smoke_stamp(self):
        source = (PROFILE / "bin" / "install-launchagents.sh").read_text(encoding="utf-8")
        self.assertIn("successful smoke stamp is missing", source)
        for field in ("source_head", "binary_fingerprint", "ops_source_head"):
            self.assertIn(field, source)

    def test_launchagents_are_valid_and_use_live_ops(self):
        plists = sorted((PROFILE / "launchagents").glob("*.plist"))
        self.assertEqual(len(plists), 3)
        labels = set()
        for path in plists:
            with path.open("rb") as handle:
                data = plistlib.load(handle)
            labels.add(data["Label"])
            program = data["ProgramArguments"][0]
            self.assertTrue(program.startswith("/Users/smlee/chromium-worker-ops/bin/"))
        self.assertEqual(
            labels,
            {
                "com.bugclaw.chromium-fuzz-webcodecs",
                "com.bugclaw.chromium-worker-health",
                "com.bugclaw.chromium-worker-sync",
            },
        )


if __name__ == "__main__":
    unittest.main()
