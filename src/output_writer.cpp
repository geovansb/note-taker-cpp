#include "output_writer.h"
#include <nlohmann/json.hpp>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <sys/stat.h>

using json = nlohmann::json;

static void mkdir_p(const std::string& path) {
    if (mkdir(path.c_str(), 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "warn: mkdir(%s): %s\n", path.c_str(), strerror(errno));
    }
}

static void write_atomic(const std::string& path, const std::string& content) {
    std::string tmp = path + ".tmp";
    int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    FILE* f = fd >= 0 ? fdopen(fd, "w") : nullptr;
    if (!f) {
        fprintf(stderr, "warn: cannot write %s: %s\n", tmp.c_str(), strerror(errno));
        return;
    }
    size_t written = fwrite(content.c_str(), 1, content.size(), f);
    if (written != content.size()) {
        fprintf(stderr, "warn: short write to %s (%zu/%zu bytes): %s\n",
                tmp.c_str(), written, content.size(), strerror(errno));
    }
    fclose(f);
    if (rename(tmp.c_str(), path.c_str()) != 0) {
        fprintf(stderr, "warn: rename %s -> %s: %s\n",
                tmp.c_str(), path.c_str(), strerror(errno));
    }
}

// Format ms-since-epoch as HH:MM:SS (local time).
static std::string ms_to_hhmmss(int64_t session_start_unix_ms, int64_t offset_ms) {
    int64_t abs_ms  = session_start_unix_ms + offset_ms;
    time_t  t       = static_cast<time_t>(abs_ms / 1000);
    struct tm tm_info;
    localtime_r(&t, &tm_info);
    char buf[16];
    strftime(buf, sizeof(buf), "%H:%M:%S", &tm_info);
    return buf;
}

OutputWriter::OutputWriter(const std::string& output_dir,
                           const std::string& session_id,
                           const std::string& model,
                           const std::string& language)
    : session_id_(session_id)
    , model_(model)
    , language_(language)
{
    mkdir_p(output_dir);
    json_path_ = output_dir + "/note_" + session_id_ + ".json";
    txt_path_  = output_dir + "/note_" + session_id_ + ".txt";
}

void OutputWriter::addSegment(int64_t start_ms, int64_t end_ms, const std::string& text) {
    std::lock_guard<std::mutex> lock(mutex_);
    segments_.push_back({start_ms, end_ms, text});
}

void OutputWriter::flush() {
    std::vector<Segment> snap;
    {
        std::lock_guard<std::mutex> lock(mutex_);
        snap = segments_;
    }

    // JSON
    json doc;
    doc["session_id"] = session_id_;
    doc["model"]      = model_;
    doc["language"]   = language_;
    doc["segments"]   = json::array();
    for (const auto& s : snap) {
        doc["segments"].push_back({
            {"start_ms", s.start_ms},
            {"end_ms",   s.end_ms},
            {"text",     s.text}
        });
    }
    write_atomic(json_path_, doc.dump(2) + "\n");

    // Plain-text transcript: one line per segment
    std::string txt;
    txt.reserve(snap.size() * 80);
    for (const auto& s : snap) {
        txt += s.text;
        txt += '\n';
    }
    write_atomic(txt_path_, txt);
}
