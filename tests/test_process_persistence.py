#!/usr/bin/env python3
"""Host checks for durable rules and ephemeral process reconciliation."""
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class ProcessPersistenceTests(unittest.TestCase):
    def test_pid_and_rule_policy_helpers(self):
        compiler = shutil.which("cc") or shutil.which("clang")
        self.assertIsNotNone(compiler, "a C compiler is required")
        with tempfile.TemporaryDirectory(prefix="vedette-pid-policy-") as tmp:
            binary = Path(tmp) / "pid-policy"
            subprocess.run([
                compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                str(ROOT / "tests/test_pid_list_helpers.c"), "-o", str(binary),
            ], check=True)
            subprocess.run([str(binary)], check=True, timeout=10)

    def test_runtime_rebuilds_from_stable_rules_without_pid_payload(self):
        common = (ROOT / "Common.h").read_text()
        source = (ROOT / "Vedette.xm").read_text()
        manager = (ROOT / "VDTProcessManager.mm").read_text()
        header = (ROOT / "VDTProcessManager.h").read_text()

        self.assertIn('"com.udevs.vedette.process-table-changed"', common)
        self.assertIn("notify_post(PROCESS_TABLE_CHANGED_NN)", source)
        self.assertNotIn("notify_set_state", source)
        self.assertNotIn("notify_get_state", source)
        self.assertIn("VDTReconcileProcessRules(newPrefs, YES)", source)
        self.assertIn("VDTReconcileProcessRules(VDTGetPrefs(), NO)", source)
        self.assertLess(source.index("notify_register_dispatch"), source.index("reloadPrefs();"))
        self.assertIn("VDTCreatePIDSnapshot", manager)
        self.assertIn("VDTPIDCountFromBytes(returnedBytes)", manager)
        self.assertIn("VDTGrowPIDCapacity(capacity, &nextCapacity)", manager)
        self.assertIn("PROC_PIDTBSDINFO", manager)
        self.assertIn("appRules[bundleIdentifier]", manager)
        self.assertIn("daemonRules[processName]", manager)
        self.assertIn("VDTResolveCPUAction", manager)
        self.assertIn("com.apple.Preferences", manager)
        self.assertIn("void VDTReconcileProcessRules", header)
        self.assertNotIn("received_new_proc(pid_t", manager)
        self.assertNotIn("pids_with_identifier_and_type", manager)
        reconcile = manager.split("void VDTReconcileProcessRules", 1)[1].split(
            "void VDTRestoreProcessesMatchingPrefs", 1
        )[0]
        self.assertEqual(reconcile.count("VDTCreatePIDSnapshot"), 1)

    def test_restore_targets_only_current_matching_pids(self):
        manager = (ROOT / "VDTProcessManager.mm").read_text()
        restore = manager.split("void VDTRestoreProcessesMatchingPrefs", 1)[1]
        self.assertIn("pidCount", restore)
        self.assertIn("VDTApplyProcessAction(pid, VDTCPUActionNone", restore)


if __name__ == "__main__":
    unittest.main()
