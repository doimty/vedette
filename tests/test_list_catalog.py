#!/usr/bin/env python3
"""Execute the production portable catalog kernel; NOT Foundation/UIKit proof."""
from pathlib import Path
import os
import subprocess
import tempfile
import shutil

ROOT = Path(__file__).resolve().parents[1]
FLAGS = [os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra',
         '-Werror', '-pedantic', '-pthread']
with tempfile.TemporaryDirectory(prefix='vdt-list-catalog-') as tmp:
    directory = Path(tmp)
    executable = str(directory / 'fixture')
    source = ROOT / 'tests/test_list_catalog.c'
    subprocess.run(FLAGS + [str(source), '-o', executable], check=True)
    subprocess.run([executable], check=True)
    # Negative controls must compile before a runtime assertion kills them.
    (directory / 'tests').mkdir()
    (directory / 'vedetteprefs').mkdir()
    shutil.copyfile(source, directory / 'tests/test_list_catalog.c')
    kernel = (ROOT / 'vedetteprefs/VDTListCatalog.h').read_text()
    mutants = {
        'stale-publish': ('if (generation != state->generation)', 'if (false)'),
        'drop-loaded-on-failure': ('if (!success) return VDTListCatalogFailed;',
            'if (!success) { state->loaded = false; return VDTListCatalogFailed; }'),
        'parallel-scan': ('if (state->loading) return false;',
            'if (state->loading) return true;'),
    }
    for name, (old, new) in mutants.items():
        assert kernel.count(old) == 1
        (directory / 'vedetteprefs/VDTListCatalog.h').write_text(kernel.replace(old, new))
        subprocess.run(FLAGS + [str(directory / 'tests/test_list_catalog.c'),
                               '-o', executable], check=True)
        result = subprocess.run([executable], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        assert result.returncode != 0, 'SURVIVED: ' + name
        print('KILLED (compiled then runtime assertion): ' + name)
