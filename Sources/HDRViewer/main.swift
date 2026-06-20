import AppKit

// Line-buffer stdout so status prints (socket listening, frames received) appear
// promptly even when output is redirected to a file or pipe rather than a TTY.
setvbuf(stdout, nil, _IOLBF, 0)

// Ensure we run on the main thread.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// Regular activation policy: real Dock icon, Cmd-Tab entry, and a menu bar.
// When launched from an .app bundle this is implied, but setting it explicitly
// keeps the bare CLI binary (.build/release/HDRViewer) behaving identically.
app.setActivationPolicy(.regular)

app.run()
