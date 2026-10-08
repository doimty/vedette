"""Reviewed best-effort uninstall delta: dpkg must never be vetoed by the tool.

The postinst/prerm scripts keep the journal and still ask nicectl to restore,
but a control failure is a warning now. Both full-file texts are pinned here,
so any other edit is rejected rather than silently accepted.
"""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='1d35e7a4a6f8b0f904513491ade7899ee62faf2a'
FILES={'layout/DEBIAN/postinst','layout/DEBIAN/prerm'}
NEW_POSTINST='''#!/bin/bash
set -u
# Resume is advisory. A control failure must never leave dpkg half-configured;
# the journal stays on disk and the runtime reloads it on the next launch.
if command -v jbroot >/dev/null 2>&1; then
    ctl="$(jbroot)/usr/libexec/vedette-nicectl"
    if [ -x "$ctl" ]; then
        "$ctl" resume || echo "Vedette: nice resume failed (errno=$?); continuing package configuration." >&2
    else
        echo 'Vedette: nice control tool missing; continuing package configuration.' >&2
    fi
else
    echo 'Vedette: cannot resolve nice control path; continuing package configuration.' >&2
fi

echo "Killing runningboardd..."
killall -9 runningboardd || true

exit 0
'''
NEW_PRERM='''#!/bin/bash
set -u
# Best effort: a reboot or process exit restores kernel nice automatically.
# Never delete the journal here; diagnostics remain available after removal.
continue_after_nice_failure() {
    echo "Vedette: nice restoration/control failed (errno=$1); continuing package removal." >&2
}
case "${1:-}" in
    remove|deconfigure)
        if ! command -v jbroot >/dev/null 2>&1; then
            echo 'Vedette: cannot resolve roothide path; continuing package removal.' >&2
        else
            ctl="$(jbroot)/usr/libexec/vedette-nicectl"
            if [ ! -x "$ctl" ]; then
                echo 'Vedette: nice restoration tool missing; continuing package removal.' >&2
            else
                "$ctl" restore-for-removal || continue_after_nice_failure "$?"
            fi
        fi
        ;;
esac
exit 0
'''
EXPECTED={'layout/DEBIAN/postinst':NEW_POSTINST.encode(),'layout/DEBIAN/prerm':NEW_PRERM.encode()}

def without_softremove(name, actual):
    if name not in FILES: return actual
    assert actual==EXPECTED[name],'Unexpected change outside reviewed uninstall delta: '+name
    # Return the pinned pre-delta content so the older freeze chains still apply.
    return subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT)
