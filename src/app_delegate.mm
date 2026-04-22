#import "app_delegate.h"
#include "app_controller.h"
#include "app_status.h"
#include "event_tap.h"
#include "text_injector.h"
#include <Carbon/Carbon.h>

static NSString* const kLangKey      = @"language";
static NSString* const kModelKey     = @"model";

static NSString* const kHotkeyKey    = @"hotkey_keycode";
static NSString* const kSensitivityKey = @"vad_sensitivity";
static NSString* const kSilenceKey     = @"silence_timeout";
static NSString* const kOutputDirKey   = @"output_dir";

@implementation AppDelegate {
    NSStatusItem*  _statusItem;
    AppController* _controller;   // owned; stopped and deleted in applicationWillTerminate:
    EventTap       _eventTap;     // owned; lives on main thread, forwards to controller
    NSTimer*       _accessibilityRetryTimer;
    std::string    _outputDir;
    NSString*      _language;
    NSString*      _model;        // selected for next restart
    NSString*      _activeModel;  // currently loaded
    int            _hotkeyCode;
    BOOL           _wasFinalizing; // track session finalize → idle transition
}

// ── NSApplicationDelegate ─────────────────────────────────────────────────────

- (void)applicationWillFinishLaunching:(NSNotification*)__unused note {
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
}

- (void)applicationDidFinishLaunching:(NSNotification*)__unused note {
    NSString* defaultNotesDir = [NSHomeDirectory() stringByAppendingPathComponent:@"notes"];
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kLangKey:        @"auto",
        kModelKey:       @"large-v3-turbo",
        kHotkeyKey:      @(kVK_RightOption),
        kSensitivityKey: @"medium",
        kSilenceKey:     @5.0,
        kOutputDirKey:   defaultNotesDir,
    }];
    _language     = [[NSUserDefaults standardUserDefaults] stringForKey:kLangKey];
    _model        = [[NSUserDefaults standardUserDefaults] stringForKey:kModelKey];
    _activeModel  = _model;  // loaded model = selected at launch
    _hotkeyCode   = (int)[[NSUserDefaults standardUserDefaults] integerForKey:kHotkeyKey];

    // Monitor sleep/wake to handle audio interruption gracefully.
    __weak AppDelegate* weakSelfForSleep = self;
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceWillSleepNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification*) {
        AppDelegate* d = weakSelfForSleep;
        if (!d) return;
        NSLog(@"[note-taker] System will sleep — audio capture paused");
    }];
    [[[NSWorkspace sharedWorkspace] notificationCenter]
        addObserverForName:NSWorkspaceDidWakeNotification
                    object:nil queue:nil
                usingBlock:^(NSNotification*) {
        AppDelegate* d = weakSelfForSleep;
        if (!d || !d->_controller) return;
        NSLog(@"[note-taker] System woke — audio capture resumed");
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* d2 = weakSelfForSleep;
            if (d2) [d2 setStatusTitle:@"⚠ Audio resumed after sleep"];  // local UI-only, not from controller
        });
    }];

    [self setupStatusItem];
    [self startController];
}

- (void)applicationWillTerminate:(NSNotification*)__unused note {
    if (_accessibilityRetryTimer) {
        [_accessibilityRetryTimer invalidate];
        _accessibilityRetryTimer = nil;
    }
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
                            @"3. Return to the app\n\n"
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

- (BOOL)attemptStartEventTapWithPrompt:(BOOL)prompt {
    __weak AppDelegate* weakSelf = self;
    _eventTap.setHotkey(_hotkeyCode);
    bool tap_ok = _eventTap.start(
        [weakSelf] {
            AppDelegate* d = weakSelf;
            if (d && d->_controller) d->_controller->onHotkeyDown();
        },
        [weakSelf] {
            AppDelegate* d = weakSelf;
            if (d && d->_controller) d->_controller->onHotkeyUp();
        },
        prompt
    );

    if (tap_ok && _accessibilityRetryTimer) {
        [_accessibilityRetryTimer invalidate];
        _accessibilityRetryTimer = nil;
        NSLog(@"[note-taker] EventTap started");
    }
    return tap_ok;
}

- (void)scheduleAccessibilityRetry {
    if (_accessibilityRetryTimer) return;

    __weak AppDelegate* weakSelf = self;
    _accessibilityRetryTimer =
        [NSTimer scheduledTimerWithTimeInterval:1.0
                                        repeats:YES
                                          block:^(NSTimer* timer) {
            AppDelegate* d = weakSelf;
            if (!d) {
                [timer invalidate];
                return;
            }
            if ([d attemptStartEventTapWithPrompt:NO]) {
                [timer invalidate];
                d->_accessibilityRetryTimer = nil;
            }
        }];
}

// ── Controller setup ──────────────────────────────────────────────────────────

- (void)startController {
    // Resolve paths in ObjC context, then hand off to pure-C++ AppController.
    NSString* modelNS = [self modelPathForKey:_model];
    NSString* notesNS = [[NSUserDefaults standardUserDefaults] stringForKey:kOutputDirKey];

    std::string modelPath = std::string([modelNS UTF8String]);
    std::string language  = std::string([_language UTF8String]);
    _outputDir            = std::string([notesNS UTF8String]);

    __weak AppDelegate* weakSelf = self;

    _controller = new AppController(modelPath, /*use_metal=*/true, language, _outputDir);
    [self applyVadSensitivity:[[NSUserDefaults standardUserDefaults] stringForKey:kSensitivityKey]];
    _controller->setSilenceTimeout((float)[[NSUserDefaults standardUserDefaults] doubleForKey:kSilenceKey]);

    _controller->setOnStatusChange([weakSelf](AppStatusEvent event) {
        // Called from any thread — dispatch UI updates to main queue.
        AppStatus st = event.status;
        std::string detail = std::move(event.detail);
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* d = weakSelf;
            if (!d) return;

            // Beep is synthetic: play error sound, don't change display.
            if (st == AppStatus::Beep) {
                NSBeep();
                return;
            }

            // Build display label — append detail for error states.
            std::string label = statusLabel(st);
            if (!detail.empty()) label += " — " + detail;
            NSString* s = [NSString stringWithUTF8String:label.c_str()];

            [d setStatusTitle:s];
            [d updateMenuForStatus:st];

            // Notify user when a recording session finishes.
            if (d->_wasFinalizing && st == AppStatus::Idle) {
                d->_wasFinalizing = NO;
                [d postSessionSavedNotification];
            }
            if (st == AppStatus::Finalizing) {
                d->_wasFinalizing = YES;
            }

            // Show prominent alerts for startup errors.
            if (st == AppStatus::ErrorModelNotFound) {
                [d showModelMissingAlertForKey:d->_model];
            } else if (st == AppStatus::ErrorMicDenied) {
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

    // Start the EventTap silently on launch. If Accessibility is still denied,
    // show our own instructions instead of auto-triggering the system prompt on
    // every app start. A retry timer will start the tap as soon as permission
    // is granted, without requiring a relaunch.
    if (![self attemptStartEventTapWithPrompt:NO]) {
        NSLog(@"[note-taker] EventTap not started — Accessibility not granted");
        [self showAccessibilityDeniedAlert];
        [self scheduleAccessibilityRetry];
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

    [self applyIconForStatus:AppStatus::Idle];
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

    NSMenuItem* hint = [[NSMenuItem alloc] initWithTitle:
        [NSString stringWithFormat:@"Hold %@ to dictate", [self labelForKeycode:_hotkeyCode]]
                         action:nil keyEquivalent:@""];
    hint.tag     = 7;
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

    // Recording Settings submenu
    NSMenuItem* recSettingsParent = [[NSMenuItem alloc] initWithTitle:@"Recording Settings"
                                      action:nil keyEquivalent:@""];
    recSettingsParent.submenu = [self buildRecordingSettingsMenu];
    [menu addItem:recSettingsParent];

    [menu addItem:[NSMenuItem separatorItem]];

    // tag 8 — Language submenu (title shows active language)
    NSMenuItem* langParent = [[NSMenuItem alloc] initWithTitle:
        [NSString stringWithFormat:@"Language — %@", [self labelForLanguage:_language]]
                               action:nil keyEquivalent:@""];
    langParent.tag     = 8;
    langParent.submenu = [self buildLanguageMenu];
    [menu addItem:langParent];

    // tag 6 — Model submenu (title shows loaded model, rebuilt in selectModel:)
    NSMenuItem* modelParent = [[NSMenuItem alloc] initWithTitle:
        [NSString stringWithFormat:@"Model — %@", _activeModel]
                                action:nil keyEquivalent:@""];
    modelParent.tag     = 6;
    modelParent.submenu = [self buildModelMenu];
    [menu addItem:modelParent];

    // Hotkey submenu
    NSMenuItem* hotkeyParent = [[NSMenuItem alloc] initWithTitle:@"Dictation Hotkey"
                                 action:nil keyEquivalent:@""];
    hotkeyParent.submenu = [self buildHotkeyMenu];
    [menu addItem:hotkeyParent];

    [menu addItem:[NSMenuItem separatorItem]];

    [menu addItemWithTitle:@"About note-taker"
                    action:@selector(showAbout:) keyEquivalent:@""];
    [menu addItemWithTitle:@"Quit" action:@selector(terminate:) keyEquivalent:@"q"];

    return menu;
}

- (NSString*)labelForLanguage:(NSString*)key {
    NSDictionary* map = @{
        @"auto": @"Auto", @"pt": @"Português", @"en": @"English",
        @"es": @"Español",
    };
    return map[key] ?: key;
}

- (NSMenu*)buildLanguageMenu {
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Language"];
    NSArray<NSString*>* keys   = @[@"auto", @"pt", @"en", @"es"];
    NSArray<NSString*>* labels = @[@"Auto", @"Português", @"English", @"Español"];
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
    ];

    // Pending restart hint
    if (![_model isEqualToString:_activeModel]) {
        NSMenuItem* pending = [[NSMenuItem alloc] initWithTitle:
            [NSString stringWithFormat:@"⟳ %@ on next restart", _model]
                                action:nil keyEquivalent:@""];
        pending.enabled = NO;
        [sub addItem:pending];
        [sub addItem:[NSMenuItem separatorItem]];
    }

    for (NSString* m in models) {
        NSString* path   = [self modelPathForKey:m];
        BOOL      exists = [[NSFileManager defaultManager] fileExistsAtPath:path];
        NSString* title  = exists ? m : [m stringByAppendingString:@"  ⚠ not downloaded"];
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                             action:@selector(selectModel:) keyEquivalent:@""];
        item.representedObject = m;
        // Checkmark on the currently loaded model
        item.state = [m isEqualToString:_activeModel] ? NSControlStateValueOn : NSControlStateValueOff;
        if (!exists) {
            item.toolTip = [NSString stringWithFormat:@"Run: ./scripts/download_model.sh %@", m];
        }
        [sub addItem:item];
    }
    return sub;
}

- (NSString*)labelForKeycode:(int)code {
    switch (code) {
        case kVK_RightOption:  return @"Right Option (⌥)";
        case kVK_Option:       return @"Left Option (⌥)";
        case kVK_RightCommand: return @"Right Command (⌘)";
        case kVK_Function:     return @"Fn";
        default:               return [NSString stringWithFormat:@"Key 0x%02X", code];
    }
}

- (NSMenu*)buildHotkeyMenu {
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Hotkey"];
    int codes[] = { kVK_RightOption, kVK_Option, kVK_RightCommand, kVK_Function };
    for (int code : codes) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:[self labelForKeycode:code]
                             action:@selector(selectHotkey:) keyEquivalent:@""];
        item.tag   = code;
        item.state = (code == _hotkeyCode) ? NSControlStateValueOn : NSControlStateValueOff;
        [sub addItem:item];
    }
    return sub;
}

- (NSMenu*)buildRecordingSettingsMenu {
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Recording Settings"];

    // Open Notes Folder  Cmd+O (tag 4)
    NSMenuItem* openFolder = [[NSMenuItem alloc] initWithTitle:@"Open Notes Folder"
                               action:@selector(openNotesFolder:) keyEquivalent:@"o"];
    openFolder.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    openFolder.tag     = 4;
    openFolder.enabled = YES;
    [sub addItem:openFolder];

    // Change Notes Folder…
    NSMenuItem* changeFolder = [[NSMenuItem alloc] initWithTitle:@"Change Notes Folder…"
                                 action:@selector(changeNotesFolder:) keyEquivalent:@""];
    [sub addItem:changeFolder];

    [sub addItem:[NSMenuItem separatorItem]];

    // VAD Sensitivity
    NSMenuItem* sensitivityParent = [[NSMenuItem alloc] initWithTitle:@"VAD Sensitivity"
                                      action:nil keyEquivalent:@""];
    sensitivityParent.submenu = [self buildSensitivityMenu];
    [sub addItem:sensitivityParent];

    // Silence Timeout
    NSMenuItem* silenceParent = [[NSMenuItem alloc] initWithTitle:@"Silence Timeout"
                                  action:nil keyEquivalent:@""];
    silenceParent.submenu = [self buildSilenceTimeoutMenu];
    [sub addItem:silenceParent];

    return sub;
}

- (void)applyVadSensitivity:(NSString*)key {
    // threshold / gain pairs: lower threshold + higher gain = more sensitive
    float threshold = 0.015f, gain = 1.3f; // medium (default)
    if ([key isEqualToString:@"low"]) {
        threshold = 0.025f; gain = 1.0f;
    } else if ([key isEqualToString:@"high"]) {
        threshold = 0.008f; gain = 1.8f;
    }
    if (_controller) _controller->setVadSensitivity(threshold, gain);
}

- (NSMenu*)buildSensitivityMenu {
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Sensitivity"];
    NSString* current = [[NSUserDefaults standardUserDefaults] stringForKey:kSensitivityKey];
    NSArray<NSString*>* keys   = @[@"low", @"medium", @"high"];
    NSArray<NSString*>* labels = @[@"Low", @"Medium", @"High"];
    for (NSUInteger i = 0; i < keys.count; i++) {
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:labels[i]
                             action:@selector(selectSensitivity:) keyEquivalent:@""];
        item.representedObject = keys[i];
        item.state = [keys[i] isEqualToString:current]
                     ? NSControlStateValueOn : NSControlStateValueOff;
        [sub addItem:item];
    }
    return sub;
}

- (NSMenu*)buildSilenceTimeoutMenu {
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Silence Timeout"];
    float current = (float)[[NSUserDefaults standardUserDefaults] doubleForKey:kSilenceKey];
    float values[] = { 2.0f, 3.0f, 5.0f, 8.0f, 10.0f };
    for (float v : values) {
        NSString* title = [NSString stringWithFormat:@"%.0fs", v];
        NSMenuItem* item = [[NSMenuItem alloc] initWithTitle:title
                             action:@selector(selectSilenceTimeout:) keyEquivalent:@""];
        item.representedObject = @(v);
        item.state = (fabsf(v - current) < 0.1f)
                     ? NSControlStateValueOn : NSControlStateValueOff;
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

- (void)showAbout:(id)__unused sender {
    NSString* version = [[NSBundle mainBundle]
        objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (!version) version = @"dev";

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"note-taker";
    alert.informativeText = [NSString stringWithFormat:
        @"Version %@\nModel: %@\n\nLocal speech transcription powered by whisper.cpp.\n"
        @"github.com/geovansb/note-taker-cpp",
        version, _activeModel];
    alert.alertStyle = NSAlertStyleInformational;
    [alert addButtonWithTitle:@"OK"];
    [alert runModal];
}

- (void)postSessionSavedNotification {
    // Menu bar apps (LSUIElement) can't reliably use UNUserNotificationCenter
    // because macOS won't show the permission prompt. Instead, provide feedback
    // directly in the menu bar: sound + temporary checkmark icon + status text.
    [[NSSound soundNamed:@"Glass"] play];

    [self setStatusTitle:[NSString stringWithUTF8String:statusLabel(AppStatus::RecordingSaved).c_str()]];

    // Show a checkmark icon for 4 seconds, then revert to idle.
    NSImage* checkImg = [NSImage imageWithSystemSymbolName:@"checkmark.circle.fill"
                                   accessibilityDescription:@"note-taker: saved"];
    if (checkImg) {
        [checkImg setTemplate:YES];
        _statusItem.button.image = checkImg;
    }

    __weak AppDelegate* weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        AppDelegate* d = weakSelf;
        if (!d) return;
        NSString* idleLabel = [NSString stringWithUTF8String:statusLabel(AppStatus::Idle).c_str()];
        [d setStatusTitle:idleLabel];
        [d applyIconForStatus:AppStatus::Idle];
    });
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

- (void)changeNotesFolder:(id)__unused sender {
    NSOpenPanel* panel = [NSOpenPanel openPanel];
    panel.canChooseFiles          = NO;
    panel.canChooseDirectories    = YES;
    panel.canCreateDirectories    = YES;
    panel.allowsMultipleSelection = NO;
    panel.prompt                  = @"Choose";
    panel.message                 = @"Select folder for session transcripts";
    panel.directoryURL = [NSURL fileURLWithPath:
        [NSString stringWithUTF8String:_outputDir.c_str()]];

    if ([panel runModal] == NSModalResponseOK && panel.URL) {
        NSString* path = panel.URL.path;

        if (access([path fileSystemRepresentation], W_OK) != 0) {
            NSAlert* alert = [[NSAlert alloc] init];
            alert.messageText = @"Folder not writable";
            alert.informativeText = [NSString stringWithFormat:
                @"Cannot write to \"%@\". Choose a different folder.", path];
            [alert addButtonWithTitle:@"OK"];
            [alert runModal];
            return;
        }

        _outputDir = std::string([path UTF8String]);
        [[NSUserDefaults standardUserDefaults] setObject:path forKey:kOutputDirKey];
        if (_controller) _controller->setOutputDir(_outputDir);
    }
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

    // Update parent menu title to show active language
    NSMenuItem* langParent = [_statusItem.menu itemWithTag:8];
    if (langParent) {
        langParent.title = [NSString stringWithFormat:@"Language — %@",
                            [self labelForLanguage:key]];
    }
}

- (void)selectHotkey:(NSMenuItem*)sender {
    int code = (int)sender.tag;
    if (code == _hotkeyCode) return;

    _hotkeyCode = code;
    [[NSUserDefaults standardUserDefaults] setInteger:code forKey:kHotkeyKey];
    _eventTap.setHotkey(code);

    // Update checkmarks
    for (NSMenuItem* item in sender.menu.itemArray) {
        item.state = (item.tag == code) ? NSControlStateValueOn : NSControlStateValueOff;
    }

    // Update the hint text (tag 7)
    NSMenuItem* hint = [_statusItem.menu itemWithTag:7];
    if (hint) {
        hint.title = [NSString stringWithFormat:@"Hold %@ to dictate",
                      [self labelForKeycode:code]];
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

    // Rebuild submenu to show pending restart hint. Title stays as _activeModel.
    NSMenuItem* modelParent = [_statusItem.menu itemWithTag:6];
    if (modelParent) {
        modelParent.submenu = [self buildModelMenu];
    }

    // Offer to restart now so the new model takes effect immediately.
    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Restart required";
    alert.informativeText = [NSString stringWithFormat:
        @"Model \"%@\" will be loaded after restarting the app.", m];
    [alert addButtonWithTitle:@"Restart Now"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        // Re-launch the app bundle, then terminate.
        NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
        [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open"
                                 arguments:@[@"-n", bundlePath]];
        [NSApp terminate:nil];
    }
}

- (void)selectSensitivity:(NSMenuItem*)sender {
    NSString* key = sender.representedObject;
    [[NSUserDefaults standardUserDefaults] setObject:key forKey:kSensitivityKey];
    [self applyVadSensitivity:key];
    for (NSMenuItem* item in sender.menu.itemArray) {
        item.state = [item.representedObject isEqualToString:key]
                     ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

- (void)selectSilenceTimeout:(NSMenuItem*)sender {
    float val = [sender.representedObject floatValue];
    [[NSUserDefaults standardUserDefaults] setDouble:val forKey:kSilenceKey];
    if (_controller) _controller->setSilenceTimeout(val);
    for (NSMenuItem* item in sender.menu.itemArray) {
        item.state = (fabsf([item.representedObject floatValue] - val) < 0.1f)
                     ? NSControlStateValueOn : NSControlStateValueOff;
    }
}

// ── Status updates ────────────────────────────────────────────────────────────

- (void)setStatusTitle:(NSString*)title {
    // Must be called on the main thread.
    NSMenuItem* item = [_statusItem.menu itemWithTag:1];
    if (item) item.title = title;
}

- (void)applyIconForStatus:(AppStatus)status {
    NSString* symbolName;
    NSString* a11yLabel;
    switch (status) {
        case AppStatus::RecordingListening:
        case AppStatus::RecordingCapturing:
            symbolName = @"record.circle.fill";
            a11yLabel  = @"note-taker: recording session";
            break;
        case AppStatus::Dictating:
            symbolName = @"mic";
            a11yLabel  = @"note-taker: dictating";
            break;
        case AppStatus::LoadingModel:
        case AppStatus::Transcribing:
        case AppStatus::Finalizing:
            symbolName = @"waveform";
            a11yLabel  = @"note-taker: processing";
            break;
        case AppStatus::ErrorModelNotFound:
        case AppStatus::ErrorMicDenied:
        case AppStatus::ErrorAudioDeviceChanged:
        case AppStatus::ErrorTranscription:
        case AppStatus::ErrorGeneric:
            symbolName = @"mic.fill";
            a11yLabel  = @"note-taker: error";
            break;
        default:
            symbolName = @"mic.fill";
            a11yLabel  = @"note-taker: idle";
            break;
    }

    NSImage* img = [NSImage imageWithSystemSymbolName:symbolName
                              accessibilityDescription:a11yLabel];
    if (img) {
        [img setTemplate:YES];
        _statusItem.button.image = img;
    } else {
        _statusItem.button.title = @"NT";
    }
    _statusItem.button.accessibilityLabel = a11yLabel;
}

- (void)updateMenuForStatus:(AppStatus)status {
    // Must be called on the main thread.
    NSMenuItem* startRec = [_statusItem.menu itemWithTag:2];
    NSMenuItem* stopRec  = [_statusItem.menu itemWithTag:3];

    BOOL isIdle      = (status == AppStatus::Idle || status == AppStatus::RecordingSaved);
    BOOL isRecording = (status == AppStatus::RecordingListening ||
                        status == AppStatus::RecordingCapturing);

    startRec.enabled = isIdle;
    stopRec.enabled  = isRecording;

    // Show contextual hints when both buttons are disabled (FINALIZING,
    // TRANSCRIBING, DICTATING) so the user knows something is in progress.
    if (isIdle || isRecording) {
        startRec.title = @"▶  Start Recording";
        stopRec.title  = @"■  Stop Recording";
    } else if (status == AppStatus::Finalizing) {
        startRec.title = @"⏳ Finalizing, please wait…";
        stopRec.title  = @"■  Stop Recording";
    } else if (status == AppStatus::Dictating) {
        startRec.title = @"⏺  Dictating… (release key to stop)";
        stopRec.title  = @"■  Stop Recording";
    } else if (status == AppStatus::Transcribing || status == AppStatus::LoadingModel) {
        startRec.title = @"⏳ Processing, please wait…";
        stopRec.title  = @"■  Stop Recording";
    }

    [self applyIconForStatus:status];
}

@end
