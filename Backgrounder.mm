/**
 * Name: Backgrounder
 * Type: iPhone OS 2.x SpringBoard extension (MobileSubstrate-based)
 * Description: allow applications to run in the background
 * Author: Lance Fetters (aka. ashikase)
 * Last-modified: 2008-10-09 21:25:37
 */

/**
 * Copyright (C) 2008  Lance Fetters (aka. ashikase)
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in
 *    the documentation and/or other materials provided with the
 *    distribution.
 *
 * 3. The name of the author may not be used to endorse or promote
 *    products derived from this software without specific prior
 *    written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR "AS IS" AND ANY EXPRESS
 * OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
 * (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
 * SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT,
 * STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING
 * IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 */

#import <objc/message.h>
#include <signal.h>
#include <substrate.h>

#import <GraphicsServices/GraphicsServices.h>

#import <Foundation/NSArray.h>
#import <Foundation/NSAutoreleasePool.h>
#import <Foundation/NSBundle.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSString.h>
#import <Foundation/NSTimer.h>

#import <SpringBoard/SBApplication.h>
#import <SpringBoard/SBAlertItemsController.h>
#import <SpringBoard/SBDisplayStack.h>
#import <SpringBoard/SpringBoard.h>

#import <UIKit/UIApplication.h>

#import "SimplePopup.h"
#import "TaskMenuPopup.h"

// -----------------------------------------------------------------------------
// ------------------------------ SPRINGBOARD ----------------------------------
// -----------------------------------------------------------------------------

#define SIMPLE_POPUP 0
#define TASK_MENU_POPUP 1
static int activationFeedback = 0;

static NSMutableArray *backgroundingEnabledApps = nil;

//______________________________________________________________________________
//______________________________________________________________________________

@protocol BackgrounderSBStack
- (id)bg_init;
@end

static SBDisplayStack *displayStack = nil;

static id $SBDisplayStack$init(SBDisplayStack<BackgrounderSBStack> *self, SEL sel)
{
    // NOTE: SpringBoard appears to create five stacks at startup;
    //       the first stack is for applications (the others, unknown)
    id ret = [self bg_init];
    if (!displayStack)
        displayStack = ret;
    return ret;
}

//______________________________________________________________________________
//______________________________________________________________________________

static BOOL alertTimerDidFire = NO;

// The alert window displays instructions when the home button is held down
static NSTimer *alertTimer = nil;
static id alert = nil;

static void cancelAlertTimer()
{
    // Disable and release timer (may be nil)
    [alertTimer invalidate];
    [alertTimer release];
    alertTimer = nil;
}

static void cancelAlert()
{
    // Hide and release alert window (may be nil)
    if (activationFeedback == TASK_MENU_POPUP) {
        [alert deactivate];
    } else {
        [alert dismiss];
    }
    [alert release];
    alert = nil;
}

@protocol BackgrounderSB
- (void)bg_applicationDidFinishLaunching:(id)application;
- (void)bg_dealloc;
- (void)bg_menuButtonDown:(GSEvent *)event;
- (void)bg_menuButtonUp:(GSEvent *)event;
@end

static void $SpringBoard$toggleBackgrounding(id self, SEL sel)
{
    alertTimerDidFire = YES;

    id app = [displayStack topApplication];
    if (app) {
        // Notify the application that the menu button was pressed
        kill([app pid], SIGUSR1);

        // Store the backgrounding status of the application
        NSString *identifier = [app bundleIdentifier];
        NSUInteger index = [backgroundingEnabledApps indexOfObject:identifier];
        if (index != NSNotFound)
            // Backgrounding disabled
            [backgroundingEnabledApps removeObjectAtIndex:index];
        else
            // Backgrounding enabled
            [backgroundingEnabledApps addObject:identifier];

        // Display popup alert
        if (activationFeedback == TASK_MENU_POPUP) {
            Class $SBAlert = objc_getClass("BackgrounderAlert");
            alert = [[$SBAlert alloc] initWithApplication:app];
            [alert activate];
        } else {
            NSString *status = [NSString stringWithFormat:@"Backgrounding %s",
                     ((index != NSNotFound) ? "Disabled" : "Enabled")];

            Class $BackgrounderAlertItem = objc_getClass("BackgrounderAlertItem");
            alert = [[$BackgrounderAlertItem alloc] initWithTitle:status
                message:@"(Continue holding to force-quit)"];

            Class $SBAlertItemsController(objc_getClass("SBAlertItemsController"));
            SBAlertItemsController *controller = [$SBAlertItemsController sharedInstance];
            [controller activateAlertItem:alert];
        }
    }
}

static void $SpringBoard$applicationDidFinishLaunching$(SpringBoard<BackgrounderSB> *self, SEL sel, id application)
{
    // NOTE: The initial capacity value was arbitrarily chosen
    backgroundingEnabledApps = [[NSMutableArray alloc] initWithCapacity:3];

    [self bg_applicationDidFinishLaunching:application];
}

static void $SpringBoard$dealloc(SpringBoard<BackgrounderSB> *self, SEL sel)
{
    [backgroundingEnabledApps release];
    [self bg_dealloc];
}

static void $SpringBoard$menuButtonDown$(SpringBoard<BackgrounderSB> *self, SEL sel, GSEvent *event)
{
    // Setup toggle-delay timer
    id app = [displayStack topApplication];
    if (app && app != self)
        alertTimer = [[NSTimer scheduledTimerWithTimeInterval:0.7f
            target:self selector:@selector(showBackgrounderMessageBox)
            userInfo:nil repeats:NO] retain];

    // Begin normal 'kill if held' sequence
    [self bg_menuButtonDown:event];
}

static void $SpringBoard$menuButtonUp$(SpringBoard<BackgrounderSB> *self, SEL sel, GSEvent *event)
{
    // Stop popup alert from showing (if button-up before timeout)
    cancelAlertTimer();

    // Hide and destroy the popup alert
    cancelAlert();

    [self bg_menuButtonUp:event];
}

//______________________________________________________________________________
//______________________________________________________________________________

@protocol BackgrounderSBApp
- (BOOL)bg_shouldLaunchPNGless;
- (void)bg_launchSucceeded;
- (BOOL)bg_kill;
- (void)bg__startTerminationWatchdogTimer;
@end

static BOOL $SBApplication$shouldLaunchPNGless(SBApplication<BackgrounderSBApp> *self, SEL sel)
{
    // Only show splash-screen on initial launch
    return ([self pid] != -1) ? YES : [self bg_shouldLaunchPNGless];
}

#define PREFS_FILE "/var/mobile/Library/Preferences/jp.ashikase.backgrounder.plist"

static void $SBApplication$launchSucceeded(SBApplication<BackgrounderSBApp> *self, SEL sel)
{
    NSString *identifier = [self bundleIdentifier];

    if (![backgroundingEnabledApps containsObject:identifier]) {
        // Initial launch; check if this application defaults to backgrounding
        // NOTE: Can't use CFPreferences* functions due to AppStore sandboxing
        NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@PREFS_FILE];
        NSArray *array = [prefs objectForKey:@"enabled_apps"];
        if ([array containsObject:identifier]) {
            // Tell the application to enable backgrounding
            kill([self pid], SIGUSR1);
            // Store the backgrounding status of the application
            [backgroundingEnabledApps addObject:identifier];
        }
    }

    [self bg_launchSucceeded];
}

static BOOL $SBApplication$kill(SBApplication<BackgrounderSBApp> *self, SEL sel)
{
    // Hide and destroy the popup alert
    cancelAlert();
    return [self bg_kill];
}

static void $SBApplication$_startTerminationWatchdogTimer(SBApplication<BackgrounderSBApp> *self, SEL sel)
{
    if (![backgroundingEnabledApps containsObject:[self bundleIdentifier]])
        [self bg__startTerminationWatchdogTimer];
}

// -----------------------------------------------------------------------------
// ---------------------------- THE APPLICATION --------------------------------
// -----------------------------------------------------------------------------

static BOOL backgroundingEnabled = NO;

// Callback
static void toggleBackgrounding(int signal)
{
    backgroundingEnabled = !backgroundingEnabled;
}

// Class methods

static BOOL $UIApplication$isBackgroundingEnabled(id self, SEL sel)
{
    return backgroundingEnabled;
}

static void $UIApplication$setBackgroundingEnabled$(id self, SEL sel, BOOL enable)
{
    backgroundingEnabled = enable;
}

//______________________________________________________________________________
//______________________________________________________________________________

@protocol BackgrounderApp
- (void)bg_applicationWillSuspend;
- (void)bg_applicationDidResume;
- (void)bg_applicationWillResignActive:(UIApplication *)application;
- (void)bg_applicationDidBecomeActive:(UIApplication *)application;;
- (void)bg_applicationSuspend:(GSEvent *)event;
//- (void)bg__setSuspended:(BOOL)val;
- (void)bg__loadMainNibFile;
@end

// Prevent execution of application's on-suspend/resume methods
static void $UIApplication$applicationWillSuspend(UIApplication<BackgrounderApp> *self, SEL sel)
{
    if (!backgroundingEnabled)
        [self bg_applicationWillSuspend];
}

static void $UIApplication$applicationDidResume(UIApplication<BackgrounderApp> *self, SEL sel)
{
    if (!backgroundingEnabled)
        [self bg_applicationDidResume];
}

static void $UIApplication$applicationWillResignActive$(UIApplication<BackgrounderApp> *self, SEL sel, id application)
{
    if (!backgroundingEnabled)
        [self bg_applicationWillResignActive:application];
}

static void $UIApplication$applicationDidBecomeActive$(UIApplication<BackgrounderApp> *self, SEL sel, id application)
{
    if (!backgroundingEnabled)
        [self bg_applicationDidBecomeActive:application];
}

// Overriding this method prevents the application from quitting on suspend
static void $UIApplication$applicationSuspend$(UIApplication<BackgrounderApp> *self, SEL sel, GSEvent *event)
{
    if (!backgroundingEnabled)
        [self bg_applicationSuspend:event];
}

// FIXME: Tests make this appear unneeded... confirm
#if 0
static void $UIApplication$_setSuspended$(UIApplication<BackgrounderApp> *self, SEL sel, BOOL val)
{
    //[self bg__setSuspended:val];
}
#endif

static void $UIApplication$_loadMainNibFile(UIApplication<BackgrounderApp> *self, SEL sel)
{
    // NOTE: This method always gets called, even if no NIB files are used.
    //       Also note that if an application overrides this method (unlikely,
    //       but possible), this extension's hooks will not be installed.
    [self bg__loadMainNibFile];

    Class $UIApplication([self class]);
    MSHookMessage($UIApplication, @selector(applicationSuspend:), (IMP)&$UIApplication$applicationSuspend$, "bg_");
    MSHookMessage($UIApplication, @selector(applicationWillSuspend), (IMP)&$UIApplication$applicationWillSuspend, "bg_");
    MSHookMessage($UIApplication, @selector(applicationDidResume), (IMP)&$UIApplication$applicationDidResume, "bg_");

    id delegate = [self delegate];
    Class $AppDelegate(delegate ? [delegate class] : [self class]);
    MSHookMessage($AppDelegate, @selector(applicationWillResignActive:), (IMP)&$UIApplication$applicationWillResignActive$, "bg_");
    MSHookMessage($AppDelegate, @selector(applicationDidBecomeActive:), (IMP)&$UIApplication$applicationDidBecomeActive$, "bg_");
}

//______________________________________________________________________________
//______________________________________________________________________________

#define APP_ID "jp.ashikase.backgrounder"

extern "C" void BackgrounderInitialize()
{
    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

    NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];

    if ([identifier isEqualToString:@"com.apple.springboard"]) {
        // Is SpringBoard
        Class $SBDisplayStack(objc_getClass("SBDisplayStack"));
        MSHookMessage($SBDisplayStack, @selector(init), (IMP)&$SBDisplayStack$init, "bg_");

        Class $SpringBoard(objc_getClass("SpringBoard"));
        MSHookMessage($SpringBoard, @selector(applicationDidFinishLaunching:), (IMP)&$SpringBoard$applicationDidFinishLaunching$, "bg_");
        MSHookMessage($SpringBoard, @selector(dealloc), (IMP)&$SpringBoard$dealloc, "bg_");
        MSHookMessage($SpringBoard, @selector(menuButtonDown:), (IMP)&$SpringBoard$menuButtonDown$, "bg_");
        MSHookMessage($SpringBoard, @selector(menuButtonUp:), (IMP)&$SpringBoard$menuButtonUp$, "bg_");
        class_addMethod($SpringBoard, @selector(showBackgrounderMessageBox), (IMP)&$SpringBoard$toggleBackgrounding, "v@:");

        Class $SBApplication(objc_getClass("SBApplication"));
        MSHookMessage($SBApplication, @selector(shouldLaunchPNGless), (IMP)&$SBApplication$shouldLaunchPNGless, "bg_");
        MSHookMessage($SBApplication, @selector(launchSucceeded), (IMP)&$SBApplication$launchSucceeded, "bg_");
        MSHookMessage($SBApplication, @selector(kill), (IMP)&$SBApplication$kill, "bg_");
        MSHookMessage($SBApplication, @selector(_startTerminationWatchdogTimer), (IMP)&$SBApplication$_startTerminationWatchdogTimer, "bg_");

        CFPropertyListRef prefFeedback = CFPreferencesCopyAppValue(CFSTR("activationFeedback"), CFSTR(APP_ID));
        if ([(NSString *)prefFeedback isEqualToString:@"taskMenuPopup"]) {
            // Task menu popup
            activationFeedback = TASK_MENU_POPUP;
            initTaskMenuPopup();
        } else {
            // Simple notification popup
            activationFeedback = SIMPLE_POPUP;
            initSimplePopup();
        }
    } else {
        // Is an application
        Class $UIApplication(objc_getClass("UIApplication"));
        MSHookMessage($UIApplication, @selector(_loadMainNibFile), (IMP)&$UIApplication$_loadMainNibFile, "bg_");
        class_addMethod($UIApplication, @selector(isBackgroundingEnabled), (IMP)&$UIApplication$isBackgroundingEnabled, "c@:");
        class_addMethod($UIApplication, @selector(setBackgroundingEnabled:), (IMP)&$UIApplication$setBackgroundingEnabled$, "v@:c");

        // Setup action to take upon receiving toggle signal from SpringBoard
        // NOTE: Done this way as the application hooks *must* be installed in
        //       the UIApplication process, not the SpringBoard process
        sigset_t block_mask;
        sigfillset(&block_mask);
        struct sigaction action;
        action.sa_handler = toggleBackgrounding;
        action.sa_mask = block_mask;
        action.sa_flags = 0;
        sigaction(SIGUSR1, &action, NULL);
    }

    [pool release];
}

/* vim: set syntax=objcpp sw=4 ts=4 sts=4 expandtab textwidth=80 ff=unix: */
