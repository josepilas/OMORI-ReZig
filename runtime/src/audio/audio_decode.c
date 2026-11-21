/* Streaming, content-sniffed audio for both Android and PC game data.
 * Bytes remain owned by the Zig mixer until close. The decoder never owns
 * an entire PCM song: the existing bounded mixer window is reused.
 * stb_vorbis is compiled separately; dr_libs licenses are in their headers.
 */
#include <stdlib.h>
#include <string.h>
#define STB_VORBIS_HEADER_ONLY
#include "stb_vorbis.c"
#define DR_MP3_NO_STDIO
#define DR_MP3_IMPLEMENTATION
#include "dr_mp3.h"
#define DR_WAV_NO_STDIO
#define DR_WAV_IMPLEMENTATION
#include "dr_wav.h"

typedef struct {
    unsigned int sample_rate;
    int channels;
} OmoriAudioInfo;

typedef struct {
    int kind;
    OmoriAudioInfo info;
    union {
        stb_vorbis *ogg;
        drmp3 mp3;
        drwav wav;
    } codec;
} OmoriAudioDecoder;

void omori_audio_close(OmoriAudioDecoder *d)
{
    if (!d) return;
    switch (d->kind) {
    case 1: stb_vorbis_close(d->codec.ogg); break;
    case 2: drmp3_uninit(&d->codec.mp3); break;
    case 3: drwav_uninit(&d->codec.wav); break;
    }
    free(d);
}

OmoriAudioDecoder *omori_audio_open_memory(const unsigned char *data, int len,
                                         int *error_code, void *unused)
{
    OmoriAudioDecoder *d;
    (void)unused;
    if (error_code) *error_code = -1;
    if (!data || len < 4) return NULL;
    d = (OmoriAudioDecoder *)calloc(1, sizeof(*d));
    if (!d) return NULL;
    if (!memcmp(data, "OggS", 4)) {
        stb_vorbis_info info;
        d->codec.ogg = stb_vorbis_open_memory(data, len, error_code, NULL);
        if (!d->codec.ogg) goto fail;
        d->kind = 1;
        info = stb_vorbis_get_info(d->codec.ogg);
        d->info.sample_rate = info.sample_rate;
        d->info.channels = info.channels;
    } else if (len >= 12 && !memcmp(data, "RIFF", 4) && !memcmp(data + 8, "WAVE", 4)) {
        if (!drwav_init_memory(&d->codec.wav, data, (size_t)len, NULL)) goto fail;
        d->kind = 3;
        d->info.sample_rate = d->codec.wav.sampleRate;
        d->info.channels = (int)d->codec.wav.channels;
    } else if (!memcmp(data, "ID3", 3) || (data[0] == 0xff && (data[1] & 0xe0) == 0xe0)) {
        if (!drmp3_init_memory(&d->codec.mp3, data, (size_t)len, NULL)) goto fail;
        d->kind = 2;
        d->info.sample_rate = d->codec.mp3.sampleRate;
        d->info.channels = (int)d->codec.mp3.channels;
    } else goto fail;
    if (d->info.channels < 1 || d->info.channels > 2 ||
        d->info.sample_rate < 8000 || d->info.sample_rate > 192000) goto fail;
    if (error_code) *error_code = 0;
    return d;
fail:
    omori_audio_close(d);
    return NULL;
}

OmoriAudioInfo omori_audio_get_info(OmoriAudioDecoder *d) { return d->info; }

int omori_audio_read(OmoriAudioDecoder *d, int channels, short *output, int samples)
{
    if (!d || channels != d->info.channels || samples <= 0) return 0;
    switch (d->kind) {
    case 1: return stb_vorbis_get_frame_short_interleaved(d->codec.ogg, channels, output, samples);
    case 2: return (int)drmp3_read_pcm_frames_s16(&d->codec.mp3, (drmp3_uint64)(samples / channels), output);
    case 3: return (int)drwav_read_pcm_frames_s16(&d->codec.wav, (drwav_uint64)(samples / channels), output);
    default: return 0;
    }
}

int omori_audio_seek_start(OmoriAudioDecoder *d)
{
    if (!d) return 0;
    switch (d->kind) {
    case 1: return stb_vorbis_seek_start(d->codec.ogg);
    case 2: return (int)drmp3_seek_to_pcm_frame(&d->codec.mp3, 0);
    case 3: return (int)drwav_seek_to_pcm_frame(&d->codec.wav, 0);
    default: return 0;
    }
}
