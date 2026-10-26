#import <Foundation/Foundation.h>
#include <assert.h>
#include <fcntl.h>
#include <unistd.h>
#include <notify.h>
static NSMutableDictionary *store;
static int notifications;
static int nativeLimit=100;
static BOOL lag;
static BOOL syncSucceeds=YES;
int battery_preferences_limit(void) { return nativeLimit; }
static NSString *slot(CFStringRef key,CFStringRef user,CFStringRef host) {return [NSString stringWithFormat:@"%@|%@|%@",user,host,key];}
static CFPropertyListRef mockCopy(CFStringRef key,CFStringRef app,CFStringRef user,CFStringRef host) {
    assert(CFEqual(app,CFSTR("com.apple.smartcharging.topoffprotection")));
    id value=store[slot(key,user,host)]; return value ? CFRetain((__bridge CFTypeRef)value) : NULL;
}
static void mockSet(CFStringRef key,CFPropertyListRef value,CFStringRef app,CFStringRef user,CFStringRef host) {
    assert(CFEqual(app,CFSTR("com.apple.smartcharging.topoffprotection")));
    assert(CFEqual(key,CFSTR("mclLimitValue")) || CFEqual(key,CFSTR("MCLFeatureState")));
    if(value)store[slot(key,user,host)]=(__bridge id)value;else[store removeObjectForKey:slot(key,user,host)];
}
static Boolean mockSync(CFStringRef app,CFStringRef user,CFStringRef host) {(void)app;(void)user;(void)host;return syncSucceeds;}
static uint32_t mockNotify(const char *name) {assert(strcmp(name,"com.apple.smartcharging.defaultschanged")==0);notifications++;
    if(!lag) {id level=store[slot(CFSTR("mclLimitValue"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost)];id feature=store[slot(CFSTR("MCLFeatureState"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost)];nativeLimit=[feature intValue]==1 ? [level intValue] : 100;}
    return 0;}
#define CFPreferencesCopyValue mockCopy
#define CFPreferencesSetValue mockSet
#define CFPreferencesSynchronize mockSync
#define notify_post mockNotify
#define BATTERY_PREFERENCES_TEST 1
#import "preferences.m"
int main(void) { @autoreleasepool {
    store=[NSMutableDictionary dictionary];
    char temporary[]="/tmp/uniapi-preferences-test.XXXXXX";assert(mkdtemp(temporary));
    int directory=open(temporary,O_RDONLY|O_DIRECTORY);assert(directory>=0);
    NSString *error=nil;
    assert(battery_preferences_apply(directory,0,&error));
    assert(!battery_preferences_apply(directory,50,&error));
    NSString *level=slot(CFSTR("mclLimitValue"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    NSString *feature=slot(CFSTR("MCLFeatureState"),kCFPreferencesCurrentUser,kCFPreferencesAnyHost);
    store[level]=@80;store[feature]=@0;
    assert(battery_preferences_apply(directory,50,&error));
    assert([store[level] isEqual:@50] && [store[feature] isEqual:@1]);
    int previous=notifications;
    assert(battery_preferences_apply(directory,50,&error) && notifications==previous);
    assert(battery_preferences_apply(directory,45,&error) && [store[level] isEqual:@45]);
    assert(battery_preferences_apply(directory,0,&error));
    assert([store[level] isEqual:@80] && [store[feature] isEqual:@0]);
    assert(faccessat(directory,"preferences.plist",F_OK,0)!=0);
    store[level]=@0.8;
    assert(!battery_preferences_apply(directory,50,&error) && [store[level] isEqual:@0.8]);
    store[level]=@80;
    assert(battery_preferences_apply(directory,50,&error));
    store[level]=@60;
    assert(!battery_preferences_apply(directory,0,&error) && [store[level] isEqual:@60]);
    store[level]=@50;
    assert(battery_preferences_apply(directory,0,&error));
    assert(battery_preferences_apply(directory,50,&error));
    [store removeObjectForKey:level];
    assert(!battery_preferences_apply(directory,0,&error) && store[level]==nil);
    store[level]=@50;
    lag=YES;
    assert(!battery_preferences_apply(directory,0,&error) && battery_preferences_is_pending());
    assert(faccessat(directory,"preferences.plist",F_OK,0)==0);
    nativeLimit=100;lag=NO;
    assert(battery_preferences_apply(directory,0,&error));
    assert(battery_preferences_apply(directory,50,&error));
    store[level]=@80;store[feature]=@0;nativeLimit=100;
    assert(battery_preferences_apply(directory,50,&error) && [store[level] isEqual:@50]);
    assert(battery_preferences_apply(directory,0,&error));
    assert(battery_preferences_apply(directory,50,&error));
    syncSucceeds=NO;
    assert(!battery_preferences_apply(directory,0,&error));
    nativeLimit=100;
    assert(!battery_preferences_apply(directory,0,&error));
    assert(faccessat(directory,"preferences.plist",F_OK,0)==0);
    syncSucceeds=YES;
    assert(battery_preferences_apply(directory,0,&error));
    assert(symlinkat("/dev/zero",directory,"preferences.plist")==0);
    assert(!battery_preferences_apply(directory,50,&error));
    unlinkat(directory,"preferences.plist",0);
    assert(!battery_preferences_apply(directory,24,&error));
    assert([store[level] isEqual:@80]);
    close(directory);rmdir(temporary);
    puts("native preference transaction and rollback checks passed");
} }
