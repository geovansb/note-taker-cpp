#import "app_delegate.h"
#include "event_tap.h"

@implementation AppDelegate {
    NSStatusItem* _statusItem;
    EventTap* _eventTap;
}

- (void)applicationWillFinishLaunching:(NSNotification*)__unused note {
    fprintf(stderr, "debug: applicationWillFinishLaunching\n");
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (void)applicationDidFinishLaunching:(NSNotification*)__unused note {
    fprintf(stderr, "debug: applicationDidFinishLaunching\n");
    [self setupStatusItem];
    _eventTap = new EventTap();
    bool ok = _eventTap->start(
        []() { fprintf(stderr, "debug: hotkey DOWN\n"); },
        []() { fprintf(stderr, "debug: hotkey UP\n"); }
    );
    if (!ok) {
        fprintf(stderr, "debug: failed to start EventTap\n");
    } else {
        fprintf(stderr, "debug: EventTap started\n");
    }
    fprintf(stderr, "debug: done\n");
}

- (void)applicationWillTerminate:(NSNotification*)__unused note {
    fprintf(stderr, "debug: applicationWillTerminate\n");
    if (_eventTap) {
        _eventTap->stop();
        delete _eventTap;
        _eventTap = nullptr;
    }
}

- (void)setupStatusItem {
    _statusItem = [[NSStatusBar systemStatusBar]
                   statusItemWithLength:NSVariableStatusItemLength];

    NSImage* img = [NSImage imageWithSystemSymbolName:@"mic.fill"
                             accessibilityDescription:@"note-taker"];
    if (img) {
        [img setTemplate:YES];
        _statusItem.button.image = img;
    } else {
        _statusItem.button.title = @"NT";
    }

    // Full menu skeleton
    NSMenu* menu = [[NSMenu alloc] init];

    // tag 1 — dynamic status string, updated by AppController via setStatusTitle:
    NSMenuItem* statusItem = [[NSMenuItem alloc] initWithTitle:@"● Idle"
                              action:nil keyEquivalent:@""];
    statusItem.tag = 1;
    statusItem.enabled = NO;
    [menu addItem:statusItem];

    [menu addItem:[NSMenuItem separatorItem]];

    // Dictation hint (informational, always disabled)
    NSMenuItem* hint = [[NSMenuItem alloc] initWithTitle:@"Hold ⌥ Right Option to dictate"
                        action:nil keyEquivalent:@""];
    hint.enabled = NO;
    [menu addItem:hint];

    [menu addItem:[NSMenuItem separatorItem]];

    // tag 2 — Start Recording (enabled by AppController when IDLE)
    NSMenuItem* startRec = [[NSMenuItem alloc] initWithTitle:@"▶ Start Recording"
                             action:@selector(startRecording:) keyEquivalent:@""];
    startRec.tag = 2;
    startRec.enabled = NO;   // disabled until AppController wired
    [menu addItem:startRec];

    // tag 3 — Stop Recording (enabled only when RECORDING)
    NSMenuItem* stopRec = [[NSMenuItem alloc] initWithTitle:@"■ Stop Recording"
                            action:@selector(stopRecording:) keyEquivalent:@""];
    stopRec.tag = 3;
    stopRec.enabled = NO;
    [menu addItem:stopRec];

    // Open Notes Folder (tag 4)
    NSMenuItem* openFolder = [[NSMenuItem alloc] initWithTitle:@"📂 Open Notes Folder"
                               action:@selector(openNotesFolder:) keyEquivalent:@""];
    openFolder.tag = 4;
    openFolder.enabled = NO;   // enabled in T4.5
    [menu addItem:openFolder];

    [menu addItem:[NSMenuItem separatorItem]];

    // Quit — always enabled
    [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];

    _statusItem.menu = menu;

    fprintf(stderr, "debug: NSStatusItem ready\n");

    // macOS Tahoe 26+: the system may release the NSStatusItem immediately if
    // the app hasn't been authorised under "Allow in the Menu Bar" yet.
    // Use a weak reference so the block doesn't crash on the released object,
    // and reschedule a fresh status item if the current one was discarded.
    __weak AppDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AppDelegate* s = weakSelf;
        if (!s) return;

        // Check if the system released our status item.
        BOOL released = (s->_statusItem == nil || s->_statusItem.button == nil);

        if (!released) {
            // Check off-screen rendering (another Tahoe hiding mechanism).
            NSWindow* w = s->_statusItem.button.window;
            released = (!w || w.frame.origin.y < -100);
        }

        if (released) {
            fprintf(stderr,
                "\n[!] macOS removed the menu bar icon (app not authorised).\n"
                "    Go to: System Settings -> Menu Bar -> Allow in the Menu Bar\n"
                "    Find 'note-taker' and enable it, then relaunch.\n\n");
            // Keep the app alive so it stays in the list.
            s->_statusItem = nil;
        }
    });
}

- (void)setStatusTitle:(NSString*)title {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMenuItem* item = [self->_statusItem.menu itemWithTag:1];
        if (item) item.title = title;
    });
}

// Stub selectors — no-ops until AppController wired
- (void)startRecording:(id)__unused sender {}
- (void)stopRecording:(id)__unused sender {}
- (void)openNotesFolder:(id)__unused sender {}

- (void)dealloc {
    if (_eventTap) {
        delete _eventTap;
    }
#if !__has_feature(objc_arc)
    [super dealloc];
#endif
}

@end
