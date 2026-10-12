#!/usr/bin/env python3
"""Host/mock and source contracts only. Never connects to a device.

Temporary compilers/binaries stay under the delegated diagnostics directory,
are removed at teardown, and are never added to the package. Mutants must
compile before their behavioral rejection counts as a killed mutation.
"""
import errno
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

TOOL = Path(__file__).resolve().parents[1]
REPO = TOOL.parents[1]
LOG_DIR = Path(os.environ.get("VDT_DIAGNOSTICS_LOG_DIR", str(REPO.parent / "vedette-memory-plan/m1-diagnostics")))
FLAGS = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic"]
SOURCE = (TOOL / "main.c").read_text()


def source_contracts(source):
    """Closed allowlist, including commands and absence of a generic gateway."""
    code = re.sub(r"/\*.*?\*/|//[^\n]*", "", source, flags=re.S)
    # Removing // also strips URLs in literals; no call expressions live there.
    issues = []
    for name, value in (("GET_PRIORITY_LIST", "1u"), ("GET_MEMLIMIT_PROPERTIES", "8u")):
        if not re.search(r"^#define MEMORYSTATUS_CMD_" + name + r"\s+" + value + r"\s*$", code, re.M):
            issues.append("changed GET command constant " + name)
    command_defs = re.findall(r"^#define\s+(MEMORYSTATUS_CMD_\w+)", code, re.M)
    if sorted(command_defs) != ["MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES", "MEMORYSTATUS_CMD_GET_PRIORITY_LIST"]:
        issues.append("extra command definition")
    without_declaration = re.sub(r"extern int memorystatus_control\(uint32_t, int32_t, uint32_t, void \*, size_t\);", "", code)
    calls = re.findall(r"memorystatus_control\s*\((.*?)\);", without_declaration, re.S)
    normalized = [re.sub(r"\s+", "", c) for c in calls]
    expected = [
        "MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES,pid,0,out,sizeof(*out)",
        "MEMORYSTATUS_CMD_GET_PRIORITY_LIST,pid,0,out,sizeof(*out)",
    ]
    if normalized != expected:
        issues.append("OS call list is not the two fixed single-PID GETs")
    if re.search(r"\b(?:syscall|system|exec\w*|popen|fopen|open|kill|ptrace|setuid|seteuid)\s*\(", code):
        issues.append("unexpected side-effect/raw-syscall API")
    if re.search(r"\b(?:MEMORYSTATUS_CMD_SET_\w*|proc_set\w*|proc_disable\w*|proc_clear\w*)\b", code):
        issues.append("write-policy API")
    if re.search(r"\b(?:int|uint32_t|unsigned)\s+command\b", code):
        issues.append("generic command argument")
    if re.findall(r"sysctlbyname\s*\((.*?)\);", code, re.S) != ["name, out, size, NULL, 0"]:
        issues.append("sysctl must have NULL newp and zero newlen")
    return issues


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def check_unknown(result):
    code, d, counts = result
    require(code == 1, "unknown version/ABI must not succeed")
    require(not d["abi_gate"]["allowed"], "unknown kernel gate opened")
    require(counts[:2] == (0, 0), "unknown kernel issued GET")
    require(d["memlimit"]["active"]["mib"] is None, "unknown version fabricated MiB")
    require(d["priority"]["effective_band"] is None, "unknown version fabricated band")
    for resource in ("memlimit", "priority"):
        require(d[resource]["call"] == {"attempted": False, "raw_return": None, "errno": None, "errno_text": None}, "skipped syscall fabricated raw evidence")


def check_failed(result, error):
    code, d, counts = result
    require(code == 1 and counts[:2] == (1, 1), "expected attempted failure, not skipped or success")
    for name in ("memlimit", "priority"):
        c = d[name]["call"]
        require(c["attempted"] and c["raw_return"] == -1, "failure return lost")
        require(c["errno"] == error, "failure errno overwritten")
        require(d[name]["status"] == "syscall_failed", "failure status lost")
        require(all(v is None for v in d[name]["raw_observation"].values()), "failed buffer consumed")
    for state in ("active", "inactive"):
        for key in ("mib", "fatal", "flags", "unknown_flag_bits"):
            require(d["memlimit"][state][key] is None, "failure fabricated 0/flag/limit")
        require(d["memlimit"][state]["interpretation"] == "unknown", "failure claimed a mode")
    for key in ("effective_band", "user_data", "selected_limit_mib"):
        require(d["priority"][key] is None, "failure fabricated priority")
    require(not d["complete_observation"], "failure marked complete")


def check_unstable(result):
    code, d, _ = result
    require(d["identity"]["status"] == "unstable" and d["identity"]["stable"] is False, "unstable identity reported stable")
    require(code == 1, "unstable identity must not succeed")
    require(d["stable_effective_policy"] is None and not d["complete_observation"], "unstable effective policy conclusion")
    require(d["memlimit"]["active"]["mib"] is None, "unattributed memory read shown as effective")
    require(d["priority"]["effective_band"] is None and d["priority"]["user_data"] is None, "unattributed priority read shown as effective")


class ReadonlyContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.compiler = shutil.which("clang")
        if not cls.compiler:
            raise RuntimeError("clang missing; no installation attempted")
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        # iSH stat/fstat directory identity can disagree, making Python's
        # fd-based rmtree reject a real directory as a symlink. The fixture
        # creates only direct regular files; explicitly delete those exact
        # owned files and require rmdir to succeed (no ignored cleanup errors).
        cls.work = Path(tempfile.mkdtemp(prefix="readonly-tests-", dir=LOG_DIR))
        cls.addClassCleanup(cls.cleanup_work)
        cls.fake = cls.compile(SOURCE, "baseline-fake", True)
        cls.host = cls.compile(SOURCE, "baseline-host", False)

    @classmethod
    def cleanup_work(cls):
        for path in cls.work.iterdir():
            if not path.is_file() or path.is_symlink():
                raise AssertionError("unexpected fixture cleanup entry: " + path.name)
            path.unlink()
        cls.work.rmdir()

    @classmethod
    def compile(cls, source, name, fake):
        path = cls.work / (name + ".c")
        binary = cls.work / name
        path.write_text(source)
        cmd = [cls.compiler, *FLAGS, "-I", str(TOOL)]
        if fake:
            cmd.append("-DVDT_READONLY_FAKE=1")
        result = subprocess.run([*cmd, str(path), "-o", str(binary)], text=True, capture_output=True, timeout=90)
        if result.returncode:
            raise AssertionError("compile failed (not a killed mutant): " + result.stderr)
        return binary

    def run_case(self, case="success16", binary=None, pid="4242"):
        env = dict(os.environ)
        env["VDT_MOCK_CASE"] = case
        result = subprocess.run([str(binary or self.fake), pid], env=env, text=True, capture_output=True, timeout=20)
        d = json.loads(result.stdout)
        match = re.fullmatch(r"FAKE limits=(\d+) priority=(\d+) info=(\d+) path=(\d+)\n", result.stderr)
        self.assertIsNotNone(match, result.stderr)
        counts = tuple(map(int, match.groups()))
        self.assertEqual(d["provenance"], "host_mock_no_device_evidence")
        self.assertEqual(d["pid"], int(pid))
        self.assertIs(d["read_only"], True)
        self.assertIs(d["atomic_snapshot"], False)
        self.assertIs(d["identity"]["atomic_binding"], False)
        self.assertIsNone(d["memlimit"]["default_sentinel"])
        self.assertIn("unknown", d["memlimit"]["original_mode"])
        self.assertIsNone(d["priority"]["requested_priority"])
        self.assertIsNone(d["priority"]["assertion_priority"])
        self.assertEqual(d["priority"]["requested_priority_source"], "not_exposed_by_GET")
        self.assertEqual(d["active_state_semantics"], "kernel_active_not_equivalent_to_foreground")
        self.assertIs(d["abi_gate"]["runtime_patch_verified"], False)
        return result.returncode, d, counts

    def test_01_source_allowlist(self):
        self.assertEqual(source_contracts(SOURCE), [])
        self.assertNotIn('#include "../../', SOURCE)
        self.assertNotIn("VDTMemoryPolicy", SOURCE)
        self.assertNotIn("VDTJetsamPolicy", SOURCE)

    def test_02_known_four_reference_tags(self):
        for ios, darwin, tag, band in ((15, 21, "8019.41.5", 21), (16, 22, "8792.41.9", 210), (17, 23, "10002.1.13", 210), (18, 24, "11215.1.10", 210)):
            with self.subTest(ios=ios):
                code, d, counts = self.run_case("success" + str(ios))
                self.assertEqual((code, counts), (0, (1, 1, 3, 3)))
                self.assertEqual(d["abi_gate"]["reference_xnu"], tag)
                self.assertEqual(d["abi_gate"]["ios_major"], ios)
                self.assertEqual(d["abi_gate"]["darwin_major"], darwin)
                self.assertEqual(d["abi_gate"]["reference_max_band"], band)
                self.assertEqual(d["memlimit"]["call"]["raw_return"], 0)
                self.assertEqual(d["priority"]["call"]["raw_return"], 24)
                self.assertEqual(d["memlimit"]["active"]["mib"], 512)
                self.assertEqual(d["memlimit"]["inactive"]["mib"], 128)
                self.assertIs(d["memlimit"]["active"]["fatal"], True)
                self.assertIs(d["memlimit"]["inactive"]["fatal"], False)
                self.assertEqual(d["priority"]["user_data"], "0xfedcba9876543210")
                self.assertIs(d["complete_observation"], True)

    def test_03_permissions_not_assumed_from_root(self):
        for case, error in (("all_eperm", errno.EPERM), ("all_esrch", errno.ESRCH), ("all_einval", errno.EINVAL)):
            with self.subTest(case=case):
                result = self.run_case(case)
                self.assertIs(result[1]["permission"]["is_root"], True)
                check_failed(result, error)
        code, d, counts = self.run_case("nonroot_success")
        self.assertEqual((code, counts[:2]), (0, (1, 1)))
        self.assertIs(d["permission"]["is_root"], False)

    def test_04_unknown_versions_fail_closed(self):
        for case in ("unknown_darwin", "unknown_kernel", "xnu_prefix_collision", "os_mismatch", "unknown_abi", "sysctl_fail", "sysctl_partial", "sysctl_oversize", "malformed_version", "kernel_version_mismatch"):
            with self.subTest(case=case):
                check_unknown(self.run_case(case))

    def test_05_partial_reads_and_copyout_failure(self):
        for case, resource, raw, error in (("mem_partial_return", "memlimit", 8, 0), ("mem_copyout_fail", "memlimit", -1, errno.EFAULT), ("priority_partial_return", "priority", 16, 0), ("priority_zero_return", "priority", 0, 0), ("priority_copyout_fail", "priority", -1, errno.EFAULT)):
            with self.subTest(case=case):
                code, d, counts = self.run_case(case)
                self.assertEqual(code, 1)
                self.assertEqual(counts[:2], (1, 1))
                self.assertEqual(d[resource]["call"]["raw_return"], raw)
                self.assertEqual(d[resource]["call"]["errno"], error)
                self.assertTrue(all(v is None for v in d[resource]["raw_observation"].values()))
                self.assertIsNone(d[resource]["active"]["mib"] if resource == "memlimit" else d[resource]["effective_band"])
                other = "priority" if resource == "memlimit" else "memlimit"
                self.assertEqual(d[other]["status"], "read_success")
                self.assertIs(d["complete_observation"], False)

    def test_06_per_resource_failure_does_not_erase_other_get(self):
        for case, failed, good in (("mem_eperm", "memlimit", "priority"), ("priority_eperm", "priority", "memlimit")):
            with self.subTest(case=case):
                code, d, counts = self.run_case(case)
                self.assertEqual((code, counts[:2]), (1, (1, 1)))
                self.assertEqual(d[failed]["call"]["errno"], errno.EPERM)
                self.assertEqual(d[good]["status"], "read_success")
                self.assertIs(d["complete_observation"], False)

    def test_07_pid_reuse_and_path_change(self):
        for case, expected_calls in (("pid_reuse_between", (1, 0)), ("pid_reuse_after", (1, 1)), ("path_changed", (1, 0)), ("priority_pid_mismatch", (1, 1))):
            with self.subTest(case=case):
                result = self.run_case(case)
                check_unstable(result)
                self.assertEqual(result[2][:2], expected_calls)
        _, d, _ = self.run_case("priority_pid_mismatch")
        self.assertTrue(all(v is None for v in d["priority"]["raw_observation"].values()), "must not expose another PID's data")

    def test_08_unreadable_or_partial_identity_before_get(self):
        for case in ("info_fail", "info_partial", "info_pid_mismatch", "zero_start", "bad_microseconds", "path_fail", "path_partial", "path_unterminated"):
            with self.subTest(case=case):
                code, d, counts = self.run_case(case)
                self.assertEqual((code, counts[:2]), (1, (0, 0)))
                self.assertEqual(d["identity"]["status"], "unknown")
                self.assertIsNone(d["identity"]["stable"])
                self.assertIsNone(d["memlimit"]["active"]["mib"])
        _, d, _ = self.run_case("path_fail")
        self.assertIsNone(d["identity"]["before"]["path"])
        self.assertEqual(d["identity"]["before"]["path_call"]["errno"], errno.EACCES)
        _, d, _ = self.run_case("info_partial")
        self.assertEqual(d["identity"]["before"]["bsdinfo_call"]["raw_return"], 128)
        self.assertIsNone(d["identity"]["before"]["start_seconds"])

    def test_09_identity_failure_after_get_cannot_assert_stable(self):
        for case in ("info_fail_after", "path_fail_after"):
            with self.subTest(case=case):
                code, d, counts = self.run_case(case)
                self.assertEqual((code, counts), (1, (1, 1, 3, 3)))
                self.assertEqual(d["identity"]["status"], "unknown")
                self.assertIsNone(d["identity"]["stable"])
                self.assertIsNone(d["memlimit"]["active"]["mib"])
                self.assertIsNone(d["priority"]["effective_band"])
                self.assertIs(d["complete_observation"], False)

    def test_10_json_escaping_all_controls_unicode_and_invalid_byte(self):
        code, d, _ = self.run_case("json_escape")
        self.assertEqual(code, 0)
        self.assertEqual(d["identity"]["before"]["path"], '/fixture/quote"\\slash\n\r\t\x01/é/中/😀/ÿ')
        for boundary in ("between", "after"):
            self.assertEqual(d["identity"][boundary]["path"], d["identity"]["before"]["path"])
        self.assertEqual(set(d), {
            "schema", "pid", "read_only", "provenance", "version_source", "versions",
            "abi_gate", "permission", "identity", "memlimit", "priority",
            "complete_observation", "atomic_snapshot", "stable_effective_policy",
            "restoration_source", "active_state_semantics", "text_encoding", "errno_semantics",
        }, "escaped input must not create, remove, or rename top-level fields")

    def test_11_nonpositive_readback_is_not_zero_or_unlimited(self):
        _, d, _ = self.run_case("nonpositive_limits")
        self.assertEqual(d["memlimit"]["raw_observation"]["active"], 0)
        self.assertEqual(d["memlimit"]["raw_observation"]["inactive"], -1)
        for state in ("active", "inactive"):
            self.assertIsNone(d["memlimit"][state]["mib"])
            self.assertEqual(d["memlimit"][state]["interpretation"], "nonpositive_readback_unknown")
        self.assertNotIn("unlimited", json.dumps(d))

    def test_12_zero_idle_and_freezer_not_remapped(self):
        for case, band in (("idle_band", 0), ("freezer_band", 75)):
            with self.subTest(case=case):
                code, d, _ = self.run_case(case)
                self.assertEqual(code, 0)
                self.assertEqual(d["priority"]["effective_band"], band)
        _, d, _ = self.run_case("unknown_flags")
        self.assertEqual(d["memlimit"]["active"]["flags"], 5)
        self.assertEqual(d["memlimit"]["active"]["unknown_flag_bits"], 4)
        self.assertIs(d["memlimit"]["active"]["fatal"], True)

    def test_13_cli_requires_exactly_one_explicit_pid(self):
        for args in ([], ["0"], ["-1"], ["+42"], [" 42"], ["42x"], ["1.5"], ["2147483648"], ["999999999999999999999999999"], ["--set", "42"], ["--pid", "42"], ["42", "43"], ["--darwin", "22"], ["--all"]):
            with self.subTest(args=args):
                r = subprocess.run([str(self.fake), *args], capture_output=True, text=True, timeout=20)
                self.assertEqual(r.returncode, 2)
                self.assertEqual(r.stdout, "")
                self.assertIn("Usage:", r.stderr)
                self.assertNotIn("FAKE", r.stderr)
        r = subprocess.run([str(self.fake), "--help"], capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stderr, "")
        self.assertIn("requires separate explicit authorization", r.stdout)
        self.assertEqual(self.run_case(pid="2147483647")[0], 0)

    def test_14_plain_host_does_not_claim_phone_os(self):
        r = subprocess.run([str(self.host), "4242"], capture_output=True, text=True, timeout=20)
        self.assertEqual(r.returncode, 1)
        self.assertEqual(r.stderr, "")
        d = json.loads(r.stdout)
        self.assertEqual(d["provenance"], "unsupported_host_no_phone_evidence")
        self.assertFalse(d["abi_gate"]["allowed"])
        self.assertTrue(all(v["value"] is None for v in d["versions"].values()))
        self.assertFalse(d["memlimit"]["call"]["attempted"])
        self.assertFalse(d["priority"]["call"]["attempted"])

    def test_15_independent_makefile_not_in_package(self):
        m = (TOOL / "Makefile").read_text()
        self.assertRegex(m, r"(?m)^all: help$")
        self.assertNotRegex(m, r"(?m)^(install|package|run|sign):")
        self.assertNotRegex(m, r"(?m)^include ")
        self.assertNotIn("memorystatus-readonly", (REPO / "Makefile").read_text())

    def test_16_source_mutant_write_command_killed(self):
        mutant = SOURCE.replace("#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES 8u", "#define MEMORYSTATUS_CMD_GET_MEMLIMIT_PROPERTIES 7u", 1)
        self.assertNotEqual(mutant, SOURCE)
        self.assertIn("changed GET command constant GET_MEMLIMIT_PROPERTIES", source_contracts(mutant))
        self.compile(mutant, "mutant-write-command", True)
        print("MUTATION KILLED: numeric write command 7", flush=True)

    def test_17_source_mutant_arbitrary_command_gateway_killed(self):
        mutant = SOURCE.replace("static int backend_limits(int32_t pid, Limits *out)", "static int backend_limits(int32_t pid, Limits *out)", 1)
        mutant += "\n#if defined(__APPLE__)\nint arbitrary_gateway(uint32_t command, int32_t pid, void *out, size_t size) { return memorystatus_control(command, pid, 0, out, size); }\n#endif\n"
        self.assertIn("generic command argument", source_contracts(mutant))
        self.assertIn("OS call list is not the two fixed single-PID GETs", source_contracts(mutant))
        self.compile(mutant, "mutant-generic-gateway", True)
        print("MUTATION KILLED: arbitrary command gateway", flush=True)

    def test_18_behavior_mutant_failure_pseudo_zero_killed(self):
        mutant = SOURCE.replace("json_int(available && value > 0, value);", "json_int(true, 0);", 1)
        self.assertNotEqual(mutant, SOURCE)
        binary = self.compile(mutant, "mutant-failure-zero", True)
        with self.assertRaisesRegex(AssertionError, "failure fabricated 0"):
            check_failed(self.run_case("all_eperm", binary), errno.EPERM)
        print("MUTATION KILLED: failed GET rendered zero MiB", flush=True)

    def test_19_behavior_mutant_errno_cleared_killed(self):
        mutant = SOURCE.replace("int err = errno;", "int err = 0;")
        self.assertNotEqual(mutant, SOURCE)
        binary = self.compile(mutant, "mutant-errno-cleared", True)
        with self.assertRaisesRegex(AssertionError, "failure errno overwritten"):
            check_failed(self.run_case("all_eperm", binary), errno.EPERM)
        print("MUTATION KILLED: errno cleared after failure", flush=True)

    def test_20_behavior_mutant_unknown_kernel_get_killed(self):
        mutant = SOURCE.replace("bool supported = backend_abi_supported() && ref != NULL;", "bool supported = backend_abi_supported();", 1)
        self.assertNotEqual(mutant, SOURCE)
        binary = self.compile(mutant, "mutant-unknown-kernel", True)
        with self.assertRaises(AssertionError):
            check_unknown(self.run_case("unknown_darwin", binary))
        print("MUTATION KILLED: unknown Darwin GET allowed", flush=True)

    def test_21_behavior_mutant_unstable_policy_killed(self):
        mutant = SOURCE.replace("bool stable = !unstable && identity_same(&before, &between) && identity_same(&between, &after);", "bool stable = true;", 1)
        self.assertNotEqual(mutant, SOURCE)
        binary = self.compile(mutant, "mutant-unstable-policy", True)
        with self.assertRaisesRegex(AssertionError, "unstable identity reported stable"):
            check_unstable(self.run_case("pid_reuse_after", binary))
        print("MUTATION KILLED: unstable PID treated as effective policy", flush=True)

    def test_22_behavior_mutant_partial_priority_accepted_killed(self):
        mutant = SOURCE.replace("priority_valid = rc == (int)sizeof(Priority) && priority.pid == pid;", "priority_valid = rc >= 0 && priority.pid == pid;", 1)
        self.assertNotEqual(mutant, SOURCE)
        binary = self.compile(mutant, "mutant-priority-partial", True)
        result = self.run_case("priority_partial_return", binary)
        with self.assertRaisesRegex(AssertionError, "partial read shown as effective"):
            require(result[1]["priority"]["effective_band"] is None, "partial read shown as effective")
        print("MUTATION KILLED: partial priority return accepted", flush=True)

    def test_23_behavior_mutant_json_injection_killed(self):
        old = "if (c == '\"' || c == '\\\\')"
        mutant = SOURCE.replace(old, "if (c == '\\\\')", 1)
        self.assertNotEqual(mutant, SOURCE)
        binary = self.compile(mutant, "mutant-json-unescaped", True)
        with self.assertRaises(json.JSONDecodeError):
            self.run_case("json_escape", binary)
        print("MUTATION KILLED: unescaped JSON quote", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
