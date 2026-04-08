#include "event_tap.h"

#import <ApplicationServices/ApplicationServices.h>
#import <Carbon/Carbon.h>

#include <thread>

struct EventTap::Impl {
    CGEventTapRef tap_ = nullptr;
    CFRunLoopSourceRef src_ = nullptr;
    CFRunLoopRef run_loop_ = nullptr;
    std::thread thread_;
    int hotkey_ = kVK_RightOption;  // 0x3D
    std::function<void()> on_down_;
    std::function<void()> on_up_;

    ~Impl() {
        if (tap_) CFRelease(tap_);
        if (src_) CFRelease(src_);
    }
};

static CGEventRef event_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void* refcon) {
    EventTap* self = (EventTap*)refcon;
    int keycode = (int)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    if (keycode == self->impl_->hotkey_) {
        if (type == kCGEventKeyDown) {
            self->impl_->on_down_();
        } else if (type == kCGEventKeyUp) {
            self->impl_->on_up_();
        }
    }
    return event;  // listen-only
}

EventTap::EventTap() : impl_(new Impl()) {}

EventTap::~EventTap() {
    stop();
    delete impl_;
}

void EventTap::setHotkey(int keycode) {
    impl_->hotkey_ = keycode;
}

bool EventTap::start(std::function<void()> on_down, std::function<void()> on_up) {
    if (!AXIsProcessTrustedWithOptions(nullptr)) {
        fprintf(stderr, "warning: Accessibility permission denied\n");
        return false;
    }

    impl_->on_down_ = on_down;
    impl_->on_up_ = on_up;

    impl_->tap_ = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
        kCGEventMaskBit(kCGEventKeyDown) | kCGEventMaskBit(kCGEventKeyUp),
        event_callback, this);
    if (!impl_->tap_) return false;

    impl_->src_ = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, impl_->tap_, 0);
    if (!impl_->src_) {
        CFRelease(impl_->tap_);
        impl_->tap_ = nullptr;
        return false;
    }

    impl_->thread_ = std::thread([this]() {
        CFRunLoopRef rl = CFRunLoopGetCurrent();
        impl_->run_loop_ = rl;
        CFRunLoopAddSource(rl, impl_->src_, kCFRunLoopCommonModes);
        CGEventTapEnable(impl_->tap_, true);
        CFRunLoopRun();
    });

    return true;
}

void EventTap::stop() {
    if (impl_->tap_) {
        CGEventTapEnable(impl_->tap_, false);
    }
    if (impl_->run_loop_) {
        CFRunLoopStop(impl_->run_loop_);
    }
    if (impl_->thread_.joinable()) {
        impl_->thread_.join();
    }
}