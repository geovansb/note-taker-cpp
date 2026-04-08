#import "app_delegate.h"

@implementation AppDelegate {
    NSStatusItem* _statusItem;
}

- (void)applicationWillFinishLaunching:(NSNotification*)__unused note {
    fprintf(stderr, "debug: applicationWillFinishLaunching\n");
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (void)applicationDidFinishLaunching:(NSNotification*)__unused note {
    fprintf(stderr, "debug: applicationDidFinishLaunching\n");
    [self setupStatusItem];
    fprintf(stderr, "debug: done\n");
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

    // Minimal menu — just Quit to rule out menu construction as crash source.
    NSMenu* menu = [[NSMenu alloc] init];
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

@end