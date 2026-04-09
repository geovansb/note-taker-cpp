#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#include "audio_capture.h"
#include "constants.h"
#include <cstdio>

struct AudioCapture::Impl {
    AVAudioEngine*    engine    = nil;
    AVAudioConverter* converter = nil;
};

AudioCapture::AudioCapture() : impl_(new Impl()) {}

AudioCapture::~AudioCapture() {
    stop();
    delete impl_;
}

bool AudioCapture::start(std::function<void(const float*, size_t)> on_block) {
    // Request microphone permission synchronously.
    __block bool granted = false;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeAudio
                             completionHandler:^(BOOL g) {
        granted = g;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);

    if (!granted) {
        fprintf(stderr, "error: microphone permission denied — "
                        "enable in System Settings > Privacy > Microphone\n");
        return false;
    }

    impl_->engine = [[AVAudioEngine alloc] init];

    // Access inputNode BEFORE prepare/start: it is lazily initialised on first
    // access. If prepare is called before this, the engine graph has no nodes
    // and throws "required condition is false: inputNode != nullptr".
    AVAudioInputNode* inputNode = impl_->engine.inputNode;

    // prepare() finalises the hardware connection. Query the format after.
    [impl_->engine prepare];

    AVAudioFormat* hwFormat = [inputNode outputFormatForBus:0];

    fprintf(stderr, "info: hardware format %.0f Hz, %u ch\n",
            hwFormat.sampleRate, (unsigned)hwFormat.channelCount);

    AVAudioFormat* targetFormat = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
                  sampleRate:CAPTURE_SAMPLE_RATE
                    channels:1
                 interleaved:NO];

    impl_->converter = [[AVAudioConverter alloc]
        initFromFormat:hwFormat toFormat:targetFormat];

    if (!impl_->converter) {
        fprintf(stderr, "error: could not create AVAudioConverter "
                        "(%.0fHz %uch → %dHz 1ch)\n",
                hwFormat.sampleRate, (unsigned)hwFormat.channelCount,
                CAPTURE_SAMPLE_RATE);
        return false;
    }

    // macOS requires the tap format to exactly match the inputNode's hardware format.
    // We convert to 16kHz mono float32 explicitly inside the callback.
    AVAudioConverter* conv = impl_->converter; // strong capture for the block
    [inputNode installTapOnBus:0
                    bufferSize:4096
                        format:hwFormat
                         block:^(AVAudioPCMBuffer* inBuf, AVAudioTime*) {
        @autoreleasepool {
            AVAudioFrameCount outCapacity =
                (AVAudioFrameCount)(inBuf.frameLength *
                                    targetFormat.sampleRate / hwFormat.sampleRate) + 2;

            AVAudioPCMBuffer* outBuf = [[AVAudioPCMBuffer alloc]
                initWithPCMFormat:targetFormat frameCapacity:outCapacity];

            __block BOOL consumed = NO;
            NSError* convErr = nil;
            [conv convertToBuffer:outBuf
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

            if (!convErr && outBuf.frameLength > 0) {
                on_block(outBuf.floatChannelData[0], outBuf.frameLength);
            }
        }
    }];

    NSError* err = nil;
    [impl_->engine startAndReturnError:&err];
    if (err) {
        fprintf(stderr, "error: AVAudioEngine failed to start: %s\n",
                err.localizedDescription.UTF8String);
        return false;
    }

    return true;
}

void AudioCapture::stop() {
    if (impl_->engine) {
        [impl_->engine.inputNode removeTapOnBus:0];
        [impl_->engine stop];
        impl_->converter = nil;
        impl_->engine    = nil;
    }
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
