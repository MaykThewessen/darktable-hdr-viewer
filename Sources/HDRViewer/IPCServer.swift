import Foundation
import Darwin

/// One decoded frame from darktable: working-space linear RGB pixels plus the
/// working profile's RGB -> XYZ(D50) matrix needed to color-manage them.
struct HDRFrame {
    let width: UInt32
    let height: UInt32
    /// Interleaved RGB float32, linear working primaries, row-major top-to-bottom.
    let pixels: [Float]
    /// Row-major 3x3 working-RGB -> XYZ(D50) matrix (9 floats).
    let rgbToXYZ: [Float]
    /// Min/max pixel value across all channels. Used to detect scene-referred
    /// input (no display transform applied): such data carries large negatives
    /// and values far above 1.0, which can never come out of filmic/sigmoid.
    let pmin: Float
    let pmax: Float
}

/// Listens on a Unix domain socket and decodes pixel frames sent by darktable.
///
/// Wire format (protocol v2, little-endian) — see darktable's hdr_viewer.h:
///   [4]  magic 'D','T','H','V'
///   [4]  version (UInt32, = 2)
///   [4]  width  (UInt32)
///   [4]  height (UInt32)
///   [4]  channels (UInt32, = 3)
///   [4]  transfer (UInt32, 0 = linear)
///   [36] rgb_to_xyz : 9 x Float32, row-major working RGB -> XYZ(D50)
///   [w*h*3*4] Float32 RGB pixels, row-major top-to-bottom
///
/// Robustness contract:
///   darktable opens a NEW connection PER FRAME, so the accept loop must stay
///   resilient: a malformed, truncated, oversized, or aborted client must never
///   crash the process, leak a file descriptor, or wedge the loop. Every header
///   field is validated defensively and frames are byte-capped before any
///   allocation, so hostile or corrupt input cannot exhaust memory.
///
///   onFrame is invoked on the IPC background thread. If frames arrive faster
///   than the UI can render, the consumer (the view controller) is expected to
///   coalesce on the main thread and keep only the latest frame; this server
///   intentionally does no buffering of its own.
final class IPCServer {

    static let defaultSocketPath = "/tmp/dt_hdr_viewer.sock"
    static let protocolVersion: UInt32 = 2
    static let headerSize = 60

    /// Hard ceiling on a single frame's pixel payload, independent of the
    /// dimension checks, so a plausible-looking but absurd width*height can't
    /// trigger a multi-gigabyte allocation. ~512 MB of float32 pixels.
    static let maxPixelBytes = 512 * 1024 * 1024

    /// Largest single recv() chunk. Bounds the kernel copy and keeps progress
    /// observable; the read loop iterates until the full payload is in.
    private static let maxChunk = 8 * 1024 * 1024

    /// Per-frame receive timeout (seconds). Generous for any one frame; guards
    /// against a client that connects, sends a partial header, then stalls.
    private static let recvTimeoutSeconds: Int = 5

    /// Called on a background thread with each decoded frame.
    var onFrame: ((HDRFrame) -> Void)?

    private let socketPath: String
    private var serverFD: Int32 = -1
    private var isRunning = false
    private let queue = DispatchQueue(label: "com.darktable.hdr-viewer.ipc", qos: .userInteractive)

    /// Guards `serverFD` and `isRunning`, which are touched from both the caller
    /// thread (start/stop, e.g. main) and the accept `queue`. Critical sections
    /// are tiny and never wrap a blocking call, so this cannot deadlock.
    private let stateLock = NSLock()

    /// Reused pixel buffer to avoid per-frame allocation churn when frames are
    /// the same size (the common live-preview case). Only touched on `queue`.
    private var pixelScratch: [Float] = []

    init(socketPath: String = IPCServer.defaultSocketPath) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    func start() {
        stateLock.lock()
        if isRunning { stateLock.unlock(); return }
        isRunning = true
        stateLock.unlock()
        queue.async { [weak self] in
            self?.runAcceptLoop()
        }
    }

    /// Thread-safe snapshot of the running flag.
    private func running() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return isRunning
    }

    func stop() {
        stateLock.lock()
        isRunning = false
        let fd = serverFD     // take sole ownership of the listening fd
        serverFD = -1
        stateLock.unlock()
        // Closing the listening fd unblocks a pending accept() with EBADF, which
        // the loop treats as a shutdown signal. Closed exactly once, here only,
        // so the accept loop must NOT also close it (avoids a double-close /
        // fd-reuse race).
        if fd >= 0 { Darwin.close(fd) }
        unlink(socketPath)
    }

    // MARK: - Accept loop

    private func runAcceptLoop() {
        // Ignore SIGPIPE process-wide: writing to a peer that vanished must
        // surface as EPIPE, never as a fatal signal. (We only read, but the
        // peer may also reset the connection.)
        signal(SIGPIPE, SIG_IGN)

        // Remove any stale socket file from a previous run.
        unlink(socketPath)

        // Create UNIX domain socket.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            printErr("IPCServer: socket() failed: \(errnoString())")
            return
        }
        stateLock.lock(); serverFD = fd; stateLock.unlock()

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind. sun_path is a fixed C array; refuse paths that don't fit rather
        // than silently binding to a truncated path.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path) - 1
        let pathBytes = Array(socketPath.utf8)
        guard pathBytes.count <= pathCapacity else {
            printErr("IPCServer: socket path too long (\(pathBytes.count) > \(pathCapacity))")
            Darwin.close(fd)
            stateLock.lock(); serverFD = -1; stateLock.unlock()
            return
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            let base = ptr.baseAddress!.assumingMemoryBound(to: CChar.self)
            for (i, b) in pathBytes.enumerated() { base[i] = CChar(bitPattern: b) }
            base[pathBytes.count] = 0
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            printErr("IPCServer: bind() failed: \(errnoString())")
            Darwin.close(fd)
            stateLock.lock(); serverFD = -1; stateLock.unlock()
            return
        }

        // Listen. darktable reconnects per frame, so a small backlog lets a new
        // connection queue while we decode the previous one.
        guard listen(fd, 8) == 0 else {
            printErr("IPCServer: listen() failed: \(errnoString())")
            Darwin.close(fd)
            stateLock.lock(); serverFD = -1; stateLock.unlock()
            return
        }

        print("IPCServer: listening on \(socketPath)")

        while running() {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientAddrLen)
                }
            }

            guard clientFD >= 0 else {
                // EINTR: interrupted by a signal, just retry the accept.
                if errno == EINTR { continue }
                // EBADF/EINVAL: listening fd was closed by stop(), shut down.
                if errno == EBADF || errno == EINVAL { break }
                if !running() { break }
                // EMFILE/ENFILE: the process or system is out of file
                // descriptors. The pending connection stays queued, so retrying
                // accept() immediately hot-spins this thread at 100% CPU. Back
                // off briefly to yield, then retry once fds free up.
                if errno == EMFILE || errno == ENFILE { usleep(100_000) }
                printErr("IPCServer: accept() failed: \(errnoString())")
                continue
            }

            // Per-frame receive timeout so a stalled or crashed client can't
            // pin a worker forever waiting on a half-sent frame.
            var tv = timeval(tv_sec: IPCServer.recvTimeoutSeconds, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv,
                       socklen_t(MemoryLayout<timeval>.size))

            handleClient(clientFD)
        }

        // The listening fd is owned and closed solely by stop(); do not close it
        // here (that caused a double-close / fd-reuse race). stop() also unlinks.
        unlink(socketPath)
        print("IPCServer: stopped.")
    }

    // MARK: - Client handling

    private func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }  // always reclaim the client fd

        // Read the fixed-size header in full.
        var header = [UInt8](repeating: 0, count: IPCServer.headerSize)
        guard readExactBytes(fd: fd, buffer: &header, byteCount: IPCServer.headerSize) else {
            printErr("IPCServer: failed to read header (client disconnected or timed out)")
            return
        }

        // Validate magic 'DTHV'.
        guard header[0] == 0x44, header[1] == 0x54, header[2] == 0x48, header[3] == 0x56 else {
            printErr("IPCServer: bad magic (expected DTHV)")
            return
        }

        func le32(_ off: Int) -> UInt32 {
            UInt32(header[off]) | (UInt32(header[off + 1]) << 8)
                | (UInt32(header[off + 2]) << 16) | (UInt32(header[off + 3]) << 24)
        }

        let version  = le32(4)
        let width    = le32(8)
        let height   = le32(12)
        let channels = le32(16)
        let transfer = le32(20)  // reserved; 0 = linear (the only mode sent today)

        guard version == IPCServer.protocolVersion else {
            printErr("IPCServer: unsupported protocol version \(version)")
            return
        }
        guard channels == 3 else {
            printErr("IPCServer: unsupported channel count \(channels)")
            return
        }
        guard transfer == 0 else {
            printErr("IPCServer: unsupported transfer function \(transfer)")
            return
        }
        guard width >= 1, height >= 1, width <= 32768, height <= 32768 else {
            printErr("IPCServer: invalid dimensions \(width)x\(height)")
            return
        }

        // Compute the payload size with overflow-safe arithmetic and enforce the
        // absolute byte ceiling BEFORE allocating anything. width/height are each
        // <= 32768 so the products stay well within Int on 64-bit, but we guard
        // explicitly so this stays correct if the bounds ever change.
        let w = Int(width)
        let h = Int(height)
        let (pixCount, mulOverflow) = w.multipliedReportingOverflow(by: h)
        guard !mulOverflow else {
            printErr("IPCServer: pixel count overflow for \(width)x\(height)")
            return
        }
        let (floatCount, mul3Overflow) = pixCount.multipliedReportingOverflow(by: 3)
        guard !mul3Overflow else {
            printErr("IPCServer: float count overflow for \(width)x\(height)")
            return
        }
        let (byteCount, mul4Overflow) = floatCount.multipliedReportingOverflow(by: MemoryLayout<Float>.size)
        guard !mul4Overflow else {
            printErr("IPCServer: byte count overflow for \(width)x\(height)")
            return
        }
        guard byteCount <= IPCServer.maxPixelBytes else {
            printErr("IPCServer: frame too large (\(byteCount) bytes > cap \(IPCServer.maxPixelBytes)); rejecting \(width)x\(height)")
            return
        }

        // Extract the 9-float RGB -> XYZ(D50) matrix (bytes 24..59, host-order
        // Float32 little-endian). Reject non-finite matrices: a NaN/Inf here
        // would propagate into the color transform and produce garbage.
        var rgbToXYZ = [Float](repeating: 0, count: 9)
        header.withUnsafeBytes { raw in
            for i in 0 ..< 9 {
                rgbToXYZ[i] = raw.loadUnaligned(fromByteOffset: 24 + i * 4, as: Float.self)
            }
        }
        guard rgbToXYZ.allSatisfy({ $0.isFinite }) else {
            printErr("IPCServer: non-finite rgb->xyz matrix; rejecting frame")
            return
        }

        // Reuse the pixel buffer across frames when sizes match; only grow/shrink
        // when the frame size changes. Bounded by the byte ceiling above.
        if pixelScratch.count != floatCount {
            pixelScratch = [Float](repeating: 0, count: floatCount)
        }

        let ok = pixelScratch.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress, ptr.count >= byteCount else { return false }
            return readExactBytes(fd: fd, buffer: base, byteCount: byteCount)
        }
        guard ok else {
            printErr("IPCServer: failed to read pixel data (\(byteCount) bytes; truncated or timed out)")
            return
        }

        // On little-endian hosts (all modern Macs) Float byte order is native,
        // so no byte-swapping is needed.

        // Diagnostic + scene-referred detection: pixel value range and the full
        // matrix. NaN/Inf in pixel data is tolerated (the shader clamps), so we
        // only track finite extrema for a meaningful min/max.
        var pmin: Float = .greatestFiniteMagnitude
        var pmax: Float = -.greatestFiniteMagnitude
        var psum: Double = 0
        var finiteCount = 0
        pixelScratch.withUnsafeBufferPointer { buf in
            for i in 0 ..< floatCount {
                let v = buf[i]
                if v.isFinite {
                    if v < pmin { pmin = v }
                    if v > pmax { pmax = v }
                    psum += Double(v)
                    finiteCount += 1
                }
            }
        }
        if finiteCount == 0 { pmin = 0; pmax = 0 }
        let pmean = finiteCount == 0 ? 0 : Float(psum / Double(finiteCount))
        let m = rgbToXYZ
        print(String(format:
            "IPCServer: frame %ux%u ch=%u  px[min=%.4f max=%.4f mean=%.4f]  "
            + "rgb->xyz(D50)=[%.4f %.4f %.4f | %.4f %.4f %.4f | %.4f %.4f %.4f]",
            width, height, channels, pmin, pmax, pmean,
            m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8]))

        // Hand a fresh copy to the consumer so our reusable scratch buffer can be
        // overwritten by the next frame without racing the UI's coalescing read.
        let frame = HDRFrame(width: width, height: height,
                             pixels: Array(pixelScratch[0 ..< floatCount]),
                             rgbToXYZ: rgbToXYZ, pmin: pmin, pmax: pmax)
        onFrame?(frame)
    }

    // MARK: - Low-level I/O helpers

    /// Read exactly `byteCount` bytes into `buffer`, looping over short reads.
    /// Returns false on clean EOF (peer closed), recv timeout (EAGAIN/
    /// EWOULDBLOCK), or any unrecoverable error. EINTR is retried.
    private func readExactBytes(fd: Int32, buffer: UnsafeMutableRawPointer, byteCount: Int) -> Bool {
        var remaining = byteCount
        var offset    = 0
        while remaining > 0 {
            let chunk = min(remaining, IPCServer.maxChunk)
            let n = recv(fd, buffer.advanced(by: offset), chunk, 0)
            if n > 0 {
                offset    += n
                remaining -= n
                continue
            }
            if n == 0 {
                return false  // peer closed connection (mid-frame if remaining > 0)
            }
            // n < 0: inspect errno.
            switch errno {
            case EINTR:
                continue  // interrupted by signal, retry
            case EAGAIN, EWOULDBLOCK:
                return false  // SO_RCVTIMEO fired: client stalled mid-frame
            default:
                return false  // ECONNRESET, EPIPE, EBADF, etc.
            }
        }
        return true
    }

    private func readExactBytes(fd: Int32, buffer: inout [UInt8], byteCount: Int) -> Bool {
        guard byteCount <= buffer.count else { return false }
        return buffer.withUnsafeMutableBytes { ptr in
            guard let base = ptr.baseAddress else { return false }
            return readExactBytes(fd: fd, buffer: base, byteCount: byteCount)
        }
    }
}

// MARK: - Helpers

private func errnoString() -> String {
    String(cString: strerror(errno))
}

private func printErr(_ msg: String) {
    let data = ((msg + "\n").data(using: .utf8)) ?? Data()
    FileHandle.standardError.write(data)
}
