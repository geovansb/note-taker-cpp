#import "app_delegate.h"
#include "app_controller.h"
#include "event_tap.h"

@implementation AppDelegate {
    NSStatusItem*  _statusItem;
    AppController* _controller;   // owned; stopped and deleted in applicationWillTerminate:
    EventTap       _eventTap;     // owned; lives on main thread, forwards to controller
    std::string    _outputDir;
}

// ── NSApplicationDelegate ─────────────────────────────────────────────────────

- (void)applicationWillFinishLaunching:(NSNotification*)__unused note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (void)applicationDidFinishLaunching:(NSNotification*)__unused note {
    [self setupStatusItem];
    [self startController];
}

- (void)applicationWillTerminate:(NSNotification*)__unused note {
    _eventTap.stop();
    if (_controller) {
        _controller->stop();
        delete _controller;
        _controller = nullptr;
    }
}

// ── Controller setup ──────────────────────────────────────────────────────────

- (void)startController {
    // Resolve paths in ObjC context, then hand off to pure-C++ AppController.
    NSString* bundleDir = [[[NSBundle mainBundle] bundlePath]
                            stringByDeletingLastPathComponent];
    NSString* modelNS   = [[bundleDir stringByAppendingPathComponent:
                            @"../models/ggml-large-v3.bin"]
                            stringByStandardizingPath];
    NSString* notesNS   = [NSHomeDirectory()
                            stringByAppendingPathComponent:@"notes"];

    std::string modelPath = std::string([modelNS UTF8String]);
    _outputDir            = std::string([notesNS UTF8String]);

    __weak AppDelegate* weakSelf = self;

    _controller = new AppController(modelPath, /*use_metal=*/true, "auto", _outputDir);

    _controller->setOnStatusChange([weakSelf](std::string status) {
        // Called from any thread — dispatch UI updates to main queue.
        NSString* s = [NSString stringWithUTF8String:status.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* d = weakSelf;
            if (!d) return;
            [d setStatusTitle:s];
            [d updateMenuForStatus:s];
        });
    });

    _controller->setOnDictationResult([](std::string text) {
        // T4.4 will replace this with TextInjector.
        // For now, log the result so it's visible in the system log.
        NSLog(@"[dictation] %s", text.c_str());
    });

    // EventTap must start on the main thread so AXIsProcessTrustedWithOptions
    // can show the system Accessibility dialog (UI operations require main thread).
    bool tap_ok = _eventTap.start(
        [weakSelf] {
            AppDelegate* d = weakSelf;
            if (d && d->_controller) d->_controller->onHotkeyDown();
        },
        [weakSelf] {
            AppDelegate* d = weakSelf;
            if (d && d->_controller) d->_controller->onHotkeyUp();
        }
    );
    if (!tap_ok) {
        NSLog(@"[note-taker] EventTap not started — Accessibility not granted; "
              "dictation unavailable until permission is granted and app is relaunched");
    }

    // Load model off the main thread (whisper_init_from_file blocks ~3-5 s).
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        AppDelegate* d = weakSelf;
        if (!d || !d->_controller) return;
        d->_controller->start();
    });
}

// ── Menu construction ─────────────────────────────────────────────────────────

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

    _statusItem.menu = [self buildMenu];

    // macOS Tahoe 26+: warn if the system releases the status item because
    // the app hasn't been authorised under "Allow in the Menu Bar" yet.
    __weak AppDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AppDelegate* s = weakSelf;
        if (!s) return;
        BOOL released = (s->_statusItem == nil || s->_statusItem.button == nil);
        if (!released) {
            NSWindow* w = s->_statusItem.button.window;
            released = (!w || w.frame.origin.y < -100);
        }
        if (released) {
            NSLog(@"[note-taker] Menu bar icon removed by macOS — "
                  "go to System Settings -> Menu Bar and enable note-taker-bar");
            s->_statusItem = nil;
        }
    });
}

- (NSMenu*)buildMenu {
    NSMenu* menu = [[NSMenu alloc] init];

    // tag 1 — dynamic status (updated via setStatusTitle:)
    NSMenuItem* statusItem = [[NSMenuItem alloc] initWithTitle:@"● Idle"
                               action:nil keyEquivalent:@""];
    statusItem.tag     = 1;
    statusItem.enabled = NO;
    [menu addItem:statusItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* hint = [[NSMenuItem alloc] initWithTitle:@"Hold ⌥ Right Option to dictate"
                         action:nil keyEquivalent:@""];
    hint.enabled = NO;
    [menu addItem:hint];

    [menu addItem:[NSMenuItem separatorItem]];

    // tag 2 — Start Recording (enabled when IDLE)
    NSMenuItem* startRec = [[NSMenuItem alloc] initWithTitle:@"▶  Start Recording"
                             action:@selector(startRecording:) keyEquivalent:@""];
    startRec.tag     = 2;
    startRec.enabled = NO;  // enabled once model loads (updateMenuForStatus:)
    [menu addItem:startRec];

    // tag 3 — Stop Recording (enabled when RECORDING)
    NSMenuItem* stopRec = [[NSMenuItem alloc] initWithTitle:@"■  Stop Recording"
                            action:@selector(stopRecording:) keyEquivalent:@""];
    stopRec.tag     = 3;
    stopRec.enabled = NO;
    [menu addItem:stopRec];

    // tag 4 — Open Notes Folder
    NSMenuItem* openFolder = [[NSMenuItem alloc] initWithTitle:@"Open Notes Folder"
                               action:@selector(openNotesFolder:) keyEquivalent:@""];
    openFolder.tag     = 4;
    openFolder.enabled = YES;
    [menu addItem:openFolder];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];

    return menu;
}

// ── Menu actions ──────────────────────────────────────────────────────────────

- (void)startRecording:(id)__unused sender {
    if (_controller) _controller->startSession();
}

- (void)stopRecording:(id)__unused sender {
    if (_controller) _controller->stopSession();
}

- (void)openNotesFolder:(id)__unused sender {
    NSString* dir = [NSString stringWithUTF8String:_outputDir.c_str()];
    if (![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:nil];
    }
    [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:dir]];
}

// ── Status updates ────────────────────────────────────────────────────────────

- (void)setStatusTitle:(NSString*)title {
    // Must be called on the main thread.
    NSMenuItem* item = [_statusItem.menu itemWithTag:1];
    if (item) item.title = title;
}

- (void)updateMenuForStatus:(NSString*)status {
    // Must be called on the main thread.
    NSMenuItem* startRec = [_statusItem.menu itemWithTag:2];
    NSMenuItem* stopRec  = [_statusItem.menu itemWithTag:3];
    BOOL isIdle      = [status hasPrefix:@"● Idle"];
    BOOL isRecording = [status hasPrefix:@"🔴"];
    startRec.enabled = isIdle;
    stopRec.enabled  = isRecording;
}

@end
