import AppKit
import Metal
import HDRViewerCore

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

    // Subtle translucent overlay (top-trailing corner) summarising the live
    // state: connection, image size, EDR headroom and the frame's peak value.
    private var infoPanel: NSVisualEffectView!
    private var infoLabel: NSTextField!
    private var infoVisible = true

    // Gentle hint shown when the signal carries highlights above reference
    // white but the display currently exposes no EDR headroom (typical on the
    // built-in XDR at max brightness). Distinct from the scene-linear warning.
    private var headroomHintLabel: NSTextField!

    // Latest frame facts, retained so the overlay can be rebuilt when the
    // headroom changes (window moved between displays, brightness adjusted)
    // even if no new frame has arrived.
    private var haveFrame = false
    private var lastWidth = 0
    private var lastHeight = 0
    private var lastPeak: Float = 0
    private var lastSceneLinear = false
    private var connected = false

    // Polls the current screen's EDR headroom so the overlay and the headroom
    // hint stay live when the user changes display brightness or drags the
    // window to another screen, independent of frame delivery.
    private var headroomTimer: Timer?
    private var lastShownHeadroom: Float = -1

    // MARK: - Constants

    private enum Layout {
        static let panelMargin: CGFloat = 12
        static let panelCornerRadius: CGFloat = 8
        static let panelPaddingX: CGFloat = 10
        static let panelPaddingY: CGFloat = 7
        static let bannerTopInset: CGFloat = 12
    }

    /// A frame is treated as scene-referred (no display transform) when it has
    /// large negatives or very high peaks. Thresholds are generous so a real
    /// HDR edit (highlights a few × reference white) never trips the warning.
    private enum SceneLinear {
        static let minThreshold: Float = -1.0
        static let maxThreshold: Float = 20.0
    }

    /// Above this peak the frame genuinely carries highlights beyond reference
    /// white, so a display with no headroom is worth pointing out.
    private static let hdrSignalPeak: Float = 1.2

    // MARK: - View lifecycle

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
        setupHeadroomHintLabel()
        setupInfoPanel()
        startIPCServer()
        startHeadroomTimer()
        refreshOverlay()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // The view must be in a window before it can receive key events.
        view.window?.makeFirstResponder(self)
    }

    deinit {
        headroomTimer?.invalidate()
        ipcServer?.stop()
    }

    // MARK: - Setup

    private func setupHDRView() {
        hdrView = HDRMetalView(frame: view.bounds)
        hdrView.autoresizingMask = [.width, .height]
        view.addSubview(hdrView)
    }

    private func setupStatusLabel() {
        statusLabel = NSTextField(labelWithString: "Waiting for darktable…\nSocket: \(IPCServer.defaultSocketPath)")
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
            warningLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.bannerTopInset),
            warningLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24)
        ])
    }

    private func setupHeadroomHintLabel() {
        headroomHintLabel = NSTextField(labelWithString:
            "Lower display brightness (or enable HDR) to see highlights")
        headroomHintLabel.alignment = .center
        headroomHintLabel.textColor = .white
        headroomHintLabel.backgroundColor = NSColor.black.withAlphaComponent(0.55)
        headroomHintLabel.drawsBackground = true
        headroomHintLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        headroomHintLabel.maximumNumberOfLines = 0
        headroomHintLabel.alignment = .center
        headroomHintLabel.wantsLayer = true
        headroomHintLabel.layer?.cornerRadius = 6
        headroomHintLabel.translatesAutoresizingMaskIntoConstraints = false
        headroomHintLabel.isHidden = true

        view.addSubview(headroomHintLabel)
        NSLayoutConstraint.activate([
            headroomHintLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            headroomHintLabel.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -Layout.bannerTopInset),
            headroomHintLabel.widthAnchor.constraint(lessThanOrEqualTo: view.widthAnchor, constant: -24)
        ])
    }

    private func setupInfoPanel() {
        infoPanel = NSVisualEffectView()
        infoPanel.material = .hudWindow
        infoPanel.blendingMode = .withinWindow
        infoPanel.state = .active
        infoPanel.wantsLayer = true
        infoPanel.layer?.cornerRadius = Layout.panelCornerRadius
        infoPanel.layer?.masksToBounds = true
        infoPanel.translatesAutoresizingMaskIntoConstraints = false

        infoLabel = NSTextField(labelWithString: "")
        infoLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        infoLabel.textColor = NSColor.labelColor
        infoLabel.maximumNumberOfLines = 0
        infoLabel.alignment = .left
        infoLabel.translatesAutoresizingMaskIntoConstraints = false
        infoLabel.setContentHuggingPriority(.required, for: .horizontal)

        infoPanel.addSubview(infoLabel)
        view.addSubview(infoPanel)

        NSLayoutConstraint.activate([
            infoPanel.topAnchor.constraint(equalTo: view.topAnchor, constant: Layout.panelMargin),
            infoPanel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Layout.panelMargin),

            infoLabel.leadingAnchor.constraint(equalTo: infoPanel.leadingAnchor, constant: Layout.panelPaddingX),
            infoLabel.trailingAnchor.constraint(equalTo: infoPanel.trailingAnchor, constant: -Layout.panelPaddingX),
            infoLabel.topAnchor.constraint(equalTo: infoPanel.topAnchor, constant: Layout.panelPaddingY),
            infoLabel.bottomAnchor.constraint(equalTo: infoPanel.bottomAnchor, constant: -Layout.panelPaddingY)
        ])
    }

    private func startIPCServer() {
        ipcServer = IPCServer(socketPath: IPCServer.defaultSocketPath)
        ipcServer.onFrame = { [weak self] frame in
            // IPCServer may call back on a background thread; hop to main.
            DispatchQueue.main.async {
                self?.handleFrame(frame)
            }
        }
        ipcServer.start()
    }

    private func startHeadroomTimer() {
        // Keep the overlay and the headroom hint live when the display's EDR
        // headroom changes for reasons unrelated to frame delivery (brightness
        // change, window moved to a different screen). Cheap and idle-friendly.
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.headroomTick()
        }
        RunLoop.main.add(timer, forMode: .common)
        headroomTimer = timer
    }

    // MARK: - EDR headroom

    /// The EDR headroom the current screen exposes RIGHT NOW. 1.0 means no
    /// headroom (SDR / display at max brightness); higher values render brighter
    /// than reference white. Mirrors what HDRMetalView feeds the shader.
    private var currentHeadroom: Float {
        Float(view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1.0)
    }

    private func headroomTick() {
        let hr = currentHeadroom
        if abs(hr - lastShownHeadroom) > 0.01 {
            refreshOverlay()
        }
    }

    // MARK: - Frame handling

    private func handleFrame(_ frame: HDRFrame) {
        connected = true

        // Hide the status label once we have a real frame
        if !statusLabel.isHidden {
            statusLabel.isHidden = true
        }

        // If the window was closed (the app stays alive), bring it back so a
        // new frame is never lost behind a missing window.
        if let win = view.window, !win.isVisible {
            win.makeKeyAndOrderFront(nil)
            win.makeFirstResponder(self)
        }

        let w = Int(frame.width)
        let h = Int(frame.height)

        // Flag scene-referred input: filmic/sigmoid output is non-negative and
        // bounded near [0,1], so large negatives or very high values mean no
        // display transform is applied.
        lastSceneLinear = frame.pmin < SceneLinear.minThreshold
            || frame.pmax > SceneLinear.maxThreshold
        lastPeak = frame.pmax
        lastWidth = w
        lastHeight = h
        haveFrame = true

        // Update aspect ratio and resize window if this is the first frame
        // or the image dimensions changed.
        let newAspect = CGFloat(w) / CGFloat(h)
        if abs(newAspect - imageAspectRatio) > 0.001 {
            imageAspectRatio = newAspect
            adjustWindowForAspectRatio()
        }

        hdrView.updateTexture(width: w, height: h,
                              pixels: frame.pixels, rgbToXYZ: frame.rgbToXYZ,
                              sceneReferred: lastSceneLinear)

        refreshOverlay()
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

    // MARK: - Overlay

    private func refreshOverlay() {
        let hr = currentHeadroom
        lastShownHeadroom = hr

        // Banners
        warningLabel.isHidden = !(haveFrame && lastSceneLinear)

        // The headroom hint applies only to genuine HDR signal shown on a
        // display that currently offers no headroom. Suppress it when the
        // scene-linear warning is already up (that takes priority and explains
        // the larger problem).
        let realHDRSignal = haveFrame && lastPeak > Self.hdrSignalPeak
        let noHeadroom = hr <= 1.001
        headroomHintLabel.isHidden = !(realHDRSignal && noHeadroom && !lastSceneLinear)

        // Info panel
        infoPanel.isHidden = !infoVisible
        if infoVisible {
            infoLabel.stringValue = infoText(headroom: hr)
        }
    }

    private func infoText(headroom: Float) -> String {
        var lines: [String] = []

        lines.append(connected ? "● darktable connected" : "○ waiting for darktable")

        if haveFrame {
            lines.append("\(lastWidth) × \(lastHeight)")

            if headroom > 1.001 {
                lines.append(String(format: "HDR  %.1f× headroom", headroom))
            } else {
                lines.append("SDR  (no headroom)")
            }

            lines.append(String(format: "peak  %.2f", lastPeak))
        }

        return lines.joined(separator: "\n")
    }

    // MARK: - Key handling

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard let chars = event.charactersIgnoringModifiers?.lowercased() else {
            super.keyDown(with: event)
            return
        }

        switch chars {
        case "c":
            // Toggle the highlight-clipping overlay in the Metal view.
            hdrView.showClipping.toggle()
        case "i":
            // Toggle the translucent status overlay.
            infoVisible.toggle()
            refreshOverlay()
        default:
            super.keyDown(with: event)
        }
    }
}

// MARK: - NSWindow titlebar height helper
private extension NSWindow {
    var titlebarHeight: CGFloat {
        frame.height - contentLayoutRect.height
    }
}
