#include <cassert>
#include <cstdio>
#include <memory>
#include <vector>

#include "mode_machine.h"

static std::vector<AppStatus> statuses;

static std::unique_ptr<ModeMachine> makeMachine() {
    statuses.clear();
    auto m = std::make_unique<ModeMachine>();
    m->setStatusCallback([](AppStatus s) { statuses.push_back(s); });
    return m;
}

// ── Valid transitions ────────────────────────────────────────────────────────

static void test_dictation_flow() {
    auto m = makeMachine();
    assert(m->mode() == Mode::Idle);

    assert(m->tryDictate());
    assert(m->mode() == Mode::Dictating);
    assert(statuses.back() == AppStatus::Dictating);

    assert(m->finishDictation());
    assert(m->mode() == Mode::Transcribing);
    assert(statuses.back() == AppStatus::Transcribing);

    m->transcriptionDone();
    assert(m->mode() == Mode::Idle);
    assert(statuses.back() == AppStatus::Idle);

    printf("test_dictation_flow: OK\n");
}

static void test_dictation_cancel() {
    auto m = makeMachine();
    assert(m->tryDictate());

    assert(m->cancelDictation());
    assert(m->mode() == Mode::Idle);
    assert(statuses.back() == AppStatus::Idle);

    printf("test_dictation_cancel: OK\n");
}

static void test_recording_flow() {
    auto m = makeMachine();

    assert(m->tryRecord());
    assert(m->mode() == Mode::Recording);
    assert(m->isRecording());
    assert(statuses.back() == AppStatus::RecordingListening);

    assert(m->stopRecord());
    assert(m->mode() == Mode::Finalizing);
    assert(statuses.back() == AppStatus::Finalizing);

    m->finalizeDone();
    assert(m->mode() == Mode::Idle);
    assert(statuses.back() == AppStatus::Idle);

    printf("test_recording_flow: OK\n");
}

// ── Rejected transitions ─────────────────────────────────────────────────────

static void test_dictate_rejected_during_recording() {
    auto m = makeMachine();
    assert(m->tryRecord());
    statuses.clear();

    assert(!m->tryDictate());
    assert(m->mode() == Mode::Recording);
    assert(statuses.back() == AppStatus::Beep);

    printf("test_dictate_rejected_during_recording: OK\n");
}

static void test_dictate_rejected_during_transcribing() {
    auto m = makeMachine();
    assert(m->tryDictate());
    assert(m.finishDictation());
    statuses.clear();

    assert(!m->tryDictate());
    assert(m->mode() == Mode::Transcribing);
    assert(statuses.back() == AppStatus::Beep);

    printf("test_dictate_rejected_during_transcribing: OK\n");
}

static void test_dictate_rejected_during_finalizing() {
    auto m = makeMachine();
    assert(m->tryRecord());
    assert(m->stopRecord());
    statuses.clear();

    assert(!m->tryDictate());
    assert(m->mode() == Mode::Finalizing);
    assert(statuses.back() == AppStatus::Beep);

    printf("test_dictate_rejected_during_finalizing: OK\n");
}

static void test_double_dictate_rejected() {
    auto m = makeMachine();
    assert(m->tryDictate());
    statuses.clear();

    assert(!m->tryDictate());
    assert(m->mode() == Mode::Dictating);
    assert(statuses.back() == AppStatus::Beep);

    printf("test_double_dictate_rejected: OK\n");
}

static void test_record_rejected_during_dictation() {
    auto m = makeMachine();
    assert(m->tryDictate());

    assert(!m->tryRecord());
    assert(m->mode() == Mode::Dictating);

    printf("test_record_rejected_during_dictation: OK\n");
}

static void test_double_record_rejected() {
    auto m = makeMachine();
    assert(m->tryRecord());

    assert(!m->tryRecord());
    assert(m->mode() == Mode::Recording);

    printf("test_double_record_rejected: OK\n");
}

static void test_stop_record_when_idle() {
    auto m = makeMachine();

    assert(!m->stopRecord());
    assert(m->mode() == Mode::Idle);

    printf("test_stop_record_when_idle: OK\n");
}

static void test_finish_dictation_when_idle() {
    auto m = makeMachine();

    assert(!m->finishDictation());
    assert(m->mode() == Mode::Idle);

    printf("test_finish_dictation_when_idle: OK\n");
}

// ── reset / queries ──────────────────────────────────────────────────────────

static void test_reset_from_any_state() {
    auto m = makeMachine();

    assert(m->tryDictate());
    m->reset();
    assert(m->mode() == Mode::Idle);

    assert(m->tryRecord());
    m->reset();
    assert(m->mode() == Mode::Idle);

    assert(m->tryRecord());
    assert(m->stopRecord());
    m->reset();
    assert(m->mode() == Mode::Idle);

    assert(m->tryDictate());
    assert(m.finishDictation());
    m->reset();
    assert(m->mode() == Mode::Idle);

    printf("test_reset_from_any_state: OK\n");
}

static void test_isDictating() {
    auto m = makeMachine();
    assert(!m->isDictating());

    assert(m->tryDictate());
    assert(m->isDictating());

    assert(m.finishDictation());
    assert(!m->isDictating());

    printf("test_isDictating: OK\n");
}

// ── main ─────────────────────────────────────────────────────────────────────

int main() {
    test_dictation_flow();
    test_dictation_cancel();
    test_recording_flow();
    test_dictate_rejected_during_recording();
    test_dictate_rejected_during_transcribing();
    test_dictate_rejected_during_finalizing();
    test_double_dictate_rejected();
    test_record_rejected_during_dictation();
    test_double_record_rejected();
    test_stop_record_when_idle();
    test_finish_dictation_when_idle();
    test_reset_from_any_state();
    test_isDictating();

    puts("\nmode_machine_test: all assertions passed");
    return 0;
}
