cmake_minimum_required(VERSION 3.22)
project(note-taker CXX OBJCXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_OBJCXX_STANDARD 17)
set(CMAKE_OBJCXX_STANDARD_REQUIRED ON)

# Prevent cmake from defaulting all executables to bundles.
set(MACOSX_BUNDLE FALSE)

option(NOTETAKER_NATIVE_ARCH "Build with -march=native for this CPU" OFF)

# whisper.cpp — disable everything we don't need
set(WHISPER_BUILD_TESTS    OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
set(WHISPER_BUILD_SERVER   OFF CACHE BOOL "" FORCE)
set(BUILD_SHARED_LIBS      OFF CACHE BOOL "" FORCE)
set(GGML_LTO               ON  CACHE BOOL "" FORCE)

option(GGML_METAL "Enable Metal GPU acceleration (Apple Silicon)" ON)

add_subdirectory(whisper.cpp)

execute_process(
    COMMAND git describe --tags --abbrev=0
    WORKING_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}"
    OUTPUT_VARIABLE NOTETAKER_GIT_TAG
    OUTPUT_STRIP_TRAILING_WHITESPACE
    ERROR_QUIET
)
if(NOT NOTETAKER_GIT_TAG)
    set(NOTETAKER_GIT_TAG "v0.0.0")
endif()
string(REGEX REPLACE "^v" "" NOTETAKER_BUNDLE_VERSION "${NOTETAKER_GIT_TAG}")
configure_file(
    "${CMAKE_CURRENT_SOURCE_DIR}/bar/Info.plist.in"
    "${CMAKE_CURRENT_BINARY_DIR}/bar/Info.plist"
    @ONLY
)

# ── note-taker-bar: unified menu bar app (M4) ────────────────────────────────

add_executable(note-taker-bar MACOSX_BUNDLE
    src/bar_main.mm
    src/app_logger.mm
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
    src/mode_machine.cpp
    src/dictation_history.cpp
)
set_target_properties(note-taker-bar PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST "${CMAKE_CURRENT_BINARY_DIR}/bar/Info.plist"
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
# Copy ggml Metal resources into the bundle when shaders are NOT embedded.
# When GGML_METAL_EMBED_LIBRARY is ON (default), shaders are compiled into the
# static library and no external files are needed at runtime.
if(GGML_METAL AND NOT GGML_METAL_EMBED_LIBRARY)
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
endif()
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

add_executable(wav_writer_test
    tests/wav_writer_test.cpp
    src/app_logger.mm
    src/wav_writer.cpp
)
target_include_directories(wav_writer_test PRIVATE src)

add_executable(output_writer_test
    tests/output_writer_test.cpp
    src/app_logger.mm
    src/output_writer.cpp
)
target_include_directories(output_writer_test PRIVATE src third_party)

add_executable(whisper_worker_test
    tests/whisper_worker_test.cpp
    src/app_logger.mm
    src/whisper_worker.cpp
    src/output_writer.cpp
    src/wav_writer.cpp
)
target_include_directories(whisper_worker_test PRIVATE src third_party whisper.cpp/include)
target_link_libraries(whisper_worker_test PRIVATE whisper)

add_executable(mode_machine_test
    tests/mode_machine_test.cpp
    src/mode_machine.cpp
)
target_include_directories(mode_machine_test PRIVATE src)

add_executable(dictation_history_test
    tests/dictation_history_test.cpp
    src/dictation_history.cpp
)
target_include_directories(dictation_history_test PRIVATE src)
