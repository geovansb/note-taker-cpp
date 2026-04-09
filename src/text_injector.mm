#include "text_injector.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>

void injectText(const std::string& utf8_text) {
    if (utf8_text.empty()) return;

    NSString* text = [NSString stringWithUTF8String:utf8_text.c_str()];
    if (!text) return;

    NSPasteboard* pb = [NSPasteboard generalPasteboard];

    // ── Save current pasteboard so we can restore it after paste ──────────────
    // We snapshot the types and data before overwriting.
    NSArray<NSPasteboardItem*>* saved_items = nil;
    NSArray<NSString*>* types = pb.types;
    if (types.count > 0) {
        NSMutableArray<NSPasteboardItem*>* snapshot = [NSMutableArray array];
        for (NSPasteboardItem* item in pb.pasteboardItems) {
            NSPasteboardItem* copy = [[NSPasteboardItem alloc] init];
            for (NSString* type in item.types) {
                NSData* data = [item dataForType:type];
                if (data) [copy setData:data forType:type];
            }
            [snapshot addObject:copy];
        }
        saved_items = snapshot;
    }

    // ── Write text to pasteboard ───────────────────────────────────────────────
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];

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

    // ── Restore original pasteboard after paste has been processed ────────────
    NSArray<NSPasteboardItem*>* items_to_restore = saved_items;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(300 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (items_to_restore.count > 0) {
            [pb clearContents];
            [pb writeObjects:items_to_restore];
        }
    });
}
