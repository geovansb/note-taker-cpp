#pragma once
#import <AppKit/AppKit.h>

// NSApplicationDelegate for note-taker-bar.
// Owns the NSStatusItem and menu. All UI updates must happen on the main thread.
// AppController will be attached in T4.3; for now the delegate is self-contained.
@interface AppDelegate : NSObject <NSApplicationDelegate>

// Update the menu bar icon text (call from any thread — dispatches to main queue).
- (void)setStatusTitle:(NSString*)title;

// Stub selectors — no-ops until AppController wired
- (void)startRecording:(id)sender;
- (void)stopRecording:(id)sender;
- (void)openNotesFolder:(id)sender;

@end
