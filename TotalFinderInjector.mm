#import <Cocoa/Cocoa.h>
#import "TFStandardVersionComparator.h"

#if !defined(DEBUG)
#define CHECK_SIGNATURE 1
#endif

#define EXPORT extern "C" __attribute__((visibility("default"))) __attribute__((used))

#define TOTALFINDER_INSTALL_LOCATION_CONFIG_PATH "~/.totalfinder-install-location"
#define TOTALFINDER_STANDARD_BUNDLE_LOCATION "/Applications/TotalFinder.app/Contents/Resources/TotalFinder.bundle"
#define TOTALFINDER_DEV_BUNDLE_LOCATION "~/Applications/TotalFinder.app/Contents/Resources/TotalFinder.bundle"
#define TOTALFINDER_OSAX_BUNDLE_LOCATION "/Library/ScriptingAdditions/TotalFinder.osax/Contents/Resources/TotalFinder.bundle"
#define TOTALFINDER_SYSTEM_OSAX_BUNDLE_LOCATION "/System/Library/ScriptingAdditions/TotalFinder.osax/Contents/Resources/TotalFinder.bundle"
#define TOTALFINDER_USER_OSAX_BUNDLE_LOCATION "~/Library/ScriptingAdditions/TotalFinder.osax/Contents/Resources/TotalFinder.bundle"
#define TOTALFINDER_INJECTED_NOTIFICATION @"TotalFinderInjectedNotification"
#define TOTALFINDER_FAILED_INJECTION_NOTIFICATION @"TotalFinderFailedInjectionNotification"

static NSString* globalLock = @"I'm the global lock to prevent concurrent handler executions";
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
//   "Connection is Invalid -609" or "The operation could not be completed -1708" or some other mysterious applescript error codes.
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
                                                               userInfo:@{
                                                                 @"pid" : @(pid)
                                                               }
                                                     deliverImmediately:YES];
}

static void broadcastSuccessfulInjection() { broadcastNotification(TOTALFINDER_INJECTED_NOTIFICATION); }

static void broadcastUnsuccessfulInjection() { broadcastNotification(TOTALFINDER_FAILED_INJECTION_NOTIFICATION); }

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
  size_t maxBytes;
  CFIndex length, actualBytes;

  length = CFStringGetLength((__bridge CFStringRef)string);
  maxBytes = (size_t)CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8);

  textBuf = (UInt8*)malloc(maxBytes);
  if (!textBuf) {
    return memFullErr;
  }

  CFStringGetBytes((__bridge CFStringRef)string, CFRangeMake(0, length), kCFStringEncodingUTF8, 0, true, textBuf, maxBytes, &actualBytes);
  OSErr err = AEPutParamPtr(event, keyword, typeUTF8Text, textBuf, actualBytes);
  free(textBuf);
  return err;
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

#if defined(CHECK_SIGNATURE)
static NSString* checkSignature(CFURLRef bundleURL, CFStringRef requirementString) {
  CFErrorRef error = NULL;
  SecStaticCodeRef staticCode = NULL;
  SecStaticCodeCreateWithPath(bundleURL, kSecCSDefaultFlags, &staticCode);

  if (!staticCode) {
    return @"SecStaticCodeCreateWithPath returned no staticCode";
  }

  SecRequirementRef requirementRef = NULL;
  OSStatus requirementCreateStatus = SecRequirementCreateWithStringAndErrors(requirementString, kSecCSDefaultFlags, &error, &requirementRef);
  if (error) {
    if (requirementRef) {
      CFRelease(requirementRef);
    }
    NSString* result = [NSString stringWithFormat:@"SecRequirementCreateWithStringAndErrors reported %@", error];
    CFRelease(error);
    return result;
  }

  if (requirementCreateStatus != errSecSuccess) {
    if (requirementRef) {
      CFRelease(requirementRef);
    }
    return [NSString stringWithFormat:@"SecRequirementCreateWithString returned %d)", requirementCreateStatus];
  }

  SecCSFlags flags = (SecCSFlags)(kSecCSDefaultFlags | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode);
  OSStatus signatureCheckResult = SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirementRef, &error);
  CFRelease(requirementRef);
  CFRelease(staticCode);

  if (error) {
    NSString* result = [NSString stringWithFormat:@"SecStaticCodeCheckValidityWithErrors reported %@", error];
    CFRelease(error);
    return result;
  }

  if (signatureCheckResult != errSecSuccess) {
    return [NSString stringWithFormat:@"SecStaticCodeCheckValidityWithErrors returned %d", signatureCheckResult];
  }

  return nil;
}

@interface CorruptionNotificationDelegate : NSObject<NSUserNotificationCenterDelegate> {
}
@end

@implementation CorruptionNotificationDelegate

- (BOOL)userNotificationCenter:(NSUserNotificationCenter*)center shouldPresentNotification:(NSUserNotification*)notification {
  return YES;
}

- (void)userNotificationCenter:(NSUserNotificationCenter*)center didActivateNotification:(NSUserNotification*)notification {
  [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://totalfinder.binaryage.com"]];
}

@end

void displayCorruptionNotificationIfNeeded() {
  static bool alreadyPresented = false;
  static id delegate = nil;
  if (alreadyPresented) {
    return;
  }
  alreadyPresented = true;
  NSUserNotification* notification = [[NSUserNotification alloc] init];
  notification.title = @"TotalFinder is corrupted";
  notification.informativeText = @"A code signature check failed.\nPlease reinstall TotalFinder.";
  notification.hasActionButton = YES;
  notification.actionButtonTitle = @"Download";
  NSUserNotificationCenter* notificationCenter = [NSUserNotificationCenter defaultUserNotificationCenter];
  if (!delegate) {
    delegate = [[CorruptionNotificationDelegate alloc] init];
  }
  notificationCenter.delegate = delegate;
  [notificationCenter deliverNotification:notification];
}
#endif

static bool checkExistenceOfTotalFinderBundleAtPath(NSString* path) {
  NSFileManager* fileManager = [NSFileManager defaultManager];
  BOOL dir = FALSE;
  if ([fileManager fileExistsAtPath:path isDirectory:&dir]) {
    if (!dir) {
      NSLog(@"TotalFinderInjector: unexpected situation, filesystem path exists but it is not a directory: %@", path);
      return false;
    }
    if (![fileManager isReadableFileAtPath:path]) {
      NSLog(@"TotalFinderInjector: unexpected situation, filesystem path exists but it is not readable: %@", path);
      return false;
    }
    return true;
  }
  return false;
}

static NSString* determineTotalFinderBundlePath() {
  // config file can override standard installation location
  NSFileManager* fileManager = [NSFileManager defaultManager];
  NSString* installLocationConfigPath = [@TOTALFINDER_INSTALL_LOCATION_CONFIG_PATH stringByStandardizingPath];
  if ([fileManager fileExistsAtPath:installLocationConfigPath]) {
    NSData* configData = [fileManager contentsAtPath:installLocationConfigPath];
    if (configData) {
      NSString* content = [[NSString alloc] initWithData:configData encoding:NSUTF8StringEncoding];
      if (content && [content length]) {
        if (checkExistenceOfTotalFinderBundleAtPath(content)) {
          return content;
        } else {
          NSLog(@"TotalFinderInjector: install location specified path which does not point to existing TotalFinder.bundle\nconfig file:%@\nspecified bundle "
                @"path:%@",
                installLocationConfigPath, content);
        }
      } else {
        NSLog(@"TotalFinderInjector: unable to read content of %@", installLocationConfigPath);
      }
    } else {
      NSLog(@"TotalFinderInjector: unable to read installation location from %@", installLocationConfigPath);
    }
  }

  NSString* path;

#if defined(DEBUG)
  // this is used during development
  path = [@TOTALFINDER_DEV_BUNDLE_LOCATION stringByStandardizingPath];
  if (checkExistenceOfTotalFinderBundleAtPath(path)) {
    return path;
  }
#endif

  // this location is standard since TotalFinder 1.7.13, TotalFinder.bundle is located in TotalFinder.app's resources
  path = [@TOTALFINDER_STANDARD_BUNDLE_LOCATION stringByStandardizingPath];
  if (checkExistenceOfTotalFinderBundleAtPath(path)) {
    return path;
  }

  // prior TotalFinder 1.7.13, budle was included in the OSAX
  path = [@TOTALFINDER_OSAX_BUNDLE_LOCATION stringByStandardizingPath];
  if (checkExistenceOfTotalFinderBundleAtPath(path)) {
    return path;
  }

  // this is a special case if someone decided to move TotalFinder.bundle under system osax location for some reason
  path = [@TOTALFINDER_SYSTEM_OSAX_BUNDLE_LOCATION stringByStandardizingPath];
  if (checkExistenceOfTotalFinderBundleAtPath(path)) {
    return path;
  }

  // this is a special case if someone decided to move TotalFinder.bundle under user osax location for some reason (we use this during development)
  path = [@TOTALFINDER_USER_OSAX_BUNDLE_LOCATION stringByStandardizingPath];
  if (checkExistenceOfTotalFinderBundleAtPath(path)) {
    return path;
  }

  return nil;
}

EXPORT OSErr HandleInitEvent(const AppleEvent* __unused ev, AppleEvent* reply, long __unused refcon) {
  @synchronized(globalLock) {
    @autoreleasepool {
      NSString* targetAppName = @"Finder";
      NSString* bundleName = @"TotalFinder";
      TFStandardVersionComparator* comparator = [TFStandardVersionComparator defaultComparator];
      NSBundle* injectorBundle = [NSBundle bundleForClass:[TotalFinderInjector class]];
      id injectorVersion = [injectorBundle objectForInfoDictionaryKey:@"CFBundleVersion"];

      if (!injectorVersion || ![injectorVersion isKindOfClass:[NSString class]]) {
        reportError(reply, [NSString stringWithFormat:@"Unable to determine TotalFinderInjector version!"]);
        return 11;
      }

      NSString* injectorBundlePath = [injectorBundle bundlePath];
      NSLog(@"TotalFinderInjector v%@ received init event (%@)", injectorVersion, injectorBundlePath);

      if (totalFinderAlreadyLoaded) {
        NSLog(@"TotalFinderInjector: %@ has been already loaded. Ignoring this request.", bundleName);
        broadcastSuccessfulInjection();  // prevent continuous injection
        return noErr;
      }

      NSString* totalFinderBundlePath = determineTotalFinderBundlePath();
      if (!totalFinderBundlePath) {
        NSLog(@"TotalFinderInjector: unable to determine location of TotalFinder.bundle (likely a corrupted TotalFinder installation).");
        return 12;
      }

      @try {

#if !defined(CHECK_SIGNATURE)
        NSLog(@"TotalFinderInjector: skipped signature check because compiled without CHECK_SIGNATURE");
#else
        NSURL* totalFinderBundleURL = [NSURL fileURLWithPath:totalFinderBundlePath];
        static CFStringRef injectorRequirement = CFSTR(
            "anchor apple generic and identifier com.binaryage.totalfinder and certificate leaf[subject.CN] = \"Developer ID Application: BinaryAge Limited\"");
        NSString* signatureError = checkSignature((__bridge CFURLRef)totalFinderBundleURL, injectorRequirement);
        if (signatureError) {
          displayCorruptionNotificationIfNeeded();
          reportError(reply, [NSString stringWithFormat:@"Invalid code signature of '%@'.\n%@", totalFinderBundlePath, signatureError]);
          return 14;
        }
#endif

        NSBundle* totalFinderBundle = [NSBundle bundleWithPath:totalFinderBundlePath];
        if (!totalFinderBundle) {
          reportError(reply, [NSString stringWithFormat:@"Unable to create bundle from path: %@", totalFinderBundlePath]);
          return 2;
        }

        id maxTestedVersion = [totalFinderBundle objectForInfoDictionaryKey:@"FinderMaxTestedVersion"];
        if (!maxTestedVersion || ![maxTestedVersion isKindOfClass:[NSString class]]) {
          maxTestedVersion = nil;
        }

        id minTestedVersion = [totalFinderBundle objectForInfoDictionaryKey:@"FinderMinTestedVersion"];
        if (!minTestedVersion || ![minTestedVersion isKindOfClass:[NSString class]]) {
          minTestedVersion = nil;
        }

        id unsupportedVersion = [totalFinderBundle objectForInfoDictionaryKey:@"FinderUnsupportedVersion"];
        if (!unsupportedVersion || ![unsupportedVersion isKindOfClass:[NSString class]]) {
          unsupportedVersion = nil;
        }

        NSBundle* mainBundle = [NSBundle mainBundle];
        if (!mainBundle) {
          reportError(reply, [NSString stringWithFormat:@"Unable to locate main %@ bundle!", targetAppName]);
          return 4;
        }

        id mainVersion = [mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"];
        if (!mainVersion || ![mainVersion isKindOfClass:[NSString class]]) {
          reportError(reply, [NSString stringWithFormat:@"Unable to determine %@ version!", targetAppName]);
          return 5;
        }

        // future versions from some point can be explicitely unsupported
        if (unsupportedVersion) {
          NSComparisonResult comparatorResult = [comparator compareVersion:mainVersion toVersion:unsupportedVersion];
          if (comparatorResult == NSOrderedDescending || comparatorResult == NSOrderedSame) {
            NSLog(@"TotalFinderInjector: You have %@ version %@. But %@ was marked as unsupported with %@ since version %@.", targetAppName, mainVersion,
                  bundleName, targetAppName, unsupportedVersion);

            // TODO: maybe we want to use a system notification to inform the user here
            return 13;
          }
        }

        // warn about non-tested minor versions into the log only
        BOOL maxTestFailed = maxTestedVersion && [comparator compareVersion:mainVersion toVersion:maxTestedVersion] == NSOrderedDescending;
        BOOL minTestFailed = minTestedVersion && [comparator compareVersion:mainVersion toVersion:minTestedVersion] == NSOrderedAscending;
        if (maxTestFailed || minTestFailed) {
          NSLog(@"TotalFinderInjector: You have %@ version %@. But %@ was properly tested only with %@ versions in range %@ - %@.", targetAppName, mainVersion,
                bundleName, targetAppName, minTestedVersion ? minTestedVersion : @"*", maxTestedVersion ? maxTestedVersion : @"*");
        }

        NSLog(@"TotalFinderInjector: Installing TotalFinder from %@", totalFinderBundlePath);
        NSError* error;
        if (![totalFinderBundle loadAndReturnError:&error]) {
          reportError(reply, [NSString stringWithFormat:@"Unable to load bundle from path: %@ error: %@ [code=%ld]", totalFinderBundlePath,
                                                        [error localizedDescription], (long)[error code]]);
          return 6;
        }
        gPrincipalClass = [totalFinderBundle principalClass];
        if (!gPrincipalClass) {
          reportError(reply, [NSString stringWithFormat:@"Unable to retrieve principalClass for bundle: %@", totalFinderBundle]);
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
        broadcastSuccessfulInjection();

        return noErr;
      } @catch (NSException* exception) {
        reportError(reply, [NSString stringWithFormat:@"Failed to load %@ with exception: %@", bundleName, exception]);
        broadcastUnsuccessfulInjection();  // stops subsequent attempts
      }

      return 1;
    }
  }
}

EXPORT OSErr HandleCheckEvent(const AppleEvent* __unused ev, AppleEvent* reply, long __unused refcon) {
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
EXPORT OSErr HandleCrashEvent(const AppleEvent* __unused ev, AppleEvent* reply, long __unused refcon) {
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
