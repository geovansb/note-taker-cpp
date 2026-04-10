#import <AppKit/AppKit.h>
#import "app_delegate.h"

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        // Prevent multiple instances — conflicting event taps and session file
        // overwrites would cause data loss.
        NSString* bundleId = [[NSBundle mainBundle] bundleIdentifier];
        if (bundleId) {
            NSArray<NSRunningApplication*>* others =
                [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleId];
            // Filter out ourselves (pid match).
            for (NSRunningApplication* app in others) {
                if (app.processIdentifier != getpid()) {
                    fprintf(stderr, "error: another instance of note-taker-bar is already running (pid %d)\n",
                            app.processIdentifier);
                    // Bring the existing instance's menu to attention.
                    [app activateWithOptions:NSApplicationActivateIgnoringOtherApps];
                    return 1;
                }
            }
        }

        NSApplication* app = [NSApplication sharedApplication];
        AppDelegate* delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
