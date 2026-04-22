#include "mode_machine.h"

bool ModeMachine::tryDictate() {
    int expected = static_cast<int>(Mode::Idle);
    if (!state_.compare_exchange_strong(expected, static_cast<int>(Mode::Dictating))) {
        emit(AppStatus::Beep);
        return false;
    }
    emit(AppStatus::Dictating);
    return true;
}

bool ModeMachine::cancelDictation() {
    int expected = static_cast<int>(Mode::Dictating);
    if (!state_.compare_exchange_strong(expected, static_cast<int>(Mode::Idle)))
        return false;
    emit(AppStatus::Idle);
    return true;
}

bool ModeMachine::finishDictation() {
    int expected = static_cast<int>(Mode::Dictating);
    if (!state_.compare_exchange_strong(expected, static_cast<int>(Mode::Transcribing)))
        return false;
    emit(AppStatus::Transcribing);
    return true;
}

void ModeMachine::transcriptionDone() {
    state_.store(static_cast<int>(Mode::Idle));
    emit(AppStatus::Idle);
}

bool ModeMachine::tryRecord() {
    int expected = static_cast<int>(Mode::Idle);
    if (!state_.compare_exchange_strong(expected, static_cast<int>(Mode::Recording)))
        return false;
    emit(AppStatus::RecordingListening);
    return true;
}

bool ModeMachine::stopRecord() {
    int expected = static_cast<int>(Mode::Recording);
    if (!state_.compare_exchange_strong(expected, static_cast<int>(Mode::Finalizing)))
        return false;
    emit(AppStatus::Finalizing);
    return true;
}

void ModeMachine::finalizeDone() {
    state_.store(static_cast<int>(Mode::Idle));
    emit(AppStatus::Idle);
}

void ModeMachine::reset() {
    state_.store(static_cast<int>(Mode::Idle));
}
