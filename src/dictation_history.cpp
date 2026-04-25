#include "dictation_history.h"

#include <algorithm>
#include <utility>

namespace {

bool isBlank(const std::string& text) {
    return std::all_of(text.begin(), text.end(), [](unsigned char c) {
        return c == ' ' || c == '\t' || c == '\n' || c == '\r';
    });
}

}  // namespace

DictationHistory::DictationHistory(size_t limit)
    : limit_(limit == 0 ? 1 : limit)
{
}

void DictationHistory::add(std::string text) {
    if (text.empty() || isBlank(text)) return;
    items_.insert(items_.begin(), std::move(text));
    if (items_.size() > limit_) items_.resize(limit_);
}

void DictationHistory::clear() {
    items_.clear();
}

const std::vector<std::string>& DictationHistory::items() const {
    return items_;
}

size_t DictationHistory::limit() const {
    return limit_;
}

bool DictationHistory::empty() const {
    return items_.empty();
}
