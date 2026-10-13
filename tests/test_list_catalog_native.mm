// Production Foundation catalog integration. Queued executor + fake LS only;
// real scanner, metadata validator and filesystem snapshot publication run.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#define LSApplicationWorkspace VDTCatalogFixtureWorkspace
#define LSApplicationProxy VDTCatalogFixtureProxy
#define LSBundleProxy VDTCatalogFixtureBundle
#define LSResourceProxy VDTCatalogFixtureResource
#define _LSQueryResult VDTCatalogFixtureResult
#import "../PrivateHeaders.h"
#import "../vedetteprefs/VDTExtensionCatalog.h"
static NSArray *installed;
static unsigned scans;
static BOOL failRead;
static NSMutableArray *jobs;
static Class CatalogClassLookup(const char *name) {
    if (!strcmp(name,"LSApplicationWorkspace")) return VDTCatalogFixtureWorkspace.class;
    return objc_getClass(name);
}
static void CatalogDispatch(dispatch_queue_t queue, dispatch_block_t block) {
    if (queue == dispatch_get_main_queue()) block(); else [jobs addObject:[block copy]];
}
#define objc_getClass CatalogClassLookup
#define dispatch_async CatalogDispatch
#import "../vedetteprefs/VDTExtensionCatalog.m"
#undef dispatch_async
#undef objc_getClass
@implementation VDTCatalogFixtureWorkspace
+ (instancetype)defaultWorkspace { static id w; if (!w) w=[self new]; return w; }
- (NSArray *)allApplications { ++scans; return failRead ? nil : installed; }
- (void)addObserver:(id)observer { (void)observer; }
- (void)removeObserver:(id)observer { (void)observer; }
@end
@implementation VDTCatalogFixtureResult @end
@implementation VDTCatalogFixtureResource @end
@implementation VDTCatalogFixtureBundle
- (NSString *)bundleIdentifier { return nil; }
- (NSString *)bundleExecutable { return nil; }
- (NSURL *)bundleURL { return nil; }
- (NSURL *)bundleContainerURL { return nil; }
- (NSURL *)dataContainerURL { return nil; }
@end
static NSURL *hostURL;
@implementation VDTCatalogFixtureProxy
+ (id)applicationProxyForBundleURL:(NSURL *)url { (void)url; return nil; }
- (NSURL *)bundleURL { return hostURL; }
- (NSString *)bundleIdentifier { return @"fixture.host"; }
@end
@interface VDTCatalogObserver : NSObject <VDTExtensionCatalogObserver>
@property unsigned callbacks;
@end
@implementation VDTCatalogObserver
- (void)extensionCatalogDidUpdate:(VDTExtensionCatalog *)c { (void)c; self.callbacks++; }
@end
static unsigned assertions;
#define CHECK(...) do { ++assertions; if (!(__VA_ARGS__)) { fprintf(stderr,"catalog assertion line %d: %s\n",__LINE__,#__VA_ARGS__); abort(); } } while(0)
static void step(void) { CHECK(jobs.count>0); dispatch_block_t b=[jobs[0] copy]; [jobs removeObjectAtIndex:0]; b(); }
int main(void) { @autoreleasepool {
    CHECK(NSThread.isMainThread); jobs=[NSMutableArray new];
    NSString *root=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *host=[root stringByAppendingPathComponent:@"Host.app"], *ext=[host stringByAppendingPathComponent:@"PlugIns/Widget.appex"];
    CHECK([fm createDirectoryAtPath:ext withIntermediateDirectories:YES attributes:nil error:nil]);
    CHECK([@{ @"CFBundleIdentifier":@"fixture.host", @"CFBundleExecutable":@"Host" } writeToFile:[host stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
    CHECK([@{ @"CFBundleIdentifier":@"fixture.ext", @"CFBundleExecutable":@"Widget", @"CFBundleDisplayName":@"Widget", @"NSExtension":@{ @"NSExtensionPointIdentifier":@"fixture.point" } } writeToFile:[ext stringByAppendingPathComponent:@"Info.plist"] atomically:YES]);
    CHECK([fm createFileAtPath:[ext stringByAppendingPathComponent:@"Widget"] contents:[NSData data] attributes:nil]);
    hostURL=[NSURL fileURLWithPath:host]; installed=@[[VDTCatalogFixtureProxy new]];
    // Original Choicy runtime names coexisting cannot select this VDT catalog.
    for (NSString *name in @[@"CHPDaemonInfo",@"CHPDaemonList",@"CHPDaemonListController",@"CHPListController"]) {
        Class c=objc_allocateClassPair(NSObject.class,name.UTF8String,0); CHECK(c!=Nil); objc_registerClassPair(c);
    }
    VDTExtensionCatalog *c=[VDTExtensionCatalog sharedInstance];
    VDTCatalogObserver *observer=[VDTCatalogObserver new]; [c addObserver:observer];
    [c ensureLoaded]; CHECK(c.loading && !c.loaded && jobs.count==1); step();
    CHECK(c.loaded && !c.loading && c.records.count==1 && scans==1);
    NSDictionary *record=c.records[0]; CHECK([record[@"extensionIdentifier"] isEqual:@"fixture.ext"]);
    CHECK([record[@"containingAppIdentifier"] isEqual:@"fixture.host"]);
    for (unsigned i=0;i<1000;i++) [[VDTExtensionCatalog sharedInstance] ensureLoaded];
    CHECK(scans==1 && jobs.count==0 && c==[VDTExtensionCatalog sharedInstance]);
    // Event invalidation while a scan is pending rejects the old completion,
    // starts exactly one newer scan, and keeps the warm snapshot in the meantime.
    [c refresh]; [c applicationsDidInstall:nil]; [c applicationsDidUninstall:nil];
    CHECK(jobs.count==1 && c.records[0]==record); step();
    CHECK(jobs.count==1 && c.loading && c.records[0]==record); step();
    CHECK(jobs.count==0 && !c.loading && c.loaded && scans==3);
    NSArray *warm=c.records; failRead=YES; [c refresh]; step();
    CHECK(c.failed && c.loaded && !c.loading && c.records==warm && jobs.count==0);
    [c ensureLoaded]; CHECK(jobs.count==0); // no retry loop after failure
    failRead=NO; installed=@[]; [c refresh]; step();
    CHECK(!c.failed && c.loaded && c.records.count==0); // real successful empty
    [c removeObserver:observer]; unsigned notifications=observer.callbacks;
    [c refresh]; step(); CHECK(observer.callbacks==notifications);
    CHECK([fm removeItemAtPath:root error:nil]);
    printf("PASS production Foundation catalog: %u assertions; fake LS/executor, real metadata/filesystem; not UIKit/device\n",assertions);
} return 0; }
