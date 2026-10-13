"""Read the real once-only validation workflow plus its checked-in entrypoint."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
def workflow_test_source():
 flow=(ROOT/'.github/workflows/roothide-build.yml').read_text()
 assert flow.count('bash ci/run_host_tests.sh')==1, 'missing/duplicate native test job'
 assert '  validate:\n' in flow and '    needs: validate\n' in flow, 'packages can bypass validation'
 package=flow.split('  package:\n',1)[1]
 assert 'Run host regression tests' not in package and 'ci/run_host_tests.sh' not in package, 'duplicate full regression per package'
 return flow+'\n'+(ROOT/'ci/run_host_tests.sh').read_text()
