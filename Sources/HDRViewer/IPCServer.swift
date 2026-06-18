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
final class IPCServer {

    static let defaultSocketPath = "/tmp/dt_hdr_viewer.sock"
    static let protocolVersion: UInt32 = 2
    static let headerSize = 60

    /// Called on a background thread with each decoded frame.
    var onFrame: ((HDRFrame) -> Void)?

    private let socketPath: String
    private var serverFD: Int32 = -1
    private var isRunning = false
    private let queue = DispatchQueue(label: "com.darktable.hdr-viewer.ipc", qos: .userInteractive)

    init(socketPath: String = IPCServer.defaultSocketPath) {
        self.socketPath = socketPath
    }

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    func start() {
        guard !isRunning else { return }
        isRunning = true
        queue.async { [weak self] in
            self?.runAcceptLoop()
        }
    }

    func stop() {
        isRunning = false
        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        unlink(socketPath)
    }

    // MARK: - Accept loop

    private func runAcceptLoop() {
        // Remove stale socket file
        unlink(socketPath)

        // Create UNIX domain socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            printErr("IPCServer: socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        serverFD = fd

        // Set SO_REUSEADDR
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
            socketPath.withCString { cstr in
                _ = strncpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self),
                            cstr,
                            ptr.count - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            printErr("IPCServer: bind() failed: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        // Listen (backlog = 4; darktable typically sends one frame at a time)
        guard listen(fd, 4) == 0 else {
            printErr("IPCServer: listen() failed: \(String(cString: strerror(errno)))")
            Darwin.close(fd)
            return
        }

        print("IPCServer: listening on \(socketPath)")

        while isRunning {
            var clientAddr = sockaddr_un()
            var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(fd, $0, &clientAddrLen)
                }
            }

            guard clientFD >= 0 else {
                if errno == EINTR || errno == EBADF { break }
                printErr("IPCServer: accept() failed: \(String(cString: strerror(errno)))")
                continue
            }

            // Set a receive timeout so we don't block forever if darktable
            // crashes mid-frame. 5 seconds is generous for any single frame.
            var tv = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(clientFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

            handleClient(clientFD)
        }

        Darwin.close(fd)
        unlink(socketPath)
        print("IPCServer: stopped.")
    }

    // MARK: - Client handling

    private func handleClient(_ fd: Int32) {
        defer { Darwin.close(fd) }

        // Read the fixed-size header in one shot.
        var header = [UInt8](repeating: 0, count: IPCServer.headerSize)
        guard readExactBytes(fd: fd, buffer: &header, byteCount: IPCServer.headerSize) else {
            printErr("IPCServer: failed to read header")
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
        // transfer = le32(20) — reserved (0 = linear); only linear is sent today.

        guard version == IPCServer.protocolVersion else {
            printErr("IPCServer: unsupported protocol version \(version)")
            return
        }
        guard channels == 3 else {
            printErr("IPCServer: unsupported channel count \(channels)")
            return
        }
        guard width > 0, height > 0, width <= 32768, height <= 32768 else {
            printErr("IPCServer: invalid dimensions \(width)x\(height)")
            return
        }

        // Extract the 9-float RGB -> XYZ(D50) matrix (bytes 24..59, host-order Float32).
        var rgbToXYZ = [Float](repeating: 0, count: 9)
        header.withUnsafeBytes { raw in
            for i in 0 ..< 9 {
                rgbToXYZ[i] = raw.loadUnaligned(fromByteOffset: 24 + i * 4, as: Float.self)
            }
        }

        let floatCount = Int(width) * Int(height) * 3
        let byteCount  = floatCount * MemoryLayout<Float>.size

        var pixels = [Float](repeating: 0, count: floatCount)
        guard readExactBytes(fd: fd, buffer: &pixels, byteCount: byteCount) else {
            printErr("IPCServer: failed to read pixel data (\(byteCount) bytes)")
            return
        }

        // On little-endian hosts (all modern Macs) Float byte order is native,
        // so no byte-swapping is needed.

        onFrame?(HDRFrame(width: width, height: height, pixels: pixels, rgbToXYZ: rgbToXYZ))
    }

    // MARK: - Low-level I/O helpers

    private func readExactBytes(fd: Int32, buffer: UnsafeMutableRawPointer, byteCount: Int) -> Bool {
        var remaining = byteCount
        var offset    = 0
        while remaining > 0 {
            let n = recv(fd, buffer.advanced(by: offset), remaining, 0)
            if n <= 0 {
                if n == 0 { return false }  // connection closed
                if errno == EINTR { continue }
                return false
            }
            offset    += n
            remaining -= n
        }
        return true
    }

    private func readExactBytes(fd: Int32, buffer: inout [Float], byteCount: Int) -> Bool {
        buffer.withUnsafeMutableBytes { ptr in
            readExactBytes(fd: fd, buffer: ptr.baseAddress!, byteCount: byteCount)
        }
    }
}

// MARK: - Helpers

private func printErr(_ msg: String) {
    let data = ((msg + "\n").data(using: .utf8)) ?? Data()
    FileHandle.standardError.write(data)
}
