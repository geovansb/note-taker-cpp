#pragma once
#include <functional>

// CGEventTap wrapper. Runs its own CFRunLoop thread.
// Default hotkey: Right Option (kVK_RightOption = 0x3D).
// Requires Accessibility permission (AXIsProcessTrustedWithOptions).
class EventTap {
public:
    EventTap();
    ~EventTap();

    // Call before start(). Defaults to Right Option (0x3D).
    void setHotkey(int keycode);

    // Start monitoring. on_down/on_up called on the CFRunLoop thread.
    // Returns false if Accessibility permission denied.
    bool start(std::function<void()> on_down, std::function<void()> on_up);

    void stop();

private:
    struct Impl;
    Impl* impl_;
};