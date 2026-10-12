#!/usr/bin/env python3
"""Manager-side resource integration contracts (source level, not a runtime test).

Pins: independent memoryRules/jetsamRules loading with frozen-core validation,
per-resource inheritance selection, resource-only target reachability, the
capability-gated apply stage with its NULL production backend, and the
Vedette.xm call sites. Negative controls must be rejected by the same gates.
"""
from pathlib import Path
import unittest

from extension_projection import projected_bytes
from extension_projection import function_source

ROOT = Path(__file__).resolve().parents[1]
MANAGER = ROOT / 'VDTProcessManager.mm'
HEADER = ROOT / 'VDTProcessManager.h'
RUNTIME = ROOT / 'Vedette.xm'


def has(text, *tokens):
    for token in tokens:
        assert token in text, 'missing manager evidence: ' + token


def manager_contract(manager):
    # Rule loading and typed classification.
    has(manager,
        'for (NSString *sectionKey in @[@"memoryRules", @"jetsamRules"]) {',
        '@"bundleIdentifier", VDTConfigTypeApp, globallyEnabled',
        '@"daemonName", VDTConfigTypeDaemon, globallyEnabled',
        '@"extensionIdentifier", VDTConfigTypeExtension, globallyEnabled',
        'VDTPolicyRecordState state = VDTPolicyRecordInvalid;',
        'state = VDTPolicyRecordDisabled;',
        'resource_memory_core_rule(validatedEntry, VDTPolicyRecordEnabled).parseStatus',
        'resource_jetsam_core_rule(validatedEntry, VDTPolicyRecordEnabled).parseStatus',
        '@"state": @(state),',
        'VDTPolicyInputBoolean', 'VDTPolicyInputFloatingPoint',
        'VDTPolicyInputOverflow', 'VDTPolicyInputString')
    # Index, presence and selection.
    assert manager.count('if (!map[identifier]) map[identifier] = rule;') == 2, \
        'both app and extension indexes must be first-entry-wins'
    has(manager,
        'typedef struct VDTResourceRuleMaps {',
        'if (!map[identifier]) map[identifier] = rule;',
        'static BOOL resource_maps_empty(VDTResourceRuleMaps maps){',
        'NSDictionary *extensionRule = extensionRulesById[extensionIdentifier];',
        'if (extensionRule) return extensionRule;',
        'if (configured && VDTProcessNameMatches(configured, executableName, procComm)) return rule;')
    # Resolution: resource-only targets survive and carry their intents.
    has(manager,
        'BOOL hasResourceIntent = memoryRule != nil || jetsamRule != nil;',
        'if (!matched && !hasResourceIntent) return nil;',
        'typeValue = resourceIdentityType;',
        'enabledValue = @NO;',
        'if (memoryRule) target[VDTTargetMemoryRuleKey] = memoryRule;',
        'if (jetsamRule) target[VDTTargetJetsamRuleKey] = jetsamRule;',
        'NSArray<NSDictionary *>* vdt_resolve_targets(NSArray<NSDictionary *> *configs, NSArray<NSDictionary *> *resourceRules){',
        'NSArray<NSDictionary *>* vdt_targets_for_pid(pid_t pid, NSArray<NSDictionary *> *configs, NSArray<NSDictionary *> *resourceRules){',
        'VDTResourceRuleMaps resourceMaps = resource_rule_maps(resourceRules);')
    # Apply stage: capability gates stay closed and the backend stays NULL.
    has(manager,
        'static VDTApplyCapabilities vdt_resource_capabilities(void){',
        'capabilities.writeMemoryCustom = false;',
        'capabilities.writeMemoryUnlimited = false;',
        'capabilities.writeJetsamBand = false;',
        'capabilities.restoreWriteback = false;',
        'static const VDTResourceBackend *vdt_resource_backend(void){\n    return NULL;',
        'VDTApplyBuildProgram(pid,',
        'vdt_resource_capabilities());',
        'VDTApplyExecute(&program, &applyTarget,',
        '"runningboardd.resourceStage"',
        'BOOL cpuApplied = result.success;',
        'BOOL resourceSettled = vdt_apply_resource_target(target);',
        'return cpuApplied && resourceSettled;',
        'report.memoryOutcome != VDTApplyOutcomeFailed &&')
    apply_body = function_source(manager, 'BOOL vdt_apply_target(NSDictionary *rawTarget)')
    assert apply_body.index('VDTApplyPolicyTransition(') < apply_body.index('BOOL resourceSettled = vdt_apply_resource_target(target);'), \
        'CPU transition must run before the resource stage'
    assert 'result.success ? vdt_apply_resource_target' not in apply_body, 'resource stage must not be gated on CPU success'


def header_contract(header):
    has(header,
        'extern NSString * const VDTTargetMemoryRuleKey;',
        'extern NSString * const VDTTargetJetsamRuleKey;',
        'NSArray<NSDictionary *>* vdt_resource_rules_from_prefs(NSDictionary *prefs);',
        'NSArray<NSDictionary *>* vdt_resolve_targets(NSArray<NSDictionary *> *configs, NSArray<NSDictionary *> *resourceRules);',
        'NSArray<NSDictionary *>* vdt_targets_for_pid(pid_t pid, NSArray<NSDictionary *> *configs, NSArray<NSDictionary *> *resourceRules);')


def runtime_contract(runtime):
    has(runtime,
        'static NSArray<NSDictionary *> *normalized_resource_rules_snapshot;',
        'current_normalized_resource_rules_sync(void){',
        'vdt_resource_rules_from_prefs(VDTGetPrefs())',
        'vdt_resolve_targets(configs, current_normalized_resource_rules_sync());',
        'vdt_targets_for_pid(pid, configs, current_normalized_resource_rules_sync());',
        'NSArray<NSDictionary *> *resourceRules = vdt_resource_rules_from_prefs(newPrefs);',
        'normalized_resource_rules_snapshot = [resourceRules copy];',
        'vdt_resolve_targets(configs, resourceRules);',
        'vdt_resolve_targets(restoreConfigs, vdt_resource_rules_from_prefs(getTempPrefs()))',
        '[restoreTarget removeObjectForKey:VDTTargetMemoryRuleKey];',
        '[restoreTarget removeObjectForKey:VDTTargetJetsamRuleKey];')
    for stale in ('vdt_resolve_targets(configs);', 'vdt_targets_for_pid(pid, configs);'):
        assert stale not in runtime, 'stale pre-resource call remains: ' + stale


class ResourceManagerIntegration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.manager = MANAGER.read_text()
        cls.header = HEADER.read_text()
        cls.runtime = RUNTIME.read_text()

    def test_contracts(self):
        manager_contract(self.manager)
        header_contract(self.header)
        runtime_contract(self.runtime)

    def test_reviewed_paths_project_to_ui21_baseline(self):
        for path in ('VDTProcessManager.mm', 'VDTProcessManager.h', 'Vedette.xm'):
            with self.subTest(file=path):
                self.assertNotEqual(projected_bytes(path), b'')

    def test_stale_resolve_call_is_rejected(self):
        mutated = self.runtime.replace(
            'vdt_resolve_targets(configs, current_normalized_resource_rules_sync());',
            'vdt_resolve_targets(configs);', 1)
        self.assertNotEqual(mutated, self.runtime)
        with self.assertRaises(AssertionError):
            runtime_contract(mutated)

    def test_open_capability_is_rejected(self):
        mutated = self.manager.replace('capabilities.writeMemoryCustom = false;', 'capabilities.writeMemoryCustom = true;', 1)
        self.assertNotEqual(mutated, self.manager)
        with self.assertRaises(AssertionError):
            manager_contract(mutated)

    def test_cpu_gated_resource_stage_is_rejected(self):
        mutated = self.manager.replace(
            'BOOL resourceSettled = vdt_apply_resource_target(target);',
            'BOOL resourceSettled = result.success ? vdt_apply_resource_target(target) : YES;', 1)
        self.assertNotEqual(mutated, self.manager)
        with self.assertRaises(AssertionError):
            manager_contract(mutated)

    def test_last_entry_wins_index_is_rejected(self):
        mutated = self.manager.replace('if (!map[identifier]) map[identifier] = rule;', 'map[identifier] = rule;')
        self.assertNotEqual(mutated, self.manager)
        with self.assertRaises(AssertionError):
            manager_contract(mutated)

    def test_dropped_resource_only_gate_is_rejected(self):
        mutated = self.manager.replace('if (!matched && !hasResourceIntent) return nil;', 'if (!matched) return nil;', 1)
        self.assertNotEqual(mutated, self.manager)
        with self.assertRaises(AssertionError):
            manager_contract(mutated)

    def test_typed_classifier_downgrade_is_rejected(self):
        mutated = self.manager.replace(
            'if (!isfinite(numericValue)) return (VDTPolicyInteger){VDTPolicyInputOverflow, 0};',
            'if (!isfinite(numericValue)) return (VDTPolicyInteger){VDTPolicyInputInteger, (long long)numericValue};', 1)
        self.assertNotEqual(mutated, self.manager)
        with self.assertRaises(AssertionError):
            manager_contract(mutated)


if __name__ == '__main__':
    unittest.main(verbosity=2)
