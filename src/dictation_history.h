#pragma once

#include <cstddef>
#include <string>
#include <vector>

class DictationHistory {
public:
    explicit DictationHistory(size_t limit = 9);

    void add(std::string text);
    void clear();

    const std::vector<std::string>& items() const;
    size_t limit() const;
    bool empty() const;

private:
    size_t limit_;
    std::vector<std::string> items_;
};
