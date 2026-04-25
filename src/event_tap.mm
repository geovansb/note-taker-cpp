#include "event_tap.h"
#include "app_logger.h"

#import <AppKit/AppKit.h>
#import <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <thread>
#include <atomic>
#include <condition_variable>
#include <mutex>

struct EventTapImpl {
    std::atomic<int>         hotkey   { kVK_RightOption };
    std::function<void()>    on_down;
    std::function<void()>    on_up;
    CFMachPortRef            tap      = nullptr;
    CFRunLoopSourceRef       src      = nullptr;
    CFRunLoopRef             run_loop = nullptr;
    CFRunLoopTimerRef        health_timer = nullptr;
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
        NT_LOG_WARN("event_tap", "tap disabled by %s; re-enabling",
                    type == kCGEventTapDisabledByTimeout ? "timeout" : "user input");
        if (impl->tap) CGEventTapEnable(impl->tap, true);
        return event;
    }

    int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (keycode != impl->hotkey.load(std::memory_order_relaxed)) return event;

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
    impl_->hotkey.store(keycode, std::memory_order_relaxed);
}

bool EventTap::isTrusted(bool prompt) const {
    if (!prompt) return AXIsProcessTrusted();

    NSDictionary* opts = @{ (__bridge id)kAXTrustedCheckOptionPrompt: @YES };
    return AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)opts);
}

bool EventTap::start(std::function<void()> on_down, std::function<void()> on_up,
                     bool prompt) {
    if (impl_->running) return true;

    bool trusted = isTrusted(prompt);
    NT_LOG_WARN("event_tap", "AXIsProcessTrusted=%s", trusted ? "YES" : "NO");
    if (!trusted) {
        NT_LOG_WARN("event_tap", "Accessibility not granted; grant in System Settings");
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
        NT_LOG_ERROR("event_tap", "CGEventTapCreate failed; Accessibility denied?");
        return false;
    }

    impl_->src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, impl_->tap, 0);
    impl_->running = true;

    impl_->ready = false;
    impl_->thread = std::thread([this] {
        impl_->run_loop = CFRunLoopGetCurrent();
        CFRunLoopAddSource(impl_->run_loop, impl_->src, kCFRunLoopCommonModes);
        CGEventTapEnable(impl_->tap, true);

        // Periodic health check: re-enable the tap if macOS silently disabled it.
        // This handles cases where the disabled notification event is not delivered
        // (e.g. after sleep/wake, Accessibility permission changes, system updates).
        CFRunLoopTimerContext timer_ctx = { 0, impl_, nullptr, nullptr, nullptr };
        impl_->health_timer = CFRunLoopTimerCreate(
            kCFAllocatorDefault,
            CFAbsoluteTimeGetCurrent() + 5.0,  // first fire after 5s
            5.0,                                 // repeat every 5s
            0, 0,
            [](CFRunLoopTimerRef, void* info) {
                EventTapImpl* impl = static_cast<EventTapImpl*>(info);
                if (impl->tap && !CGEventTapIsEnabled(impl->tap)) {
                    NT_LOG_WARN("event_tap", "health check found tap disabled; re-enabling");
                    CGEventTapEnable(impl->tap, true);
                }
            },
            &timer_ctx
        );
        CFRunLoopAddTimer(impl_->run_loop, impl_->health_timer, kCFRunLoopCommonModes);

        // Signal that the run loop is about to start — start() can return safely.
        {
            std::lock_guard<std::mutex> lock(impl_->ready_mutex);
            impl_->ready = true;
        }
        impl_->ready_cv.notify_one();
        CFRunLoopRun();   // blocks until CFRunLoopStop()
        CGEventTapEnable(impl_->tap, false);
        CFRunLoopRemoveSource(impl_->run_loop, impl_->src, kCFRunLoopCommonModes);
        if (impl_->health_timer) {
            CFRunLoopRemoveTimer(impl_->run_loop, impl_->health_timer, kCFRunLoopCommonModes);
            CFRelease(impl_->health_timer);
            impl_->health_timer = nullptr;
        }
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
        // Do NOT null run_loop here — the thread still needs it for cleanup
        // (CFRunLoopRemoveSource / CFRunLoopRemoveTimer) after CFRunLoopRun()
        // returns. Nulling before join() is a use-after-free race.
    }
    if (impl_->thread.joinable()) impl_->thread.join();
    impl_->run_loop = nullptr;

    if (impl_->src)  { CFRelease(impl_->src);  impl_->src  = nullptr; }
    if (impl_->tap)  { CFRelease(impl_->tap);  impl_->tap  = nullptr; }
}
