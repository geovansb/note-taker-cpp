#pragma once

#include <string>

enum class LogLevel {
    Debug = 0,
    Info,
    Warn,
    Error,
};

class AppLogger {
public:
    static void init(const std::string& notes_dir, LogLevel min_level);
    static void shutdown();

    static void setNotesDir(const std::string& notes_dir);
    static void setLevel(LogLevel min_level);

    static std::string path();
    static std::string logsDir();

    static void redirectStandardStreams();

    static void log(LogLevel level, const char* component, const char* fmt, ...)
#if defined(__GNUC__) || defined(__clang__)
        __attribute__((format(printf, 3, 4)))
#endif
        ;

    static LogLevel parseLevel(const std::string& value, LogLevel fallback = LogLevel::Warn);
    static const char* levelName(LogLevel level);
    static std::string normalizedLevelValue(LogLevel level);
};

#define NT_LOG_DEBUG(component, fmt, ...) AppLogger::log(LogLevel::Debug, component, fmt, ##__VA_ARGS__)
#define NT_LOG_INFO(component, fmt, ...)  AppLogger::log(LogLevel::Info,  component, fmt, ##__VA_ARGS__)
#define NT_LOG_WARN(component, fmt, ...)  AppLogger::log(LogLevel::Warn,  component, fmt, ##__VA_ARGS__)
#define NT_LOG_ERROR(component, fmt, ...) AppLogger::log(LogLevel::Error, component, fmt, ##__VA_ARGS__)
