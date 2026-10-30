#!/usr/bin/env python3
"""Reader/Model Foundation regression with a compiled old-boxing mutant.

Default: Darwin builds/runs real Reader + Model and a targeted mutant; elsewhere
SKIP 77 without building. --require-native makes an unsupported host fail.
--source-only checks a narrow source contract, never Foundation execution.
All external preference/status functions are in-memory stubs; no device IO.
"""
import argparse
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
PREFS = ROOT / 'vedetteprefs'
READER = PREFS / 'VDTCheckResultReader.m'
MODEL = PREFS / 'VDTCheckResultModel.m'
FIXTURE = ROOT / 'tests/test_check_result_reader_native.m'
STUBS = ROOT / 'tests/native_stubs'
FIXED = 'result[@"configurationValid"] = available && readerGlobalValid(prefs) && sectionValid ? @YES : @NO;'
OLD = 'result[@"configurationValid"] = @(available && readerGlobalValid(prefs) && sectionValid);'
MARKER = 'CHECK_READER_FAIL:valid-configuration'


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def old_boxing_mutant(source):
    require(source.count(FIXED) == 1, 'fixed configurationValid expression is absent or ambiguous')
    require(OLD not in source, 'old integer-boxing expression remains in Reader')
    mutated = source.replace(FIXED, OLD, 1)
    require(mutated.count(OLD) == 1 and FIXED not in mutated, 'mutation is not unique')
    return mutated


def source_contracts():
    reader = READER.read_text(encoding='utf-8')
    model = MODEL.read_text(encoding='utf-8')
    old_boxing_mutant(reader)
    require('CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID()' in reader,
            'Reader must validate saved Boolean preferences')
    require('CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID() ? value : nil' in model,
            'Model must validate CFBoolean configuration flags')
    require('readerSectionValid(prefs, section)' in reader and 'readerGlobalValid(prefs)' in reader,
            'global and section validation must remain wired into Reader')
    require('VDTCheckResultModels(niceRule, niceReceipt,' in reader,
            'Reader must project through the production Model')
    print('PASS check-result Reader source contract (source only; no native execution)', flush=True)
    return reader


def run_native(reader):
    with tempfile.TemporaryDirectory(prefix='vdt-check-reader-') as directory:
        temporary = Path(directory)
        binary = temporary / 'check-reader'
        command = ['xcrun', 'clang', '-std=gnu11', '-fobjc-arc', '-fblocks', '-O1',
                   '-Wall', '-Wextra', '-Werror', '-I' + str(PREFS), '-I' + str(ROOT),
                   '-I' + str(STUBS)]

        def build(reader_path):
            subprocess.run(command + [str(reader_path), str(MODEL), str(FIXTURE),
                                      '-framework', 'Foundation', '-framework', 'CoreFoundation',
                                      '-o', str(binary)], cwd=ROOT, check=True)
            return binary

        # Baseline compiles the original source files directly, without extraction.
        subprocess.run([str(build(READER))], cwd=temporary, check=True)
        mutant = temporary / 'VDTCheckResultReader.m'
        mutant.write_text(old_boxing_mutant(reader), encoding='utf-8')
        build(mutant)  # A compilation failure is a gate failure, not a mutant kill.
        import resource
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        result = subprocess.run([str(binary)], cwd=temporary, capture_output=True, text=True)
        require(result.returncode != 0 and MARKER in result.stderr,
                'old-boxing mutant survived or failed off-target: '
                + str(result.returncode) + '\n' + result.stdout + result.stderr)
        print('KILLED compiled Reader mutant: old logical-expression integer boxing', flush=True)
        print('PASS native Reader + Model and targeted mutant (Foundation; no device IO)', flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--require-native', action='store_true', help='fail if Darwin Foundation is unavailable')
    mode.add_argument('--source-only', action='store_true', help='check source contract only; never a native pass')
    args = parser.parse_args()
    if args.source_only:
        source_contracts()
        return 0
    if platform.system() != 'Darwin':
        print('SKIP check-result Reader native gate: requires Darwin Foundation; no build or native run performed')
        return 1 if args.require_native else 77
    run_native(source_contracts())
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
