/*
 * test-sender.c — synthetic protocol-v2 frame generator for the HDR viewer.
 *
 * Lets you verify a viewer build end-to-end without running darktable. It links
 * the reference client (../dt_hdr_client.c), so it exercises the exact wire
 * encoding darktable uses. The frame is a horizontal luminance ramp from 0 up
 * to 4.0 (the right third is super-white HDR signal) split into red/green/blue
 * bands, sent with an sRGB(D65) -> XYZ(D50) working matrix.
 *
 * Build & run (from the repository root, with the viewer already running):
 *   clang -O2 -I. tools/test-sender.c dt_hdr_client.c -o /tmp/dt-hdr-test-sender
 *   /tmp/dt-hdr-test-sender
 *
 * On an HDR display the right side should be visibly brighter than SDR white;
 * press "c" in the viewer to flag pixels above the display's EDR headroom.
 */
#include "dt_hdr_client.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    const uint32_t w = 512, h = 384;

    /* sRGB(D65) -> XYZ(D50), Bradford-adapted (Lindbloom), row-major. */
    const float rgb_to_xyz[9] = {
        0.4360747f, 0.3850649f, 0.1430804f,
        0.2225045f, 0.7168786f, 0.0606169f,
        0.0139322f, 0.0971045f, 0.7141733f
    };

    float *rgb = malloc((size_t)w * h * 3 * sizeof(float));
    if(!rgb) { fprintf(stderr, "oom\n"); return 1; }

    for(uint32_t y = 0; y < h; y++)
    {
        for(uint32_t x = 0; x < w; x++)
        {
            const float ramp = 4.0f * (float)x / (float)(w - 1);
            const int band = (int)(3.0f * (float)y / (float)h); /* 0,1,2 */
            float r = ramp, g = ramp, b = ramp;
            if(band == 0) { g *= 0.2f; b *= 0.2f; }      /* red-ish band   */
            else if(band == 1) { r *= 0.2f; b *= 0.2f; } /* green-ish band */
            else { r *= 0.2f; g *= 0.2f; }               /* blue-ish band  */
            const size_t i = ((size_t)y * w + x) * 3;
            rgb[i + 0] = r; rgb[i + 1] = g; rgb[i + 2] = b;
        }
    }

    int fd = dt_hdr_viewer_connect();
    if(fd < 0)
    {
        fprintf(stderr, "connect failed (is the viewer running?)\n");
        free(rgb);
        return 2;
    }

    dt_hdr_viewer_send_frame(fd, w, h, rgb, rgb_to_xyz);
    dt_hdr_viewer_disconnect(fd);
    free(rgb);

    printf("sent %ux%u frame (ramp 0..4.0, 3 color bands)\n", w, h);
    return 0;
}
