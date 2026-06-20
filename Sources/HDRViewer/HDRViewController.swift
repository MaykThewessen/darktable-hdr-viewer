import AppKit
import Metal

/// Ties together the Metal view and the IPC server.
/// Receives frames from darktable via Unix socket and forwards them to the Metal view.
final class HDRViewController: NSViewController {

    private var hdrView: HDRMetalView!
    private var ipcServer: IPCServer!

    // Track the current image aspect ratio for window resize constraints
    private var imageAspectRatio: CGFloat = 4.0 / 3.0

    // Status label shown while waiting for the first frame
    private var statusLabel: NSTextField!

    // Banner shown when the incoming frame is scene-referred (no display
    // transform applied in darktable). Such data is unbounded linear and is not
    // meant for direct display, so the preview will look wrong until the user
    // adds filmic rgb or sigmoid.
    private var warningLabel: NSTextField!

    override func loadView() {
        // Create a plain backing view; the HDRMetalView will fill it.
        view = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        setupHDRView()
        setupStatusLabel()
        setupWarningLabel()
        startIPCServer()
    }

    // MARK: - Setup

    private func setupHDRView() {
        hdrView = HDRMetalView(frame: view.bounds)
        hdrView.autoresizingMask = [.width, .height]
        view.addSubview(hdrView)
    }

    private func setupStatusLabel() {
        statusLabel = NSTextField(labelWithString: "Waiting for darktable…\nSocket: /tmp/dt_hdr_viewer.sock")
        statusLabel.alignment = .center
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.font = NSFont.systemFont(ofSize: 16, weight: .light)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.maximumNumberOfLines = 0

        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -40)
        ])
    }

    private func setupWarningLabel() {
        warningLabel = NSTextField(labelWithString:
            "⚠︎ Scene-linear input — no display transform.\n"
            + "Enable filmic rgb or sigmoid in darktable for a correct preview.")
        warningLabel.alignment = .center
        warningLabel.textColor = .black
        warningLabel.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.92)
        warningLabel.drawsBackground = true
        warningLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        warningLabel.maximumNumberOfLines = 0
        warningLabel.wantsLayer = true
        warningLabel.layer?.cornerRadius = 6
        warningLabel.translatesAutoresizingMaskIntoConstraints = false
        warningLabel.isHidden = true

        view.addSubview(warningLabel)
        NSLayoutConstraint.activate([
            warningLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            warningLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
            warningLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24)
        ])
    }

    private func startIPCServer() {
        ipcServer = IPCServer(socketPath: IPCServer.defaultSocketPath)
        ipcServer.onFrame = { [weak self] frame in
            self?.handleFrame(frame)
        }
        ipcServer.start()
    }

    // MARK: - Frame handling

    private func handleFrame(_ frame: HDRFrame) {
        // Update the Metal view on the main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Hide the status label once we have a real frame
            if !self.statusLabel.isHidden {
                self.statusLabel.isHidden = true
            }

            // If the window was closed (the app stays alive), bring it back so a
            // new frame is never lost behind a missing window.
            if let win = self.view.window, !win.isVisible {
                win.makeKeyAndOrderFront(nil)
            }

            // Flag scene-referred input: filmic/sigmoid output is non-negative and
            // bounded near [0,1], so large negatives or very high values mean no
            // display transform is applied. Thresholds are generous so a real HDR
            // edit (highlights a few × reference white) never trips the warning.
            let sceneLinear = frame.pmin < -1.0 || frame.pmax > 20.0
            self.warningLabel.isHidden = !sceneLinear

            let w = Int(frame.width)
            let h = Int(frame.height)

            // Update aspect ratio and resize window if this is the first frame
            // or the image dimensions changed.
            let newAspect = CGFloat(w) / CGFloat(h)
            if abs(newAspect - self.imageAspectRatio) > 0.001 {
                self.imageAspectRatio = newAspect
                self.adjustWindowForAspectRatio()
            }

            self.hdrView.updateTexture(width: w, height: h,
                                       pixels: frame.pixels, rgbToXYZ: frame.rgbToXYZ)
        }
    }

    private func adjustWindowForAspectRatio() {
        guard let window = view.window else { return }
        // Keep current width, adjust height to match aspect ratio
        let currentWidth = window.frame.width
        let newHeight = currentWidth / imageAspectRatio
        var frame = window.frame
        frame.size.height = newHeight + window.titlebarHeight
        window.setFrame(frame, display: true, animate: false)

        // Set content aspect ratio so dragging corners maintains it
        window.contentAspectRatio = NSSize(width: imageAspectRatio, height: 1.0)
    }
}

// MARK: - NSWindow titlebar height helper
private extension NSWindow {
    var titlebarHeight: CGFloat {
        frame.height - contentLayoutRect.height
    }
}
