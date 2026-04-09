#pragma once
#include <string>

// Injects UTF-8 text at the current cursor position by:
//   1. Saving the current general pasteboard contents
//   2. Writing the text to the pasteboard
//   3. Simulating Cmd+V via CGEvent
//   4. Restoring the original pasteboard after a short delay
//
// Works universally (browsers, Electron apps, terminals, native apps).
// Must be called from the main thread.
void injectText(const std::string& utf8_text);
