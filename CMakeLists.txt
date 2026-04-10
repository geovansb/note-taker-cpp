cmake_minimum_required(VERSION 3.22)
project(note-taker CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# Prevent cmake from defaulting all executables to bundles.
set(MACOSX_BUNDLE FALSE)

option(NOTETAKER_NATIVE_ARCH "Build with -march=native for this CPU" ON)

# whisper.cpp — disable everything we don't need
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)

option(GGML_METAL "Enable Metal GPU acceleration (Apple Silicon)" OFF)

add_subdirectory(whisper.cpp)

add_executable(note-taker
    src/main.cpp
    src/audio_capture.mm
    src/vad.cpp
    src/chunk_assembler.cpp
    src/whisper_worker.cpp
    src/output_writer.cpp
    src/wav_writer.cpp
)
target_include_directories(note-taker PRIVATE src third_party whisper.cpp/include)
target_compile_options(note-taker PRIVATE
    -Wall -Wextra -Wno-unused-parameter
    $<$<AND:$<BOOL:${NOTETAKER_NATIVE_ARCH}>,$<CONFIG:Release>>:-march=native>
)

target_link_libraries(note-taker PRIVATE
    whisper
    "-framework AVFoundation"
    "-framework CoreAudio"
    "-framework Foundation"
    "-framework AudioToolbox"
)

# Embed Info.plist into the binary so AVFoundation can find
# NSMicrophoneUsageDescription (required even for CLI tools on macOS 14+).
target_link_options(note-taker PRIVATE
    "LINKER:-sectcreate,__TEXT,__info_plist,${CMAKE_CURRENT_SOURCE_DIR}/Info.plist"
)

# Ad-hoc sign with audio-input entitlement so TCC grants microphone access.
add_custom_command(TARGET note-taker POST_BUILD
    COMMAND codesign --force --sign -
            --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/entitlements.plist"
            --options runtime
            "$<TARGET_FILE:note-taker>"
    COMMENT "Signing note-taker with audio-input entitlement"
)

# ── note-taker-bar: unified menu bar app (M4) ────────────────────────────────

add_executable(note-taker-bar MACOSX_BUNDLE
    src/bar_main.mm
    src/app_delegate.mm
    src/app_controller.cpp
    src/event_tap.mm
    src/text_injector.mm
    src/audio_capture.mm
    src/vad.cpp
    src/chunk_assembler.cpp
    src/whisper_worker.cpp
    src/output_writer.cpp
    src/wav_writer.cpp
)
set_target_properties(note-taker-bar PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_SOURCE_DIR}/bar/Info.plist"
)
# Enable ARC for all ObjC/ObjC++ sources in this target so we can use
# __weak references (required for safe dispatch_after blocks on Tahoe).
target_compile_options(note-taker-bar PRIVATE
    -Wall -Wextra -Wno-unused-parameter
    $<$<COMPILE_LANGUAGE:OBJCXX>:-fobjc-arc>
    $<$<AND:$<BOOL:${NOTETAKER_NATIVE_ARCH}>,$<CONFIG:Release>>:-march=native>
)
target_include_directories(note-taker-bar PRIVATE src third_party whisper.cpp/include)
target_link_libraries(note-taker-bar PRIVATE
    whisper
    "-framework AppKit"
    "-framework AVFoundation"
    "-framework CoreAudio"
    "-framework Foundation"
    "-framework AudioToolbox"
    "-framework CoreGraphics"
    "-framework ApplicationServices"
    "-framework Carbon"
)
# Copy ggml Metal resources into the bundle before signing.
# ggml looks for these via [NSBundle mainBundle] at runtime, so they must live
# in Contents/Resources/. The .metallib is the precompiled shader library;
# .metal is the source fallback used if the library is missing.
add_custom_command(TARGET note-taker-bar POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory
            "$<TARGET_BUNDLE_DIR:note-taker-bar>/Contents/Resources"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_BINARY_DIR}/bin/default.metallib"
            "$<TARGET_BUNDLE_DIR:note-taker-bar>/Contents/Resources/default.metallib"
    COMMAND ${CMAKE_COMMAND} -E copy_if_different
            "${CMAKE_BINARY_DIR}/bin/ggml-metal.metal"
            "$<TARGET_BUNDLE_DIR:note-taker-bar>/Contents/Resources/ggml-metal.metal"
    COMMENT "Bundling ggml Metal resources into note-taker-bar.app"
    VERBATIM
)
# Sign the whole .app bundle (not just the executable).
add_custom_command(TARGET note-taker-bar POST_BUILD
    COMMAND codesign --force --sign -
            --entitlements "${CMAKE_CURRENT_SOURCE_DIR}/bar/entitlements.plist"
            --options runtime
            --deep
            "$<TARGET_BUNDLE_DIR:note-taker-bar>"
    COMMENT "Signing note-taker-bar.app"
)

# ── unit tests ────────────────────────────────────────────────────────────────

add_executable(vad_test
    tests/vad_test.cpp
    src/vad.cpp
)
target_include_directories(vad_test PRIVATE src)

add_executable(chunk_assembler_test
    tests/chunk_assembler_test.cpp
    src/chunk_assembler.cpp
    src/vad.cpp
)
target_include_directories(chunk_assembler_test PRIVATE src)
