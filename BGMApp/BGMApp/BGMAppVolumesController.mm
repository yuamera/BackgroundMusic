// This file is part of Background Music.
//
// Background Music is free software: you can redistribute it and/or
// modify it under the terms of the GNU General Public License as
// published by the Free Software Foundation, either version 2 of the
// License, or (at your option) any later version.
//
// Background Music is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Background Music. If not, see <http://www.gnu.org/licenses/>.

//
//  BGMAppVolumesController.mm
//  BGMApp
//
//  Copyright © 2017, 2018 Kyle Neideck
//  Copyright © 2017 Andrew Tonner
//  Copyright © 2021 Marcus Wu
//

// Self Include
#import "BGMAppVolumesController.h"

// Local Includes
#import "BGM_Types.h"
#import "BGM_Utils.h"
#import "BGMAppVolumes.h"
#import "BGMUserDefaults.h"

// PublicUtility Includes
#import "CACFArray.h"
#import "CACFDictionary.h"
#import "CACFString.h"

// System Includes
#include <libproc.h>


#pragma clang assume_nonnull begin

@implementation BGMAppVolumesController {
    BGMAppVolumes* appVolumes;
    BGMAudioDeviceManager* audioDevices;
    BGMUserDefaults* userDefaults;

    // Holds bundle IDs -> target volumes for apps that have been assigned a saved volume in the UI
    // but haven't yet been restored on the driver side (because the app hasn't started playing audio
    // yet). A single deferred attempt is made to restore these volumes.
    NSMutableDictionary<NSString*, NSNumber*>* pendingDriverRestores;
}

#pragma mark Initialisation

- (id) initWithMenu:(NSMenu*)menu
      appVolumeView:(NSView*)view
       audioDevices:(BGMAudioDeviceManager*)devices
        userDefaults:(BGMUserDefaults*)defaults {
    if ((self = [super init])) {
        audioDevices = devices;
        userDefaults = defaults;
        pendingDriverRestores = [NSMutableDictionary new];
        appVolumes = [[BGMAppVolumes alloc] initWithController:self
                                                        bgmMenu:menu
                                                  appVolumeView:view];

        // Create the menu items for controlling app volumes.
        NSArray<NSRunningApplication*>* apps = [[NSWorkspace sharedWorkspace] runningApplications];
        [self insertMenuItemsForApps:apps];

        // Register for notifications when the user opens or closes apps, so we can update the menu.
        auto opts = NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld;
        [[NSWorkspace sharedWorkspace] addObserver:self
                                        forKeyPath:@"runningApplications"
                                           options:opts
                                           context:nil];
    }

    return self;
}

- (void) dealloc {
    [[NSWorkspace sharedWorkspace] removeObserver:self
                                        forKeyPath:@"runningApplications"
                                           context:nil];
}


// Checks whether the given bundle ID appears in the app volumes reported by the audio driver.
- (BOOL) isBundleIDPresentInVolumes:(NSString*)bundleID
                         fromDevice:(const CACFArray&)volumesFromBGMDevice {
    for (UInt32 i = 0; i < volumesFromBGMDevice.GetNumberItems(); i++) {
        CACFDictionary appVolume(false);
        volumesFromBGMDevice.GetCACFDictionary(i, appVolume);

        CACFString dictBundleID;
        dictBundleID.DontAllowRelease();
        appVolume.GetCACFString(CFSTR(kBGMAppVolumesKey_BundleID), dictBundleID);

        if ([bundleID isEqualToString:(__bridge NSString*)dictBundleID.GetCFString()]) {
            return YES;
        }
    }
    return NO;
}

// Adds a volume control menu item for each given app.
- (void) insertMenuItemsForApps:(NSArray<NSRunningApplication*>*)apps {
    NSAssert([NSThread isMainThread], @"insertMenuItemsForApps is not thread safe");

    // TODO: Handle the C++ exceptions this method can throw. They can cause crashes because this
    //       method is called in a KVO handler.

    // Get the app volumes currently set on the device
    CACFArray volumesFromBGMDevice([audioDevices bgmDevice].GetAppVolumes(), false);

    for (NSRunningApplication* app in apps) {
        if ([self shouldBeIncludedInMenu:app]) {
            BGMAppVolumeAndPan initial = [self getVolumeAndPanForApp:app
                                                         fromVolumes:volumesFromBGMDevice];

            [appVolumes insertMenuItemForApp:app
                               initialVolume:initial.volume
                                  initialPan:initial.pan];

            NSString* bundleID = app.bundleIdentifier;
            if (bundleID) {
                SInt32 savedVolume = [userDefaults appVolumeForBundleID:bundleID withDefault:-1];
                if (savedVolume != -1) {
                    [appVolumes setVolumeAndPanForAppWithoutAction:app
                                                            volume:savedVolume
                                                               pan:initial.pan];

                    if ([self isBundleIDPresentInVolumes:bundleID fromDevice:volumesFromBGMDevice]) {
                        audioDevices.bgmDevice.SetAppVolume(savedVolume,
                                                             app.processIdentifier,
                                                             (__bridge_retained CFStringRef)bundleID);
                    } else {
                        pendingDriverRestores[bundleID] = @(savedVolume);
                    }
                }
            }
        }
    }

    if (pendingDriverRestores.count > 0) {
        [self scheduleDeferredDriverRestore];
    }
}

// Schedules a deferred attempt to restore pending volumes on the driver. This gives apps time to
// start playing audio and register as BGMDevice clients.
- (void) scheduleDeferredDriverRestore {
    __unsafe_unretained BGMAppVolumesController* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [weakSelf performDeferredDriverRestore];
    });
}

// First deferred attempt. Tries to restore pending volumes by sending SetAppVolume to the driver
// for each pending app, regardless of whether it appears in GetAppVolumes. (GetAppVolumes only
// returns clients with non-default volumes, so it's not a reliable way to check if an app is
// registered.)
- (void) performDeferredDriverRestore {
    if (pendingDriverRestores.count == 0) return;

    NSMutableDictionary<NSString*, NSNumber*>* remaining = [NSMutableDictionary new];

    for (NSString* bundleID in pendingDriverRestores) {
        SInt32 targetVolume = [pendingDriverRestores[bundleID] intValue];
        BOOL restored = NO;

        NSArray<NSRunningApplication*>* runningApps = [[NSWorkspace sharedWorkspace] runningApplications];
        for (NSRunningApplication* app in runningApps) {
            if ([app.bundleIdentifier isEqualToString:bundleID]) {
                audioDevices.bgmDevice.SetAppVolume(targetVolume,
                                                     app.processIdentifier,
                                                     (__bridge_retained CFStringRef)bundleID);
                restored = YES;
                break;
            }
        }

        if (!restored) {
            remaining[bundleID] = @(targetVolume);
        }
    }

    pendingDriverRestores = remaining;

    if (pendingDriverRestores.count > 0) {
        __unsafe_unretained BGMAppVolumesController* weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [weakSelf finalDriverRestoreAttempt];
        });
    }
}

// Final attempt. Gives up on any apps that still aren't registered as driver clients.
- (void) finalDriverRestoreAttempt {
    if (pendingDriverRestores.count == 0) return;

    for (NSString* bundleID in pendingDriverRestores) {
        SInt32 targetVolume = [pendingDriverRestores[bundleID] intValue];

        NSArray<NSRunningApplication*>* runningApps = [[NSWorkspace sharedWorkspace] runningApplications];
        for (NSRunningApplication* app in runningApps) {
            if ([app.bundleIdentifier isEqualToString:bundleID]) {
                audioDevices.bgmDevice.SetAppVolume(targetVolume,
                                                     app.processIdentifier,
                                                     (__bridge_retained CFStringRef)bundleID);
                break;
            }
        }
    }

    [pendingDriverRestores removeAllObjects];
}

- (BGMAppVolumeAndPan) getVolumeAndPanForApp:(NSRunningApplication *)app {
    return [appVolumes getVolumeAndPanForApp:app];
}

- (void) setVolumeAndPan:(BGMAppVolumeAndPan)volumeAndPan forApp:(NSRunningApplication*)app {
    [appVolumes setVolumeAndPan:volumeAndPan forApp:app];
    if (volumeAndPan.volume != -1) {
        [self setVolume:volumeAndPan.volume forAppWithProcessID:app.processIdentifier bundleID:app.bundleIdentifier];
    }
    if (volumeAndPan.pan != kAppPanNoValue) {
        [self setPanPosition:volumeAndPan.pan forAppWithProcessID:app.processIdentifier bundleID:app.bundleIdentifier];
    }
}

- (BGMAppVolumeAndPan) getVolumeAndPanForApp:(NSRunningApplication*)app
                                 fromVolumes:(const CACFArray&)volumes {
    BGMAppVolumeAndPan volumeAndPan = {
        .volume = -1,
        .pan = kAppPanNoValue
    };

    for (UInt32 i = 0; i < volumes.GetNumberItems(); i++) {
        CACFDictionary appVolume(false);
        volumes.GetCACFDictionary(i, appVolume);

        // Match the app to the volume/pan by pid or bundle ID.
        CACFString bundleID;
        bundleID.DontAllowRelease();
        appVolume.GetCACFString(CFSTR(kBGMAppVolumesKey_BundleID), bundleID);

        pid_t pid;
        appVolume.GetSInt32(CFSTR(kBGMAppVolumesKey_ProcessID), pid);

        if ((app.processIdentifier == pid) ||
            [app.bundleIdentifier isEqualToString:(__bridge NSString*)bundleID.GetCFString()]) {
            // Found a match, so read the volume and pan.
            appVolume.GetSInt32(CFSTR(kBGMAppVolumesKey_RelativeVolume), volumeAndPan.volume);
            appVolume.GetSInt32(CFSTR(kBGMAppVolumesKey_PanPosition), volumeAndPan.pan);
            break;
        }
    }

    return volumeAndPan;
}

- (BOOL) shouldBeIncludedInMenu:(NSRunningApplication*)app {
    // Ignore hidden apps and Background Music itself.
    // TODO: Would it be better to only show apps that are registered as HAL clients?
    BOOL isHidden = app.activationPolicy != NSApplicationActivationPolicyRegular &&
                    app.activationPolicy != NSApplicationActivationPolicyAccessory;

    NSString* bundleID = app.bundleIdentifier;
    BOOL isBGMApp = bundleID && [@kBGMAppBundleID isEqualToString:BGMNN(bundleID)];

    return !isHidden && !isBGMApp;
}

- (void) removeMenuItemsForApps:(NSArray<NSRunningApplication*>*)apps {
    NSAssert([NSThread isMainThread], @"removeMenuItemsForApps is not thread safe");

    for (NSRunningApplication* app in apps) {
        [appVolumes removeMenuItemForApp:app];
    }
}

#pragma mark Accessors

- (void)  setVolume:(SInt32)volume
forAppWithProcessID:(pid_t)processID
           bundleID:(NSString* __nullable)bundleID {
    // Update the app's volume.
    audioDevices.bgmDevice.SetAppVolume(volume, processID, (__bridge_retained CFStringRef)bundleID);

    // Persist the volume to UserDefaults.
    NSString* nonNullBundleID = bundleID;
    if (nonNullBundleID) {
        [userDefaults setAppVolume:volume forBundleID:nonNullBundleID];
    }

    // If this volume is for FaceTime, set the volume for the avconferenced process as well. This
    // works around FaceTime not playing its own audio. It plays UI sounds through
    // systemsoundserverd and call audio through avconferenced.
    //
    // This isn't ideal because other apps might play audio through avconferenced, but I don't see a
    // good way we could find out which app is actually playing the audio. We could probably figure
    // it out from reading avconferenced's logs, at least, if it turns out to be important. See
    // https://github.com/kyleneideck/BackgroundMusic/issues/139.
    if ([bundleID isEqual:@"com.apple.FaceTime"]) {
        [self setAvconferencedVolume:volume];
    }
}

- (void) setAvconferencedVolume:(SInt32)volume {
    // TODO: This volume will be lost if avconferenced is restarted.
    pid_t pids[1024];
    size_t procCount = proc_listallpids(pids, 1024);
    char path[PROC_PIDPATHINFO_MAXSIZE];

    for (int i = 0; i < procCount; i++) {
        pid_t pid = pids[i];

        if (proc_pidpath(pid, path, sizeof(path)) > 0 &&
            strncmp(path, "/usr/libexec/avconferenced", sizeof(path)) == 0) {
            DebugMsg("Setting avconferenced volume: %d", volume);
            audioDevices.bgmDevice.SetAppVolume(volume, pid, nullptr);
            return;
        }
    }

    LogWarning("Failed to set avconferenced volume.");
}

- (void) setPanPosition:(SInt32)pan
    forAppWithProcessID:(pid_t)processID
               bundleID:(NSString* __nullable)bundleID {
    audioDevices.bgmDevice.SetAppPanPosition(pan,
                                             processID,
                                             (__bridge_retained CFStringRef)bundleID);
}

#pragma mark KVO

- (void) observeValueForKeyPath:(NSString* __nullable)keyPath
                       ofObject:(id __nullable)object
                         change:(NSDictionary* __nullable)change
                        context:(void* __nullable)context
{
    #pragma unused (object, context)

    // KVO callback for the apps currently running on the system. Adds/removes the associated menu
    // items.
    if (keyPath && change && [keyPath isEqualToString:@"runningApplications"]) {
        NSArray<NSRunningApplication*>* newApps = change[NSKeyValueChangeNewKey];
        NSArray<NSRunningApplication*>* oldApps = change[NSKeyValueChangeOldKey];

        int changeKind = [change[NSKeyValueChangeKindKey] intValue];

        switch (changeKind) {
            case NSKeyValueChangeInsertion:
                [self insertMenuItemsForApps:newApps];
                break;

            case NSKeyValueChangeRemoval:
                [self removeMenuItemsForApps:oldApps];
                break;

            case NSKeyValueChangeReplacement:
                [self removeMenuItemsForApps:oldApps];
                [self insertMenuItemsForApps:newApps];
                break;

            case NSKeyValueChangeSetting:
                [appVolumes removeAllAppVolumeMenuItems];
                [self insertMenuItemsForApps:newApps];
                break;
        }
    }
}

@end

#pragma clang assume_nonnull end

