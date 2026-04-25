#import "app_delegate.h"
#include "app_controller.h"
#include "app_status.h"
#include "dictation_history.h"
#include "event_tap.h"
#include "text_injector.h"
#include <Carbon/Carbon.h>

static NSString* const kLangKey      = @"language";
static NSString* const kModelKey     = @"model";

static NSString* const kHotkeyKey    = @"hotkey_keycode";
static NSString* const kSensitivityKey = @"vad_sensitivity";
static NSString* const kSilenceKey     = @"silence_timeout";
static NSString* const kOutputDirKey   = @"output_dir";
static NSString* const kDictationHistoryEnabledKey = @"dictation_history_enabled";

static constexpr NSInteger kTagStatus             = 1;
static constexpr NSInteger kTagStartRecording     = 2;
static constexpr NSInteger kTagStopRecording      = 3;
static constexpr NSInteger kTagHotkeyHint         = 7;
static constexpr NSInteger kTagRecentDictations   = 10;
static constexpr CGFloat   kSettingsRightPadding  = 36.0;

@implementation AppDelegate {
    NSStatusItem*  _statusItem;
    NSWindow*      _settingsWindow;
    NSView*        _settingsContentView;
    AppController* _controller;   // owned; stopped and deleted in applicationWillTerminate:
    EventTap       _eventTap;     // owned; lives on main thread, forwards to controller
    NSTimer*       _accessibilityRetryTimer;
    DictationHistory _dictationHistory;
    std::string    _outputDir;
    NSString*      _language;
    NSString*      _model;        // selected for next restart
    NSString*      _activeModel;  // currently loaded
    NSString*      _settingsCategory;
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
        kDictationHistoryEnabledKey: @NO,
    }];
    _language     = [[NSUserDefaults standardUserDefaults] stringForKey:kLangKey];
    _model        = [[NSUserDefaults standardUserDefaults] stringForKey:kModelKey];
    _activeModel  = _model;  // loaded model = selected at launch
    _settingsCategory = @"General";
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
    if (_settingsWindow) {
        [_settingsWindow close];
        _settingsWindow = nil;
        _settingsContentView = nil;
    }
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

    _controller->setOnDictationResult([weakSelf](std::string text) {
        // Inject text at cursor. Must run on main thread (CGEventPost requirement).
        dispatch_async(dispatch_get_main_queue(), ^{
            AppDelegate* d = weakSelf;
            if (!d) return;
            if ([d dictationHistoryEnabled]) {
                d->_dictationHistory.add(text);
                [d refreshRecentDictationsMenu];
                [d rebuildSettingsContent];
            }
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

    NSMenuItem* statusItem = [[NSMenuItem alloc] initWithTitle:@"● Idle"
                               action:nil keyEquivalent:@""];
    statusItem.tag     = kTagStatus;
    statusItem.enabled = NO;
    [menu addItem:statusItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* hint = [[NSMenuItem alloc] initWithTitle:
        [NSString stringWithFormat:@"Hold %@ to dictate", [self labelForKeycode:_hotkeyCode]]
                         action:nil keyEquivalent:@""];
    hint.tag     = kTagHotkeyHint;
    hint.enabled = NO;
    [menu addItem:hint];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* startRec = [[NSMenuItem alloc] initWithTitle:@"▶  Start Recording"
                             action:@selector(startRecording:) keyEquivalent:@"r"];
    startRec.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    startRec.tag     = kTagStartRecording;
    startRec.enabled = NO;  // enabled once model loads (updateMenuForStatus:)
    [menu addItem:startRec];

    NSMenuItem* stopRec = [[NSMenuItem alloc] initWithTitle:@"■  Stop Recording"
                            action:@selector(stopRecording:) keyEquivalent:@"r"];
    stopRec.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    stopRec.tag     = kTagStopRecording;
    stopRec.enabled = NO;
    [menu addItem:stopRec];

    NSMenuItem* openFolder = [[NSMenuItem alloc] initWithTitle:@"Open Notes Folder"
                              action:@selector(openNotesFolder:) keyEquivalent:@"o"];
    openFolder.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    [menu addItem:openFolder];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* recentParent = [[NSMenuItem alloc] initWithTitle:@"Recent Dictations"
                                action:nil keyEquivalent:@""];
    recentParent.tag = kTagRecentDictations;
    recentParent.submenu = [self buildRecentDictationsMenu];
    [menu addItem:recentParent];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem* settings = [[NSMenuItem alloc] initWithTitle:@"Settings…"
                              action:@selector(showSettings:) keyEquivalent:@","];
    NSImage* gear = [NSImage imageWithSystemSymbolName:@"gearshape"
                              accessibilityDescription:@"Settings"];
    if (gear) {
        [gear setTemplate:YES];
        settings.image = gear;
    }
    [menu addItem:settings];
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

- (BOOL)dictationHistoryEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kDictationHistoryEnabledKey];
}

- (NSString*)previewForHistoryText:(NSString*)text {
    NSString* collapsed = [[text componentsSeparatedByCharactersInSet:
        [NSCharacterSet newlineCharacterSet]] componentsJoinedByString:@" "];
    while ([collapsed containsString:@"  "]) {
        collapsed = [collapsed stringByReplacingOccurrencesOfString:@"  " withString:@" "];
    }
    if (collapsed.length <= 64) return collapsed;
    return [[collapsed substringToIndex:64] stringByAppendingString:@"…"];
}

- (NSMenu*)buildRecentDictationsMenu {
    NSMenu* sub = [[NSMenu alloc] initWithTitle:@"Recent Dictations"];
    if (![self dictationHistoryEnabled]) {
        NSMenuItem* disabled = [[NSMenuItem alloc] initWithTitle:@"History disabled"
                                  action:nil keyEquivalent:@""];
        disabled.enabled = NO;
        [sub addItem:disabled];
        return sub;
    }

    const auto& items = _dictationHistory.items();
    if (items.empty()) {
        NSMenuItem* empty = [[NSMenuItem alloc] initWithTitle:@"No recent dictations"
                              action:nil keyEquivalent:@""];
        empty.enabled = NO;
        [sub addItem:empty];
        return sub;
    }

    for (const auto& item : items) {
        NSString* text = [NSString stringWithUTF8String:item.c_str()];
        if (!text) continue;
        NSMenuItem* menuItem = [[NSMenuItem alloc] initWithTitle:[self previewForHistoryText:text]
                                  action:@selector(copyRecentDictation:) keyEquivalent:@""];
        menuItem.representedObject = text;
        [sub addItem:menuItem];
    }
    [sub addItem:[NSMenuItem separatorItem]];
    [sub addItemWithTitle:@"Clear History" action:@selector(clearDictationHistory:) keyEquivalent:@""];
    return sub;
}

- (void)refreshRecentDictationsMenu {
    NSMenuItem* parent = [_statusItem.menu itemWithTag:kTagRecentDictations];
    if (!parent) return;
    parent.submenu = [self buildRecentDictationsMenu];
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

// ── Settings window ────────────────────────────────────────────────────────────

- (NSTextField*)labelWithText:(NSString*)text fontSize:(CGFloat)fontSize bold:(BOOL)bold {
    NSTextField* label = [NSTextField labelWithString:text];
    label.font = bold ? [NSFont boldSystemFontOfSize:fontSize] : [NSFont systemFontOfSize:fontSize];
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

- (void)addLabel:(NSString*)label control:(NSView*)control toStack:(NSStackView*)stack {
    NSTextField* labelView = [self labelWithText:label fontSize:13 bold:NO];
    NSStackView* row = [NSStackView stackViewWithViews:@[
        labelView,
        control
    ]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 16;
    row.translatesAutoresizingMaskIntoConstraints = NO;
    labelView.translatesAutoresizingMaskIntoConstraints = NO;
    control.translatesAutoresizingMaskIntoConstraints = NO;
    [labelView.widthAnchor constraintEqualToConstant:130].active = YES;
    [control.widthAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    [stack addArrangedSubview:row];
}

- (NSPopUpButton*)popupWithLabels:(NSArray<NSString*>*)labels values:(NSArray*)values
                          current:(id)current action:(SEL)action {
    NSPopUpButton* popup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    for (NSUInteger i = 0; i < labels.count; ++i) {
        [popup addItemWithTitle:labels[i]];
        popup.lastItem.representedObject = values[i];
        if ([values[i] isEqual:current]) [popup selectItem:popup.lastItem];
    }
    popup.target = self;
    popup.action = action;
    return popup;
}

- (NSButton*)settingsSidebarButton:(NSString*)title category:(NSString*)category {
    NSButton* button = [NSButton buttonWithTitle:title target:self action:@selector(selectSettingsCategory:)];
    button.bezelStyle = NSBezelStyleRegularSquare;
    button.bordered = NO;
    button.alignment = NSTextAlignmentLeft;
    button.identifier = category;
    button.state = [_settingsCategory isEqualToString:category] ? NSControlStateValueOn : NSControlStateValueOff;
    return button;
}

- (NSButton*)linkButtonWithTitle:(NSString*)title url:(NSString*)url {
    NSButton* button = [NSButton buttonWithTitle:title target:self action:@selector(openLink:)];
    button.bezelStyle = NSBezelStyleInline;
    button.bordered = NO;
    button.alignment = NSTextAlignmentLeft;
    button.contentTintColor = [NSColor linkColor];
    button.identifier = url;
    return button;
}

- (NSStackView*)githubLinkRow {
    NSImageView* icon = [[NSImageView alloc] initWithFrame:NSZeroRect];
    NSImage* image = [NSImage imageWithSystemSymbolName:@"chevron.left.forwardslash.chevron.right"
                               accessibilityDescription:@"GitHub"];
    if (image) {
        [image setTemplate:YES];
        icon.image = image;
        icon.contentTintColor = [NSColor labelColor];
    }
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [icon.widthAnchor constraintEqualToConstant:20].active = YES;
    [icon.heightAnchor constraintEqualToConstant:20].active = YES;

    NSButton* link = [self linkButtonWithTitle:@"github.com/geovansb/note-taker-cpp"
                                           url:@"https://github.com/geovansb/note-taker-cpp"];
    NSStackView* row = [NSStackView stackViewWithViews:@[icon, link]];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8;
    return row;
}

- (void)showSettings:(id)__unused sender {
    if (!_settingsWindow) {
        NSRect frame = NSMakeRect(0, 0, 720, 460);
        _settingsWindow = [[NSWindow alloc] initWithContentRect:frame
                                                      styleMask:(NSWindowStyleMaskTitled |
                                                                 NSWindowStyleMaskClosable |
                                                                 NSWindowStyleMaskMiniaturizable)
                                                        backing:NSBackingStoreBuffered
                                                          defer:NO];
        _settingsWindow.title = @"Settings";
        _settingsWindow.releasedWhenClosed = NO;

        NSView* root = [[NSView alloc] initWithFrame:frame];
        root.translatesAutoresizingMaskIntoConstraints = NO;
        _settingsWindow.contentView = root;

        NSStackView* sidebar = [[NSStackView alloc] initWithFrame:NSZeroRect];
        sidebar.orientation = NSUserInterfaceLayoutOrientationVertical;
        sidebar.alignment = NSLayoutAttributeLeading;
        sidebar.spacing = 6;
        sidebar.edgeInsets = NSEdgeInsetsMake(20, 16, 20, 16);
        sidebar.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:sidebar];

        NSArray<NSString*>* categories = @[@"General", @"Recording", @"Privacy", @"About"];
        for (NSString* category in categories) {
            NSButton* button = [self settingsSidebarButton:category category:category];
            [button.widthAnchor constraintEqualToConstant:140].active = YES;
            [sidebar addArrangedSubview:button];
        }

        _settingsContentView = [[NSView alloc] initWithFrame:NSZeroRect];
        _settingsContentView.translatesAutoresizingMaskIntoConstraints = NO;
        [root addSubview:_settingsContentView];

        [NSLayoutConstraint activateConstraints:@[
            [sidebar.leadingAnchor constraintEqualToAnchor:root.leadingAnchor],
            [sidebar.topAnchor constraintEqualToAnchor:root.topAnchor],
            [sidebar.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
            [sidebar.widthAnchor constraintEqualToConstant:180],
            [_settingsContentView.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
            [_settingsContentView.trailingAnchor constraintEqualToAnchor:root.trailingAnchor],
            [_settingsContentView.topAnchor constraintEqualToAnchor:root.topAnchor],
            [_settingsContentView.bottomAnchor constraintEqualToAnchor:root.bottomAnchor],
        ]];
    }

    [self rebuildSettingsContent];
    [_settingsWindow center];
    [_settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)selectSettingsCategory:(NSButton*)sender {
    NSString* category = sender.identifier;
    if (!category) return;
    _settingsCategory = category;
    for (NSView* view in sender.superview.subviews) {
        if ([view isKindOfClass:[NSButton class]]) {
            NSButton* button = (NSButton*)view;
            button.state = [button.identifier isEqualToString:category]
                         ? NSControlStateValueOn : NSControlStateValueOff;
        }
    }
    [self rebuildSettingsContent];
}

- (NSStackView*)freshSettingsStackWithTitle:(NSString*)title {
    for (NSView* subview in _settingsContentView.subviews) {
        [subview removeFromSuperview];
    }

    NSStackView* stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 14;
    stack.edgeInsets = NSEdgeInsetsMake(24, 28, 24, 28);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_settingsContentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:_settingsContentView.leadingAnchor],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:_settingsContentView.trailingAnchor
                                                       constant:-kSettingsRightPadding],
        [stack.topAnchor constraintEqualToAnchor:_settingsContentView.topAnchor],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:_settingsContentView.bottomAnchor],
    ]];
    [stack addArrangedSubview:[self labelWithText:title fontSize:22 bold:YES]];
    return stack;
}

- (void)rebuildSettingsContent {
    if (!_settingsContentView) return;

    if ([_settingsCategory isEqualToString:@"Recording"]) {
        NSStackView* stack = [self freshSettingsStackWithTitle:@"Recording"];

        NSString* folderPath = [NSString stringWithUTF8String:_outputDir.c_str()];
        NSTextField* folderField = [NSTextField textFieldWithString:folderPath ?: @""];
        folderField.editable = NO;
        folderField.selectable = YES;
        folderField.lineBreakMode = NSLineBreakByTruncatingMiddle;
        folderField.translatesAutoresizingMaskIntoConstraints = NO;

        NSButton* change = [NSButton buttonWithTitle:@"Change…" target:self action:@selector(changeNotesFolder:)];
        change.translatesAutoresizingMaskIntoConstraints = NO;
        NSStackView* folderControls = [NSStackView stackViewWithViews:@[folderField, change]];
        folderControls.orientation = NSUserInterfaceLayoutOrientationVertical;
        folderControls.alignment = NSLayoutAttributeTrailing;
        folderControls.spacing = 8;
        folderControls.translatesAutoresizingMaskIntoConstraints = NO;
        [folderField.widthAnchor constraintEqualToConstant:500].active = YES;

        NSStackView* folderRow = [NSStackView stackViewWithViews:@[
            [self labelWithText:@"Notes Folder" fontSize:13 bold:NO],
            folderControls
        ]];
        folderRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        folderRow.alignment = NSLayoutAttributeTop;
        folderRow.spacing = 16;
        folderRow.translatesAutoresizingMaskIntoConstraints = NO;
        folderRow.views[0].translatesAutoresizingMaskIntoConstraints = NO;
        [folderRow.views[0].widthAnchor constraintEqualToConstant:130].active = YES;
        [stack addArrangedSubview:folderRow];

        NSString* sensitivity = [[NSUserDefaults standardUserDefaults] stringForKey:kSensitivityKey];
        [self addLabel:@"VAD Sensitivity"
               control:[self popupWithLabels:@[@"Low", @"Medium", @"High"]
                                       values:@[@"low", @"medium", @"high"]
                                      current:sensitivity
                                       action:@selector(selectSensitivityFromPopup:)]
               toStack:stack];

        NSNumber* silence = @([[NSUserDefaults standardUserDefaults] doubleForKey:kSilenceKey]);
        [self addLabel:@"Silence Timeout"
               control:[self popupWithLabels:@[@"2s", @"3s", @"5s", @"8s", @"10s"]
                                       values:@[@2.0, @3.0, @5.0, @8.0, @10.0]
                                      current:silence
                                       action:@selector(selectSilenceTimeoutFromPopup:)]
               toStack:stack];
        return;
    }

    if ([_settingsCategory isEqualToString:@"Privacy"]) {
        NSStackView* stack = [self freshSettingsStackWithTitle:@"Privacy"];
        NSButton* toggle = [NSButton checkboxWithTitle:@"Save Last 9 Dictations"
                                                target:self
                                                action:@selector(toggleDictationHistory:)];
        toggle.state = [self dictationHistoryEnabled] ? NSControlStateValueOn : NSControlStateValueOff;
        [stack addArrangedSubview:toggle];

        NSTextField* privacyNote = [self labelWithText:@"History is kept only in memory and disappears when the app quits. Dictation injection does not use the clipboard." fontSize:12 bold:NO];
        [privacyNote.widthAnchor constraintLessThanOrEqualToConstant:520].active = YES;
        NSView* checkboxOffset = [[NSView alloc] initWithFrame:NSZeroRect];
        checkboxOffset.translatesAutoresizingMaskIntoConstraints = NO;
        [checkboxOffset.widthAnchor constraintEqualToConstant:44].active = YES;
        NSStackView* privacyNoteRow = [NSStackView stackViewWithViews:@[checkboxOffset, privacyNote]];
        privacyNoteRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        privacyNoteRow.alignment = NSLayoutAttributeTop;
        privacyNoteRow.spacing = 0;
        [stack addArrangedSubview:privacyNoteRow];

        NSButton* clear = [NSButton buttonWithTitle:@"Clear Dictation History"
                                             target:self
                                             action:@selector(clearDictationHistory:)];
        clear.enabled = !_dictationHistory.empty();
        [stack addArrangedSubview:clear];
        return;
    }

    if ([_settingsCategory isEqualToString:@"About"]) {
        NSStackView* stack = [self freshSettingsStackWithTitle:@"About"];
        NSString* version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if (!version) version = @"dev";
        [stack addArrangedSubview:[self labelWithText:@"note-taker" fontSize:18 bold:YES]];
        [stack addArrangedSubview:[self labelWithText:[NSString stringWithFormat:@"Version %@", version] fontSize:13 bold:NO]];
        [stack addArrangedSubview:[self labelWithText:[NSString stringWithFormat:@"Active model: %@", _activeModel] fontSize:13 bold:NO]];
        NSStackView* poweredBy = [NSStackView stackViewWithViews:@[
            [self labelWithText:@"Local speech transcription powered by" fontSize:13 bold:NO],
            [self linkButtonWithTitle:@"whisper.cpp" url:@"https://github.com/ggerganov/whisper.cpp"]
        ]];
        poweredBy.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        poweredBy.alignment = NSLayoutAttributeCenterY;
        poweredBy.spacing = 4;
        [stack addArrangedSubview:poweredBy];
        [stack addArrangedSubview:[self labelWithText:@"Projeto no GitHub:" fontSize:13 bold:YES]];
        [stack addArrangedSubview:[self githubLinkRow]];
        return;
    }

    NSStackView* stack = [self freshSettingsStackWithTitle:@"General"];
    [self addLabel:@"Language"
           control:[self popupWithLabels:@[@"Auto", @"Português", @"English", @"Español"]
                                   values:@[@"auto", @"pt", @"en", @"es"]
                                  current:_language
                                   action:@selector(selectLanguageFromPopup:)]
           toStack:stack];

    [self addLabel:@"Model"
           control:[self popupWithLabels:@[@"large-v3", @"large-v3-turbo"]
                                   values:@[@"large-v3", @"large-v3-turbo"]
                                  current:_model
                                   action:@selector(selectModelFromPopup:)]
           toStack:stack];

    [self addLabel:@"Dictation Hotkey"
           control:[self popupWithLabels:@[[self labelForKeycode:kVK_RightOption],
                                           [self labelForKeycode:kVK_Option],
                                           [self labelForKeycode:kVK_RightCommand],
                                           [self labelForKeycode:kVK_Function]]
                                   values:@[@(kVK_RightOption), @(kVK_Option), @(kVK_RightCommand), @(kVK_Function)]
                                  current:@(_hotkeyCode)
                                   action:@selector(selectHotkeyFromPopup:)]
           toStack:stack];
}

// ── Menu actions ──────────────────────────────────────────────────────────────

- (void)startRecording:(id)__unused sender {
    if (_controller) _controller->startSession();
}

- (void)stopRecording:(id)__unused sender {
    if (_controller) _controller->stopSession();
}

- (void)openLink:(NSButton*)sender {
    NSString* urlString = sender.identifier;
    if (!urlString) return;
    NSURL* url = [NSURL URLWithString:urlString];
    if (url) [[NSWorkspace sharedWorkspace] openURL:url];
}

- (void)copyRecentDictation:(NSMenuItem*)sender {
    NSString* text = sender.representedObject;
    if (!text) return;
    copyTextToClipboard(std::string([text UTF8String]));
}

- (void)clearDictationHistory:(id)__unused sender {
    _dictationHistory.clear();
    [self refreshRecentDictationsMenu];
    [self rebuildSettingsContent];
}

- (void)toggleDictationHistory:(NSButton*)sender {
    BOOL enabled = (sender.state == NSControlStateValueOn);
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kDictationHistoryEnabledKey];
    if (!enabled) _dictationHistory.clear();
    [self refreshRecentDictationsMenu];
    [self rebuildSettingsContent];
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

- (void)selectLanguageFromPopup:(NSPopUpButton*)sender {
    NSString* key = sender.selectedItem.representedObject;
    if (!key || [key isEqualToString:_language]) return;

    _language = key;
    [[NSUserDefaults standardUserDefaults] setObject:key forKey:kLangKey];
    if (_controller) {
        _controller->setLanguage(std::string([key UTF8String]));
    }
}

- (void)selectHotkeyFromPopup:(NSPopUpButton*)sender {
    int code = [sender.selectedItem.representedObject intValue];
    if (code == _hotkeyCode) return;

    _hotkeyCode = code;
    [[NSUserDefaults standardUserDefaults] setInteger:code forKey:kHotkeyKey];
    _eventTap.setHotkey(code);

    NSMenuItem* hint = [_statusItem.menu itemWithTag:kTagHotkeyHint];
    if (hint) {
        hint.title = [NSString stringWithFormat:@"Hold %@ to dictate",
                      [self labelForKeycode:code]];
    }
}

- (void)selectModelFromPopup:(NSPopUpButton*)sender {
    NSString* m = sender.selectedItem.representedObject;
    if (!m || [m isEqualToString:_model]) return;

    NSString* path = [self modelPathForKey:m];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        [self showModelMissingAlertForKey:m];
        [self rebuildSettingsContent];
        return;
    }

    _model = m;
    [[NSUserDefaults standardUserDefaults] setObject:m forKey:kModelKey];
    [self rebuildSettingsContent];

    NSAlert* alert = [[NSAlert alloc] init];
    alert.messageText = @"Restart required";
    alert.informativeText = [NSString stringWithFormat:
        @"Model \"%@\" will be loaded after restarting the app.", m];
    [alert addButtonWithTitle:@"Restart Now"];
    [alert addButtonWithTitle:@"Later"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSString* bundlePath = [[NSBundle mainBundle] bundlePath];
        [NSTask launchedTaskWithLaunchPath:@"/usr/bin/open"
                                 arguments:@[@"-n", bundlePath]];
        [NSApp terminate:nil];
    }
}

- (void)selectSensitivityFromPopup:(NSPopUpButton*)sender {
    NSString* key = sender.selectedItem.representedObject;
    [[NSUserDefaults standardUserDefaults] setObject:key forKey:kSensitivityKey];
    [self applyVadSensitivity:key];
}

- (void)selectSilenceTimeoutFromPopup:(NSPopUpButton*)sender {
    float val = [sender.selectedItem.representedObject floatValue];
    [[NSUserDefaults standardUserDefaults] setDouble:val forKey:kSilenceKey];
    if (_controller) _controller->setSilenceTimeout(val);
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
