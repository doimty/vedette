#include "VDTBundleRules.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

static void path_case(const char *path, const char *suffix, const char *wanted) {
    char result[1024]; memset(result, 'X', sizeof(result));
    bool ok = VDTCopyNearestBundlePath(path, suffix, result, sizeof(result));
    assert(ok == (wanted != NULL));
    if (wanted) assert(strcmp(result, wanted) == 0);
    else assert(result[0] == '\0');
}

int main(void) {
    // Every priority combination, including disabled/malformed configs (present=true).
    for (unsigned bits = 0; bits < 32; ++bits) {
        bool app=bits&1, ext=bits&2, valid=bits&4, ec=bits&8, ac=bits&16;
        VDTBundleRuleChoice wanted;
        if (ext) wanted = !valid ? VDTBundleRuleNone : ec ? VDTBundleRuleExtension :
            app && ac ? VDTBundleRuleApp : VDTBundleRuleNone;
        else wanted = app ? (ac ? VDTBundleRuleApp : VDTBundleRuleNone) : VDTBundleRuleDaemon;
        assert(VDTChooseBundleRule(app,ext,valid,ec,ac) == wanted);
    }
    path_case("/A.app/A", "app", "/A.app");
    path_case("/A.app/PlugIns/B.appex/B", "appex", "/A.app/PlugIns/B.appex");
    path_case("/A.app/PlugIns/B.appex/B", "app", "/A.app");
    path_case("/A.app/PlugIns/B.appex/Frameworks/Helper", "appex", "/A.app/PlugIns/B.appex");
    path_case("/A.APP/PlugIns/B.APPEX/B", "APPEX", "/A.APP/PlugIns/B.APPEX");
    path_case("/A.app/Nested/C.app/C", "app", "/A.app/Nested/C.app");
    path_case("/System/X.appex/X", "app", NULL);
    path_case("/System/X.appex/X", "appex", "/System/X.appex");
    path_case("/usr/bin/not.an.app", "app", NULL);
    path_case("/usr/bin/app", "app", NULL);
    path_case("relative.app/A", "app", NULL);
    path_case("/A.app/../Daemon", "app", NULL);
    path_case("/A.app/./A", "app", NULL);
    path_case("/A.app//A", "app", NULL);
    path_case("/A.app/A/", "app", NULL);
    path_case("/.app/A", "app", NULL);
    path_case("/A.app/A", "plugin", NULL);
    path_case(NULL, "app", NULL);
    char small[4]={'X','X','X','X'};
    assert(!VDTCopyNearestBundlePath("/A.app/A","app",small,sizeof(small)));
    assert(small[0]=='\0');
    char exact[7]; memset(exact, 'X', sizeof(exact));
    assert(!VDTCopyNearestBundlePath("/A.app/A","app",exact,6));
    assert(exact[0]=='\0');
    assert(!VDTCopyNearestBundlePath("/A.app/A","app",NULL,0));
    assert(VDTBundleExecutableNameIsValid("Widget"));
    assert(VDTBundleExecutableNameIsValid("com.example.widget"));
    assert(!VDTBundleExecutableNameIsValid(NULL));
    assert(!VDTBundleExecutableNameIsValid(""));
    assert(!VDTBundleExecutableNameIsValid("."));
    assert(!VDTBundleExecutableNameIsValid(".."));
    assert(!VDTBundleExecutableNameIsValid("../Helper"));
    assert(!VDTBundleExecutableNameIsValid("a/b"));
    puts("bundle rule kernel: 32 precedence combinations and 26 path/metadata checks passed");
    return 0;
}
