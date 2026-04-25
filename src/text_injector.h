#pragma once
#include <string>

// Injects UTF-8 text at the current cursor position by:
//   1. Replacing the general pasteboard with the text and a private marker
//   2. Simulating Cmd+V via CGEvent
//   3. Optionally clearing the pasteboard later if our marker is still present
//
// Works universally (browsers, Electron apps, terminals, native apps).
// Must be called from the main thread.
// clear_after_seconds: 0 keeps the transcribed text in the pasteboard;
// 1..59 clears it after that many seconds.
void injectText(const std::string& utf8_text, int clear_after_seconds);
