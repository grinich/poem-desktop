import Foundation
import Compression

public struct ReleaseVersion: Comparable, Sendable, CustomStringConvertible {
    public let major: UInt
    public let minor: UInt
    public let patch: UInt
    public var description: String { "\(major).\(minor).\(patch)" }

    public init(_ raw: String) throws {
        let value = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts.allSatisfy({ part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } &&
                (part.count == 1 || part.first != "0")
        }), let major = UInt(parts[0]), let minor = UInt(parts[1]), let patch = UInt(parts[2]) else {
            throw ReleaseUpdateError.invalid("The release version is invalid.")
        }
        self.major = major; self.minor = minor; self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public enum ReleaseUpdateError: LocalizedError {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

public struct ReleaseUpdate: Sendable {
    public static let repository = "grinich/poem-desktop"
    public static let assetName = "PoemDesktop.app.zip"
    public static let appName = "Poem Desktop.app"
    public static let maximumArchiveSize = 100 * 1024 * 1024
    public static let endpoint = URL(string: "https://api.github.com/repos/grinich/poem-desktop/releases/latest")!
    public let tag: String
    public let version: ReleaseVersion
    public let downloadURL: URL
    public let size: Int
    public let sha256: String?

    public init(data: Data) throws {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
            let size: Int
            let digest: String?
        }
        struct Release: Decodable {
            let tag_name: String
            let draft: Bool
            let prerelease: Bool
            let assets: [Asset]
        }
        guard data.count <= 2 * 1024 * 1024 else {
            throw ReleaseUpdateError.invalid("The release response is too large.")
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft && !release.prerelease else {
            throw ReleaseUpdateError.invalid("Only published stable releases can be installed.")
        }
        tag = release.tag_name
        version = try ReleaseVersion(tag)
        let matches = release.assets.filter { $0.name == Self.assetName }
        guard matches.count == 1, let asset = matches.first, asset.size > 0,
              asset.size <= Self.maximumArchiveSize,
              let url = URL(string: asset.browser_download_url),
              url.absoluteString == "https://github.com/\(Self.repository)/releases/download/\(tag)/\(Self.assetName)" else {
            throw ReleaseUpdateError.invalid("The release must contain the expected GitHub app download.")
        }
        downloadURL = url
        size = asset.size
        if let digest = asset.digest {
            guard digest.hasPrefix("sha256:"), digest.count == 71,
                  digest.dropFirst(7).allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
                throw ReleaseUpdateError.invalid("GitHub returned an unsupported or invalid archive digest.")
            }
            sha256 = String(digest.dropFirst(7)).lowercased()
        } else { sha256 = nil }
    }

    public static func isAllowedDownloadURL(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, url.fragment == nil else { return false }
        if url.host == "github.com" {
            return url.path.hasPrefix("/\(repository)/releases/download/") &&
                url.lastPathComponent == assetName && url.query == nil
        }
        // GitHub redirects the repository-scoped asset URL onto its signed CDN URL.
        return url.host == "release-assets.githubusercontent.com" &&
            (url.path.hasPrefix("/github-production-release-asset/") ||
             url.path.hasPrefix("/github-production-release-asset-"))
    }
}

/// Validate archive topology before handing any entry to the system extractor.
/// This small app intentionally ships no symlinks or ZIP64 archives.
public enum UpdateArchiveValidator {
    public static func validate(_ data: Data) throws {
        func invalid() -> ReleaseUpdateError { .invalid("The update archive contains an unsafe or unsupported entry.") }
        let bytes = [UInt8](data)
        func u16(_ at: Int) throws -> Int {
            guard at >= 0, at <= bytes.count - 2 else { throw invalid() }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8
        }
        func u32(_ at: Int) throws -> Int {
            guard at >= 0, at <= bytes.count - 4 else { throw invalid() }
            return Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func validateExtraFields(at start: Int, length: Int, local: Bool) throws {
            var position = start
            let end = start + length
            guard end <= bytes.count else { throw invalid() }
            while position < end {
                guard position + 4 <= end else { throw invalid() }
                let identifier = try u16(position)
                let size = try u16(position + 2)
                // Our ditto archives use only the fixed Unix time/UID/GID field.
                // Reject alternate-path, link, ZIP64, and unknown interpretation fields.
                guard identifier == 0x5855, size == (local ? 12 : 8), position + 4 + size <= end else { throw invalid() }
                position += 4 + size
            }
        }
        guard bytes.count >= 22, bytes.count <= ReleaseUpdate.maximumArchiveSize else { throw invalid() }
        var end: Int?
        for at in stride(from: bytes.count - 22, through: max(0, bytes.count - 65_557), by: -1) {
            if try u32(at) == 0x06054b50, at + 22 + (try u16(at + 20)) == bytes.count { end = at; break }
        }
        guard let end, try u16(end + 4) == 0, try u16(end + 6) == 0 else { throw invalid() }
        let entries = try u16(end + 10)
        guard entries > 0, entries <= 4096, try u16(end + 8) == entries else { throw invalid() }
        let centralSize = try u32(end + 12)
        let centralOffset = try u32(end + 16)
        guard centralOffset + centralSize == end else { throw invalid() }
        var cursor = centralOffset
        var names = Set<String>()
        var localRecords: [Range<Int>] = []
        var totalSize = 0
        var hasExecutable = false
        for _ in 0..<entries {
            guard try u32(cursor) == 0x02014b50 else { throw invalid() }
            let flags = try u16(cursor + 8)
            let method = try u16(cursor + 10)
            let crc = try u32(cursor + 16)
            let compressedSize = try u32(cursor + 20)
            let expandedSize = try u32(cursor + 24)
            let nameLength = try u16(cursor + 28)
            let extraLength = try u16(cursor + 30)
            let commentLength = try u16(cursor + 32)
            let mode = (try u32(cursor + 38)) >> 16
            let localOffset = try u32(cursor + 42)
            let next = cursor + 46 + nameLength + extraLength + commentLength
            guard flags & 1 == 0, [0, 8].contains(method), try u16(cursor + 34) == 0,
                  [0, 0o040000, 0o100000].contains(mode & 0o170000), mode & 0o7000 == 0,
                  expandedSize <= 200 * 1024 * 1024,
                  nameLength > 0, next <= end else { throw invalid() }
            let nameBytes = Array(bytes[(cursor + 46)..<(cursor + 46 + nameLength)])
            try validateExtraFields(at: cursor + 46 + nameLength, length: extraLength, local: false)
            guard let name = String(bytes: nameBytes, encoding: .utf8),
                  !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid() }
            var parts = name.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if parts.last == "" { parts.removeLast() }
            guard !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  parts.first == ReleaseUpdate.appName || (parts.first == "__MACOSX" &&
                    (parts.count == 1 || parts[1] == ReleaseUpdate.appName ||
                     (parts.count == 2 && parts[1] == "._" + ReleaseUpdate.appName))),
                  names.insert(parts.joined(separator: "/").lowercased()).inserted else { throw invalid() }
            guard try u32(localOffset) == 0x04034b50,
                  try u16(localOffset + 6) == flags, try u16(localOffset + 8) == method else { throw invalid() }
            let localNameLength = try u16(localOffset + 26)
            let localExtraLength = try u16(localOffset + 28)
            let payloadStart = localOffset + 30 + localNameLength + localExtraLength
            guard localNameLength == nameLength, payloadStart <= centralOffset,
                  payloadStart + compressedSize <= centralOffset,
                  Array(bytes[(localOffset + 30)..<(localOffset + 30 + localNameLength)]) == nameBytes else { throw invalid() }
            try validateExtraFields(at: localOffset + 30 + localNameLength, length: localExtraLength, local: true)
            if flags & 8 == 0 {
                guard try u32(localOffset + 14) == crc,
                      try u32(localOffset + 18) == compressedSize,
                      try u32(localOffset + 22) == expandedSize else { throw invalid() }
                localRecords.append(localOffset..<(payloadStart + compressedSize))
            } else {
                // ditto writes standard signed ZIP data descriptors for file entries.
                let descriptor = payloadStart + compressedSize
                guard descriptor + 16 <= centralOffset, try u32(descriptor) == 0x08074b50,
                      try u32(descriptor + 4) == crc, try u32(descriptor + 8) == compressedSize,
                      try u32(descriptor + 12) == expandedSize else { throw invalid() }
                let localCRC = try u32(localOffset + 14)
                let localCompressedSize = try u32(localOffset + 18)
                let localExpandedSize = try u32(localOffset + 22)
                guard [0, crc].contains(localCRC), [0, compressedSize].contains(localCompressedSize),
                      [0, expandedSize].contains(localExpandedSize) else { throw invalid() }
                localRecords.append(localOffset..<(descriptor + 16))
            }
            totalSize += expandedSize
            guard totalSize <= 300 * 1024 * 1024 else { throw invalid() }
            // Validate the actual deflate output before extraction. Some extractors
            // ignore claimed ZIP sizes, so metadata checks alone do not bound disk use.
            try validatePayload(Array(bytes[payloadStart..<(payloadStart + compressedSize)]),
                                method: method, expandedSize: expandedSize, expectedCRC: UInt32(crc))
            if name == "\(ReleaseUpdate.appName)/Contents/MacOS/PoemDesktop" { hasExecutable = true }
            cursor = next
        }
        guard cursor == end, hasExecutable else { throw invalid() }
        // ditto follows local records, including records absent from the central
        // directory. Require every local byte to belong to one validated entry.
        var coveredThrough = 0
        for range in localRecords.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound == coveredThrough else { throw invalid() }
            coveredThrough = range.upperBound
        }
        guard coveredThrough == centralOffset else { throw invalid() }
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var crc = UInt32(value)
        for _ in 0..<8 { crc = (crc & 1 == 0) ? crc >> 1 : (crc >> 1) ^ 0xedb88320 }
        return crc
    }

    private static func validatePayload(_ bytes: [UInt8], method: Int, expandedSize: Int,
                                        expectedCRC: UInt32) throws {
        func invalid() -> ReleaseUpdateError { .invalid("The archive’s decompressed data does not match its declared size or checksum.") }
        var crc: UInt32 = 0xffffffff
        func consume(_ pointer: UnsafePointer<UInt8>, count: Int) {
            for byte in UnsafeBufferPointer(start: pointer, count: count) {
                crc = crcTable[Int((crc ^ UInt32(byte)) & 0xff)] ^ (crc >> 8)
            }
        }
        if method == 0 {
            guard bytes.count == expandedSize else { throw invalid() }
            bytes.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress { consume(base, count: buffer.count) }
            }
        } else {
            let capacity = 65_536
            let output = UnsafeMutablePointer<UInt8>.allocate(capacity: capacity)
            defer { output.deallocate() }
            try bytes.withUnsafeBufferPointer { buffer in
                guard let source = buffer.baseAddress else { throw invalid() }
                var stream = compression_stream(dst_ptr: output, dst_size: capacity, src_ptr: source, src_size: buffer.count, state: nil)
                guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) != COMPRESSION_STATUS_ERROR else { throw invalid() }
                defer { compression_stream_destroy(&stream) }
                stream.src_ptr = source
                stream.src_size = buffer.count
                var total = 0
                while true {
                    stream.dst_ptr = output
                    stream.dst_size = capacity
                    let remainingBefore = stream.src_size
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let produced = capacity - stream.dst_size
                    total += produced
                    guard total <= expandedSize, status != COMPRESSION_STATUS_ERROR else { throw invalid() }
                    consume(output, count: produced)
                    if status == COMPRESSION_STATUS_END {
                        guard total == expandedSize, stream.src_size == 0 else { throw invalid() }
                        break
                    }
                    guard produced > 0 || stream.src_size < remainingBefore else { throw invalid() }
                }
            }
        }
        guard crc ^ 0xffffffff == expectedCRC else { throw invalid() }
    }
}
