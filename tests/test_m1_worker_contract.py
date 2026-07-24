import pathlib
import plistlib
import subprocess
import unittest


REPO_ROOT = pathlib.Path(__file__).parents[1]
PROFILE = REPO_ROOT / "m1-worker"


class M1WorkerContractTest(unittest.TestCase):
    def test_all_shell_files_parse(self):
        scripts = sorted((PROFILE / "bin").glob("*.sh"))
        self.assertGreaterEqual(len(scripts), 13)
        for script in scripts:
            subprocess.run(["bash", "-n", str(script)], check=True)
        for script in (
            REPO_ROOT / "scripts" / "send_media_seed_packet.sh",
            REPO_ROOT / "scripts" / "seed_issue_corpus_media_queue.sh",
            REPO_ROOT / "scripts" / "seed_fresh_media_fixes.sh",
            REPO_ROOT / "scripts" / "install-media-seed-launchagents.sh",
        ):
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
        self.assertIn('PRIMARY_TARGET="media_h264_decoder_fuzzer"', config)
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
        self.assertNotIn("(^|[[:space:]])(ERROR: AddressSanitizer", source)

    def test_command_recording_uses_bash_printf_for_percent_q(self):
        source = (PROFILE / "bin" / "run-lane.sh").read_text(encoding="utf-8")
        self.assertIn("printf '%q '", source)
        self.assertNotIn("/usr/bin/printf '%q '", source)
        self.assertIn('cd "$session_dir/logs"', source)

    def test_primary_target_is_consistent(self):
        target = "media_h264_decoder_fuzzer"
        config = (PROFILE / "config" / "worker.env").read_text(encoding="utf-8")
        self.assertIn(f'PRIMARY_TARGET="{target}"', config)
        for name in (
            "lane-loop.sh",
            "provenance-status.sh",
            "run-lane.sh",
            "smoke-current.sh",
        ):
            source = (PROFILE / "bin" / name).read_text(encoding="utf-8")
            self.assertIn('${1:-$PRIMARY_TARGET}', source)
        install = (PROFILE / "bin" / "install-launchagents.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn('target="$PRIMARY_TARGET"', install)

        for name in (
            "com.bugclaw.chromium-fuzz-media-h264.plist",
            "com.bugclaw.chromium-worker-health.plist",
        ):
            with (PROFILE / "launchagents" / name).open("rb") as handle:
                data = plistlib.load(handle)
            self.assertIn(target, data["ProgramArguments"])

    def test_repo_sync_is_fetch_ff_only(self):
        source = (PROFILE / "bin" / "sync-repo.sh").read_text(encoding="utf-8")
        self.assertIn("fetch --prune origin main", source)
        self.assertIn("merge --ff-only", source)
        self.assertIn("canonical repository is dirty", source)
        self.assertNotIn("git -C \"$REPO_ROOT\" push", source)
        self.assertNotIn("git -C \"$REPO_ROOT\" commit", source)
        self.assertIn('if [ ! -e "$OPS_ROOT" ]; then', source)
        self.assertIn("previous operations directory preserved", source)
        self.assertIn('for dictionary in "$stage"/dicts/*', source)
        self.assertIn('if [ -f "$dictionary" ]', source)
        self.assertIn("SYNC_ALLOW_ACTIVE_LANE", source)
        self.assertIn('! -name "$PRIMARY_TARGET.lockdir"', source)

    def test_launch_requires_matching_smoke_stamp(self):
        source = (PROFILE / "bin" / "install-launchagents.sh").read_text(encoding="utf-8")
        self.assertIn("successful smoke stamp is missing", source)
        for field in ("source_head", "binary_fingerprint", "ops_source_head"):
            self.assertIn(field, source)
        self.assertIn("Discord bot token is missing", source)
        self.assertIn('token_mode', source)

    def test_discord_notifications_are_human_gated(self):
        config = (PROFILE / "config" / "worker.env").read_text(encoding="utf-8")
        self.assertIn("DISCORD_TOKEN_FILE=", config)
        self.assertNotIn("discord.com/api", config)
        notifier = (PROFILE / "bin" / "notify-artifacts.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(".current_tree_eligible == 1", notifier)
        self.assertIn(".support_only == 0", notifier)
        self.assertIn(".detection_kpi_eligible == 1", notifier)
        self.assertIn("auto_promote: false", notifier)
        sender = (PROFILE / "bin" / "discord-send.sh").read_text(encoding="utf-8")
        self.assertIn("Authorization: Bot $token", sender)
        self.assertIn("DISCORD_DRY_RUN", sender)
        self.assertIn("discord-rest-guard.tsv", sender)
        self.assertIn('set_guard "auth_$status" 21600', sender)
        self.assertIn("triage_bundle:", notifier)
        self.assertIn("logs.tar.gz", notifier)
        status = (PROFILE / "bin" / "post-worker-status.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn("detection_kpi_eligible:", status)
        self.assertIn("ops_integrity:", status)
        self.assertIn("for _ in {1..30}", status)
        self.assertIn("noise_artifacts_timeout_slow_oom:", status)
        self.assertIn("seed_inbox_pending:", status)
        self.assertIn("STATUS_DRY_RUN", status)

        install = (PROFILE / "bin" / "install-launchagents.sh").read_text(
            encoding="utf-8"
        )
        fuzzer_pos = install.index("com.bugclaw.chromium-fuzz-media-h264")
        status_pos = install.index("com.bugclaw.chromium-worker-discord-status")
        self.assertLess(fuzzer_pos, status_pos)

    def test_launchagents_are_valid_and_use_live_ops(self):
        plists = sorted((PROFILE / "launchagents").glob("*.plist"))
        self.assertEqual(len(plists), 7)
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
                "com.bugclaw.chromium-fuzz-media-h264",
                "com.bugclaw.chromium-worker-discord-artifacts",
                "com.bugclaw.chromium-worker-discord-status",
                "com.bugclaw.chromium-worker-health",
                "com.bugclaw.chromium-worker-seed-admission",
                "com.bugclaw.chromium-worker-sync",
                "com.bugclaw.chromium-worker-watchdog",
            },
        )

    def test_seed_admission_and_watchdog_fail_closed(self):
        consumer = (PROFILE / "bin" / "consume-seed-inbox.sh").read_text(
            encoding="utf-8"
        )
        self.assertIn(".current_tree_eligible == 1", consumer)
        self.assertIn("h264-seed-mutator.py", consumer)
        self.assertIn("-runs=1", consumer)
        self.assertIn("seed-quarantine", consumer)
        self.assertIn("auto_promote:false", consumer)
        watchdog = (PROFILE / "bin" / "watchdog.sh").read_text(encoding="utf-8")
        for marker in (
            "LAUNCHD_UNLOADED",
            "COORDINATOR_MISSING",
            "COORDINATOR_DUPLICATE",
            "WORKERS_LOW",
            "WORKERS_EXCESS",
            "LOG_STALE",
            "PROVENANCE_",
            "DISK_LOW",
            "DISCORD_GUARD",
            "RECOVERED",
            "WATCHDOG_REALERT_SECS",
            "WATCHDOG_PROVENANCE_MAX_AGE_SECS",
        ):
            self.assertIn(marker, watchdog)
        sync = (PROFILE / "bin" / "sync-repo.sh").read_text(encoding="utf-8")
        self.assertIn('"$PROFILE_ROOT"/bin/*.py', sync)

    def test_control_plane_seed_launchagents_are_valid(self):
        plists = sorted(
            (REPO_ROOT / "launchagents").glob(
                "com.bugclaw.chromium-fuzzer-mac-seed-*.plist"
            )
        )
        self.assertEqual(len(plists), 2)
        for path in plists:
            with path.open("rb") as handle:
                data = plistlib.load(handle)
            self.assertTrue(data["Label"].startswith(
                "com.bugclaw.chromium-fuzzer-mac-seed-"
            ))


if __name__ == "__main__":
    unittest.main()
