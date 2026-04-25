#import <AppKit/AppKit.h>
#include "app_logger.h"
#import "app_delegate.h"

int main(int argc, const char* argv[]) {
    @autoreleasepool {
        NSString* defaultNotesDir = [NSHomeDirectory() stringByAppendingPathComponent:@"notes"];
        [[NSUserDefaults standardUserDefaults] registerDefaults:@{
            @"output_dir": defaultNotesDir,
            @"log_level": @"warn",
        }];

        NSString* notesNS = [[NSUserDefaults standardUserDefaults] stringForKey:@"output_dir"];
        NSString* levelNS = [[NSUserDefaults standardUserDefaults] stringForKey:@"log_level"];
        std::string notesDir = notesNS ? std::string([notesNS UTF8String]) : std::string([defaultNotesDir UTF8String]);
        std::string level = levelNS ? std::string([levelNS UTF8String]) : "warn";

        AppLogger::init(notesDir, AppLogger::parseLevel(level));
        AppLogger::redirectStandardStreams();
        NT_LOG_WARN("app", "starting note-taker-bar pid=%d log_path=%s",
                    getpid(), AppLogger::path().c_str());

        // Prevent multiple instances — conflicting event taps and session file
        // overwrites would cause data loss.
        NSString* bundleId = [[NSBundle mainBundle] bundleIdentifier];
        if (bundleId) {
            NSArray<NSRunningApplication*>* others =
                [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleId];
            // Filter out ourselves (pid match).
            for (NSRunningApplication* app in others) {
                if (app.processIdentifier != getpid()) {
                    NT_LOG_ERROR("app", "another instance of note-taker-bar is already running pid=%d",
                                 app.processIdentifier);
                    // Bring the existing instance's menu to attention.
                    [app activateWithOptions:0];
                    AppLogger::shutdown();
                    return 1;
                }
            }
        }

        NSApplication* app = [NSApplication sharedApplication];
        AppDelegate* delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
        NT_LOG_WARN("app", "note-taker-bar exited");
        AppLogger::shutdown();
    }
    return 0;
}
