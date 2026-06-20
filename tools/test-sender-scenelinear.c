/*
 * test-sender-scenelinear.c — synthetic UN-transformed (scene-referred) frame.
 *
 * Mimics what darktable's tap sends when no display transform (filmic/sigmoid)
 * is active: working-space linear values far above 1.0 plus some negatives from
 * out-of-gamut channels. Used to verify the viewer flags scene-linear input.
 *
 *   clang -O2 -I. tools/test-sender-scenelinear.c dt_hdr_client.c -o /tmp/dt-hdr-test-sl
 *   /tmp/dt-hdr-test-sl
 */
#include "dt_hdr_client.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    const uint32_t w = 512, h = 384;

    /* linear Rec.2020 -> XYZ(D50), as darktable's default working profile. */
    const float rgb_to_xyz[9] = {
        0.6734f, 0.1656f, 0.1251f,
        0.2790f, 0.6754f, 0.0457f,
       -0.0019f, 0.0299f, 0.7973f
    };

    float *rgb = malloc((size_t)w * h * 3 * sizeof(float));
    if(!rgb) { fprintf(stderr, "oom\n"); return 1; }

    for(uint32_t y = 0; y < h; y++)
        for(uint32_t x = 0; x < w; x++)
        {
            /* ramp up to 50 (scene-linear highlights), with a negative dip on
               the left edge to emulate out-of-gamut channels. */
            const float t = (float)x / (float)(w - 1);
            const float v = 50.0f * t - 5.0f * (1.0f - t);
            const size_t i = ((size_t)y * w + x) * 3;
            rgb[i + 0] = v;
            rgb[i + 1] = v * 0.8f;
            rgb[i + 2] = v * 0.6f;
        }

    int fd = dt_hdr_viewer_connect();
    if(fd < 0) { fprintf(stderr, "connect failed (viewer running?)\n"); free(rgb); return 2; }
    dt_hdr_viewer_send_frame(fd, w, h, rgb, rgb_to_xyz);
    dt_hdr_viewer_disconnect(fd);
    free(rgb);
    printf("sent %ux%u scene-linear frame (min ~-5, max ~50)\n", w, h);
    return 0;
}
