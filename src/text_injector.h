#pragma once
#include <string>

// Injects UTF-8 text at the current cursor position by synthesizing unicode
// keyboard events. This bypasses the pasteboard.
//
// Must be called from the main thread.
void injectText(const std::string& utf8_text);

// Copies text to the system pasteboard. Used only for explicit user actions,
// such as copying a previous dictation from the in-memory history.
void copyTextToClipboard(const std::string& utf8_text);
