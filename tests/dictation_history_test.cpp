#include "dictation_history.h"

#include <cassert>
#include <cstdio>
#include <string>

static void test_ignores_empty_text() {
    DictationHistory history(9);
    history.add("");
    history.add("   \n\t");
    assert(history.empty());
    printf("test_ignores_empty_text: OK\n");
}

static void test_newest_first() {
    DictationHistory history(9);
    history.add("first");
    history.add("second");
    history.add("third");
    const auto& items = history.items();
    assert(items.size() == 3);
    assert(items[0] == "third");
    assert(items[1] == "second");
    assert(items[2] == "first");
    printf("test_newest_first: OK\n");
}

static void test_limit() {
    DictationHistory history(9);
    for (int i = 0; i < 12; ++i) {
        history.add("item-" + std::to_string(i));
    }
    const auto& items = history.items();
    assert(items.size() == 9);
    assert(items[0] == "item-11");
    assert(items[8] == "item-3");
    printf("test_limit: OK\n");
}

static void test_clear() {
    DictationHistory history(9);
    history.add("one");
    history.add("two");
    history.clear();
    assert(history.empty());
    printf("test_clear: OK\n");
}

int main() {
    test_ignores_empty_text();
    test_newest_first();
    test_limit();
    test_clear();
    puts("\ndictation_history_test: all assertions passed");
    return 0;
}
