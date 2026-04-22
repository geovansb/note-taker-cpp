#pragma once
#import <AppKit/AppKit.h>
#include "app_status.h"

// NSApplicationDelegate for note-taker-bar.
// Owns the NSStatusItem and menu. All UI updates must happen on the main thread.
@interface AppDelegate : NSObject <NSApplicationDelegate>

// Update the menu bar label (must be called on main thread).
- (void)setStatusTitle:(NSString*)title;

// Enable/disable Start/Stop Recording items based on status (main thread).
- (void)updateMenuForStatus:(AppStatus)status;

@end
