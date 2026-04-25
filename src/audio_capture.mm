#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include "audio_capture.h"
#include "constants.h"
#include <cstdio>

struct AudioCapture::Impl {
    AVAudioEngine*    engine    = nil;
    AVAudioConverter* converter = nil;
    AVAudioPCMBuffer* outBuf   = nil;  // reused across tap callbacks
    id                configObserver = nil;
    bool              permission_checked = false;
    bool              permission_granted = false;
    AudioStartError   last_start_error = AudioStartError::None;
    std::function<void()> on_config_change;
    std::function<void()> on_recovery_failed;
    std::function<void(const float*, size_t)> on_block; // kept for tap reinstall

    void resetEngineState() {
        if (configObserver) {
            [[NSNotificationCenter defaultCenter] removeObserver:configObserver];
            configObserver = nil;
        }
        if (engine) {
            @try {
                [engine.inputNode removeTapOnBus:0];
            } @catch (__unused NSException* ex) {
                // start() can fail before a tap is installed; teardown must stay best-effort.
            }
            [engine stop];
            engine = nil;
        }
        converter = nil;
        outBuf    = nil;
    }

    // (Re)install tap + converter on the current engine's input node.
    // Called from start() and from the config-change notification handler.
    bool installTap() {
        AVAudioInputNode* inputNode = engine.inputNode;
        [engine prepare];

        AVAudioFormat* hwFormat = [inputNode outputFormatForBus:0];
        fprintf(stderr, "info: hardware format %.0f Hz, %u ch\n",
                hwFormat.sampleRate, (unsigned)hwFormat.channelCount);

        // Reject invalid formats that appear transiently during device changes
        // (e.g. Bluetooth disconnect → 0 Hz / 0 channels).
        if (hwFormat.sampleRate < 1.0 || hwFormat.channelCount == 0) {
            fprintf(stderr, "warn: invalid hardware format — device not ready\n");
            last_start_error = AudioStartError::InvalidDeviceFormat;
            return false;
        }

        AVAudioFormat* targetFormat = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatFloat32
                      sampleRate:CAPTURE_SAMPLE_RATE
                        channels:1
                     interleaved:NO];

        converter = [[AVAudioConverter alloc] initFromFormat:hwFormat toFormat:targetFormat];
        if (!converter) {
            fprintf(stderr, "error: could not create AVAudioConverter "
                            "(%.0fHz %uch → %dHz 1ch)\n",
                    hwFormat.sampleRate, (unsigned)hwFormat.channelCount,
                    CAPTURE_SAMPLE_RATE);
            last_start_error = AudioStartError::ConverterFailed;
            return false;
        }

        AVAudioFrameCount outCapacity =
            (AVAudioFrameCount)(4096 * targetFormat.sampleRate / hwFormat.sampleRate) + 2;
        outBuf = [[AVAudioPCMBuffer alloc]
            initWithPCMFormat:targetFormat frameCapacity:outCapacity];

        AVAudioConverter* conv = converter;
        AVAudioPCMBuffer* reusableBuf = outBuf;
        auto callback = on_block;

        // installTapOnBus: throws NSException on invalid state (format mismatch,
        // device gone, tap already installed). Catch to return false instead of
        // crashing — the retry loop in the config-change handler will try again.
        @try {
            [inputNode installTapOnBus:0
                            bufferSize:4096
                                format:hwFormat
                                 block:^(AVAudioPCMBuffer* inBuf, AVAudioTime*) {
                @autoreleasepool {
                    reusableBuf.frameLength = 0;

                    __block BOOL consumed = NO;
                    NSError* convErr = nil;
                    [conv convertToBuffer:reusableBuf
                                    error:&convErr
                      withInputFromBlock:^AVAudioBuffer*(AVAudioPacketCount,
                                                         AVAudioConverterInputStatus* status) {
                        if (consumed) {
                            *status = AVAudioConverterInputStatus_NoDataNow;
                            return nil;
                        }
                        consumed = YES;
                        *status = AVAudioConverterInputStatus_HaveData;
                        return inBuf;
                    }];

                    if (!convErr && reusableBuf.frameLength > 0) {
                        callback(reusableBuf.floatChannelData[0], reusableBuf.frameLength);
                    }
                }
            }];
        } @catch (NSException* ex) {
            fprintf(stderr, "warn: installTapOnBus threw: %s — %s\n",
                    ex.name.UTF8String, ex.reason.UTF8String);
            last_start_error = AudioStartError::TapInstallFailed;
            return false;
        }
        return true;
    }
};

AudioCapture::AudioCapture() : impl_(new Impl()) {}

AudioCapture::~AudioCapture() {
    stop();
    delete impl_;
}

bool AudioCapture::start(std::function<void(const float*, size_t)> on_block) {
    impl_->last_start_error = AudioStartError::None;

    // Request microphone permission once per process. The result is cached so
    // subsequent start() calls skip the semaphore wait entirely. This avoids a
    // potential deadlock: requestAccessForMediaType: may dispatch its completion
    // handler to the main queue when the result is already cached, and if the
    // caller is also on the main queue, dispatch_semaphore_wait blocks it.
    if (!impl_->permission_checked) {
        __block bool granted = false;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                                 completionHandler:^(BOOL g) {
            granted = g;
            dispatch_semaphore_signal(sem);
        }];
        dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        impl_->permission_checked = true;
        impl_->permission_granted = granted;
    }

    if (!impl_->permission_granted) {
        fprintf(stderr, "error: microphone permission denied — "
                        "enable in System Settings > Privacy > Microphone\n");
        impl_->last_start_error = AudioStartError::PermissionDenied;
        return false;
    }

    // If a previous start attempt failed after partially initializing the
    // engine, clear it out before we try again.
    impl_->resetEngineState();

    impl_->on_block = on_block;
    impl_->engine = [[AVAudioEngine alloc] init];

    // Access inputNode BEFORE prepare/start: it is lazily initialised on first
    // access. If prepare is called before this, the engine graph has no nodes
    // and throws "required condition is false: inputNode != nullptr".
    (void)impl_->engine.inputNode;

    if (!impl_->installTap()) {
        impl_->resetEngineState();
        return false;
    }

    // Monitor audio configuration changes (device unplug, format change).
    // On change: tear down old tap/converter, reconfigure for new hardware, reinstall.
    Impl* p = impl_;
    impl_->configObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVAudioEngineConfigurationChangeNotification
                    object:impl_->engine
                     queue:nil
                usingBlock:^(NSNotification*) {
        fprintf(stderr, "warn: audio configuration changed — reconfiguring…\n");
        // Remove old tap before reinstalling with the new format.
        [p->engine.inputNode removeTapOnBus:0];
        p->converter = nil;
        p->outBuf    = nil;

        // Retry with backoff — the new device may not be ready immediately.
        static const int    kMaxRetries = 3;
        static const double kBackoffMs[] = { 200, 500, 1000 };
        bool recovered = false;

        for (int attempt = 0; attempt < kMaxRetries; ++attempt) {
            if (attempt > 0) {
                fprintf(stderr, "info: retry %d/%d after %.0fms…\n",
                        attempt + 1, kMaxRetries, kBackoffMs[attempt]);
                [NSThread sleepForTimeInterval:kBackoffMs[attempt] / 1000.0];
                // Re-prepare engine so it picks up the new device.
                [p->engine.inputNode removeTapOnBus:0];
                p->converter = nil;
                p->outBuf    = nil;
            }

            if (!p->installTap()) {
                fprintf(stderr, "warn: installTap failed (attempt %d/%d)\n",
                        attempt + 1, kMaxRetries);
                continue;
            }

            NSError* restartErr = nil;
            [p->engine startAndReturnError:&restartErr];
            if (restartErr) {
                fprintf(stderr, "warn: engine restart failed (attempt %d/%d): %s\n",
                        attempt + 1, kMaxRetries,
                        restartErr.localizedDescription.UTF8String);
                continue;
            }

            recovered = true;
            fprintf(stderr, "info: audio capture resumed after config change\n");
            break;
        }

        if (!recovered) {
            fprintf(stderr, "error: audio recovery failed after %d attempts — "
                            "restart required\n", kMaxRetries);
            if (p->on_recovery_failed) p->on_recovery_failed();
        }
        if (p->on_config_change) p->on_config_change();
    }];

    NSError* err = nil;
    [impl_->engine startAndReturnError:&err];
    if (err) {
        fprintf(stderr, "error: AVAudioEngine failed to start: %s\n",
                err.localizedDescription.UTF8String);
        impl_->last_start_error = AudioStartError::EngineStartFailed;
        impl_->resetEngineState();
        return false;
    }

    return true;
}

void AudioCapture::stop() {
    impl_->resetEngineState();
}

AudioStartError AudioCapture::lastStartError() const {
    return impl_->last_start_error;
}

void AudioCapture::setOnConfigChange(std::function<void()> cb) {
    impl_->on_config_change = std::move(cb);
}

void AudioCapture::setOnRecoveryFailed(std::function<void()> cb) {
    impl_->on_recovery_failed = std::move(cb);
}

std::vector<std::string> AudioCapture::listDevices() {
    std::vector<std::string> result;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<AVCaptureDevice*>* devices =
        [AVCaptureDevice devicesWithMediaType:AVMediaTypeAudio];
#pragma clang diagnostic pop

    int idx = 0;
    for (AVCaptureDevice* dev in devices) {
        std::string entry = std::to_string(idx++) + ": " +
                            std::string(dev.localizedName.UTF8String) +
                            " [" + std::string(dev.uniqueID.UTF8String) + "]";
        result.push_back(entry);
    }
    return result;
}
