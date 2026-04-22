#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <sstream>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

#include "output_writer.h"
#include <nlohmann/json.hpp>

using json = nlohmann::json;

// Create a unique temp directory and return its path.
static std::string makeTmpDir() {
    char tpl[] = "/tmp/output_writer_test_XXXXXX";
    char* dir = mkdtemp(tpl);
    assert(dir && "mkdtemp failed");
    return std::string(dir);
}

static std::string readFile(const std::string& path) {
    std::ifstream f(path);
    assert(f.good() && "file must exist");
    std::ostringstream ss;
    ss << f.rdbuf();
    return ss.str();
}

static void rmrf(const std::string& dir) {
    // Simple cleanup — only removes files we created + the dir itself.
    std::string cmd = "rm -rf " + dir;
    (void)system(cmd.c_str());
}

// ── Test 1: single flush produces correct JSON and TXT ───────────────────────

static void test_single_flush() {
    std::string dir = makeTmpDir();
    OutputWriter ow(dir, "test01", "ggml-large-v3.bin", "pt");

    ow.addSegment(0, 5000, " Hello world.");
    ow.addSegment(5000, 10000, " Second segment.");
    ow.flush();

    // Verify JSON
    json doc = json::parse(readFile(ow.jsonPath()));
    assert(doc["session_id"] == "test01");
    assert(doc["model"] == "ggml-large-v3.bin");
    assert(doc["language"] == "pt");
    assert(doc["segments"].size() == 2);
    assert(doc["segments"][0]["start_ms"] == 0);
    assert(doc["segments"][0]["end_ms"] == 5000);
    assert(doc["segments"][0]["text"] == " Hello world.");
    assert(doc["segments"][1]["start_ms"] == 5000);
    assert(doc["segments"][1]["text"] == " Second segment.");

    // Verify TXT
    std::string txt = readFile(ow.txtPath());
    assert(txt == " Hello world.\n Second segment.\n");

    rmrf(dir);
    printf("test_single_flush: OK\n");
}

// ── Test 2: multiple flushes accumulate segments ─────────────────────────────

static void test_accumulate() {
    std::string dir = makeTmpDir();
    OutputWriter ow(dir, "test02", "model", "en");

    ow.addSegment(0, 1000, " A");
    ow.flush();

    ow.addSegment(1000, 2000, " B");
    ow.addSegment(2000, 3000, " C");
    ow.flush();

    json doc = json::parse(readFile(ow.jsonPath()));
    assert(doc["segments"].size() == 3);
    assert(doc["segments"][0]["text"] == " A");
    assert(doc["segments"][1]["text"] == " B");
    assert(doc["segments"][2]["text"] == " C");

    std::string txt = readFile(ow.txtPath());
    assert(txt == " A\n B\n C\n");

    rmrf(dir);
    printf("test_accumulate: OK\n");
}

// ── Test 3: flush with no pending segments is a no-op ────────────────────────

static void test_empty_flush() {
    std::string dir = makeTmpDir();
    OutputWriter ow(dir, "test03", "model", "en");

    // Flush with nothing pending — should not create files.
    ow.flush();

    struct stat st;
    assert(stat(ow.jsonPath().c_str(), &st) != 0 && "JSON must not exist after empty flush");
    assert(stat(ow.txtPath().c_str(), &st) != 0 && "TXT must not exist after empty flush");

    rmrf(dir);
    printf("test_empty_flush: OK\n");
}

// ── Test 4: output dir is created if absent ──────────────────────────────────

static void test_creates_dir() {
    std::string base = makeTmpDir();
    std::string nested = base + "/sub/dir";

    // mkdir_p only creates one level, so use a single-level subdir.
    std::string subdir = base + "/notes";
    OutputWriter ow(subdir, "test04", "model", "en");

    ow.addSegment(0, 1000, " test");
    ow.flush();

    struct stat st;
    assert(stat(subdir.c_str(), &st) == 0 && "subdir must be created");
    assert(S_ISDIR(st.st_mode));

    rmrf(base);
    printf("test_creates_dir: OK\n");
}

// ── Test 5: file paths follow naming convention ──────────────────────────────

static void test_file_paths() {
    std::string dir = makeTmpDir();
    OutputWriter ow(dir, "20260421_143000", "model", "en");

    assert(ow.jsonPath() == dir + "/note_20260421_143000.json");
    assert(ow.txtPath()  == dir + "/note_20260421_143000.txt");

    rmrf(dir);
    printf("test_file_paths: OK\n");
}

// ── main ─────────────────────────────────────────────────────────────────────

int main() {
    test_single_flush();
    test_accumulate();
    test_empty_flush();
    test_creates_dir();
    test_file_paths();

    puts("\noutput_writer_test: all assertions passed");
    return 0;
}
