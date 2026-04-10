#pragma once
#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>

// NSApplicationDelegate for note-taker-bar.
// Owns the NSStatusItem and menu. All UI updates must happen on the main thread.
// Conforms to UNUserNotificationCenterDelegate so notifications appear even when
// the app is in the foreground (menu bar apps are always "active").
@interface AppDelegate : NSObject <NSApplicationDelegate, UNUserNotificationCenterDelegate>

// Update the menu bar label (must be called on main thread).
- (void)setStatusTitle:(NSString*)title;

// Enable/disable Start/Stop Recording items based on status string (main thread).
- (void)updateMenuForStatus:(NSString*)status;

@end
