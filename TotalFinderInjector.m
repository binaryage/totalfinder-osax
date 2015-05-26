#import "TFStandardVersionComparator.h"

#define EXPORT __attribute__((visibility("default")))

#define WAIT_FOR_APPLE_EVENT_TO_ENTER_HANDLER_IN_SECONDS 1.0
#define TOTALFINDER_STANDARD_INSTALL_LOCATION "/Applications/TotalFinder.app"
#define HOMEPAGE_URL @"http://totalfinder.binaryage.com"
#define FINDER_MIN_TESTED_VERSION @"10.8.0"
#define FINDER_MAX_TESTED_VERSION @"10.10.5"
#define FINDER_UNSUPPORTED_VERSION @"10.11"
#define TOTALFINDER_INJECTED_NOTIFICATION @"TotalFinderInjectedNotification"
#define TOTALFINDER_FAILED_INJECTION_NOTIFICATION @"TotalFinderFailedInjectionNotification"
#define TOTALFINDER_COMPATIBILITY_PAGE @"http://totalfinder.binaryage.com/compatibility#yosemite"

EXPORT OSErr HandleInitEvent(const AppleEvent* ev, AppleEvent* reply, long refcon);

static NSString* globalLock = @"I'm the global lock to prevent concruent handler executions";
static bool totalFinderAlreadyLoaded = false;
static Class gPrincipalClass = nil;

// Imagine this code:
//
//    NSString* source = @"tell application \"Finder\" to «event BATFinit»";
//    NSAppleScript* appleScript = [[NSAppleScript alloc] initWithSource:source];
//    [appleScript executeAndReturnError:nil];
//
// Force-quit Finder.app, wait for plain Finder.app to be relaunched by launchd, execute this code...
//
// On my machine (OS X 10.8.4-12E55) it sends following 4 events to the Finder process:
//
//    aevt('BATF'\'init' transactionID=0 returnID=29128 sourcePSN=[0x0,202202 "Finder"] timeout=7200 eventSource=3 { &'subj':null(), &'csig':magn(65536) })
//    aevt('ascr'\'gdut' transactionID=0 returnID=23693 sourcePSN=[0x0,202202 "Finder"] timeout=7200 eventSource=3 {  })
//    aevt('BATF'\'init' transactionID=0 returnID=29128 sourcePSN=[0x0,202202 "Finder"] timeout=7200 eventSource=3 { &'subj':null(), &'csig':magn(65536) })
//    aevt('BATF'\'init' transactionID=0 returnID=29128 sourcePSN=[0x0,202202 "Finder"] timeout=7200 eventSource=3 { &'subj':null(), &'csig':magn(65536),
// &'autx':autx('autx'(368CEB26DFB7FE807CA5860100000000000000000000000000000000000000000036)) })
//
//
// My explanation (pure speculation):
//
// 1. First, it naively fails (-1708)
// 2. Then it tries to load dynamic additions (http://developer.apple.com/library/mac/#qa/qa1070/_index.html)
// 3. Then it tries again but fails because the Finder requires "signature" (-10004)
// 4. Finally it signs the event, sends it again and it succeeds
//
// Ok, this works, so why do we need a better solution?
//
//   quite some people have had troubles injecting TotalFinder during startup using applescript.
//   I don't know what is wrong with their machines or applescript subsystem, but they were getting:
//   "Connection is Invalid -609" or "The operation couldn’t be completed -1708" or some other mysterious applescript error codes.
//
// Here are several possible scenarios:
//
//   1. system is busy, Finder process is busy or applescriptd is busy => timeout
//   2. Finder crashed during startup, got (potentially) restarted, but applescript subsystem caches handle and is unable to deliver events
//   3. our script is too fast and finished launching before Finder.app itself entered main loop => unexpected timing errors
//   4. some other similar issue
//
// A more robust solution?
//
//   1. Don't use high-level applescript. Send raw events using lowest level API available (AESendMessage).
//   2. Don't deal with timeouts, don't wait for replies and don't process errors.
//   3. Wait for Finder.app to fully launch.
//   4. Try multiple times.
//   5. Enable excessive debug logging for troubleshooting
//

static void broadcastNotification(NSString* notification) {
  pid_t pid = [[NSProcessInfo processInfo] processIdentifier];

  [[NSDistributedNotificationCenter defaultCenter] postNotificationName:notification
                                                                 object:[[NSBundle mainBundle] bundleIdentifier]
                                                               userInfo:@{@"pid" : @(pid)}
                                                     deliverImmediately:YES];
}

static void broadcastSucessfulInjection() { broadcastNotification(TOTALFINDER_INJECTED_NOTIFICATION); }

static void broadcastUnsucessfulInjection() { broadcastNotification(TOTALFINDER_FAILED_INJECTION_NOTIFICATION); }

// SIMBL-compatible interface
@interface TotalFinder : NSObject {
}
+ (void)install;
@end

// just a dummy class for locating our bundle
@interface TotalFinderInjector : NSObject {
}
@end

@implementation TotalFinderInjector
@end

static OSErr AEPutParamString(AppleEvent* event, AEKeyword keyword, NSString* string) {
  UInt8* textBuf;
  CFIndex length, maxBytes, actualBytes;

  length = CFStringGetLength((CFStringRef)string);
  maxBytes = CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8);
  textBuf = malloc(maxBytes);
  if (textBuf) {
    CFStringGetBytes((CFStringRef)string, CFRangeMake(0, length), kCFStringEncodingUTF8, 0, true, (UInt8*)textBuf, maxBytes, &actualBytes);
    OSErr err = AEPutParamPtr(event, keyword, typeUTF8Text, textBuf, actualBytes);
    free(textBuf);
    return err;
  } else {
    return memFullErr;
  }
}

static void reportError(AppleEvent* reply, NSString* msg) {
  NSLog(@"TotalFinderInjector: %@", msg);
  AEPutParamString(reply, keyErrorString, msg);
}

// this is just a sanity checking to catch missing methods early
static int performSelfCheck() {
  if (!gPrincipalClass) {
    return 1;
  }

  if (![gPrincipalClass respondsToSelector:@selector(sharedInstance)]) {
    return 2;
  }

  TotalFinder* instance = [gPrincipalClass sharedInstance];
  if (!instance) {
    return 3;
  }

  return 0;
}

EXPORT OSErr HandleInitEvent(const AppleEvent* ev, AppleEvent* reply, long refcon) {
  @synchronized(globalLock) {
    @autoreleasepool {
      NSBundle* injectorBundle = [NSBundle bundleForClass:[TotalFinderInjector class]];
      NSString* injectorVersion = [injectorBundle objectForInfoDictionaryKey:@"CFBundleVersion"];

      if (!injectorVersion || ![injectorVersion isKindOfClass:[NSString class]]) {
        reportError(reply, [NSString stringWithFormat:@"Unable to determine TotalFinderInjector version!"]);
        return 7;
      }

      NSLog(@"TotalFinderInjector v%@ received init event", injectorVersion);

      NSString* bundleName = @"TotalFinder";
      NSString* targetAppName = @"Finder";
      NSString* maxVersion = FINDER_MAX_TESTED_VERSION;
      NSString* minVersion = FINDER_MIN_TESTED_VERSION;

      if (totalFinderAlreadyLoaded) {
        NSLog(@"TotalFinderInjector: %@ has been already loaded. Ignoring this request.", bundleName);
        broadcastSucessfulInjection();  // prevent continous injection
        return noErr;
      }

      @try {
        NSBundle* mainBundle = [NSBundle mainBundle];
        if (!mainBundle) {
          reportError(reply, [NSString stringWithFormat:@"Unable to locate main %@ bundle!", targetAppName]);
          return 4;
        }

        NSString* mainVersion = [mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        if (!mainVersion || ![mainVersion isKindOfClass:[NSString class]]) {
          reportError(reply, [NSString stringWithFormat:@"Unable to determine %@ version!", targetAppName]);
          return 5;
        }

        // some future versions are explicitely unsupported
        //        if (([FINDER_UNSUPPORTED_VERSION length] > 0) && ([mainVersion rangeOfString:FINDER_UNSUPPORTED_VERSION].length > 0)) {
        //          NSUserNotification* notification = [[NSUserNotification alloc] init];
        //          notification.title = [NSString stringWithFormat:@"TotalFinder Yosemite compatibility"];
        //          notification.informativeText = [NSString stringWithFormat:@"All features should work, but you could experience rough edges. We're working on
        //          it.\nhttp://totalfinder.binaryage.com/compatibility"];
        //          NSUserNotificationCenter* notificationCenter = [NSUserNotificationCenter defaultUserNotificationCenter];
        //          [notificationCenter deliverNotification:notification];
        //        }

        // warn about non-tested minor versions into the log only
        TFStandardVersionComparator* comparator = [TFStandardVersionComparator defaultComparator];
        if (([comparator compareVersion:mainVersion toVersion:maxVersion] == NSOrderedDescending) ||
            ([comparator compareVersion:mainVersion toVersion:minVersion] == NSOrderedAscending)) {
          NSLog(@"TotalFinderInjector: You have %@ version %@. But %@ was properly tested only with %@ versions in range %@ - %@.", targetAppName, mainVersion,
                bundleName, targetAppName, minVersion, maxVersion);
        }

        NSBundle* totalFinderInjectorBundle = [NSBundle bundleForClass:[TotalFinderInjector class]];
        NSString* totalFinderLocation = [totalFinderInjectorBundle pathForResource:bundleName ofType:@"bundle"];
        NSBundle* pluginBundle = [NSBundle bundleWithPath:totalFinderLocation];
        if (!pluginBundle) {
          reportError(reply, [NSString stringWithFormat:@"Unable to create bundle from path: %@ [%@]", totalFinderLocation, totalFinderInjectorBundle]);
          return 2;
        }

        NSLog(@"TotalFinderInjector: Installing TotalFinder from %@", totalFinderLocation);
        NSError* error;
        if (![pluginBundle loadAndReturnError:&error]) {
          reportError(reply, [NSString stringWithFormat:@"Unable to load bundle from path: %@ error: %@ [code=%ld]", totalFinderLocation,
                                                        [error localizedDescription], (long)[error code]]);
          return 6;
        }
        gPrincipalClass = [pluginBundle principalClass];
        if (!gPrincipalClass) {
          reportError(reply, [NSString stringWithFormat:@"Unable to retrieve principalClass for bundle: %@", pluginBundle]);
          return 3;
        }

        if (![gPrincipalClass respondsToSelector:@selector(install)]) {
          reportError(reply, [NSString stringWithFormat:@"TotalFinder's principal class does not implement 'install' method!"]);
          return 7;
        }

        [gPrincipalClass install];

        int selfCheckCode = performSelfCheck();
        if (selfCheckCode) {
          reportError(reply, [NSString stringWithFormat:@"Self-check failed with code %d", selfCheckCode]);
          return 10;
        }

        totalFinderAlreadyLoaded = true;
        broadcastSucessfulInjection();

        return noErr;
      }
      @catch (NSException* exception) {
        reportError(reply, [NSString stringWithFormat:@"Failed to load %@ with exception: %@", bundleName, exception]);
        broadcastUnsucessfulInjection();  // stops subsequent attempts
      }

      return 1;
    }
  }
}

EXPORT OSErr HandleCheckEvent(const AppleEvent* ev, AppleEvent* reply, long refcon) {
  @synchronized(globalLock) {
    @autoreleasepool {
      if (totalFinderAlreadyLoaded) {
        return noErr;
      }

      reportError(reply, @"TotalFinder not loaded");
      return 1;
    }
  }
}

// debug command to emulate a crash in our code
EXPORT OSErr HandleCrashEvent(const AppleEvent* ev, AppleEvent* reply, long refcon) {
  @synchronized(globalLock) {
    @autoreleasepool {
      if (!totalFinderAlreadyLoaded) {
        return 1;
      }

      TotalFinder* shell = [gPrincipalClass sharedInstance];
      if (!shell) {
        reportError(reply, [NSString stringWithFormat:@"Unable to retrieve shell class"]);
        return 3;
      }

      abort();
    }
  }
}
