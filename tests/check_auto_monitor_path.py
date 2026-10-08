#!/usr/bin/env python3
"""Static integration checks for Vedette's automatic monitoring path.

Executable host tests cover process identity primitives and policy-transition
failure semantics. These checks cover the Objective-C wiring that cannot run on
the Linux host: trusted config resolution, launch-notification catch-up, target
instance binding, and malformed-plist boundaries.
"""

from pathlib import Path
import re
import sys

REPO_ROOT = Path(__file__).resolve().parent.parent
MANAGER = (REPO_ROOT / "VDTProcessManager.mm").read_text()
TWEAK = (REPO_ROOT / "Vedette.xm").read_text()
HEADER = (REPO_ROOT / "VDTProcessManager.h").read_text()
SHARED = (REPO_ROOT / "VDTShared.mm").read_text()
POLICY = (REPO_ROOT / "VDTPolicyTransition.c").read_text()
POLICY_TEST = (REPO_ROOT / "tests/test_policy_transition.c").read_text()
DAEMON_INFO = (REPO_ROOT / "vedetteprefs/ChoicyPreferences/CHPDaemonInfo.m").read_text()
DAEMON_LIST = (REPO_ROOT / "vedetteprefs/ChoicyPreferences/CHPDaemonListController.m").read_text()


def fail(message: str) -> None:
    print(f"auto-monitor contract failed: {message}", file=sys.stderr)
    sys.exit(1)


def extract_function(text: str, signature: str) -> str:
    start = text.find(signature)
    if start < 0:
        fail(f"missing function {signature}")

    opening = text.find("{", start)
    if opening < 0:
        fail(f"missing body for {signature}")

    depth = 0
    for index in range(opening, len(text)):
        char = text[index]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start : index + 1]

    fail(f"unterminated function {signature}")
    raise AssertionError("unreachable")


def require(text: str, pattern: str, description: str) -> int:
    match = re.search(pattern, text, re.DOTALL)
    if not match:
        fail(f"missing {description}")
    return match.start()


def forbid(text: str, token: str, description: str) -> None:
    if token in text:
        fail(f"found {description}: {token}")


def check_launch_gate_and_catch_up() -> None:
    notify_sender = extract_function(TWEAK, "static void notify_new_pid")
    handler = extract_function(TWEAK, "static void handle_reported_pid_sync")
    apply_one = extract_function(TWEAK, "static void apply_launch_target_if_needed")
    reconcile = extract_function(TWEAK, "static void reconcile_unreported_processes_sync")
    retire = extract_function(TWEAK, "static void retire_targets_without_active_config")
    reload_sync = extract_function(TWEAK, "static void reloadPrefsSync")
    schedule = extract_function(TWEAK, "static void schedule_launch_catch_up_sync")

    resolve = require(handler, r"vdt_targets_for_pid\s*\(", "single-PID config resolution")
    no_match = require(
        handler,
        r"if\s*\(targets\.count\s*==\s*0\).*?@\"notConfigured\"",
        "unconfigured-process branch",
    )
    gated_apply = require(
        handler,
        r"apply_launch_target_if_needed\s*\(targets\.firstObject\)",
        "config-gated launch application",
    )
    catch_up = require(handler, r"schedule_launch_catch_up_sync\s*\(\)", "coalescing catch-up")
    if not (resolve < no_match < gated_apply < catch_up):
        fail("launch resolution, config gate, application, or catch-up is misordered")

    tracked = require(
        apply_one,
        r"containsObject:instanceKey.*?return",
        "same-instance duplicate suppression",
    )
    disabled = require(
        apply_one,
        r"if\s*\(!target_has_enabled_policy\(target\)\).*?addObject:instanceKey.*?return",
        "disabled launch without CPU syscalls",
    )
    policy_apply = require(apply_one, r"vdt_apply_target\s*\(target\)", "target policy application")
    if not (tracked < disabled < policy_apply):
        fail("launch deduplication or disabled-config gate occurs after policy application")

    config_cache = extract_function(TWEAK, "static NSArray<NSDictionary *> *current_normalized_configs_sync")
    require(config_cache, r"if\s*\(!normalized_configs_snapshot\).*?vdt_configs_from_prefs\s*\(VDTGetPrefs\(\)\)", "cold config snapshot fill")
    require(reconcile, r"current_normalized_configs_sync\s*\(\)", "reused catch-up config snapshot")
    require(handler, r"current_normalized_configs_sync\s*\(\)", "reused fast-path config snapshot")
    forbid(reconcile, "vdt_configs_from_prefs", "per-scan config re-normalization")
    require(reconcile, r"vdt_resolve_targets\s*\(configs\)", "catch-up target scan")
    require(reconcile, r"retire_targets_without_active_config\s*\(configs\)", "deleted-config retirement retry")
    require(reconcile, r"apply_launch_target_if_needed\s*\(target\)", "catch-up application gate")
    require(reconcile, r"intersectSet:liveInstances", "exited-instance retirement")
    immediate_scan = require(schedule, r"reconcile_unreported_processes_sync\s*\(\)", "immediate coalescing catch-up")
    trailing_scan = require(schedule, r"dispatch_after\s*\(.*?reconcile_unreported_processes_sync\s*\(\)", "trailing coalescing catch-up")
    if immediate_scan > trailing_scan:
        fail("coalescing catch-up waits for the trailing timer before its first scan")

    require(retire, r"active_config_keys\s*\(configs\)", "config-derived retirement gate")
    require(retire, r"managed_process_targets\(\)\.allKeys", "previously managed target enumeration")
    require(retire, r"activeKeys\s+containsObject:configKey", "active-config preservation on scan failure")
    lifetime = require(retire, r"vdt_target_instance_is_current\s*\(oldTarget\)", "deleted-target lifetime guard")
    identity = require(retire, r"vdt_target_is_current\s*\(oldTarget\)", "deleted-target identity guard")
    if lifetime > identity:
        fail("deleted-target path identity is checked before its PID lifetime")
    require(retire, r"restoreTarget\[VDTConfigPolicyKey\]\s*=\s*@\(VDTViolationPolicyNone\)", "deleted-target restore policy")
    require(retire, r"vdt_apply_target\s*\(restoreTarget\)", "deleted-target restore syscall gate")
    retirement = require(reload_sync, r"retire_targets_without_active_config\s*\(configs\)", "reload deletion retirement")
    new_apply = require(reload_sync, r"vdt_apply_target\s*\(target\)", "reload target application")
    if retirement > new_apply:
        fail("deleted targets are retired after new policies are applied")

    require(notify_sender, r"notify_set_state\s*\(", "Darwin PID fast path state")
    require(notify_sender, r"notify_post\s*\(", "name-only launch signal fallback")
    require(TWEAK, r"notify_get_state\s*\(", "Darwin PID fast path")
    require(TWEAK, r"if\s*\(launch_catch_up_scheduled\)\s*return", "notification-burst rate limit")
    require(TWEAK, r"else\s*\{\s*schedule_launch_catch_up_sync\s*\(\)", "state-read failure catch-up")
    require(TWEAK, r"handle_reported_pid_sync\s*\(", "serial PID handler")
    for syscall in (
        "proc_set_cpumon_params_fatal",
        "proc_setcpu_percentage",
        "proc_clear_cpulimits",
    ):
        forbid(TWEAK, syscall, "CPU syscall outside the manager policy gate")


def check_target_binding_and_policy_state_machine() -> None:
    target_body = extract_function(MANAGER, "static NSDictionary *target_for_pid")
    identity_body = extract_function(MANAGER, "static BOOL target_identity_is_current")
    apply_body = extract_function(MANAGER, "BOOL vdt_apply_target")

    for key in (
        "VDTTargetPidKey",
        "VDTTargetStartSecondsKey",
        "VDTTargetStartMicrosecondsKey",
        "VDTConfigTypeKey",
        "VDTConfigPercentageKey",
        "VDTConfigIntervalKey",
        "VDTConfigPolicyKey",
    ):
        require(target_body, rf"{key}\s*:", f"{key} bound to target")

    require(target_body, r"process_instance_token_for_pid\s*\(", "PID lifetime token capture")
    if len(re.findall(r"process_instance_token_for_pid\s*\(", identity_body)) < 2:
        fail("target identity is not lifetime-checked before and after path/name validation")
    require(identity_body, r"VDTProcessInstanceMatches\s*\(", "PID lifetime equality")
    require(identity_body, r"isEqualToString:expectedPath", "full-path identity equality")

    require(apply_body, r"VDTApplyPolicyTransition\s*\(", "tested policy state machine")
    require(apply_body, r"retirementFailed", "retirement-failure telemetry")
    require(POLICY, r"if\s*\(result\.disableResult\s*!=\s*0\).*?return\s+result", "hard retirement gate")
    require(POLICY, r"identityIsCurrent", "per-operation identity gate")
    require(POLICY_TEST, r"test_retirement_failure_blocks_new_policy", "retirement failure behavior test")
    require(POLICY_TEST, r"test_identity_is_checked_before_each_syscall", "per-syscall identity behavior test")
    require(POLICY_TEST, r"test_fatal_set_failure_is_not_resumed", "fatal failure behavior test")

    for key in ("VDTConfigPercentageKey", "VDTConfigIntervalKey", "VDTConfigPolicyKey"):
        require(apply_body, rf"target\s*\[\s*{key}\s*\]", f"{key} read from the same target")

    combined = MANAGER + TWEAK + HEADER
    for token in (
        "pids_with_identifier_and_type",
        "monitor_pids",
        "throttle_pids",
        "objectsAtIndexes",
    ):
        forbid(combined, token, "parallel-array monitor API")


def check_process_scan_and_config_boundaries() -> None:
    scan_body = extract_function(MANAGER, "NSArray<NSDictionary *>* vdt_resolve_targets")
    target_body = extract_function(MANAGER, "static NSDictionary *target_for_pid")

    require(scan_body, r"if\s*\(listBytes\s*<=\s*0\)\s*return", "proc_listpids size guard")
    require(scan_body, r"if\s*\(!buffer\)\s*return", "PID buffer allocation guard")
    require(
        scan_body,
        r"pidCount\s*=\s*writtenBytes\s*/\s*\(int\)sizeof\(int\)",
        "byte-count to PID-count conversion",
    )
    require(scan_body, r"idx\s*<\s*pidCount", "PID-count loop bound")

    for helper in ("vdt_array", "vdt_dictionary", "vdt_nonEmptyString"):
        require(MANAGER, rf"static\s+.*?\b{helper}\s*\(", f"plist guard {helper}")

    require(
        MANAGER,
        r"globallyEnabled\s*&&\s*vdt_bool\(entry\[@\"enabled\"\],\s*NO\)\s*&&\s*parametersValid",
        "global, per-process and valid-parameter opt-in folding",
    )
    require(MANAGER, r"percentage\s*<=\s*UINT8_MAX\s*:\s*percentage\s*<=\s*100", "kernel percentage bounds")
    require(
        MANAGER,
        r"policy\s*==\s*VDTViolationPolicyThrottle\s*\|\|\s*\(intervalValid\s*&&\s*interval\s*>\s*0\)",
        "policy-relevant interval validation",
    )
    require(
        MANAGER,
        r"CFGetTypeID\(\(__bridge\s+CFTypeRef\)number\)\s*==\s*CFBooleanGetTypeID\(\)",
        "boolean rejected as numeric parameter",
    )
    require(
        MANAGER,
        r"!isfinite\(numericValue\)\s*\|\|\s*numericValue\s*!=\s*\(double\)parsed",
        "fractional and non-finite numeric rejection",
    )

    require(
        MANAGER,
        r"application_bundle_path_for_executable.*?while\s*\(candidate\.length\s*>\s*1\).*?pathExtension.*?@\"app\"",
        "nested application-bundle classification",
    )
    require(target_body, r"resolvedAsApplication", "App identity classification")
    require(
        target_body,
        r"if\s*\(!matched\s*&&\s*!resolvedAsApplication\s*&&\s*daemonConfigs\.count\s*>\s*0\)",
        "App-to-daemon fallthrough block",
    )
    require(target_body, r"VDTCopyLastPathComponent\s*\(", "full executable-name derivation")
    require(target_body, r"VDTProcessNameMatches\s*\(", "daemon identity comparison")
    require(
        DAEMON_INFO,
        r"return\s+\[self\.executablePath\s+lastPathComponent\]",
        "preference-side full executable name",
    )
    require(
        DAEMON_LIST,
        r"setProperty:\[info\s+displayName\]\s+forKey:@\"daemonName\"",
        "stored daemon-name source",
    )

    require(SHARED, r"VDTDictionaryFromFile", "validated plist loader")
    require(
        SHARED,
        r"\[loaded\s+isKindOfClass:\[NSDictionary\s+class\]\]\s*\?\s*loaded\s*:\s*@\{\}",
        "malformed plist root fail-closed fallback",
    )
    forbid(SHARED, "addEntriesFromDictionary:", "unguarded plist merge")
    require(SHARED, r"VDTConfigArray\s*\(", "preference-side config collection guard")


def check_callback_and_process_classification() -> None:
    require(
        TWEAK,
        r"dispatch_async\(vedette_serial_queue\(\),\s*\^\{.*?handle_reported_pid_sync",
        "serialized new-process handler",
    )
    forbid(TWEAK, "(CFNotificationCallback)reloadPrefs", "invalid CF callback cast")
    forbid(TWEAK, "(CFNotificationCallback)restoreAllMonitors", "invalid CF callback cast")
    require(TWEAK, r"prefsChangedCallback", "typed prefs callback")
    require(TWEAK, r"restoreAllMonitorsCallback", "typed restore callback")

    require(TWEAK, r"VDTCopyProcessInfoString\s*\(pid,\s*path.*?proc_pidpath\)", "authoritative self path")
    require(TWEAK, r"isEqualToString:@\"/usr/libexec/runningboardd\"", "exact runningboardd path")
    forbid(TWEAK, "[procInfo arguments]", "argv-based privileged-process classification")


def main() -> None:
    check_launch_gate_and_catch_up()
    check_target_binding_and_policy_state_machine()
    check_process_scan_and_config_boundaries()
    check_callback_and_process_classification()
    print("automatic monitor contract checks passed")


if __name__ == "__main__":
    main()
