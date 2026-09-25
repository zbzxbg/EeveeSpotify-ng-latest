#import <Orion/Orion.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import "Tweak.h"

// NO_JBROOT（Makefile: NO_JBROOT=1）给 IPA / TrollStore 用：不导入 libroot.h，
// 于是也不会链上 /var/jb/usr/lib/libroot.dylib。这很关键 —— libroot 是加载期
// 依赖，TrollStore 设备上没有 /var/jb，dyld 一失败整个 App 就起不来。
#if NO_JBROOT
// 故意什么都不导入。
#elif THEOS_PACKAGE_SCHEME_ROOTHIDE
#import <roothide.h>
#else
#import <libroot.h>
#endif

NSString *EeveeJBRootPath(NSString *path) {
#if NO_JBROOT
    // 无越狱环境：路径本来就是对的（BundleHelper 先找 main bundle，
    // 只有找不到时才拿这里的返回值兜底）。
    return path;
#elif THEOS_PACKAGE_SCHEME_ROOTHIDE
    return jbroot(path);
#else
    return JBROOT_PATH_NSSTRING(path);
#endif
}

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument) {
    if (!target || !selector) return;
    typedef id (*SeekFn)(id, SEL, double);
    SeekFn fn = (SeekFn)objc_msgSend;
    (void)fn(target, selector, argument);
}

static void writeDebugLog(NSString *message) {
    NSString *logPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"eeveespotify_debug.log"];
    NSString *timestamp = [[NSDate date] description];
    NSString *logMessage = [NSString stringWithFormat:@"[%@] %@\n", timestamp, message];

    if ([[NSFileManager defaultManager] fileExistsAtPath:logPath]) {
        NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        [fileHandle seekToEndOfFile];
        [fileHandle writeData:[logMessage dataUsingEncoding:NSUTF8StringEncoding]];
        [fileHandle closeFile];
    } else {
        [logMessage writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

__attribute__((constructor)) static void init() {
    @try {
        NSLog(@"[EeveeSpotify] Initializing tweak...");

        // Initialize Orion - do not remove this line.
        orion_init();

        NSLog(@"[EeveeSpotify] Tweak initialized successfully");
        // Custom initialization code goes here.
    }
    @catch (NSException *exception) {
        NSString *errorMsg = [NSString stringWithFormat:@"ERROR: Failed to initialize tweak: %@, Reason: %@", exception, [exception reason]];
        NSLog(@"[EeveeSpotify] %@", errorMsg);
        writeDebugLog(errorMsg);
    }
}
