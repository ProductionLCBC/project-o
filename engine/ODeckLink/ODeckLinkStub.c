// ODeckLink — the stub built when vendor/DeckLinkSDK is absent (Package.swift).
// Every call reports the card as unavailable; nothing here touches hardware.
// Spec 4 §12: the DeckLink sink pauses on an unavailable card and the engine
// keeps running.

#include "ODeckLink.h"
#include <stddef.h>

bool odl_sdk_available(void) { return false; }

odl_status_t odl_open(const char *persistent_id, odl_device_t **out_device) {
    (void)persistent_id;
    if (out_device) *out_device = NULL;
    return ODL_ERR_UNAVAILABLE;
}

void odl_close(odl_device_t *device) { (void)device; }

odl_status_t odl_set_callbacks(odl_device_t *device, odl_frame_completed_cb on_completed,
                               odl_playback_stopped_cb on_stopped, void *context) {
    (void)device; (void)on_completed; (void)on_stopped; (void)context;
    return ODL_ERR_UNAVAILABLE;
}

odl_status_t odl_enable_output(odl_device_t *device, odl_mode_t mode, odl_pixel_format_t format,
                               odl_audio_config_t audio) {
    (void)device; (void)mode; (void)format; (void)audio;
    return ODL_ERR_UNAVAILABLE;
}

odl_status_t odl_disable_output(odl_device_t *device) { (void)device; return ODL_ERR_UNAVAILABLE; }

odl_status_t odl_start_playback(odl_device_t *device, int64_t start_time, int64_t time_scale) {
    (void)device; (void)start_time; (void)time_scale;
    return ODL_ERR_UNAVAILABLE;
}

odl_status_t odl_stop_playback(odl_device_t *device) { (void)device; return ODL_ERR_UNAVAILABLE; }

odl_status_t odl_schedule_video(odl_device_t *device, const void *bytes, int32_t row_bytes,
                                int64_t display_time, int64_t duration, int64_t time_scale,
                                void *frame_context) {
    (void)device; (void)bytes; (void)row_bytes; (void)display_time; (void)duration; (void)time_scale; (void)frame_context;
    return ODL_ERR_UNAVAILABLE;
}

odl_status_t odl_schedule_audio(odl_device_t *device, const int32_t *samples, uint32_t frame_count,
                                int64_t stream_time, int64_t time_scale, uint32_t *out_written) {
    (void)device; (void)samples; (void)frame_count; (void)stream_time; (void)time_scale;
    if (out_written) *out_written = 0;
    return ODL_ERR_UNAVAILABLE;
}

odl_status_t odl_hardware_time(odl_device_t *device, int64_t time_scale, int64_t *out_time,
                               int64_t *out_ticks_per_frame) {
    (void)device; (void)time_scale;
    if (out_time) *out_time = 0;
    if (out_ticks_per_frame) *out_ticks_per_frame = 0;
    return ODL_ERR_UNAVAILABLE;
}

odl_status_t odl_reference_locked(odl_device_t *device, bool *out_locked) {
    (void)device;
    if (out_locked) *out_locked = false;
    return ODL_ERR_UNAVAILABLE;
}

odl_status_t odl_buffered_video_frames(odl_device_t *device, uint32_t *out_count) {
    (void)device;
    if (out_count) *out_count = 0;
    return ODL_ERR_UNAVAILABLE;
}
