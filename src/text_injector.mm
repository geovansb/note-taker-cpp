#include "text_injector.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>

static NSString* const kPasteboardMarkerType = @"com.note-taker.a4f28";
static NSString* const kPasteboardMarkerValue = @"1";

// Generation counter: only clear the pasteboard for the latest injection.
// Avoids an older delayed cleanup clearing a newer dictation.
static uint64_t g_inject_gen = 0;

void injectText(const std::string& utf8_text, int clear_after_seconds) {
    if (utf8_text.empty()) return;

    NSString* text = [NSString stringWithUTF8String:utf8_text.c_str()];
    if (!text) return;

    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    uint64_t gen = ++g_inject_gen;

    // ── Write only the transient dictation item to pasteboard ─────────────────
    // Deliberately do not read or snapshot the user's previous pasteboard.
    NSPasteboardItem* item = [[NSPasteboardItem alloc] init];
    [item setString:text forType:NSPasteboardTypeString];
    [item setString:kPasteboardMarkerValue forType:kPasteboardMarkerType];
    [pb clearContents];
    if (![pb writeObjects:@[ item ]]) return;

    // ── Simulate Cmd+V ────────────────────────────────────────────────────────
    // Small delay to ensure the pasteboard write is visible to the target app.
    usleep(20 * 1000); // 20 ms

    CGEventRef key_down = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_V, true);
    CGEventRef key_up   = CGEventCreateKeyboardEvent(NULL, kVK_ANSI_V, false);

    CGEventSetFlags(key_down, kCGEventFlagMaskCommand);
    CGEventSetFlags(key_up,   kCGEventFlagMaskCommand);

    CGEventPost(kCGHIDEventTap, key_down);
    CGEventPost(kCGHIDEventTap, key_up);

    CFRelease(key_down);
    CFRelease(key_up);

    if (clear_after_seconds < 1) return;
    if (clear_after_seconds > 59) clear_after_seconds = 59;

    // ── Clear only if this app's transient marker is still present ────────────
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(clear_after_seconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (g_inject_gen != gen) return; // newer injection in flight — skip cleanup
        NSString* marker = [pb stringForType:kPasteboardMarkerType];
        if ([marker isEqualToString:kPasteboardMarkerValue]) {
            [pb clearContents];
        }
    });
}
