#pragma once
#include <functional>

// Forward-declared at file scope so the free callback function in event_tap.mm
// can access it without going through EventTap's private section.
struct EventTapImpl;

// CGEventTap wrapper. Listens for a single hotkey globally (listen-only,
// does not intercept or add latency to other apps).
// Runs its own CFRunLoop on a dedicated background thread.
// Requires Accessibility permission (AXIsProcessTrustedWithOptions).
class EventTap {
public:
    EventTap();
    ~EventTap();

    // Set the hotkey virtual keycode. Default: 0x3D (Right Option / kVK_RightOption).
    // Must be called before start().
    void setHotkey(int keycode);

    // Returns whether Accessibility trust is currently granted. When prompt is
    // true, asks macOS to show the system permission prompt if needed.
    bool isTrusted(bool prompt = false) const;

    // Start monitoring. on_down/on_up are called on the internal CFRunLoop thread.
    // Returns false and logs a warning if Accessibility is not granted.
    bool start(std::function<void()> on_down, std::function<void()> on_up,
               bool prompt = false);

    void stop();

private:
    EventTapImpl* impl_;
};
