#import "app_delegate.h"
#include "app_controller.h"
#include "event_tap.h"
#include "text_injector.h"

static NSString* const kLangKey      = @"language";
static NSString* const kModelKey     = @"model";
static NSString* const kTranslateKey = @"translate";

@implementation AppDelegate {
    NSStatusItem*  _statusItem;
    AppController* _controller;   // owned; stopped and deleted in applicationWillTerminate:
    EventTap       _eventTap;     // owned; lives on main thread, forwards to controller
    std::string    _outputDir;
    NSString*      _language;
    NSString*      _model;
}

// ── NSApplicationDelegate ─────────────────────────────────────────────────────

- (void)applicationWillFinishLaunching:(NSNotification*)__unused note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (void)applicationDidFinishLaunching:(NSNotification*)__unused note {
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kLangKey:      @"auto",
        kModelKey:     @"large-v3",
        kTranslateKey: @NO,
    }];
    _language  = [[NSUserDefaults standardUserDefaults] stringForKey:kLangKey];
    _model     = [[NSUserDefaults standardUserDefaults] stringForKey:kModelKey];

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

// ── Helpers ───────────────────────────────────────────────────────────────────

- (NSString*)modelPathForKey:(NSString*)key {
    NSString* bundleDir = [[[NSBundle mainBundle] bundlePath]
                            stringByDeletingLastPathComponent];
    NSString* modelFile = [NSString stringWithFormat:@"ggml-%@.bin", key];
    return [[bundleDir stringByAppendingPathComponent:
             [@"../models/" stringByAppendingString:modelFile]]
             stringByStandardizingPath];
}

- (void)showAccessibilityDeniedAlert {
    NSAlert* alert      = [[NSAlert alloc] init];
    alert.messageText   = @"Accessibility permission required";
    alert.informativeText = @"The dictation hotkey (Right Option) requires Accessibility access.\n\n"
                            @"1. Go to Privacy & Security → Accessibility\n"
                            @"2. Enable note-taker-bar\n"
                            @"3. Restart the app\n\n"
                            @"Recording sessions still work without this permission.";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Open System Settings"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:
            [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"]];
    }
}

- (void)showMicDeniedAlert {
    NSAlert* alert      = [[NSAlert alloc] init];
    alert.messageText   = @"Microphone access denied";
    alert.informativeText = @"Grant permission in System Settings:\n\n"
                            @"1. Go to Privacy & Security → Microphone\n"
                            @"2. Enable note-taker-bar\n"
                            @"3. Restart the app";
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"Open System Settings"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        [[NSWorkspace sharedWorkspace] openURL:
            [NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"]];
    }
}

- (void)showModelMissingAlertForKey:(NSString*)key {
    NSAlert* alert      = [[NSAlert alloc] init];
    alert.messageText   = [NSString stringWithFormat:@"Model \"%@\" not found", key];
    alert.informativeText = [NSString stringWithFormat:
        @"Download it by running:\n\n"
        @"    ./scripts/download_model.sh %@\n\n"
        @"Then restart the app.", key];
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

// ── Controller setup ──────────────────────────────────────────────────────────

- (void)startController {
    // Resolve paths in ObjC context, then hand off to pure-C++ AppController.
    NSString* modelNS = [self modelPathForKey:_model];
    NSString* notesNS   = [NSHomeDirectory()
                            stringByAppendingPathComponent:@"notes"];

    std::string modelPath = std::string([modelNS UTF8String]);
    std::string language  = std::string([_language UTF8String]);
    _outputDir            = std::string([notesNS UTF8String]);

    __weak AppDelegate* weakSelf = self;

    bool translate = [[NSUserDefaults standardUserDefaults] boolForKey:kTranslateKey];

    _controller = new AppController(modelPath, /*use_metal=*/true, language, _outputDir);
    if (translate) _controller->setTranslate(true);

    _controller->setOnStatusChange([weakSelf](std::string status) {
        // Called from any thread — dispatch UI updates to main queue.
        NSString* s = [NSString stringWithUTF8String:status.c_str()];
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* d = weakSelf;
            if (!d) return;
            [d setStatusTitle:s];
            [d updateMenuForStatus:s];
            // Show prominent alerts for startup errors.
            if ([s hasPrefix:@"⚠ Model not found"]) {
                [d showModelMissingAlertForKey:d->_model];
            } else if ([s hasPrefix:@"⚠ Mic denied"]) {
                [d showMicDeniedAlert];
            }
        });
    });

    _controller->setOnDictationResult([](std::string text) {
        // Inject text at cursor. Must run on main thread (CGEventPost requirement).
        dispatch_async(dispatch_get_main_queue(), ^{
            injectText(text);
        });
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
        NSLog(@"[note-taker] EventTap not started — Accessibility not granted");
        [self showAccessibilityDeniedAlert];
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

    [self applyIconForStatus:@"● Idle"];
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
                             action:@selector(startRecording:) keyEquivalent:@"r"];
    startRec.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    startRec.tag     = 2;
    startRec.enabled = NO;  // enabled once model loads (updateMenuForStatus:)
    [menu addItem:startRec];

    // tag 3 — Stop Recording (enabled when RECORDING)  Cmd+Shift+R
    NSMenuItem* stopRec = [[NSMenuItem alloc] initWithTitle:@"■  Stop Recording"
                            action:@selector(stopRecording:) keyEquivalent:@"r"];
    stopRec.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    stopRec.tag     = 3;
    stopRec.enabled = NO;
    [menu addItem:stopRec];

    // tag 4 — Open Notes Folder  Cmd+O
    NSMenuItem* openFolder = [[NSMenuItem alloc] initWithTitle:@"Open Notes Folder"
                               action:@selector(openNotesFolder:) keyEquivalent:@"o"];
    openFolder.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    openFolder.tag     = 4;
    openFolder.enabled = YES;
    [menu addItem:openFolder];

    [menu addItem:[NSMenuItem separatorItem]];

    // Language submenu
    NSMenuItem* langParent = [[NSMenuItem alloc] initWithTitle:@"Language"
                               action:nil keyEquivalent:@""];
    langParent.submenu = [self buildLanguageMenu];
    [menu addItem:langParent];

    // tag 5 — Translate to English toggle
    BOOL translateOn = [[NSUserDefaults standardUserDefaults] boolForKey:kTranslateKey];
    NSMenuItem* translateItem = [[NSMenuItem alloc] initWithTitle:@"Translate to English"
                                  action:@selector(toggleTranslate:) keyEquivalent:@""];
    translateItem.tag   = 5;
    translateItem.state = translateOn ? NSControlStateValueOn : NSControlStateValueOff;
    [menu addItem:translateItem];

    // tag 6 — Model submenu (rebuilt in selectModel:)
    NSMenuItem* modelParent = [[NSMenuItem alloc] initWithTitle:@"Model"
                                action:nil keyEquivalent:@""];
    modelParent.tag     = 6;
    modelParent.submenu = [self buildModelMenu];
    [menu addItem:modelParent];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];

    return menu;
}

- (NSMenu*)buildLanguageMenu {
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Language"];
    NSArray<NSString*>* keys   = @[@"auto", @"pt", @"en", @"es", @"fr", @"de"];
    NSArray<NSString*>* labels = @[@"Auto", @"Português", @"English",
                                    @"Español", @"Français", @"Deutsch"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:labels[i]
                             action:@selector(selectLanguage:) keyEquivalent:@""];
        item.representedObject = keys[i];
        item.state = [keys[i] isEqualToString:_language]
                     ? NSControlStateValueOn : NSControlStateValueOff;
        [sub addItem:item];
    }
    return sub;
}

- (NSMenu*)buildModelMenu {
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Model"];
    NSArray<NSString*>* models = @[
        @"large-v3",
        @"large-v3-turbo",
        @"large-v3-q5_0",
    ];

    // Header: active model (informational, not selectable)
    NSMenuItem* active = [[NSMenuItem alloc] initWithTitle:[NSString stringWithFormat:@"Active: %@", _model]
                           action:nil keyEquivalent:@""];
    active.enabled = NO;
    [sub addItem:active];
    [sub addItem:[NSMenuItem separatorItem]];

    // Selectable model list
    for (NSString* m in models) {
        if ([m isEqualToString:_model]) continue;  // skip the active one
        NSString* path   = [self modelPathForKey:m];
        BOOL      exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
        NSString* title  = exists ? m : [m stringByAppendingString:@"  ⚠ not downloaded"];
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                             action:@selector(selectModel:) keyEquivalent:@""];
        item.representedObject = m;
        item.toolTip = exists
                       ? @"Requires restart to take effect"
                       : [NSString stringWithFormat:@"Run: ./scripts/download_model.sh %@", m];
        [sub addItem:item];
    }
    return sub;
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

- (void)toggleTranslate:(NSMenuItem*)sender {
    BOOL nowOn = (sender.state == NSControlStateValueOff);
    sender.state = nowOn ? NSControlStateValueOn : NSControlStateValueOff;
    [[NSUserDefaults standardUserDefaults] setBool:nowOn forKey:kTranslateKey];
    if (_controller) _controller->setTranslate(nowOn);
}

- (void)selectLanguage:(NSMenuItem*)sender {
    NSString* key = sender.representedObject;
    if (!key || [key isEqualToString:_language]) return;

    _language = key;
    [[NSUserDefaults standardUserDefaults] setObject:key forKey:kLangKey];

    // Apply immediately to the running controller (no restart needed).
    if (_controller) {
        std::string lang = std::string([key UTF8String]);
        _controller->setLanguage(lang);
    }

    for (NSMenuItem* item in sender.menu.itemArray) {
        item.state = [item.representedObject isEqualToString:key]
                     ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)selectModel:(NSMenuItem*)sender {
    NSString* m = sender.representedObject;
    if (!m || [m isEqualToString:_model]) return;

    // Block selection if the model file is not on disk.
    NSString* path = [self modelPathForKey:m];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self showModelMissingAlertForKey:m];
        return;
    }

    _model = m;
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:kModelKey];

    // Rebuild the submenu so the header and selectable list update immediately.
    NSMenuItem* modelParent = [_statusItem.menu itemWithTag:6];
    if (modelParent) modelParent.submenu = [self buildModelMenu];
}

// ── Status updates ────────────────────────────────────────────────────────────

- (void)setStatusTitle:(NSString*)title {
    // Must be called on the main thread.
    NSMenuItem* item = [_statusItem.menu itemWithTag:1];
    if (item) item.title = title;
}

- (void)applyIconForStatus:(NSString*)status {
    NSString* symbolName;
    if ([status hasPrefix:@"🔴"]) {
        symbolName = @"record.circle.fill";
    } else if ([status hasPrefix:@"⏺"]) {
        symbolName = @"mic";
    } else if ([status hasPrefix:@"⏳"]) {
        symbolName = @"waveform";
    } else {
        symbolName = @"mic.fill";   // ● Idle or ⚠ error states
    }

    NSImage* img = [NSImage imageWithSystemSymbolName:symbolName
                              accessibilityDescription:@"note-taker"];
    if (img) {
        [img setTemplate:YES];
        _statusItem.button.image = img;
    } else {
        _statusItem.button.title = @"NT";
    }
}

- (void)updateMenuForStatus:(NSString*)status {
    // Must be called on the main thread.
    NSMenuItem* startRec = [_statusItem.menu itemWithTag:2];
    NSMenuItem* stopRec  = [_statusItem.menu itemWithTag:3];
    BOOL isIdle      = [status hasPrefix:@"● Idle"];
    BOOL isRecording = [status hasPrefix:@"🔴"];
    startRec.enabled = isIdle;
    stopRec.enabled  = isRecording;

    [self applyIconForStatus:status];
}

@end
