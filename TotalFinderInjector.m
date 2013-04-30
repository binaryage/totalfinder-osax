#import <Cocoa/Cocoa.h>

#import "TFStandardVersionComparator.h"

#define EXPORT __attribute__((visibility("default")))

#define TOTALFINDER_STANDARD_INSTALL_LOCATION "/Applications/TotalFinder.app"
#define FINDER_MIN_TESTED_VERSION @"10.7"
#define FINDER_MAX_TESTED_VERSION @"10.8.3"

#define DOCK_MIN_TESTED_VERSION @"0"
#define DOCK_MAX_TESTED_VERSION @"1168.6" // 10.8 Mountain Lion Preview 4

// SIMBL-compatible interface
@interface TotalFinderShell : NSObject { }
-(void) install;
-(void) crashMe;
@end

// just a dummy class for locating our bundle
@interface TotalFinderInjector : NSObject { }
@end

@implementation TotalFinderInjector { }
@end

static bool alreadyLoaded = false;
static bool dockAlreadyLoaded = false;

typedef struct {
  NSString* location;
} configuration;

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

typedef enum {
  InvalidBundleType,
  TotalFinderBundleType,
  DockHelperBundleType
} TFBundleType;

static OSErr loadBundle(TFBundleType type, AppleEvent* reply, long refcon) {
  bool isLoaded = false;
  NSString* bundleName = nil;
  NSString* targetAppName = nil;
  NSString* supressKey = nil;
  NSString* maxVersion = nil;
  NSString* minVersion = nil;

  switch (type) {
    case TotalFinderBundleType:
      isLoaded = alreadyLoaded;
      bundleName = @"TotalFinder";
      targetAppName = @"Finder";
      supressKey = @"TotalFinderSuppressFinderVersionCheck";
      maxVersion = FINDER_MAX_TESTED_VERSION;
      minVersion = FINDER_MIN_TESTED_VERSION;
      break;
    case DockHelperBundleType:
      isLoaded = dockAlreadyLoaded;
      bundleName = @"DockHelper";
      targetAppName = @"Dock";
      supressKey = @"TotalFinderSuppressDockVersionCheck";
      maxVersion = DOCK_MAX_TESTED_VERSION;
      minVersion = DOCK_MIN_TESTED_VERSION;
      break;
    default:
      NSLog(@"Failed to load bundle for type %d", type);
      return 8;

      break;
  }

  if (isLoaded) {
    NSLog(@"TotalFinderInjector: %@ has been already loaded. Ignoring this request.", bundleName);
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

    // future compatibility check
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    if (![defaults boolForKey:supressKey]) {
      TFStandardVersionComparator* comparator = [TFStandardVersionComparator defaultComparator];
      if (([comparator compareVersion:mainVersion toVersion:maxVersion] == NSOrderedDescending) ||
          ([comparator compareVersion:mainVersion toVersion:minVersion] == NSOrderedAscending)) {
        NSAlert* alert = [NSAlert new];
        [alert setMessageText:[NSString stringWithFormat:@"You have %@ version %@", targetAppName, mainVersion]];
        [alert setInformativeText:[NSString stringWithFormat:@"But %@ was properly tested only with %@ versions in range %@ - %@\n\nYou have probably updated your system and %@ version got bumped by Apple developers.\n\nYou may expect a new TotalFinder release soon.", bundleName, targetAppName, targetAppName, FINDER_MIN_TESTED_VERSION,
                                   FINDER_MAX_TESTED_VERSION]];
        [alert setShowsSuppressionButton:YES];
        [alert addButtonWithTitle:@"Launch TotalFinder anyway"];
        [alert addButtonWithTitle:@"Cancel"];
        NSInteger res = [alert runModal];
        if ([[alert suppressionButton] state] == NSOnState) {
          [defaults setBool:YES forKey:supressKey];
        }
        if (res != NSAlertFirstButtonReturn) {
          // cancel
          return noErr;
        }
      }
    }

    NSBundle* totalFinderInjectorBundle = [NSBundle bundleForClass:[TotalFinderInjector class]];
    NSString* totalFinderLocation = [totalFinderInjectorBundle pathForResource:bundleName ofType:@"bundle"];
    NSBundle* pluginBundle = [NSBundle bundleWithPath:totalFinderLocation];
    if (!pluginBundle) {
      reportError(reply, [NSString stringWithFormat:@"Unable to create bundle from path: %@ [%@]", totalFinderLocation, totalFinderInjectorBundle]);
      return 2;
    }

    NSError* error;
    if (![pluginBundle loadAndReturnError:&error]) {
      reportError(reply, [NSString stringWithFormat:@"Unable to load bundle from path: %@ error: %@", totalFinderLocation, [error localizedDescription]]);
      return 6;
    }
    Class principalClass = [pluginBundle principalClass];
    if (!principalClass) {
      reportError(reply, [NSString stringWithFormat:@"Unable to retrieve principalClass for bundle: %@", pluginBundle]);
      return 3;
    }
    id principalClassObject = NSClassFromString(NSStringFromClass(principalClass));
    if ([principalClassObject respondsToSelector:@selector(install)]) {
      NSLog(@"TotalFinderInjector: Installing %@ ...", bundleName);
      [principalClassObject install];
    }

    if (type == TotalFinderBundleType) {
      alreadyLoaded = true;
      [NSTask launchedTaskWithLaunchPath:@"/usr/bin/osascript" arguments:@[@"-e", @"tell application \"Dock\" to «event BATFinit»"]];
    } else if (type == DockHelperBundleType) {
      dockAlreadyLoaded = true;
    }

    return noErr;
  } @catch (NSException* exception) {
    reportError(reply, [NSString stringWithFormat:@"Failed to load %@ with exception: %@", bundleName, exception]);
  }

  return 1;
}

static TFBundleType mainBundleType(AppleEvent* reply) {
  @try {
    NSBundle* mainBundle = [NSBundle mainBundle];
    if (!mainBundle) {
      reportError(reply, [NSString stringWithFormat:@"Unable to locate main bundle!"]);
      return InvalidBundleType;
    }

    if ([[mainBundle bundleIdentifier] isEqualToString:@"com.apple.finder"]) {
      return TotalFinderBundleType;
    } else if ([[mainBundle bundleIdentifier] isEqualToString:@"com.apple.dock"]) {
      return DockHelperBundleType;
    }
  } @catch (NSException* exception) {
    reportError(reply, [NSString stringWithFormat:@"Failed to load main bundle with exception: %@", exception]);
  }

  return InvalidBundleType;
}

EXPORT OSErr HandleInitEvent(const AppleEvent* ev, AppleEvent* reply, long refcon) {
  NSBundle* injectorBundle = [NSBundle bundleForClass:[TotalFinderInjector class]];
  NSString* injectorVersion = [injectorBundle objectForInfoDictionaryKey:@"CFBundleVersion"];

  if (!injectorVersion || ![injectorVersion isKindOfClass:[NSString class]]) {
    reportError(reply, [NSString stringWithFormat:@"Unable to determine TotalFinderInjector version!"]);
    return 7;
  }

  NSLog(@"TotalFinderInjector v%@ received init event", injectorVersion);

  @try {
    return loadBundle(mainBundleType(reply), reply, refcon);
  } @catch (NSException* exception) {
    reportError(reply, [NSString stringWithFormat:@"Failed to load TotalFinder with exception: %@", exception]);
  }

  return 1;
}

EXPORT OSErr HandleCheckEvent(const AppleEvent* ev, AppleEvent* reply, long refcon) {
  TFBundleType type = mainBundleType(reply);

  if (((type == TotalFinderBundleType) && alreadyLoaded) || ((type == DockHelperBundleType) && dockAlreadyLoaded)) {
    return noErr;
  }

  reportError(reply, @"TotalFinder not loaded");
  return 1;
}

// debug command to emulate a crash in our code
EXPORT OSErr HandleCrashEvent(const AppleEvent* ev, AppleEvent* reply, long refcon) {
  TFBundleType type = mainBundleType(reply);

  if (((type == TotalFinderBundleType) && !alreadyLoaded) || ((type == DockHelperBundleType) && !dockAlreadyLoaded)) {
    return 1;
  }

  TotalFinderShell* shell = nil;
  if (type == TotalFinderBundleType) {
    shell = [NSClassFromString(@"TotalFinder") sharedInstance];
  } else if (type == DockHelperBundleType) {
    shell = [NSClassFromString(@"DockHelperPlugin") sharedInstance];
  }

  if (!shell) {
    reportError(reply, [NSString stringWithFormat:@"Unable to retrieve shell class"]);
    return 3;
  }

  [shell crashMe];
}
