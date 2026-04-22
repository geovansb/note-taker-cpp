#include <atomic>
#include <cassert>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "whisper_worker.h"
#include "constants.h"

// Fake transcriber: returns the chunk size as text so we can verify ordering.
static TranscribeFunc makeFakeTranscriber() {
    return [](const float*, int n_samples,
              const std::string&, bool) -> TranscribeResult {
        return {true, {{0, 100, std::to_string(n_samples)}}};
    };
}

// Helper: wait for a condition with timeout. Returns true if condition met.
template <typename Pred>
static bool waitFor(Pred pred, int timeout_ms = 2000) {
    auto deadline = std::chrono::steady_clock::now()
                  + std::chrono::milliseconds(timeout_ms);
    while (!pred()) {
        if (std::chrono::steady_clock::now() >= deadline) return false;
        std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
    return true;
}

// ── Test 1: dictation callback fires with correct text ───────────────────────

static void test_dictation_callback() {
    std::string received;
    std::mutex mu;
    std::condition_variable cv;
    bool done = false;

    WhisperWorker worker(makeFakeTranscriber(), "auto", false);
    worker.setOnResult([&](const std::string& text) {
        std::lock_guard<std::mutex> lock(mu);
        received = text;
        done = true;
        cv.notify_one();
    });
    assert(worker.start());

    // Enqueue a dictation chunk of 100 samples.
    std::vector<float> chunk(100, 0.0f);
    worker.enqueue(std::move(chunk), 1000, /*is_dictation=*/true);

    {
        std::unique_lock<std::mutex> lock(mu);
        cv.wait_for(lock, std::chrono::seconds(2), [&] { return done; });
    }
    assert(done && "on_result must fire for dictation chunk");
    assert(received == "100" && "text should be chunk size from fake transcriber");

    worker.stop();
    printf("test_dictation_callback: OK\n");
}

// ── Test 2: FIFO ordering ────────────────────────────────────────────────────

static void test_fifo_ordering() {
    std::vector<std::string> results;
    std::mutex mu;
    std::atomic<int> count{0};

    WhisperWorker worker(makeFakeTranscriber(), "auto", false);
    worker.setOnResult([&](const std::string& text) {
        std::lock_guard<std::mutex> lock(mu);
        results.push_back(text);
        count++;
    });
    assert(worker.start());

    // Enqueue 3 dictation chunks with different sizes to track order.
    for (int n : {10, 20, 30}) {
        std::vector<float> chunk(static_cast<size_t>(n), 0.0f);
        worker.enqueue(std::move(chunk), 1000, true);
    }

    assert(waitFor([&] { return count.load() >= 3; }));
    worker.stop();

    std::lock_guard<std::mutex> lock(mu);
    assert(results.size() == 3);
    assert(results[0] == "10");
    assert(results[1] == "20");
    assert(results[2] == "30");
    printf("test_fifo_ordering: OK\n");
}

// ── Test 3: drop-oldest on overflow + on_error fires ─────────────────────────

static void test_drop_oldest() {
    // Use a slow transcriber that blocks so the queue actually fills up.
    std::mutex gate_mu;
    std::condition_variable gate_cv;
    bool gate_open = false;

    TranscribeFunc slow = [&](const float*, int n_samples,
                              const std::string&, bool) -> TranscribeResult {
        // Block on the first call until the test opens the gate.
        if (n_samples == 1) {
            std::unique_lock<std::mutex> lock(gate_mu);
            gate_cv.wait(lock, [&] { return gate_open; });
        }
        return {true, {{0, 100, std::to_string(n_samples)}}};
    };

    std::atomic<int> error_count{0};
    std::vector<std::string> results;
    std::mutex results_mu;

    WhisperWorker worker(slow, "auto", false);
    worker.setOnError([&](const std::string&) { error_count++; });
    worker.setOnResult([&](const std::string& text) {
        std::lock_guard<std::mutex> lock(results_mu);
        results.push_back(text);
    });
    assert(worker.start());

    // Enqueue a blocking chunk (size=1) that holds the worker.
    worker.enqueue(std::vector<float>(1, 0.0f), 1000, true);

    // Give the worker a moment to pick up the blocking chunk.
    std::this_thread::sleep_for(std::chrono::milliseconds(50));

    // Now fill the queue to PROCESSING_QUEUE_MAX, then overflow by 2.
    for (int i = 0; i < PROCESSING_QUEUE_MAX + 2; i++) {
        worker.enqueue(std::vector<float>(static_cast<size_t>(100 + i), 0.0f), 1000, true);
    }

    // The 2 overflow items should have triggered drop-oldest + on_error.
    assert(error_count.load() >= 2 && "on_error must fire on overflow");

    // Release the gate so the worker can drain.
    {
        std::lock_guard<std::mutex> lock(gate_mu);
        gate_open = true;
    }
    gate_cv.notify_all();

    worker.stop();
    printf("test_drop_oldest: OK\n");
}

// ── Test 4: session-done fires when queue drains ─────────────────────────────

static void test_session_done() {
    std::atomic<int> processed{0};
    std::atomic<bool> session_done_fired{false};

    // Fake that counts processed session (non-dictation) chunks.
    TranscribeFunc counter = [&](const float*, int,
                                 const std::string&, bool) -> TranscribeResult {
        processed++;
        return {true, {{0, 100, "seg"}}};
    };

    WhisperWorker worker(counter, "auto", false);
    assert(worker.start());

    // Enqueue 5 session chunks.
    for (int i = 0; i < 5; i++) {
        worker.enqueue(std::vector<float>(100, 0.0f), 1000, /*is_dictation=*/false);
    }

    // Set session-done callback. It should fire after all 5 are processed.
    worker.setOnSessionDone([&] {
        session_done_fired.store(true);
    });

    assert(waitFor([&] { return session_done_fired.load(); }));
    assert(processed.load() == 5 && "all 5 session chunks must be processed before done fires");

    worker.stop();
    printf("test_session_done: OK\n");
}

// ── Test 5: session-done fires immediately if queue already empty ────────────

static void test_session_done_immediate() {
    std::atomic<bool> fired{false};

    WhisperWorker worker(makeFakeTranscriber(), "auto", false);
    assert(worker.start());

    // No items enqueued — session done should fire immediately.
    worker.setOnSessionDone([&] { fired.store(true); });

    assert(waitFor([&] { return fired.load(); }));

    worker.stop();
    printf("test_session_done_immediate: OK\n");
}

// ── Test 6: on_error fires on transcription failure ──────────────────────────

static void test_transcription_error() {
    TranscribeFunc failing = [](const float*, int,
                                const std::string&, bool) -> TranscribeResult {
        return {false, {}};
    };

    std::atomic<bool> error_fired{false};

    WhisperWorker worker(failing, "auto", false);
    worker.setOnError([&](const std::string&) { error_fired.store(true); });
    assert(worker.start());

    worker.enqueue(std::vector<float>(100, 0.0f), 1000, true);

    assert(waitFor([&] { return error_fired.load(); }));

    worker.stop();
    printf("test_transcription_error: OK\n");
}

// ── Test 7: stop() drains queue before returning ─────────────────────────────

static void test_stop_drains() {
    std::atomic<int> processed{0};

    TranscribeFunc counter = [&](const float*, int,
                                 const std::string&, bool) -> TranscribeResult {
        processed++;
        return {true, {{0, 100, "x"}}};
    };

    WhisperWorker worker(counter, "auto", false);
    assert(worker.start());

    for (int i = 0; i < 10; i++) {
        worker.enqueue(std::vector<float>(100, 0.0f), 1000, true);
    }

    worker.stop();  // must drain all 10 before returning
    assert(processed.load() == 10 && "stop() must drain all queued items");
    printf("test_stop_drains: OK\n");
}

// ── main ─────────────────────────────────────────────────────────────────────

int main() {
    test_dictation_callback();
    test_fifo_ordering();
    test_drop_oldest();
    test_session_done();
    test_session_done_immediate();
    test_transcription_error();
    test_stop_drains();

    puts("\nwhisper_worker_test: all assertions passed");
    return 0;
}
