#include "text_injector.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>

void injectText(const std::string& utf8_text) {
    if (utf8_text.empty()) return;

    NSString* text = [NSString stringWithUTF8String:utf8_text.c_str()];
    if (!text) return;

    constexpr NSUInteger kBatchSize = 20;
    NSUInteger total = text.length;

    for (NSUInteger offset = 0; offset < total; offset += kBatchSize) {
        NSUInteger len = MIN(kBatchSize, total - offset);
        unichar buffer[kBatchSize];
        [text getCharacters:buffer range:NSMakeRange(offset, len)];

        CGEventRef down = CGEventCreateKeyboardEvent(NULL, 0, true);
        CGEventRef up   = CGEventCreateKeyboardEvent(NULL, 0, false);
        if (!down || !up) {
            if (down) CFRelease(down);
            if (up) CFRelease(up);
            return;
        }

        CGEventSetFlags(down, (CGEventFlags)0);
        CGEventSetFlags(up, (CGEventFlags)0);
        CGEventKeyboardSetUnicodeString(down, len, buffer);
        CGEventKeyboardSetUnicodeString(up, len, buffer);
        CGEventPost(kCGHIDEventTap, down);
        CGEventPost(kCGHIDEventTap, up);
        CFRelease(down);
        CFRelease(up);
    }
}

void copyTextToClipboard(const std::string& utf8_text) {
    if (utf8_text.empty()) return;

    NSString* text = [NSString stringWithUTF8String:utf8_text.c_str()];
    if (!text) return;

    NSPasteboard* pb = [NSPasteboard generalPasteboard];
    [pb clearContents];
    [pb setString:text forType:NSPasteboardTypeString];
}
