import XCTest
@testable import HDRViewerCore

final class ProtocolHeaderTests: XCTestCase {

    // A representative sRGB -> XYZ(D50) matrix used as test fixture.
    private let sRGBToXYZ: [Float] = [
        0.4360747, 0.3850649, 0.1430804,
        0.2225045, 0.7168786, 0.0606169,
        0.0139322, 0.0971045, 0.7141733
    ]

    private func makeHeader(width: UInt32 = 1920,
                            height: UInt32 = 1080,
                            channels: UInt32 = 3,
                            transfer: UInt32 = 0) -> HDRProtocolHeader {
        HDRProtocolHeader(
            version:  HDRProtocolVersion,
            width:    width,
            height:   height,
            channels: channels,
            transfer: transfer,
            rgbToXYZ: sRGBToXYZ
        )
    }

    // MARK: (a) Header is exactly 60 bytes

    func testHeaderSizeIs60Bytes() {
        let data = makeHeader().encode()
        XCTAssertEqual(data.count, 60,
            "Expected 60-byte header, got \(data.count)")
    }

    func testHeaderSizeConstantIs60() {
        XCTAssertEqual(HDRProtocolHeaderSize, 60)
    }

    // MARK: (b) Magic bytes are 'DTHV'

    func testMagicBytes() {
        let data = makeHeader().encode()
        XCTAssertEqual(data[0], 0x44, "magic[0] must be 'D' (0x44)")
        XCTAssertEqual(data[1], 0x54, "magic[1] must be 'T' (0x54)")
        XCTAssertEqual(data[2], 0x48, "magic[2] must be 'H' (0x48)")
        XCTAssertEqual(data[3], 0x56, "magic[3] must be 'V' (0x56)")
    }

    func testMagicSpellsDTHV() {
        let data = makeHeader().encode()
        let chars = String(bytes: [data[0], data[1], data[2], data[3]], encoding: .ascii)
        XCTAssertEqual(chars, "DTHV")
    }

    // MARK: (c) Version == 2

    func testVersionIs2() {
        let data = makeHeader().encode()
        let version = readLE32(data, offset: 4)
        XCTAssertEqual(version, 2, "version field must be 2")
    }

    func testVersionConstantIs2() {
        XCTAssertEqual(HDRProtocolVersion, 2)
    }

    // MARK: (d) Each field round-trips at correct byte offset

    func testWidthRoundTripsAtOffset8() {
        let header = makeHeader(width: 3840)
        let data = header.encode()
        let parsed = HDRProtocolHeader(parsing: data)!
        XCTAssertEqual(parsed.width, 3840)
        // Also verify the raw bytes sit at offset 8.
        XCTAssertEqual(readLE32(data, offset: 8), 3840)
    }

    func testHeightRoundTripsAtOffset12() {
        let header = makeHeader(height: 2160)
        let data = header.encode()
        let parsed = HDRProtocolHeader(parsing: data)!
        XCTAssertEqual(parsed.height, 2160)
        XCTAssertEqual(readLE32(data, offset: 12), 2160)
    }

    func testChannelsRoundTripsAtOffset16() {
        let header = makeHeader(channels: 3)
        let data = header.encode()
        let parsed = HDRProtocolHeader(parsing: data)!
        XCTAssertEqual(parsed.channels, 3)
        XCTAssertEqual(readLE32(data, offset: 16), 3)
    }

    func testTransferRoundTripsAtOffset20() {
        let header = makeHeader(transfer: 0)
        let data = header.encode()
        let parsed = HDRProtocolHeader(parsing: data)!
        XCTAssertEqual(parsed.transfer, 0)
        XCTAssertEqual(readLE32(data, offset: 20), 0)
    }

    func testAllFieldsRoundTrip() {
        let h = makeHeader(width: 1280, height: 720, channels: 3, transfer: 0)
        let data = h.encode()
        guard let p = HDRProtocolHeader(parsing: data) else {
            XCTFail("HDRProtocolHeader parsing returned nil for valid header")
            return
        }
        XCTAssertEqual(p.version,  2)
        XCTAssertEqual(p.width,    1280)
        XCTAssertEqual(p.height,   720)
        XCTAssertEqual(p.channels, 3)
        XCTAssertEqual(p.transfer, 0)
    }

    // MARK: (e) 9 matrix floats round-trip with accuracy 1e-7

    func testMatrixFloatsRoundTrip() {
        let h = makeHeader()
        let data = h.encode()
        guard let p = HDRProtocolHeader(parsing: data) else {
            XCTFail("HDRProtocolHeader parsing returned nil for valid header")
            return
        }
        XCTAssertEqual(p.rgbToXYZ.count, 9)
        for (i, (orig, parsed)) in zip(sRGBToXYZ, p.rgbToXYZ).enumerated() {
            XCTAssertEqual(Double(parsed), Double(orig), accuracy: 1e-7,
                "Matrix element [\(i)] mismatch: expected \(orig), got \(parsed)")
        }
    }

    func testMatrixStartsAtOffset24() {
        let h = makeHeader()
        let data = h.encode()
        // Read the first float from offset 24 and compare to sRGBToXYZ[0].
        let bits = readLE32(data, offset: 24)
        let f = Float(bitPattern: bits)
        XCTAssertEqual(Double(f), Double(sRGBToXYZ[0]), accuracy: 1e-7,
            "First matrix float at offset 24 should equal sRGBToXYZ[0]")
    }

    func testMatrixEndsAtOffset59() {
        let h = makeHeader()
        let data = h.encode()
        // Last float: element [8], at offset 24 + 8*4 = 56.
        let bits = readLE32(data, offset: 56)
        let f = Float(bitPattern: bits)
        XCTAssertEqual(Double(f), Double(sRGBToXYZ[8]), accuracy: 1e-7,
            "Last matrix float at offset 56 should equal sRGBToXYZ[8]")
        // Byte 59 is the last byte of element [8].
        XCTAssertEqual(data.count, 60, "Last byte index is 59, header is 60 bytes")
    }

    // MARK: (f) Parser rejects bad inputs

    func testRejectsBadMagic() {
        var data = makeHeader().encode()
        data[0] = 0x00  // corrupt first magic byte
        XCTAssertNil(HDRProtocolHeader(parsing: data), "Must reject bad magic")
    }

    func testRejectsBadMagicAllZero() {
        var data = makeHeader().encode()
        data[0] = 0x00; data[1] = 0x00; data[2] = 0x00; data[3] = 0x00
        XCTAssertNil(HDRProtocolHeader(parsing: data), "Must reject all-zero magic")
    }

    func testRejectsWrongVersion() {
        var data = makeHeader().encode()
        // Overwrite version field (offset 4) with version 1 (LE).
        data[4] = 0x01; data[5] = 0x00; data[6] = 0x00; data[7] = 0x00
        XCTAssertNil(HDRProtocolHeader(parsing: data), "Must reject version != 2")
    }

    func testRejectsVersionZero() {
        var data = makeHeader().encode()
        data[4] = 0x00; data[5] = 0x00; data[6] = 0x00; data[7] = 0x00
        XCTAssertNil(HDRProtocolHeader(parsing: data), "Must reject version 0")
    }

    func testRejectsTruncatedBuffer() {
        let data = makeHeader().encode()
        // Any prefix shorter than 60 bytes must fail.
        for length in [0, 1, 3, 4, 7, 8, 23, 59] {
            let truncated = data.prefix(length)
            XCTAssertNil(HDRProtocolHeader(parsing: Data(truncated)),
                "Must reject \(length)-byte truncated buffer")
        }
    }

    func testAcceptsExactly60Bytes() {
        let data = makeHeader().encode()
        XCTAssertNotNil(HDRProtocolHeader(parsing: data),
            "Must accept exactly-60-byte buffer")
    }

    func testAcceptsBufferLargerThan60Bytes() {
        // Parser should use only the first 60 bytes and not fail on extra trailing data.
        var data = makeHeader().encode()
        data.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])
        XCTAssertNotNil(HDRProtocolHeader(parsing: data),
            "Must accept buffer with extra trailing bytes")
    }

    func testRejectsNaNInMatrix() {
        var data = makeHeader().encode()
        // Overwrite matrix element [0] (offset 24) with NaN (0x7FC00000 LE).
        let nanBits: UInt32 = 0x7FC00000
        data[24] = UInt8(nanBits & 0xFF)
        data[25] = UInt8((nanBits >> 8) & 0xFF)
        data[26] = UInt8((nanBits >> 16) & 0xFF)
        data[27] = UInt8((nanBits >> 24) & 0xFF)
        XCTAssertNil(HDRProtocolHeader(parsing: data), "Must reject NaN in matrix")
    }

    func testRejectsInfInMatrix() {
        var data = makeHeader().encode()
        // Overwrite matrix element [4] (offset 24 + 4*4 = 40) with +Inf (0x7F800000 LE).
        let infBits: UInt32 = 0x7F800000
        data[40] = UInt8(infBits & 0xFF)
        data[41] = UInt8((infBits >> 8) & 0xFF)
        data[42] = UInt8((infBits >> 16) & 0xFF)
        data[43] = UInt8((infBits >> 24) & 0xFF)
        XCTAssertNil(HDRProtocolHeader(parsing: data), "Must reject Inf in matrix")
    }

    // MARK: - Helpers

    /// Read a little-endian UInt32 from `data` at `offset`.
    private func readLE32(_ data: Data, offset: Int) -> UInt32 {
        UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}
