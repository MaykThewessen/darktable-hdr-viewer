# darktable HDR Viewer

A standalone macOS application that displays HDR pixel data sent from
[darktable](https://github.com/darktable-org/darktable) over a Unix domain
socket, using Metal with Extended Dynamic Range (EDR) output.

This is a companion app for darktable's HDR preview pipeline tap
([PR #20566](https://github.com/darktable-org/darktable/pull/20566)).
The C client code lives in the darktable tree (`src/common/hdr_viewer.c/.h`);
this repo contains only the macOS Metal viewer.

## Requirements

- macOS 12 Monterey or later
- Xcode Command Line Tools (provides `swift build`)
- An HDR-capable display (Pro Display XDR, MacBook Pro/Air with Liquid Retina XDR,
  or an external HDR monitor).  On SDR displays the app still works but applies a
  Reinhard tone map to keep values in [0, 1].

## Building

```sh
git clone https://github.com/MaykThewessen/darktable-hdr-viewer.git
cd darktable-hdr-viewer
swift build -c release
```

The binary is placed at `.build/release/HDRViewer`.

For development / debugging:

```sh
swift build          # debug build
swift run            # build + launch immediately
```

## Running

1. Launch the viewer:
   ```sh
   .build/release/HDRViewer
   ```

2. Launch darktable with HDR preview enabled:
   ```sh
   darktable --conf plugins/darkroom/hdr_viewer_enabled=true
   ```

3. Open an image in the darkroom. The viewer window updates live as you edit.

A window titled **"darktable HDR Preview"** appears and waits on
`/tmp/dt_hdr_viewer.sock`.  Once darktable sends a frame the status text
disappears and the image is displayed.

## Protocol

darktable communicates via a Unix domain socket at `/tmp/dt_hdr_viewer.sock`.
Each frame is a simple binary message (all integers little-endian):

| Offset | Size | Type    | Description        |
|--------|------|---------|--------------------|
| 0      | 4    | uint32  | Image width        |
| 4      | 4    | uint32  | Image height       |
| 8      | w*h*3*4 | float32[] | RGB pixels, linear BT.2020, row-major top-to-bottom |

A new connection is established per frame (or the connection may be kept
open for multiple frames; the server handles both).

## C client reference

The darktable-side C client (`dt_hdr_client.h/.c`) is included in this repo
for reference. The canonical copy lives in the darktable tree at
`src/common/hdr_viewer.c/.h`.

```c
#include "hdr_viewer.h"

int fd = dt_hdr_viewer_connect();
if (fd >= 0) {
    dt_hdr_viewer_send_frame(fd, width, height, rgb_linear_bt2020);
    dt_hdr_viewer_disconnect(fd);
}
```

`dt_hdr_viewer_connect()` returns -1 (and does **not** block) when the viewer
is not running, so it is safe to call unconditionally in a hot path.

## Architecture

```
darktable process                     HDRViewer.app
─────────────────                     ─────────────────────────────────────
hdr_viewer.c             Unix socket  IPCServer.swift
  connect()          ──────────────▶   accept()
  send_frame()       ──────frame──▶    decode → [Float]
  disconnect()                              │
                                      HDRViewController.swift
                                            │  DispatchQueue.main
                                      HDRMetalView.swift
                                            │  MTLTexture (RGBA32Float)
                                      ShaderSource.swift (embedded MSL)
                                            │  BT.2020 → Display-P3
                                            │  tone map to [0, EDR headroom]
                                      CAMetalLayer (RGBA16Float, EDR)
                                            │
                                      Display hardware (HDR)
```

### Shader pipeline

1. **Sample** the source RGBA32Float texture (linear BT.2020).
2. **Matrix multiply** with the BT.2020 → Linear Display-P3 3x3 matrix.
3. **Tone map** using a smooth knee:
   - Values <= 1.0 pass through unchanged (SDR range).
   - Values in (1.0, EDR headroom] are kept as HDR signal.
   - Values above `headroom` are soft-compressed toward `headroom`.
4. **Output** as `half4` into the `RGBA16Float` CAMetalLayer drawable, whose
   colorspace is set to `extendedLinearDisplayP3` so the OS compositor
   interprets the values correctly without additional color conversion.

### EDR headroom

The shader receives `screen.maximumExtendedDynamicRangeColorComponentValue`
each frame.  This value is typically 2.0-4.0 on an XDR display at full
brightness, and 1.0 on SDR displays.

## Known limitations

- Only one connected client at a time is fully supported (the accept loop is
  serial).  darktable sends one frame per connection, so this is not a
  practical limitation.
- The Metal shader is compiled at runtime from an embedded string
  (`ShaderSource.swift`). If you modify the shader, rebuild.
- Aspect ratio locking triggers only when the image dimensions change; it does
  not prevent arbitrary window resizing.

## License

This project is licensed under the GNU General Public License v3.0 — see
[LICENSE](LICENSE) for details.
