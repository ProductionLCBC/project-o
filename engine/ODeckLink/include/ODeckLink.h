// ODeckLink — Spec 4 §10 and §14: the C face of the DeckLink module.
//
// "Objective-C++ is confined to the DeckLink module." This header is the whole
// surface the Swift DeckLink sink and clock use: open a card by its persistent
// id, enable an output mode, schedule video and audio against the card's
// stream time, read the hardware clock and the reference status, and receive
// completion callbacks. ODeckLink.mm implements it over the Blackmagic SDK
// (vendor/DeckLinkSDK); ODeckLinkStub.c implements it when the SDK is absent
// and reports every card as unavailable, so the engine builds and runs with the
// output paused instead of failing to link.

#ifndef ODECKLINK_H
#define ODECKLINK_H

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Result codes. Zero is success.
typedef enum odl_status {
    ODL_OK = 0,
    ODL_ERR_UNAVAILABLE = 1,   // no SDK, no driver, or no card
    ODL_ERR_NOT_FOUND = 2,     // no card with that persistent id
    ODL_ERR_MODE = 3,          // the mode or pixel format is not supported
    ODL_ERR_STATE = 4,         // playback not started, already started, or stopped
    ODL_ERR_SCHEDULE = 5,      // the card refused the frame or samples
    ODL_ERR_INTERNAL = 6
} odl_status_t;

/// Spec 4 §10 — "10-bit YUV (v210) frames, limited range, Rec.709".
typedef enum odl_pixel_format {
    ODL_PIXEL_V210 = 0,
    ODL_PIXEL_BGRA8 = 1
} odl_pixel_format_t;

/// Spec 1 §3 — an output `format`: width, height, rate {num, den}, interlaced.
typedef struct odl_mode {
    int32_t width;
    int32_t height;
    int32_t rate_num;
    int32_t rate_den;
    bool interlaced;
} odl_mode_t;

/// Spec 4 §10 — "Embedded audio is enabled on the same output at 48 kHz,
/// 24-bit in 32-bit words".
typedef struct odl_audio_config {
    int32_t channel_count;   // 0 disables embedded audio
} odl_audio_config_t;

/// Spec 4 §10 — "the completion callback reports completed, displayedLate,
/// dropped or flushed per frame".
typedef enum odl_completion {
    ODL_COMPLETED = 0,
    ODL_DISPLAYED_LATE = 1,
    ODL_DROPPED = 2,
    ODL_FLUSHED = 3
} odl_completion_t;

typedef struct odl_device odl_device_t;

/// Called on the SDK's callback thread when a scheduled frame finishes.
typedef void (*odl_frame_completed_cb)(void *context, void *frame_context, odl_completion_t result);
/// Called when playback stops for a reason the sink did not ask for.
typedef void (*odl_playback_stopped_cb)(void *context);

/// True when the SDK was compiled in; false for the stub.
bool odl_sdk_available(void);

/// Opens the output of the card whose persistent id is `persistent_id`
/// (Spec 1 §3: "DeckLink port persistent ID"). Returns ODL_ERR_UNAVAILABLE
/// from the stub.
odl_status_t odl_open(const char *persistent_id, odl_device_t **out_device);
void odl_close(odl_device_t *device);

odl_status_t odl_set_callbacks(odl_device_t *device, odl_frame_completed_cb on_completed,
                               odl_playback_stopped_cb on_stopped, void *context);

/// Enables the output in `mode` with `format` and optional embedded audio.
odl_status_t odl_enable_output(odl_device_t *device, odl_mode_t mode, odl_pixel_format_t format,
                               odl_audio_config_t audio);
odl_status_t odl_disable_output(odl_device_t *device);

/// Starts scheduled playback at `start_time` on the `time_scale` stream clock.
odl_status_t odl_start_playback(odl_device_t *device, int64_t start_time, int64_t time_scale);
odl_status_t odl_stop_playback(odl_device_t *device);

/// Schedules one frame whose bytes the caller keeps valid until its completion
/// callback (Spec 4 §10: "an MTLBuffer with shared storage that the card reads
/// by DMA through a custom frame buffer object").
odl_status_t odl_schedule_video(odl_device_t *device, const void *bytes, int32_t row_bytes,
                                int64_t display_time, int64_t duration, int64_t time_scale,
                                void *frame_context);

/// Schedules interleaved 32-bit integer samples (24-bit in 32) against stream time.
odl_status_t odl_schedule_audio(odl_device_t *device, const int32_t *samples, uint32_t frame_count,
                                int64_t stream_time, int64_t time_scale, uint32_t *out_written);

/// Spec 4 §2 — "The DeckLink hardware clock". `out_time` in `time_scale` units.
odl_status_t odl_hardware_time(odl_device_t *device, int64_t time_scale, int64_t *out_time,
                               int64_t *out_ticks_per_frame);

/// Spec 4 §10 — "Reference lock status is read from the card and reported".
odl_status_t odl_reference_locked(odl_device_t *device, bool *out_locked);

/// How many frames the card holds that are scheduled and not yet displayed.
odl_status_t odl_buffered_video_frames(odl_device_t *device, uint32_t *out_count);

#ifdef __cplusplus
}
#endif

#endif
