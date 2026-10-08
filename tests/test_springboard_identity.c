#include "../VDTSpringBoardIdentity.h"
#include <stdio.h>
#include <stdlib.h>

#define CHECK(x) do { ++checks; if (!(x)) { fprintf(stderr,"line %d: %s\n",__LINE__,#x); return 1; } } while (0)
int main(void) {
    unsigned checks=0;
    CHECK(VDTSpringBoardRuleName("SpringBoard"));
    CHECK(VDTSpringBoardPathMatches(VDT_SPRINGBOARD_EXECUTABLE));
    CHECK(VDTSpringBoardRuleMatches("SpringBoard",VDT_SPRINGBOARD_EXECUTABLE));
    const char *badNames[]={NULL,"","springboard","com.apple.springboard","SpringBoardHelper","SpringBoard ","SpringBoard.app"};
    for (unsigned i=0;i<sizeof(badNames)/sizeof(badNames[0]);++i) {
        CHECK(!VDTSpringBoardRuleName(badNames[i]));
        CHECK(!VDTSpringBoardRuleMatches(badNames[i],VDT_SPRINGBOARD_EXECUTABLE));
    }
    const char *badPaths[]={NULL,"","SpringBoard","/usr/libexec/SpringBoard",
        "/var/jb/System/Library/CoreServices/SpringBoard.app/SpringBoard",
        "/rootfs/System/Library/CoreServices/SpringBoard.app/SpringBoard",
        "/System/Library/CoreServices/SpringBoard.app/SpringBoard/",
        "/System/Library/CoreServices/SpringBoard.app/SpringBoardHelper",
        "/System/Library/CoreServices/SpringBoard.app/PlugIns/Helper.appex/SpringBoard",
        "/System/Library/CoreServices/Other.app/SpringBoard",
        "/Applications/Fake.app/SpringBoard",
        "/System/Library/CoreServices/SpringBoard.app/springboard",
        "/System/Library/CoreServices/../CoreServices/SpringBoard.app/SpringBoard"};
    for (unsigned i=0;i<sizeof(badPaths)/sizeof(badPaths[0]);++i) {
        CHECK(!VDTSpringBoardPathMatches(badPaths[i]));
        CHECK(!VDTSpringBoardRuleMatches("SpringBoard",badPaths[i]));
    }
    printf("SpringBoard exact identity: %u checks passed\n",checks);
    return 0;
}
