"""Only the reviewed SpringBoard selector/catalog delta, not a broad skip."""
from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='a054671a0a3f6b0c476d95906fd924687b5b3386'
FILES={'VDTProcessManager.mm','vedetteprefs/ChoicyPreferences/CHPDaemonList.m'}
RESOLVE='''    // Only the canonical system executable may use this reserved daemon rule.
    // Explicit SpringBoard entries win (including disabled entries), so a
    // separately hand-written App rule cannot silently re-enable that target.
    if (VDTSpringBoardPathMatches(executablePath.UTF8String)) {
        for (NSDictionary *config in daemonConfigs) {
            NSString *identifier = vdt_nonEmptyString(config[VDTConfigIdentifierKey]);
            if (VDTSpringBoardRuleMatches(identifier.UTF8String, executablePath.UTF8String)) {
                matched = config;
                matchedName = identifier;
                break;
            }
        }
    }

'''
SEED='''
	// Known system entry, not an assertion that it is currently running. This
	// remains available when LaunchDaemons/LaunchServices omit SpringBoard.
	// Seed first so later discovery cannot replace it with a same-named binary.
	CHPDaemonInfo* springBoard = [[CHPDaemonInfo alloc] init];
	springBoard.executablePath = @VDT_SPRINGBOARD_EXECUTABLE;
	springBoard.plistIdentifier = @VDT_SPRINGBOARD_LAUNCHD_ID;
	[daemonListM addObject:springBoard];
'''

def expected_springboard(name,data):
    s=data.decode()
    def replace(old,new):
        nonlocal s
        assert s.count(old)==1,(name,old,s.count(old))
        s=s.replace(old,new,1)
    if name=='VDTProcessManager.mm':
        replace('#import "VDTPolicyTransition.h"\n','#import "VDTPolicyTransition.h"\n#import "VDTSpringBoardIdentity.h"\n')
        replace('    // A verified App identity is authoritative',RESOLVE+'    // A verified App identity is authoritative')
        replace('    BOOL resolvedAsApplication = NO;\n    if (executablePath) {','    BOOL resolvedAsApplication = NO;\n    if (executablePath && !matched) {')
        replace('            if (!configured) continue;\n            if (VDTProcessNameMatches(configured,','            // Never fall back to basename/p_comm for the reserved system rule.\n            if (!configured || VDTSpringBoardRuleName(configured)) continue;\n            if (VDTProcessNameMatches(configured,')
    elif name=='vedetteprefs/ChoicyPreferences/CHPDaemonList.m':
        replace('#import "../../Common.h"\n','#import "../../Common.h"\n#import "../../VDTSpringBoardIdentity.h"\n')
        replace('\tNSMutableArray* daemonListM = [NSMutableArray new];\n','\tNSMutableArray* daemonListM = [NSMutableArray new];\n'+SEED)
        replace(' && ![info.plistIdentifier isEqualToString:@"com.apple.SpringBoard"]','')
    return s.encode()

def without_springboard(name,data):
    if name not in FILES:return data
    old=subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT)
    assert data==expected_springboard(name,old),'Unexpected SpringBoard change: '+name
    return old
