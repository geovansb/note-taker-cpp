#include "app_logger.h"

#include <cerrno>
#include <cstdarg>
#include <cstdio>
#include <cstring>
#include <ctime>
#include <mutex>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <sys/time.h>
#include <unistd.h>
#include <fcntl.h>

namespace {

constexpr off_t kMaxLogBytes = 5 * 1024 * 1024;

std::mutex g_mutex;
bool g_initialized = false;
bool g_redirected = false;
LogLevel g_min_level = LogLevel::Warn;
std::string g_notes_dir;
std::string g_logs_dir;
std::string g_log_path;
int g_fd = -1;

std::string trimTrailingSlashes(std::string path) {
    while (path.size() > 1 && path.back() == '/') path.pop_back();
    return path;
}

bool mkdirIfNeeded(const std::string& path) {
    if (path.empty()) return false;
    if (mkdir(path.c_str(), 0755) == 0 || errno == EEXIST) return true;
    return false;
}

bool mkdirP(const std::string& path) {
    if (path.empty()) return false;
    std::string cur;
    if (path[0] == '/') cur = "/";

    size_t pos = (path[0] == '/') ? 1 : 0;
    while (pos <= path.size()) {
        size_t next = path.find('/', pos);
        std::string part = path.substr(pos, next == std::string::npos ? std::string::npos : next - pos);
        if (!part.empty()) {
            if (!cur.empty() && cur.back() != '/') cur += '/';
            cur += part;
            if (!mkdirIfNeeded(cur)) return false;
        }
        if (next == std::string::npos) break;
        pos = next + 1;
    }
    return true;
}

void rotateIfNeeded(const std::string& path) {
    struct stat st {};
    if (stat(path.c_str(), &st) != 0 || st.st_size <= kMaxLogBytes) return;

    std::string rotated = path + ".1";
    unlink(rotated.c_str());
    rename(path.c_str(), rotated.c_str());
}

std::string timestampNow() {
    struct timeval tv {};
    gettimeofday(&tv, nullptr);

    time_t seconds = tv.tv_sec;
    struct tm local {};
    localtime_r(&seconds, &local);

    char base[32];
    strftime(base, sizeof(base), "%Y-%m-%dT%H:%M:%S", &local);

    char zone[8];
    strftime(zone, sizeof(zone), "%z", &local);
    std::string z = zone;
    if (z.size() == 5) z.insert(3, ":");

    char out[48];
    snprintf(out, sizeof(out), "%s.%03d%s", base, static_cast<int>(tv.tv_usec / 1000), z.c_str());
    return out;
}

std::string formatMessage(const char* fmt, va_list args) {
    va_list copy;
    va_copy(copy, args);
    int needed = vsnprintf(nullptr, 0, fmt, copy);
    va_end(copy);
    if (needed < 0) return "";

    std::vector<char> buffer(static_cast<size_t>(needed) + 1);
    vsnprintf(buffer.data(), buffer.size(), fmt, args);
    return std::string(buffer.data(), static_cast<size_t>(needed));
}

bool shouldLog(LogLevel level) {
    return static_cast<int>(level) >= static_cast<int>(g_min_level);
}

void closeCurrentFd() {
    if (g_fd >= 0) {
        close(g_fd);
        g_fd = -1;
    }
}

bool openLogFileLocked(const std::string& notes_dir) {
    std::string cleaned = trimTrailingSlashes(notes_dir);
    if (cleaned.empty()) return false;

    std::string logs_dir = cleaned + "/logs";
    if (!mkdirP(logs_dir)) return false;

    std::string log_path = logs_dir + "/note-taker-bar.log";
    rotateIfNeeded(log_path);

    int fd = open(log_path.c_str(), O_WRONLY | O_CREAT | O_APPEND, 0644);
    if (fd < 0) return false;

    closeCurrentFd();
    g_fd = fd;
    g_notes_dir = cleaned;
    g_logs_dir = logs_dir;
    g_log_path = log_path;
    g_initialized = true;

    if (g_redirected) {
        dup2(g_fd, STDOUT_FILENO);
        dup2(g_fd, STDERR_FILENO);
    }
    return true;
}

} // namespace

void AppLogger::init(const std::string& notes_dir, LogLevel min_level) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_min_level = min_level;
    openLogFileLocked(notes_dir);
}

void AppLogger::shutdown() {
    std::lock_guard<std::mutex> lock(g_mutex);
    closeCurrentFd();
    g_initialized = false;
}

void AppLogger::setNotesDir(const std::string& notes_dir) {
    std::lock_guard<std::mutex> lock(g_mutex);
    std::string old_path = g_log_path;
    if (openLogFileLocked(notes_dir)) {
        std::string msg = timestampNow() + " " + levelName(LogLevel::Warn) +
            " logger: log file changed from " + old_path + " to " + g_log_path + "\n";
        write(g_fd, msg.c_str(), msg.size());
    }
}

void AppLogger::setLevel(LogLevel min_level) {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_min_level = min_level;
    if (!g_initialized || g_fd < 0) return;
    std::string msg = timestampNow() + " " + levelName(LogLevel::Warn) +
        " logger: log level set to " + levelName(min_level) + "\n";
    write(g_fd, msg.c_str(), msg.size());
}

std::string AppLogger::path() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_log_path;
}

std::string AppLogger::logsDir() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_logs_dir;
}

void AppLogger::redirectStandardStreams() {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_redirected = true;
    if (!g_initialized || g_fd < 0) return;
    dup2(g_fd, STDOUT_FILENO);
    dup2(g_fd, STDERR_FILENO);
    setvbuf(stdout, nullptr, _IOLBF, 0);
    setvbuf(stderr, nullptr, _IOLBF, 0);
}

void AppLogger::log(LogLevel level, const char* component, const char* fmt, ...) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_initialized || g_fd < 0 || !shouldLog(level)) return;

    va_list args;
    va_start(args, fmt);
    std::string message = formatMessage(fmt, args);
    va_end(args);

    while (!message.empty() && (message.back() == '\n' || message.back() == '\r')) {
        message.pop_back();
    }
    for (char& c : message) {
        if (c == '\n' || c == '\r') c = ' ';
    }

    std::string line = timestampNow();
    line += " ";
    line += levelName(level);
    line += " ";
    line += component ? component : "app";
    line += ": ";
    line += message;
    line += "\n";

    write(g_fd, line.c_str(), line.size());
}

LogLevel AppLogger::parseLevel(const std::string& value, LogLevel fallback) {
    std::string v;
    v.reserve(value.size());
    for (char c : value) {
        if (c >= 'A' && c <= 'Z') v.push_back(static_cast<char>(c - 'A' + 'a'));
        else v.push_back(c);
    }

    if (v == "debug") return LogLevel::Debug;
    if (v == "info")  return LogLevel::Info;
    if (v == "warn" || v == "wanr") return LogLevel::Warn;
    if (v == "error") return LogLevel::Error;
    return fallback;
}

const char* AppLogger::levelName(LogLevel level) {
    switch (level) {
        case LogLevel::Debug: return "DEBUG";
        case LogLevel::Info:  return "INFO";
        case LogLevel::Warn:  return "WARN";
        case LogLevel::Error: return "ERROR";
    }
    return "WARN";
}

std::string AppLogger::normalizedLevelValue(LogLevel level) {
    switch (level) {
        case LogLevel::Debug: return "debug";
        case LogLevel::Info:  return "info";
        case LogLevel::Warn:  return "warn";
        case LogLevel::Error: return "error";
    }
    return "warn";
}
