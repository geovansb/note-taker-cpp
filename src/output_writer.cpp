#include "output_writer.h"
#include "app_logger.h"
#include <nlohmann/json.hpp>
#include <cerrno>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

using json = nlohmann::json;

static void mkdir_p(const std::string& path) {
    if (mkdir(path.c_str(), 0755) != 0 && errno != EEXIST) {
        NT_LOG_WARN("output", "mkdir(%s): %s", path.c_str(), strerror(errno));
    }
}

// Returns true on success. On failure, cleans up temp file and returns false.
static bool write_atomic(const std::string& path, const std::string& content) {
    std::string tmp = path + ".tmp";
    int fd = open(tmp.c_str(), O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) {
        NT_LOG_WARN("output", "cannot open %s: %s", tmp.c_str(), strerror(errno));
        return false;
    }
    FILE* f = fdopen(fd, "w");
    if (!f) {
        NT_LOG_WARN("output", "fdopen %s: %s", tmp.c_str(), strerror(errno));
        close(fd);
        unlink(tmp.c_str());
        return false;
    }
    size_t written = fwrite(content.c_str(), 1, content.size(), f);
    bool ok = (written == content.size());
    if (!ok) {
        NT_LOG_WARN("output", "short write to %s (%zu/%zu bytes): %s",
                    tmp.c_str(), written, content.size(), strerror(errno));
    }
    fclose(f);
    if (rename(tmp.c_str(), path.c_str()) != 0) {
        NT_LOG_WARN("output", "rename %s -> %s: %s",
                    tmp.c_str(), path.c_str(), strerror(errno));
        unlink(tmp.c_str());
        return false;
    }
    return ok;
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
    NT_LOG_DEBUG("output", "created writer session_id=%s json=%s txt=%s",
                 session_id_.c_str(), json_path_.c_str(), txt_path_.c_str());
}

void OutputWriter::addSegment(int64_t start_ms, int64_t end_ms, const std::string& text) {
    std::lock_guard<std::mutex> lock(mutex_);
    pending_.push_back({start_ms, end_ms, text});
}

void OutputWriter::flush() {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (pending_.empty()) return;
        all_segments_.insert(all_segments_.end(),
                             std::make_move_iterator(pending_.begin()),
                             std::make_move_iterator(pending_.end()));
        pending_.clear();
    }

    // JSON — write the full session every time (atomic overwrite).
    json doc;
    doc["session_id"] = session_id_;
    doc["model"]      = model_;
    doc["language"]   = language_;
    doc["segments"]   = json::array();
    for (const auto& s : all_segments_) {
        doc["segments"].push_back({
            {"start_ms", s.start_ms},
            {"end_ms",   s.end_ms},
            {"text",     s.text}
        });
    }
    if (!write_atomic(json_path_, doc.dump(2) + "\n")) {
        if (on_error_) on_error_("Failed to write " + json_path_);
    }

    // Plain-text transcript: one line per segment
    std::string txt;
    txt.reserve(all_segments_.size() * 80);
    for (const auto& s : all_segments_) {
        txt += s.text;
        txt += '\n';
    }
    if (!write_atomic(txt_path_, txt)) {
        if (on_error_) on_error_("Failed to write " + txt_path_);
    }
    NT_LOG_DEBUG("output", "flushed session_id=%s segments=%zu",
                 session_id_.c_str(), all_segments_.size());
}
