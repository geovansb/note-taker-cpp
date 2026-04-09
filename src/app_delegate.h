#pragma once
#import <AppKit/AppKit.h>

// NSApplicationDelegate for note-taker-bar.
// Owns the NSStatusItem and menu. All UI updates must happen on the main thread.
// AppController will be attached in T4.3; for now the delegate is self-contained.
@interface AppDelegate : NSObject <NSApplicationDelegate>

// Update the menu bar label (must be called on main thread).
- (void)setStatusTitle:(NSString*)title;

// Enable/disable Start/Stop Recording items based on status string (main thread).
- (void)updateMenuForStatus:(NSString*)status;

@end
