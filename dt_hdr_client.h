/*
 * dt_hdr_client.h
 *
 * Minimal POSIX-only C client library for sending HDR pixel frames to the
 * darktable HDR Viewer app (https://github.com/MaykThewessen/darktable-hdr-viewer).
 *
 * The frame buffer carries the *working-space linear* RGB image (the input to
 * the output color profile module, "colorout"), so the receiver can do its own
 * accurate, display-referred color management.  The working profile's
 * RGB -> XYZ(D50) matrix travels in the header so the viewer is correct for any
 * working profile, not just the linear Rec.2020 default.
 *
 * Wire format (protocol version 2, all multi-byte values little-endian, which
 * matches the host byte order on every platform darktable supports):
 *
 *   offset  size  field
 *   0       4     magic     : bytes 'D','T','H','V'
 *   4       4     version   : uint32, currently DT_HDR_VIEWER_VERSION (2)
 *   8       4     width     : uint32, pixels
 *   12      4     height    : uint32, pixels
 *   16      4     channels  : uint32, currently 3 (interleaved RGB)
 *   20      4     transfer  : uint32, DT_HDR_VIEWER_XFER_LINEAR (0) = linear light
 *   24      36    rgb_to_xyz: 9 x float32, row-major working RGB -> XYZ (D50 PCS)
 *   60      w*h*channels*4  : float32 pixels, row-major, top-to-bottom
 *
 * Typical usage from darktable:
 *
 *   int fd = dt_hdr_viewer_connect();
 *   if(fd >= 0)
 *   {
 *     dt_hdr_viewer_send_frame(fd, width, height, rgb_linear, rgb_to_xyz);
 *     dt_hdr_viewer_disconnect(fd);
 *   }
 *
 * The server also accepts multiple frames on a single connection.
 */

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Default Unix-domain socket path used by the HDR Viewer app. */
#define DT_HDR_VIEWER_SOCKET_PATH "/tmp/dt_hdr_viewer.sock"

/** Wire protocol version understood by both ends. */
#define DT_HDR_VIEWER_VERSION 2u

/** Transfer function tag: the pixel data is linear light. */
#define DT_HDR_VIEWER_XFER_LINEAR 0u

/**
 * Connect to the HDR Viewer Unix socket.
 *
 * Returns a connected socket file descriptor on success, or -1 on failure
 * (check errno for details).  The connection attempt times out after
 * DT_HDR_VIEWER_CONNECT_TIMEOUT_MS milliseconds so it is safe to call
 * unconditionally in a hot path: when the viewer is not running it returns
 * -1 quickly rather than blocking.
 */
int dt_hdr_viewer_connect(void);

/**
 * Send one frame of working-space linear RGB pixels to the HDR Viewer.
 *
 * @param fd           File descriptor returned by dt_hdr_viewer_connect().
 * @param w            Image width  in pixels.
 * @param h            Image height in pixels.
 * @param rgb_linear   Row-major, top-to-bottom, interleaved RGB float32 buffer
 *                     of size w * h * 3 floats, linear light in the working
 *                     profile's primaries.  Values may exceed 1.0 (HDR signal).
 * @param rgb_to_xyz   9 floats, row-major 3x3 matrix converting the working
 *                     profile's linear RGB to XYZ (ICC D50 PCS).  This is
 *                     darktable's work-profile matrix_in with the SIMD padding
 *                     column removed.
 *
 * The call blocks until all data has been written.  On write error the
 * function returns silently; the caller should disconnect and reconnect on the
 * next frame.
 */
void dt_hdr_viewer_send_frame(int fd,
                              uint32_t w,
                              uint32_t h,
                              const float *rgb_linear,
                              const float rgb_to_xyz[9]);

/**
 * Close the connection to the HDR Viewer.
 *
 * @param fd  File descriptor returned by dt_hdr_viewer_connect(), or -1
 *            (no-op in that case).
 */
void dt_hdr_viewer_disconnect(int fd);

#ifdef __cplusplus
}
#endif
