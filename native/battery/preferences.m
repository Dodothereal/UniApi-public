#import "preferences.h"
#include <notify.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

static BOOL pending;
BOOL battery_preferences_is_pending(void) { return pending; }

static CFStringRef domain = CFSTR("com.apple.smartcharging.topoffprotection");
static NSArray *keys(void) { return @[@"mclLimitValue", @"MCLFeatureState"]; }
static CFStringRef userFor(NSDictionary *journal) { return [journal[@"user"] isEqual:@"any"] ? kCFPreferencesAnyUser : kCFPreferencesCurrentUser; }
static CFStringRef hostFor(NSDictionary *journal) { return [journal[@"host"] isEqual:@"current"] ? kCFPreferencesCurrentHost : kCFPreferencesAnyHost; }
static id valueFor(NSString *key, NSDictionary *journal) {
    return CFBridgingRelease(CFPreferencesCopyValue((__bridge CFStringRef)key,domain,userFor(journal),hostFor(journal)));
}
static BOOL reject(NSString **error, NSString *message) { if(error)*error=message; return NO; }

static NSDictionary *loadJournal(int directory, BOOL *exists) {
    int fd=openat(directory,"preferences.plist",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    *exists=fd>=0 || errno!=ENOENT;
    if(fd<0) return nil;
    struct stat st;
    if(fstat(fd,&st)!=0 || !S_ISREG(st.st_mode) || st.st_nlink!=1 || st.st_uid!=geteuid()
        || (st.st_mode&0077) || st.st_size<1 || st.st_size>16384) {close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)st.st_size];
    ssize_t got=read(fd,data.mutableBytes,data.length);close(fd);
    if(got!=(ssize_t)data.length)return nil;
    id object=[NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable format:NULL error:nil];
    if(![object isKindOfClass:NSDictionary.class] || ![object[@"old"] isKindOfClass:NSDictionary.class]
        || ![@[@"any",@"current"] containsObject:object[@"user"]]
        || ![@[@"any",@"current"] containsObject:object[@"host"]]
        || ![object[@"target"] isKindOfClass:NSNumber.class]
        || ![object[@"nativeLimit"] isKindOfClass:NSNumber.class]
        || [object[@"nativeLimit"] intValue]<1 || [object[@"nativeLimit"] intValue]>100) return nil;
    int target=[object[@"target"] intValue];
    return target>=25 && target<=95 ? object : nil;
}
static BOOL saveJournal(int directory, NSDictionary *journal) {
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:journal format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if(!data)return NO;
    unlinkat(directory,"preferences.new",0);
    int fd=openat(directory,"preferences.new",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return NO;
    ssize_t length=write(fd,data.bytes,data.length);
    BOOL ok=length==(ssize_t)data.length && fsync(fd)==0 && fcntl(fd,F_FULLFSYNC)==0;
    close(fd);
    if(!ok){unlinkat(directory,"preferences.new",0);return NO;}
    return renameat(directory,"preferences.new",directory,"preferences.plist")==0 && fsync(directory)==0;
}
static BOOL synchronize(NSDictionary *journal) {
    return CFPreferencesSynchronize(domain,userFor(journal),hostFor(journal));
}
static BOOL restore(int directory, NSDictionary *journal, NSString **error) {
    // Preserve a later change by System Settings or another utility. We only
    // undo values still equal to what this helper wrote, or already restored.
    BOOL changed=NO;
    for(NSString *key in keys()) {
        id current=valueFor(key,journal), old=journal[@"old"][key];
        id owned=[key isEqual:@"mclLimitValue"] ? journal[@"target"] : @1;
        BOOL matchesOld=(!current && !old) || [current isEqual:old];
        if(![current isEqual:owned] && !matchesOld)
            return reject(error,@"Another charging utility changed the native preferences; refusing to overwrite it.");
        changed |= !matchesOld;
    }
    if(changed) {
        for(NSString *key in keys()) CFPreferencesSetValue((__bridge CFStringRef)key,(__bridge CFPropertyListRef)journal[@"old"][key],domain,userFor(journal),hostFor(journal));
    }
    // Cached originals are not proof a prior failed synchronize reached disk.
    if(!synchronize(journal))return reject(error,@"Could not restore the previous native charging preferences.");
    if(changed || battery_preferences_limit()!=[journal[@"nativeLimit"] intValue]) {
        if(notify_post("com.apple.smartcharging.defaultschanged")!=NOTIFY_STATUS_OK)return reject(error,@"Could not notify the native charging service of restoration.");
    }
    if(battery_preferences_limit()!=[journal[@"nativeLimit"] intValue]) {
        pending=YES;
        return reject(error,@"Waiting for the native service to confirm restoration.");
    }
    if(unlinkat(directory,"preferences.plist",0)!=0 || fsync(directory)!=0)return reject(error,@"Could not retire the charging restoration journal.");
    return YES;
}

BOOL battery_preferences_apply(int directory, int target, NSString **error) {
    pending=NO;
    if(target && (target<25 || target>95))return reject(error,@"Invalid native charging target.");
    BOOL exists=NO;
    NSDictionary *journal=loadJournal(directory,&exists);
    if(exists && !journal)return reject(error,@"The native charging restoration journal is unreadable.");
    if(!target)return !journal || restore(directory,journal,error);
    if(journal && [journal[@"target"] intValue]==target
        && [valueFor(@"mclLimitValue",journal) isEqual:@(target)] && [valueFor(@"MCLFeatureState",journal) isEqual:@1]) {
        if(battery_preferences_limit()!=target && notify_post("com.apple.smartcharging.defaultschanged")!=NOTIFY_STATUS_OK)
            return reject(error,@"Could not notify the native charging service.");
        return YES;
    }
    // An interrupted apply or restoration may have left old/owned values.
    // Finish its rollback before creating a new transaction; restore refuses
    // any value that is neither old nor ours.
    if(journal && !restore(directory,journal,error))return NO;
    NSMutableDictionary *selected=nil;
    // Choose an existing store with an actual native percentage. Never seed a
    // guessed preference scope or reinterpret a fractional/unknown schema.
    for(NSString *user in @[@"current",@"any"]) {
        for(NSString *host in @[@"any",@"current"]) {
            NSMutableDictionary *candidate=[@{ @"user":user,@"host":host,@"target":@(target) } mutableCopy];
            id level=valueFor(@"mclLimitValue",candidate);
            if(![level isKindOfClass:NSNumber.class] || [level doubleValue]!=[level intValue] || [level intValue]<25 || [level intValue]>100)continue;
            NSMutableDictionary *old=[NSMutableDictionary dictionary];
            for(NSString *key in keys()) {id value=valueFor(key,candidate);if(value)old[key]=value;}
            candidate[@"old"]=old;selected=candidate;break;
        }
        if(selected)break;
    }
    if(!selected)return reject(error,@"No recognized native MCL preference store was found.");
    int originalNativeLimit=battery_preferences_limit();
    if(originalNativeLimit<1 || originalNativeLimit>100)return reject(error,@"Could not read the original native limit before changing it.");
    selected[@"nativeLimit"]=@(originalNativeLimit);
    if(!saveJournal(directory,selected))return reject(error,@"Could not save the previous native charging settings.");
    CFPreferencesSetValue(CFSTR("mclLimitValue"),(__bridge CFNumberRef)@(target),domain,userFor(selected),hostFor(selected));
    CFPreferencesSetValue(CFSTR("MCLFeatureState"),(__bridge CFNumberRef)@1,domain,userFor(selected),hostFor(selected));
    if(!synchronize(selected)) {restore(directory,selected,NULL);return reject(error,@"Could not synchronize native charging preferences.");}
    if(notify_post("com.apple.smartcharging.defaultschanged")!=NOTIFY_STATUS_OK)return reject(error,@"Could not notify the native charging service.");
    return YES;
}

#import <objc/runtime.h>
#import <objc/message.h>
#include <dlfcn.h>
#ifndef BATTERY_PREFERENCES_TEST
int battery_preferences_limit(void) {
    if(!dlopen("/System/Library/PrivateFrameworks/PowerUI.framework/PowerUI",RTLD_LAZY))return -1;
    Class cls=objc_getClass("PowerUISmartChargeClient");
    Method get=class_getInstanceMethod(cls,sel_registerName("getMCLLimitWithError:"));
    if(!get)return -1;
    NSMethodSignature *signature=[NSMethodSignature signatureWithObjCTypes:method_getTypeEncoding(get)];
    if(signature.numberOfArguments!=3 || strcmp(signature.methodReturnType,"C") || strcmp([signature getArgumentTypeAtIndex:2],"^@"))return -1;
    id client=((id(*)(id,SEL,id))objc_msgSend)([cls alloc],sel_registerName("initWithClientName:"),@"UniApi");
    if(!client)return -1;
    NSError *error=nil;
    unsigned char limit=((unsigned char(*)(id,SEL,NSError**))objc_msgSend)(client,sel_registerName("getMCLLimitWithError:"),&error);
    return error ? -1 : limit;
}

#endif
