#!/bin/bash
# Exactly one full host/native validation job per tested SHA. Packaging depends
# on this job; the two scheme jobs never repeat the Foundation/mutation suite.
set -euo pipefail
cd "$(dirname "$0")/.."
tests/run_process_identity_tests.sh
python3 tests/check_auto_monitor_path.py
sh tests/run_list_order_tests.sh
for suite in test_preferences_ui test_ios15_cell_lifecycle test_ui21_baseline test_process_action_ui21 test_section_text test_efficiency_contracts test_diagnostic_preprocess; do
  python3 -B "tests/$suite.py"
done
make -f Makefile.tests test-nice STORE_RUNNER=sudo
sudo bash tests/run_nice_native_tests.sh
sudo bash tests/run_springboard_native_tests.sh
for suite in test_extension_contracts test_bundle_rules; do python3 -B "tests/$suite.py"; done
python3 -B tests/test_extensions_native.py --require-native
sudo python3 -B tests/test_extension_nice_native.py --require-native
sudo python3 -B tests/test_independent_rules_native.py --require-native
python3 -B tests/test_list_catalog.py
python3 -B tests/test_list_catalog_native.py --require-native
python3 -B tests/test_list_reentry.py --require-native
for suite in test_memory_policy test_resource_apply test_resource_manager test_resource_ui21; do python3 -B "tests/$suite.py"; done
python3 -B tests/test_resource_preferences_native.py --require-native
python3 -B tests/test_rebuild_baseline.py
python3 -B tests/test_formal_projection.py
