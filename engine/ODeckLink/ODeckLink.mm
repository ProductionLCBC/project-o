// ODeckLink — Spec 4 §10 and §14: the Objective-C++ wrapper over the Blackmagic
// Desktop Video SDK. Built only when vendor/DeckLinkSDK is present
// (Package.swift); otherwise ODeckLinkStub.c stands in.
//
// "Objective-C++ is confined to the DeckLink module." This file is the only
// place C++ is allowed. It implements the C face in ODeckLink.h over the SDK's
// COM-style interfaces: open a card by its persistent id, find the display mode
// that matches the output's format, enable video (v210 or BGRA) and embedded
// audio, schedule frames over the engine's own MTLBuffer memory through a
// caller-implemented frame object (Spec 4 §10: "a custom frame buffer object"),
// schedule audio against the same stream time, read the hardware clock and the
// reference status, and hand completions back on the SDK's thread.
//
// The SDK's dispatch file is compiled into this unit: it loads
// /Library/Frameworks/DeckLinkAPI.framework at run time, so a Mac without the
// Desktop Video driver reports every card as unavailable and the engine runs
// on with the sink paused (Spec 4 §12).

#include "ODeckLink.h"

#if ODL_HAVE_SDK

#include "DeckLinkAPI.h"
#include "DeckLinkAPIDispatch.cpp"

#include <atomic>
#include <cctype>
#include <cstdlib>
#include <cstring>

namespace {

bool succeeded(HRESULT hr) { return hr >= 0; }

bool sameIID(REFIID a, REFIID b) { return std::memcmp(&a, &b, sizeof(CFUUIDBytes)) == 0; }

CFUUIDBytes unknownIID() { return CFUUIDGetUUIDBytes(IUnknownUUID); }

/// Spec 4 §10 — "an MTLBuffer with shared storage that the card reads by DMA
/// through a custom frame buffer object": a frame over memory the engine owns
/// and keeps valid until the completion callback.
class Frame final : public IDeckLinkVideoFrame, public IDeckLinkVideoBuffer {
public:
    Frame(const void *bytes, long width, long height, long rowBytes, BMDPixelFormat format, void *context)
        : bytes_(bytes), width_(width), height_(height), rowBytes_(rowBytes), format_(format), context_(context) {}

    void *context() const { return context_; }

    // IUnknown
    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (!ppv) return E_FAIL;
        if (sameIID(iid, unknownIID()) || sameIID(iid, IID_IDeckLinkVideoFrame)) {
            *ppv = static_cast<IDeckLinkVideoFrame *>(this);
            AddRef();
            return S_OK;
        }
        if (sameIID(iid, IID_IDeckLinkVideoBuffer)) {
            *ppv = static_cast<IDeckLinkVideoBuffer *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refs_; }
    ULONG Release() override {
        ULONG remaining = --refs_;
        if (remaining == 0) delete this;
        return remaining;
    }

    // IDeckLinkVideoFrame
    long GetWidth() override { return width_; }
    long GetHeight() override { return height_; }
    long GetRowBytes() override { return rowBytes_; }
    BMDPixelFormat GetPixelFormat() override { return format_; }
    BMDFrameFlags GetFlags() override { return bmdFrameFlagDefault; }
    HRESULT GetTimecode(BMDTimecodeFormat, IDeckLinkTimecode **timecode) override {
        if (timecode) *timecode = nullptr;
        return S_FALSE;
    }
    HRESULT GetAncillaryData(IDeckLinkVideoFrameAncillary **ancillary) override {
        if (ancillary) *ancillary = nullptr;
        return S_FALSE;
    }

    // IDeckLinkVideoBuffer
    HRESULT GetBytes(void **buffer) override {
        if (!buffer) return E_FAIL;
        *buffer = const_cast<void *>(bytes_);
        return S_OK;
    }
    HRESULT GetSize(uint64_t *size) override {
        if (!size) return E_FAIL;
        *size = static_cast<uint64_t>(rowBytes_) * static_cast<uint64_t>(height_);
        return S_OK;
    }
    HRESULT StartAccess(BMDBufferAccessFlags) override { return S_OK; }
    HRESULT EndAccess(BMDBufferAccessFlags) override { return S_OK; }

private:
    ~Frame() override = default;

    std::atomic<ULONG> refs_{1};
    const void *bytes_;
    long width_;
    long height_;
    long rowBytes_;
    BMDPixelFormat format_;
    void *context_;
};

odl_completion_t mapCompletion(BMDOutputFrameCompletionResult result) {
    switch (result) {
    case bmdOutputFrameCompleted: return ODL_COMPLETED;
    case bmdOutputFrameDisplayedLate: return ODL_DISPLAYED_LATE;
    case bmdOutputFrameDropped: return ODL_DROPPED;
    case bmdOutputFrameFlushed: return ODL_FLUSHED;
    }
    return ODL_FLUSHED;
}

} // namespace

struct odl_device {
    IDeckLink *deckLink = nullptr;
    IDeckLinkOutput *output = nullptr;
    IDeckLinkStatus *status = nullptr;
    IDeckLinkVideoOutputCallback *callback = nullptr;
    odl_frame_completed_cb onCompleted = nullptr;
    odl_playback_stopped_cb onStopped = nullptr;
    void *context = nullptr;
    BMDPixelFormat pixelFormat = bmdFormat10BitYUV;
    long width = 0;
    long height = 0;
    bool videoEnabled = false;
    bool audioEnabled = false;
    std::atomic<bool> playing{false};
    BMDTimeScale timeScale = 1000;
};

namespace {

/// Spec 4 §10 — "the completion callback reports completed, displayedLate,
/// dropped or flushed per frame": the SDK's thread lands here and the sink's
/// C callback takes it from there.
class Callback final : public IDeckLinkVideoOutputCallback {
public:
    explicit Callback(odl_device *owner) : owner_(owner) {}

    HRESULT QueryInterface(REFIID iid, LPVOID *ppv) override {
        if (!ppv) return E_FAIL;
        if (sameIID(iid, unknownIID()) || sameIID(iid, IID_IDeckLinkVideoOutputCallback)) {
            *ppv = static_cast<IDeckLinkVideoOutputCallback *>(this);
            AddRef();
            return S_OK;
        }
        *ppv = nullptr;
        return E_NOINTERFACE;
    }
    ULONG AddRef() override { return ++refs_; }
    ULONG Release() override {
        ULONG remaining = --refs_;
        if (remaining == 0) delete this;
        return remaining;
    }

    HRESULT ScheduledFrameCompleted(IDeckLinkVideoFrame *completedFrame, BMDOutputFrameCompletionResult result) override {
        // Every frame the card completes is one of ours (odl_schedule_video), so the downcast holds.
        Frame *frame = static_cast<Frame *>(completedFrame);
        if (owner_ && owner_->onCompleted) {
            owner_->onCompleted(owner_->context, frame ? frame->context() : nullptr, mapCompletion(result));
        }
        return S_OK;
    }

    HRESULT ScheduledPlaybackHasStopped() override {
        if (owner_) {
            owner_->playing.store(false);
            if (owner_->onStopped) owner_->onStopped(owner_->context);
        }
        return S_OK;
    }

    void detach() { owner_ = nullptr; }

private:
    ~Callback() override = default;

    std::atomic<ULONG> refs_{1};
    odl_device *owner_;
};

/// Spec 1 §3 — "DeckLink port persistent ID": the fixture writes it as hex
/// ("decklink:8f3a21c0" becomes "8f3a21c0"); the SDK reports an int64. Match
/// the hex reading, the decimal reading, or the card's display name.
bool matches(IDeckLink *deckLink, const char *persistentID) {
    if (!persistentID || !*persistentID) return true;   // no id: the first card
    bool allHex = true;
    for (const char *p = persistentID; *p; ++p) {
        if (!std::isxdigit(static_cast<unsigned char>(*p))) { allHex = false; break; }
    }
    IDeckLinkProfileAttributes *attributes = nullptr;
    if (succeeded(deckLink->QueryInterface(IID_IDeckLinkProfileAttributes, reinterpret_cast<void **>(&attributes))) && attributes) {
        int64_t reported = 0;
        bool have = succeeded(attributes->GetInt(BMDDeckLinkPersistentID, &reported));
        attributes->Release();
        if (have) {
            if (allHex && static_cast<uint64_t>(reported) == std::strtoull(persistentID, nullptr, 16)) return true;
            char *end = nullptr;
            long long decimal = std::strtoll(persistentID, &end, 10);
            if (end && *end == '\0' && decimal == reported) return true;
        }
    }
    CFStringRef name = nullptr;
    bool named = false;
    if (succeeded(deckLink->GetDisplayName(&name)) && name) {
        CFStringRef wanted = CFStringCreateWithCString(kCFAllocatorDefault, persistentID, kCFStringEncodingUTF8);
        if (wanted) {
            named = CFStringCompare(name, wanted, 0) == kCFCompareEqualTo;
            CFRelease(wanted);
        }
        CFRelease(name);
    }
    return named;
}

BMDPixelFormat pixelFormat(odl_pixel_format_t format) {
    switch (format) {
    case ODL_PIXEL_V210: return bmdFormat10BitYUV;
    case ODL_PIXEL_BGRA8: return bmdFormat8BitBGRA;
    }
    return bmdFormat10BitYUV;
}

/// Spec 1 §3 — an output `format` names width, height, rate and interlace; the
/// card names modes. The first mode with the same size, the same rate as a
/// ratio, and the right field dominance is the one.
bool findMode(IDeckLinkOutput *output, odl_mode_t mode, BMDDisplayMode *found) {
    IDeckLinkDisplayModeIterator *iterator = nullptr;
    if (!succeeded(output->GetDisplayModeIterator(&iterator)) || !iterator) return false;
    bool matched = false;
    IDeckLinkDisplayMode *candidate = nullptr;
    while (!matched && succeeded(iterator->Next(&candidate)) && candidate) {
        BMDTimeValue duration = 0;
        BMDTimeScale scale = 0;
        bool sizeOK = candidate->GetWidth() == mode.width && candidate->GetHeight() == mode.height;
        bool rateOK = succeeded(candidate->GetFrameRate(&duration, &scale)) && duration > 0 && scale > 0 &&
                      duration * static_cast<int64_t>(mode.rate_num) == scale * static_cast<int64_t>(mode.rate_den);
        BMDFieldDominance dominance = candidate->GetFieldDominance();
        bool fieldsOK = mode.interlaced ? (dominance == bmdUpperFieldFirst || dominance == bmdLowerFieldFirst)
                                        : dominance == bmdProgressiveFrame;
        if (sizeOK && rateOK && fieldsOK) {
            *found = candidate->GetDisplayMode();
            matched = true;
        }
        candidate->Release();
        candidate = nullptr;
    }
    iterator->Release();
    return matched;
}

} // namespace

extern "C" {

bool odl_sdk_available(void) {
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) return false;
    iterator->Release();
    return true;
}

odl_status_t odl_open(const char *persistent_id, odl_device_t **out_device) {
    if (out_device) *out_device = nullptr;
    if (!out_device) return ODL_ERR_INTERNAL;
    IDeckLinkIterator *iterator = CreateDeckLinkIteratorInstance();
    if (!iterator) return ODL_ERR_UNAVAILABLE;
    IDeckLink *deckLink = nullptr;
    IDeckLink *chosen = nullptr;
    bool any = false;
    while (succeeded(iterator->Next(&deckLink)) && deckLink) {
        any = true;
        if (!chosen && matches(deckLink, persistent_id)) {
            chosen = deckLink;
        } else {
            deckLink->Release();
        }
        deckLink = nullptr;
    }
    iterator->Release();
    if (!any) return ODL_ERR_UNAVAILABLE;
    if (!chosen) return ODL_ERR_NOT_FOUND;

    IDeckLinkOutput *output = nullptr;
    if (!succeeded(chosen->QueryInterface(IID_IDeckLinkOutput, reinterpret_cast<void **>(&output))) || !output) {
        chosen->Release();
        return ODL_ERR_UNAVAILABLE;   // a card with no output
    }
    odl_device *device = new odl_device();
    device->deckLink = chosen;
    device->output = output;
    IDeckLinkStatus *status = nullptr;
    if (succeeded(chosen->QueryInterface(IID_IDeckLinkStatus, reinterpret_cast<void **>(&status))) && status) {
        device->status = status;
    }
    *out_device = device;
    return ODL_OK;
}

void odl_close(odl_device_t *device) {
    if (!device) return;
    if (device->playing.load()) {
        BMDTimeValue actual = 0;
        device->output->StopScheduledPlayback(0, &actual, device->timeScale);
        device->playing.store(false);
    }
    if (device->audioEnabled) device->output->DisableAudioOutput();
    if (device->videoEnabled) device->output->DisableVideoOutput();
    device->output->SetScheduledFrameCompletionCallback(nullptr);
    if (device->callback) {
        static_cast<Callback *>(device->callback)->detach();
        device->callback->Release();
    }
    if (device->status) device->status->Release();
    device->output->Release();
    device->deckLink->Release();
    delete device;
}

odl_status_t odl_set_callbacks(odl_device_t *device, odl_frame_completed_cb on_completed,
                               odl_playback_stopped_cb on_stopped, void *context) {
    if (!device) return ODL_ERR_STATE;
    device->onCompleted = on_completed;
    device->onStopped = on_stopped;
    device->context = context;
    if (!device->callback) {
        device->callback = new Callback(device);
        if (!succeeded(device->output->SetScheduledFrameCompletionCallback(device->callback))) {
            device->callback->Release();
            device->callback = nullptr;
            return ODL_ERR_INTERNAL;
        }
    }
    return ODL_OK;
}

odl_status_t odl_enable_output(odl_device_t *device, odl_mode_t mode, odl_pixel_format_t format,
                               odl_audio_config_t audio) {
    if (!device) return ODL_ERR_STATE;
    if (device->videoEnabled) return ODL_ERR_STATE;
    BMDDisplayMode displayMode = 0;
    if (!findMode(device->output, mode, &displayMode)) return ODL_ERR_MODE;
    BMDPixelFormat pixel = pixelFormat(format);
    BMDDisplayMode actual = 0;
    bool supported = false;
    HRESULT hr = device->output->DoesSupportVideoMode(bmdVideoConnectionUnspecified, displayMode, pixel, bmdNoVideoOutputConversion,
                                                      bmdSupportedVideoModeDefault, &actual, &supported);
    if (!succeeded(hr) || !supported) return ODL_ERR_MODE;
    if (!succeeded(device->output->EnableVideoOutput(displayMode, bmdVideoOutputFlagDefault))) return ODL_ERR_MODE;
    device->videoEnabled = true;
    device->pixelFormat = pixel;
    device->width = mode.width;
    device->height = mode.height;
    if (audio.channel_count > 0) {
        // Spec 4 §10 — "Embedded audio is enabled on the same output at 48 kHz, 24-bit in 32-bit words,
        // scheduled against the same stream time as the video." A refusal keeps the picture: audio
        // scheduling then reports ODL_ERR_STATE and the sink logs it.
        hr = device->output->EnableAudioOutput(bmdAudioSampleRate48kHz, bmdAudioSampleType32bitInteger,
                                               static_cast<uint32_t>(audio.channel_count), bmdAudioOutputStreamTimestamped);
        device->audioEnabled = succeeded(hr);
    }
    return ODL_OK;
}

odl_status_t odl_disable_output(odl_device_t *device) {
    if (!device) return ODL_ERR_STATE;
    if (!device->videoEnabled) return ODL_ERR_STATE;
    if (device->audioEnabled) {
        device->output->DisableAudioOutput();
        device->audioEnabled = false;
    }
    device->output->DisableVideoOutput();
    device->videoEnabled = false;
    return ODL_OK;
}

odl_status_t odl_start_playback(odl_device_t *device, int64_t start_time, int64_t time_scale) {
    if (!device || !device->videoEnabled) return ODL_ERR_STATE;
    if (device->playing.load()) return ODL_ERR_STATE;
    if (!succeeded(device->output->StartScheduledPlayback(start_time, time_scale, 1.0))) return ODL_ERR_STATE;
    device->timeScale = time_scale;
    device->playing.store(true);
    return ODL_OK;
}

odl_status_t odl_stop_playback(odl_device_t *device) {
    if (!device) return ODL_ERR_STATE;
    if (!device->playing.load()) return ODL_ERR_STATE;
    BMDTimeValue actual = 0;
    HRESULT hr = device->output->StopScheduledPlayback(0, &actual, device->timeScale);
    device->playing.store(false);
    return succeeded(hr) ? ODL_OK : ODL_ERR_STATE;
}

odl_status_t odl_schedule_video(odl_device_t *device, const void *bytes, int32_t row_bytes,
                                int64_t display_time, int64_t duration, int64_t time_scale,
                                void *frame_context) {
    if (!device || !device->videoEnabled) return ODL_ERR_STATE;
    if (!bytes || row_bytes <= 0) return ODL_ERR_SCHEDULE;
    Frame *frame = new Frame(bytes, device->width, device->height, row_bytes, device->pixelFormat, frame_context);
    HRESULT hr = device->output->ScheduleVideoFrame(frame, display_time, duration, time_scale);
    frame->Release();   // the card holds its own reference until the frame completes
    return succeeded(hr) ? ODL_OK : ODL_ERR_SCHEDULE;
}

odl_status_t odl_schedule_audio(odl_device_t *device, const int32_t *samples, uint32_t frame_count,
                                int64_t stream_time, int64_t time_scale, uint32_t *out_written) {
    if (out_written) *out_written = 0;
    if (!device || !device->audioEnabled) return ODL_ERR_STATE;
    if (!samples || frame_count == 0) return ODL_ERR_SCHEDULE;
    uint32_t written = 0;
    HRESULT hr = device->output->ScheduleAudioSamples(const_cast<int32_t *>(samples), frame_count, stream_time, time_scale, &written);
    if (out_written) *out_written = written;
    return succeeded(hr) ? ODL_OK : ODL_ERR_SCHEDULE;
}

odl_status_t odl_hardware_time(odl_device_t *device, int64_t time_scale, int64_t *out_time,
                               int64_t *out_ticks_per_frame) {
    if (out_time) *out_time = 0;
    if (out_ticks_per_frame) *out_ticks_per_frame = 0;
    if (!device) return ODL_ERR_STATE;
    BMDTimeValue hardware = 0;
    BMDTimeValue inFrame = 0;
    BMDTimeValue ticks = 0;
    if (!succeeded(device->output->GetHardwareReferenceClock(time_scale, &hardware, &inFrame, &ticks))) return ODL_ERR_INTERNAL;
    if (out_time) *out_time = hardware;
    if (out_ticks_per_frame) *out_ticks_per_frame = ticks;
    return ODL_OK;
}

odl_status_t odl_reference_locked(odl_device_t *device, bool *out_locked) {
    if (out_locked) *out_locked = false;
    if (!device) return ODL_ERR_STATE;
    BMDReferenceStatus reference = 0;
    if (!succeeded(device->output->GetReferenceStatus(&reference))) return ODL_ERR_INTERNAL;
    if (out_locked) *out_locked = (reference & bmdReferenceLocked) != 0;
    return ODL_OK;
}

odl_status_t odl_buffered_video_frames(odl_device_t *device, uint32_t *out_count) {
    if (out_count) *out_count = 0;
    if (!device || !device->videoEnabled) return ODL_ERR_STATE;
    uint32_t count = 0;
    if (!succeeded(device->output->GetBufferedVideoFrameCount(&count))) return ODL_ERR_INTERNAL;
    if (out_count) *out_count = count;
    return ODL_OK;
}

} // extern "C"

#else
#error "ODeckLink.mm is compiled only with ODL_HAVE_SDK; Package.swift builds ODeckLinkStub.c when vendor/DeckLinkSDK is absent."
#endif
