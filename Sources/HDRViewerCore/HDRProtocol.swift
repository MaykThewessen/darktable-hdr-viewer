import Foundation

// MARK: - Protocol constants

/// Wire protocol version sent by darktable. Bump when the header layout changes.
public let HDRProtocolVersion: UInt32 = 2

/// Size of the fixed header in bytes.
///   4  magic 'DTHV'
///   4  version  (UInt32 LE)
///   4  width    (UInt32 LE)
///   4  height   (UInt32 LE)
///   4  channels (UInt32 LE)
///   4  transfer (UInt32 LE)
///  36  rgb_to_xyz: 9 x Float32 LE
/// = 60 bytes total
public let HDRProtocolHeaderSize: Int = 60

/// Magic bytes at offset 0.
public let HDRProtocolMagic: (UInt8, UInt8, UInt8, UInt8) = (0x44, 0x54, 0x48, 0x56) // 'DTHV'

// MARK: - Frame model

/// One decoded frame received from darktable.
public struct HDRFrame {
    public let width: UInt32
    public let height: UInt32
    /// Interleaved RGB float32, linear working primaries, row-major top-to-bottom.
    public let pixels: [Float]
    /// Row-major 3x3 working-RGB -> XYZ(D50) matrix (9 floats).
    public let rgbToXYZ: [Float]
    /// Min/max pixel value across all channels.
    public let pmin: Float
    public let pmax: Float

    public init(width: UInt32, height: UInt32, pixels: [Float],
                rgbToXYZ: [Float], pmin: Float, pmax: Float) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.rgbToXYZ = rgbToXYZ
        self.pmin = pmin
        self.pmax = pmax
    }
}

// MARK: - Protocol header encode / decode

/// The fixed 60-byte wire header for protocol v2.
///
/// Layout (all integers little-endian):
///   Offset  0 .. 3  : magic 0x44 0x54 0x48 0x56 ('DTHV')
///   Offset  4 .. 7  : version  UInt32
///   Offset  8 .. 11 : width    UInt32
///   Offset 12 .. 15 : height   UInt32
///   Offset 16 .. 19 : channels UInt32 (must be 3)
///   Offset 20 .. 23 : transfer UInt32 (0 = linear)
///   Offset 24 .. 59 : 9 x Float32, row-major RGB->XYZ(D50)
public struct HDRProtocolHeader {
    public let version:   UInt32
    public let width:     UInt32
    public let height:    UInt32
    public let channels:  UInt32
    public let transfer:  UInt32
    public let rgbToXYZ:  [Float]  // exactly 9 elements

    public init(version: UInt32 = HDRProtocolVersion,
                width: UInt32,
                height: UInt32,
                channels: UInt32 = 3,
                transfer: UInt32 = 0,
                rgbToXYZ: [Float]) {
        precondition(rgbToXYZ.count == 9, "rgbToXYZ must have exactly 9 elements")
        self.version  = version
        self.width    = width
        self.height   = height
        self.channels = channels
        self.transfer = transfer
        self.rgbToXYZ = rgbToXYZ
    }

    // MARK: Encode

    /// Serialize to the 60-byte wire representation (little-endian).
    public func encode() -> Data {
        var data = Data(capacity: HDRProtocolHeaderSize)

        // Magic 'DTHV'
        let (m0, m1, m2, m3) = HDRProtocolMagic
        data.append(contentsOf: [m0, m1, m2, m3])

        // UInt32 fields, little-endian
        func appendLE32(_ v: UInt32) {
            data.append(UInt8(v & 0xFF))
            data.append(UInt8((v >> 8) & 0xFF))
            data.append(UInt8((v >> 16) & 0xFF))
            data.append(UInt8((v >> 24) & 0xFF))
        }

        appendLE32(version)
        appendLE32(width)
        appendLE32(height)
        appendLE32(channels)
        appendLE32(transfer)

        // 9 floats as little-endian Float32 (IEEE 754)
        for f in rgbToXYZ {
            let bits = f.bitPattern  // UInt32 (IEEE 754 bit pattern)
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8((bits >> 8) & 0xFF))
            data.append(UInt8((bits >> 16) & 0xFF))
            data.append(UInt8((bits >> 24) & 0xFF))
        }

        assert(data.count == HDRProtocolHeaderSize,
               "encode() produced \(data.count) bytes, expected \(HDRProtocolHeaderSize)")
        return data
    }

    // MARK: Decode

    /// Parse a 60-byte header blob.
    ///
    /// Returns nil when:
    ///   - `data` has fewer than 60 bytes
    ///   - magic != 'DTHV'
    ///   - version != 2
    ///   - any matrix float is non-finite
    public init?(parsing data: Data) {
        guard data.count >= HDRProtocolHeaderSize else { return nil }

        let bytes = Array(data.prefix(HDRProtocolHeaderSize))

        // Magic
        guard bytes[0] == 0x44, bytes[1] == 0x54,
              bytes[2] == 0x48, bytes[3] == 0x56 else { return nil }

        func le32(_ off: Int) -> UInt32 {
            UInt32(bytes[off])
                | (UInt32(bytes[off + 1]) << 8)
                | (UInt32(bytes[off + 2]) << 16)
                | (UInt32(bytes[off + 3]) << 24)
        }

        let ver = le32(4)
        guard ver == HDRProtocolVersion else { return nil }

        var matrix = [Float](repeating: 0, count: 9)
        bytes.withUnsafeBytes { raw in
            for i in 0 ..< 9 {
                matrix[i] = raw.loadUnaligned(fromByteOffset: 24 + i * 4, as: Float.self)
            }
        }
        guard matrix.allSatisfy({ $0.isFinite }) else { return nil }

        self.version  = ver
        self.width    = le32(8)
        self.height   = le32(12)
        self.channels = le32(16)
        self.transfer = le32(20)
        self.rgbToXYZ = matrix
    }
}
