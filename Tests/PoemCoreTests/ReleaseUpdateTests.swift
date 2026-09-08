import XCTest
@testable import PoemCore

final class ReleaseUpdateTests: XCTestCase {
    private func release(tag: String = "v1.2.0", url: String? = nil,
                         digest: String? = "sha256:" + String(repeating: "a", count: 64),
                         prerelease: Bool = false) throws -> Data {
        var asset: [String: Any] = ["name": "PoemDesktop.app.zip", "size": 200,
            "browser_download_url": url ?? "https://github.com/grinich/poem-desktop/releases/download/\(tag)/PoemDesktop.app.zip"]
        if let digest { asset["digest"] = digest }
        return try JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": false,
            "prerelease": prerelease, "assets": [asset]])
    }

    func testReleaseVersionOrderingAndStrictSyntax() throws {
        XCTAssertGreaterThan(try ReleaseVersion("v1.10.0"), try ReleaseVersion("1.9.9"))
        XCTAssertEqual(try ReleaseVersion("v1.2.0"), try ReleaseVersion("1.2.0"))
        for value in ["1.2", "1.2.0-beta", "1.2.0/../../other", " 1.2.0", "01.2.0", "1.-2.0", "1.2.99999999999999999999999999"] {
            XCTAssertThrowsError(try ReleaseVersion(value), value)
        }
    }

    func testValidReleaseDigestAndOptionalDigest() throws {
        let candidate = try ReleaseUpdate(data: release())
        XCTAssertEqual(candidate.version.description, "1.2.0")
        XCTAssertEqual(candidate.sha256, String(repeating: "a", count: 64))
        XCTAssertNil(try ReleaseUpdate(data: release(digest: nil)).sha256)
        XCTAssertThrowsError(try ReleaseUpdate(data: release(digest: "md5:123")))
        XCTAssertThrowsError(try ReleaseUpdate(data: release(prerelease: true)))
    }

    func testRejectsUntrustedAndMismatchedDownloadAddresses() throws {
        let urls = [
            "http://github.com/grinich/poem-desktop/releases/download/v1.2.0/PoemDesktop.app.zip",
            "https://github.com/attacker/poem-desktop/releases/download/v1.2.0/PoemDesktop.app.zip",
            "https://github.com/grinich/poem-desktop/releases/download/v9.0.0/PoemDesktop.app.zip",
            "https://github.com.evil.example/grinich/poem-desktop/releases/download/v1.2.0/PoemDesktop.app.zip",
            "https://github.com/grinich/poem-desktop/releases/download/v1.2.0/PoemDesktop.app.zip?other=1"
        ]
        for url in urls { XCTAssertThrowsError(try ReleaseUpdate(data: release(url: url))) }
        XCTAssertTrue(ReleaseUpdate.isAllowedDownloadURL(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset-2e65be/123/test?signature=abc")!))
        XCTAssertTrue(ReleaseUpdate.isAllowedDownloadURL(URL(string: "https://release-assets.githubusercontent.com/github-production-release-asset/123/test?signature=abc")!))
        XCTAssertFalse(ReleaseUpdate.isAllowedDownloadURL(URL(string: "https://release-assets.githubusercontent.com/unrelated/123/test?signature=abc")!))
        XCTAssertFalse(ReleaseUpdate.isAllowedDownloadURL(URL(string: "http://release-assets.githubusercontent.com/github-production-release-asset-2e65be/123/test")!))
        XCTAssertFalse(ReleaseUpdate.isAllowedDownloadURL(URL(string: "https://example.com/update.zip")!))
    }

    func testStoredArchiveAndTraversalProtection() throws {
        XCTAssertNoThrow(try UpdateArchiveValidator.validate(storedArchive()))
        XCTAssertThrowsError(try UpdateArchiveValidator.validate(storedArchive(name: "../Poem Desktop.app/Contents/MacOS/PoemDesktop")))
        XCTAssertThrowsError(try UpdateArchiveValidator.validate(storedArchive(mode: 0o120777)))
        XCTAssertThrowsError(try UpdateArchiveValidator.validate(storedArchive(localSize: 4)))
        XCTAssertThrowsError(try UpdateArchiveValidator.validate(Data("not a zip".utf8)))
    }

    func testDeflatePayloadMustHonorDeclaredSizeAndChecksum() throws {
        // Raw DEFLATE for "test" with CRC32 0xd87f7e0c.
        let payload = Data([0x2b, 0x49, 0x2d, 0x2e, 0x01, 0x00])
        XCTAssertNoThrow(try UpdateArchiveValidator.validate(storedArchive(payload: payload, method: 8, size: 4, crc: 0xd87f7e0c)))
        XCTAssertThrowsError(try UpdateArchiveValidator.validate(storedArchive(payload: payload, method: 8, size: 1, crc: 0xd87f7e0c)))
        XCTAssertThrowsError(try UpdateArchiveValidator.validate(storedArchive(payload: payload, method: 8, size: 4, crc: 0)))
    }

    private func storedArchive(name: String = "Poem Desktop.app/Contents/MacOS/PoemDesktop",
                               mode: UInt32 = 0o100755, localSize: UInt32? = nil,
                               payload: Data = Data(), method: UInt16 = 0,
                               size: UInt32 = 0, crc: UInt32 = 0) -> Data {
        var data = Data()
        func u16(_ value: UInt16) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var little = value.littleEndian; withUnsafeBytes(of: &little) { data.append(contentsOf: $0) } }
        let filename = Data(name.utf8)
        u32(0x04034b50); u16(20); u16(0); u16(method); u16(0); u16(0)
        u32(crc); u32(UInt32(payload.count)); u32(localSize ?? size); u16(UInt16(filename.count)); u16(0)
        data.append(filename); data.append(payload)
        let centralOffset = UInt32(data.count)
        u32(0x02014b50); u16(0x0314); u16(20); u16(0); u16(method); u16(0); u16(0)
        u32(crc); u32(UInt32(payload.count)); u32(size); u16(UInt16(filename.count)); u16(0); u16(0)
        u16(0); u16(0); u32(mode << 16); u32(0); data.append(filename)
        let centralSize = UInt32(data.count) - centralOffset
        u32(0x06054b50); u16(0); u16(0); u16(1); u16(1); u32(centralSize); u32(centralOffset); u16(0)
        return data
    }
}
