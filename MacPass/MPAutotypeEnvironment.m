//
//  MPAutotypeEnvironment.m
//  MacPass
//
//  Created by Michael Starke on 15.01.20.
//  Copyright © 2020 HicknHack Software GmbH. All rights reserved.
//

#import "MPAutotypeEnvironment.h"
#import "NSRunningApplication+MPAdditions.h"
#import "MPPluginHost.h"
#import "MPPlugin.h"
#import "MPSettingsHelper.h"

static NSString *const MPAutotypeChromeBundleIdentifier = @"com.google.Chrome";
static NSString *const MPAutotypeBraveBundleIdentifier = @"com.brave.Browser";
static NSString *const MPAutotypeEdgeBundleIdentifier = @"com.microsoft.edgemac";
static NSString *const MPAutotypeChromiumBundleIdentifier = @"org.chromium.Chromium";
static const int64_t MPAutotypeURLResolutionTimeoutNanos = (int64_t)(0.2 * NSEC_PER_SEC);

static dispatch_queue_t MPAutotypeURLResolverQueue(void) {
  static dispatch_queue_t queue;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    queue = dispatch_queue_create("com.hicknhack.macpass.autotype-url-resolver", DISPATCH_QUEUE_SERIAL);
  });
  return queue;
}

@implementation MPAutotypeEnvironment

+ (instancetype)environmentWithTargetApplication:(NSRunningApplication *)targetApplication entry:(KPKEntry *)entry overrideSequence:(NSString *)overrideSequence {
  return [[MPAutotypeEnvironment alloc] initWithTargetApplication:targetApplication entry:entry overrideSequence:overrideSequence];
}

- (instancetype)initWithTargetApplication:(NSRunningApplication *)targetApplication entry:(KPKEntry *)entry overrideSequence:(NSString *)overrdieSequence {
  self = [super init];
  if(self) {
    _preferredEntry = entry;
    _hidden = NSRunningApplication.currentApplication.isHidden;
    _overrideSequence = [overrdieSequence copy];
    if(!targetApplication) {
      _pid = -1;
      _windowTitle = @"";
      _windowId = -1;
    }
    else {
      NSDictionary *frontApplicationInfoDict = targetApplication.mp_infoDictionary;
      
      _pid = [frontApplicationInfoDict[MPProcessIdentifierKey] intValue];
      _windowTitle = frontApplicationInfoDict[MPWindowTitleKey];
      _windowId = (CGWindowID)[frontApplicationInfoDict[MPWindowIDKey] integerValue];
      
      NSString *resolvedWindowTitle = @"";
      /* if we have any plugin resolvers, let them provide the window title */
      NSArray *resolvers = [MPPluginHost.sharedHost windowTitleResolverForRunningApplication:targetApplication];
      for(MPPlugin<MPAutotypeWindowTitleResolverPlugin> *resolver in resolvers) {
        NSString *windowTitle = [resolver windowTitleForRunningApplication:targetApplication];
        if(windowTitle.length > 0) {
          resolvedWindowTitle = windowTitle;
          break;
        }
      }
      if(resolvedWindowTitle.length <= 0) {
        resolvedWindowTitle = [self _nativeResolvedWindowTitleForRunningApplication:targetApplication];
      }
      if(resolvedWindowTitle.length > 0) {
        _windowTitle = resolvedWindowTitle;
      }
    }
    
  }
  return self;
}

- (BOOL)isSelfTargeting {
  return NSRunningApplication.currentApplication.processIdentifier == _pid;
}

- (NSDictionary *)_infoDictionaryForApplication:(NSRunningApplication *)application {
  NSArray *currentWindows = CFBridgingRelease(CGWindowListCopyWindowInfo(kCGWindowListExcludeDesktopElements, kCGNullWindowID));
  NSArray *windowNumbers = [NSWindow windowNumbersWithOptions:NSWindowNumberListAllApplications];
  NSUInteger minZIndex = NSNotFound;
  NSDictionary *infoDict = nil;
  for(NSDictionary *windowDict in currentWindows) {
    NSString *windowTitle = windowDict[(NSString *)kCGWindowName];
    if(windowTitle.length <= 0) {
      continue;
    }
    NSNumber *processId = windowDict[(NSString *)kCGWindowOwnerPID];
    if(processId && [processId isEqualToNumber:@(application.processIdentifier)]) {
      
      NSNumber *number = (NSNumber *)windowDict[(NSString *)kCGWindowNumber];
      NSUInteger zIndex = [windowNumbers indexOfObject:number];
      if(zIndex < minZIndex) {
        minZIndex = zIndex;
        infoDict = @{
          MPWindowTitleKey: windowTitle,
          MPProcessIdentifierKey : processId
        };
      }
    }
  }
  if(currentWindows.count > 0 && infoDict.count == 0) {
    // show some information about not being able to determine any windows
    NSLog(@"Unable to retrieve any window names. If you encounter this issue you might be running 10.15 and MacPass has no permission for screen recording.");
  }
  return infoDict;
}

- (NSString *)_nativeResolvedWindowTitleForRunningApplication:(NSRunningApplication *)runningApplication {
  if(![NSUserDefaults.standardUserDefaults boolForKey:kMPSettingsKeyAutotypeBrowserURLResolverEnabled]) {
    return @"";
  }
  dispatch_queue_t queue = MPAutotypeURLResolverQueue();
  __block NSString *resolvedWindowTitle = @"";
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  dispatch_async(queue, ^{
    resolvedWindowTitle = [self _resolvedNativeWindowTitleForRunningApplication:runningApplication];
    dispatch_semaphore_signal(semaphore);
  });
  long timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, MPAutotypeURLResolutionTimeoutNanos));
  if(timedOut != 0) {
    return @"";
  }
  return resolvedWindowTitle;
}

- (NSString *)_resolvedNativeWindowTitleForRunningApplication:(NSRunningApplication *)runningApplication {
  NSString *urlString = [self _URLForRunningApplication:runningApplication];
  NSString *trimmedURLString = [urlString stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if(trimmedURLString.length <= 0) {
    return @"";
  }

  NSURL *url = [[NSURL alloc] initWithString:trimmedURLString];
  if(url.host.length <= 0) {
    return @"";
  }

  BOOL useFullURL = [NSUserDefaults.standardUserDefaults boolForKey:kMPSettingsKeyAutotypeBrowserURLFullMatch];
  return useFullURL ? trimmedURLString : url.host;
}

- (NSString *)_URLForRunningApplication:(NSRunningApplication *)runningApplication {
  NSString *bundleIdentifier = runningApplication.bundleIdentifier ?: @"";
  if(bundleIdentifier.length <= 0) {
    return @"";
  }

  NSSet *supportedChromiumBundleIdentifiers = [NSSet setWithArray:@[
    MPAutotypeChromeBundleIdentifier,
    MPAutotypeBraveBundleIdentifier,
    MPAutotypeEdgeBundleIdentifier,
    MPAutotypeChromiumBundleIdentifier
  ]];
  if([supportedChromiumBundleIdentifiers containsObject:bundleIdentifier]) {
    NSArray<NSRunningApplication *> *runningApplications = [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleIdentifier];
    if(runningApplications.count <= 0) {
      return @"";
    }
    NSString *localizedName = runningApplication.localizedName ?: @"";
    NSString *escapedLocalizedName = [localizedName stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    if(escapedLocalizedName.length <= 0) {
      return @"";
    }
    NSString *source = [NSString stringWithFormat:@"tell application \"%@\" to get URL of active tab of front window", escapedLocalizedName];
    return [self _runAppleScript:source];
  }
  return @"";
}

- (NSString *)_runAppleScript:(NSString *)source {
  NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
  NSAppleEventDescriptor *eventDescriptor = [script executeAndReturnError:NULL];
  return eventDescriptor.stringValue ?: @"";
}

@end
