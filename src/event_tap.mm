#include "event_tap.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <thread>
#include <atomic>
#include <condition_variable>
#include <mutex>

struct EventTapImpl {
    int                      hotkey   = kVK_RightOption;
    std::function<void()>    on_down;
    std::function<void()>    on_up;
    CFMachPortRef            tap      = nullptr;
    CFRunLoopSourceRef       src      = nullptr;
    CFRunLoopRef             run_loop = nullptr;
    std::thread              thread;
    std::atomic<bool>        running  { false };
    std::mutex               ready_mutex;
    std::condition_variable  ready_cv;
    bool                     ready    = false;
};

static CGEventRef event_tap_callback(CGEventTapProxy __unused proxy,
                                     CGEventType type,
                                     CGEventRef event,
                                     void* user_info)
{
    EventTapImpl* impl = static_cast<EventTapImpl*>(user_info);

    // Re-enable the tap if the system disabled it (e.g. after a timeout).
    if (type == kCGEventTapDisabledByTimeout ||
        type == kCGEventTapDisabledByUserInput) {
        if (impl->tap) CGEventTapEnable(impl->tap, true);
        return event;
    }

    int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (keycode != impl->hotkey) return event;

    if (type == kCGEventFlagsChanged) {
        // Modifier keys use FlagsChanged instead of KeyDown/KeyUp.
        // Determine pressed vs released from the appropriate flag bit.
        CGEventFlags flags = CGEventGetFlags(event);
        CGEventFlags mask  = 0;
        switch (keycode) {
            case kVK_RightOption:  // fallthrough
            case kVK_Option:       mask = kCGEventFlagMaskAlternate; break;
            case kVK_RightCommand: // fallthrough
            case kVK_Command:      mask = kCGEventFlagMaskCommand;   break;
            case kVK_RightControl: // fallthrough
            case kVK_Control:      mask = kCGEventFlagMaskControl;   break;
            case kVK_RightShift:   // fallthrough
            case kVK_Shift:        mask = kCGEventFlagMaskShift;     break;
            case kVK_Function:     mask = kCGEventFlagMaskSecondaryFn; break;
            default:               mask = 0; break;
        }
        bool pressed = mask != 0 && (flags & mask) != 0;
        if (pressed  && impl->on_down) impl->on_down();
        if (!pressed && impl->on_up)   impl->on_up();
    } else {
        if (type == kCGEventKeyDown && impl->on_down) impl->on_down();
        if (type == kCGEventKeyUp   && impl->on_up)   impl->on_up();
    }

    return event;   // listen-only: always return the event unchanged
}

// ── EventTap ──────────────────────────────────────────────────────────────────

EventTap::EventTap() : impl_(new EventTapImpl()) {}

EventTap::~EventTap() {
    stop();
    delete impl_;
}

void EventTap::setHotkey(int keycode) {
    impl_->hotkey = keycode;
}

bool EventTap::start(std::function<void()> on_down, std::function<void()> on_up) {
    if (impl_->running) return true;

    // Pass kAXTrustedCheckOptionPrompt=YES so macOS shows the Accessibility
    // dialog automatically when the CDHash changes after a rebuild.
    NSDictionary* opts = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
    bool trusted = AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
    NSLog(@"[event_tap] AXIsProcessTrusted = %@", trusted ? @"YES" : @"NO");
    if (!trusted) {
        NSLog(@"[event_tap] Accessibility not granted — grant in System Settings and relaunch");
        return false;
    }

    impl_->on_down = std::move(on_down);
    impl_->on_up   = std::move(on_up);

    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown)
                     | CGEventMaskBit(kCGEventKeyUp)
                     | CGEventMaskBit(kCGEventFlagsChanged);  // required for modifier keys

    impl_->tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly,   // passive — never blocks other apps
        mask,
        event_tap_callback,
        impl_
    );

    if (!impl_->tap) {
        fprintf(stderr, "[event_tap] CGEventTapCreate failed (Accessibility denied?)\n");
        return false;
    }

    impl_->src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, impl_->tap, 0);
    impl_->running = true;

    impl_->ready = false;
    impl_->thread = std::thread([this] {
        impl_->run_loop = CFRunLoopGetCurrent();
        CFRunLoopAddSource(impl_->run_loop, impl_->src, kCFRunLoopCommonModes);
        CGEventTapEnable(impl_->tap, true);
        // Signal that the run loop is about to start — start() can return safely.
        {
            std::lock_guard<std::mutex> lock(impl_->ready_mutex);
            impl_->ready = true;
        }
        impl_->ready_cv.notify_one();
        CFRunLoopRun();   // blocks until CFRunLoopStop()
        CGEventTapEnable(impl_->tap, false);
        CFRunLoopRemoveSource(impl_->run_loop, impl_->src, kCFRunLoopCommonModes);
    });

    // Wait until the run loop thread is ready before returning, so no events
    // arriving immediately after start() are lost.
    {
        std::unique_lock<std::mutex> lock(impl_->ready_mutex);
        impl_->ready_cv.wait(lock, [this] { return impl_->ready; });
    }

    return true;
}

void EventTap::stop() {
    if (!impl_->running) return;
    impl_->running = false;

    if (impl_->run_loop) {
        CFRunLoopStop(impl_->run_loop);
        impl_->run_loop = nullptr;
    }
    if (impl_->thread.joinable()) impl_->thread.join();

    if (impl_->src)  { CFRelease(impl_->src);  impl_->src  = nullptr; }
    if (impl_->tap)  { CFRelease(impl_->tap);  impl_->tap  = nullptr; }
}
