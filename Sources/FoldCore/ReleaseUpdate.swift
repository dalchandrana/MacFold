import Foundation
import CryptoKit
import zlib

public enum UpdateError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// App Translocation changes a downloaded app's path, but not these verified bytes.
public struct UpdateBundleIdentity: Sendable {
    public let bundleIdentifier: String
    public let version: ReleaseVersion
    public let executableHash: String
    public init(bundleIdentifier: String, version: ReleaseVersion, executableHash: String) {
        self.bundleIdentifier = bundleIdentifier;self.version = version;self.executableHash = executableHash
    }
    public func matches(bundleIdentifier: String?, version: String?, executableHash: String) -> Bool {
        self.bundleIdentifier == bundleIdentifier && version.flatMap(ReleaseVersion.init) == self.version &&
        self.executableHash.count == 64 && self.executableHash == executableHash
    }
}

public enum UpdateHandoff {
    /// Developer ID/Development signatures seal the containing Info.plist and resources.
    /// Re-create the complete trusted bundle, not an executable detached from its seal.
    public static func writeHelperBundle(from app: URL, to helper: URL) throws {
        let files = FileManager.default
        guard app.pathExtension == "app", app.resolvingSymlinksInPath() == app.standardizedFileURL,
              !files.fileExists(atPath:helper.path),
              let entries = files.enumerator(at:app,includingPropertiesForKeys:[.isSymbolicLinkKey,.isDirectoryKey,.isRegularFileKey]) else {
            throw UpdateError.invalid("The installed app could not prepare its signed updater bundle.")
        }
        try files.createDirectory(at:helper,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        do {
            let sourcePath = app.resolvingSymlinksInPath().path
            for case let entry as URL in entries {
                let values = try entry.resourceValues(forKeys:[.isSymbolicLinkKey,.isDirectoryKey,.isRegularFileKey])
                let entryPath = entry.resolvingSymlinksInPath().path
                guard values.isSymbolicLink != true, values.isDirectory == true || values.isRegularFile == true,
                      entryPath.hasPrefix(sourcePath+"/") else {
                    throw UpdateError.invalid("The installed app contains an unsupported helper resource.")
                }
                let destination = helper.appendingPathComponent(String(entryPath.dropFirst(sourcePath.count+1)))
                if values.isDirectory == true {
                    try files.createDirectory(at:destination,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
                } else {
                    try Data(contentsOf:entry,options:.mappedIfSafe).write(to:destination,options:.withoutOverwriting)
                    let mode = (try files.attributesOfItem(atPath:entry.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0
                    try files.setAttributes([.posixPermissions:mode & 0o111 == 0 ? 0o600 : 0o700],ofItemAtPath:destination.path)
                }
            }
        } catch { try? files.removeItem(at:helper);throw error }
    }
    public static func waitUntilReady(timeout: TimeInterval = 15, isRunning: () -> Bool,
                                      hasAcknowledged: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while isRunning(), Date() < deadline {
            if hasAcknowledged() { return }
            try await Task.sleep(nanoseconds:100_000_000)
        }
        throw UpdateError.invalid("The update helper could not start safely. Mac Fold is still running; please try again or install with Finder.")
    }
}

/// Stable releases only. Numeric components avoid lexicographic version mistakes.
public struct ReleaseVersion: Comparable, Sendable {
    public let components: [Int]
    public init?(_ value: String) {
        let text = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let parts = text.split(separator:".",omittingEmptySubsequences:false)
        guard (2...4).contains(parts.count), text.count < 50,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        components = numbers + Array(repeating:0,count:4-numbers.count)
    }
    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.components.lexicographicallyPrecedes(rhs.components)
    }
}

public struct GitHubRelease: Decodable, Sendable {
    public struct Asset: Decodable, Sendable {
        public let name: String
        public let browser_download_url: String
        public let size: Int
    }
    public let tag_name: String
    public let draft: Bool
    public let prerelease: Bool
    public let assets: [Asset]
}

public struct ReleaseUpdate: Sendable {
    public static let repository = "dalchandrana/MacFold"
    public static let archiveName = "Mac-Fold-mac.zip"
    public static let checksumName = "Mac-Fold-SHA256SUMS.txt"
    public static let maximumArchiveBytes = 100 * 1024 * 1024
    public let tag: String
    public let version: ReleaseVersion
    public let archive: URL
    public let checksums: URL
    public let archiveSize: Int
    public var releasePage: URL { URL(string:"https://github.com/\(Self.repository)/releases/tag/\(tag)")! }

    public static func newerRelease(data: Data, installed: String) throws -> Self? {
        guard let current = ReleaseVersion(installed) else { throw UpdateError.invalid("This app has an unknown version. Download the latest installer from GitHub.") }
        let release = try JSONDecoder().decode(GitHubRelease.self,from:data)
        guard !release.draft, !release.prerelease,
              let version = ReleaseVersion(release.tag_name) else {
            throw UpdateError.invalid("GitHub did not return a stable Mac Fold release.")
        }
        guard version > current else { return nil }
        func asset(_ name: String, maximum: Int) throws -> GitHubRelease.Asset {
            let matches = release.assets.filter { $0.name == name }
            guard matches.count == 1, let value = matches.first, value.size > 0, value.size <= maximum,
                  let url = URL(string:value.browser_download_url),
                  url.absoluteString == "https://github.com/\(repository)/releases/download/\(release.tag_name)/\(name)" else {
                throw UpdateError.invalid("The release is missing a valid Mac Fold installer or checksum. Open the release on GitHub instead.")
            }
            return value
        }
        let zip = try asset(archiveName,maximum:maximumArchiveBytes)
        let sums = try asset(checksumName,maximum:16_384)
        return Self(tag:release.tag_name,version:version,archive:URL(string:zip.browser_download_url)!,
                    checksums:URL(string:sums.browser_download_url)!,archiveSize:zip.size)
    }

    public static func verifyChecksum(archive: Data, manifest: Data) throws {
        guard let text = String(data:manifest,encoding:.utf8) else { throw UpdateError.invalid("The release checksum could not be read.") }
        let matches = text.split(whereSeparator:\.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator:\.isWhitespace)
            guard fields.count == 2, fields[1] == Substring(archiveName) || fields[1] == Substring("*"+archiveName) else { return nil }
            return String(fields[0]).lowercased()
        }
        let digest = SHA256.hash(data:archive).map { String(format:"%02x",$0) }.joined()
        guard matches.count == 1, matches[0].count == 64, matches[0] == digest else {
            throw UpdateError.invalid("The download failed its SHA-256 integrity check. Nothing was installed.")
        }
    }
}

/// Only app files and instructions are allowed. Native bounded decompression avoids
/// archive tools interpreting alternate filenames or writing beyond declared sizes.
public enum UpdateArchive {
    public static func validate(_ data: Data) throws {
        _ = try entries(in:data)
    }
    private struct Entry {
        let name: String, mode: Int, method: Int, expanded: Int, checksum: UInt32
        let payload: Range<Int>
    }
    public static func extract(_ data: Data, into directory: URL) throws {
        let entries = try entries(in:data), files = FileManager.default
        guard directory.standardizedFileURL == directory.resolvingSymlinksInPath(),
              try files.contentsOfDirectory(atPath:directory.path).isEmpty else {
            throw UpdateError.invalid("The update staging directory is not empty or is linked elsewhere.")
        }
        for entry in entries {
            let destination = directory.appendingPathComponent(entry.name)
            if entry.name.hasSuffix("/") {
                try files.createDirectory(at:destination,withIntermediateDirectories:true,attributes:[.posixPermissions:0o755])
                continue
            }
            var content = Data(count:max(1,entry.expanded))
            if entry.method == 0 {
                guard entry.payload.count == entry.expanded else { throw UpdateError.invalid("Invalid stored archive entry.") }
                content = data.subdata(in:entry.payload)
            } else {
                let success = content.withUnsafeMutableBytes { output in
                    data.withUnsafeBytes { input in
                        var stream = z_stream()
                        stream.next_in = UnsafeMutablePointer(mutating:input.bindMemory(to:Bytef.self).baseAddress!.advanced(by:entry.payload.lowerBound))
                        stream.avail_in = uInt(entry.payload.count)
                        stream.next_out = output.bindMemory(to:Bytef.self).baseAddress!
                        stream.avail_out = uInt(max(1,entry.expanded))
                        guard inflateInit2_(&stream,-MAX_WBITS,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return false }
                        defer { inflateEnd(&stream) }
                        return inflate(&stream,Z_FINISH) == Z_STREAM_END && stream.total_out == entry.expanded && stream.total_in == entry.payload.count
                    }
                }
                guard success else { throw UpdateError.invalid("The installer contains corrupt or oversized compressed data.") }
                content.count = entry.expanded
            }
            let checksum = content.withUnsafeBytes { crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(content.count)) }
            guard UInt32(checksum) == entry.checksum else { throw UpdateError.invalid("The installer contains a corrupt file.") }
            try files.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true,attributes:[.posixPermissions:0o755])
            try content.write(to:destination,options:.withoutOverwriting)
            try files.setAttributes([.posixPermissions:(entry.mode & 0o755) | 0o600],ofItemAtPath:destination.path)
        }
    }
    private static func entries(in data: Data) throws -> [Entry] {
        func reject() -> UpdateError { .invalid("The installer archive is unsafe or unsupported. Nothing was installed.") }
        func u16(_ offset: Int) throws -> Int {
            guard offset >= 0, offset+2 <= data.count else { throw reject() }
            return Int(data[offset]) | Int(data[offset+1]) << 8
        }
        func u32(_ offset: Int) throws -> Int {
            try u16(offset) | u16(offset+2) << 16
        }
        guard data.count >= 22, data.count <= ReleaseUpdate.maximumArchiveBytes else { throw reject() }
        var end: Int?
        for offset in stride(from:data.count-22,through:max(0,data.count-65_557),by:-1) {
            if try u32(offset) == 0x06054b50, try offset+22+u16(offset+20) == data.count { end = offset;break }
        }
        guard let end, try u16(end+4) == 0, try u16(end+6) == 0 else { throw reject() }
        let count = try u16(end+10), directorySize = try u32(end+12), directory = try u32(end+16)
        guard count > 0, count < 10_000, try u16(end+8) == count,
              directory+directorySize == end else { throw reject() }
        var cursor = directory, total = 0, names = Set<String>(), ranges: [Range<Int>] = [], entries: [Entry] = []
        for _ in 0..<count {
            guard try u32(cursor) == 0x02014b50 else { throw reject() }
            let flags = try u16(cursor+8), method = try u16(cursor+10)
            let compressed = try u32(cursor+20), expanded = try u32(cursor+24)
            let nameLength = try u16(cursor+28), extraLength = try u16(cursor+30), commentLength = try u16(cursor+32)
            let mode = try u32(cursor+38) >> 16, local = try u32(cursor+42)
            guard flags & 0x2041 == 0, [0,8].contains(method), try u16(cursor+34) == 0,
                  [0,0x4000,0x8000].contains(mode & 0xf000), mode & 0x0e00 == 0,
                  nameLength > 0, cursor+46+nameLength+extraLength+commentLength <= end,
                  let name = String(data:data[(cursor+46)..<(cursor+46+nameLength)],encoding:.utf8),
                  !name.contains("\\"), !name.contains(":"), !name.unicodeScalars.contains(where: { $0.value < 32 }),
                  name == "INSTALL.txt" || name.hasPrefix("Mac Fold.app/") || name.hasPrefix("Mac Duo.app/"),
                  !name.split(separator:"/",omittingEmptySubsequences:false).dropLast(name.hasSuffix("/") ? 1 : 0).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }),
                  names.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted,
                  !name.hasSuffix("/") || (expanded == 0 && compressed == 0) else { throw reject() }
            total += expanded
            guard total <= 512 * 1024 * 1024, expanded <= 150 * 1024 * 1024,
                  local >= 0, local+30 < directory, try u32(local) == 0x04034b50,
                  try u16(local+6) == flags, try u16(local+8) == method, try u16(local+26) == nameLength else { throw reject() }
            let localNameStart = local+30, localExtra = try u16(local+28)
            let payload = localNameStart+nameLength+localExtra
            guard payload+compressed <= directory,
                  data[localNameStart..<(localNameStart+nameLength)] == data[(cursor+46)..<(cursor+46+nameLength)] else { throw reject() }
            let range = local..<(payload+compressed)
            guard !ranges.contains(where: { $0.overlaps(range) }) else { throw reject() }
            ranges.append(range)
            entries.append(Entry(name:name,mode:mode,method:method,expanded:expanded,
                                 checksum:UInt32(try u32(cursor+16)),payload:payload..<(payload+compressed)))
            cursor += 46+nameLength+extraLength+commentLength
        }
        guard cursor == end,
              (names.contains("mac fold.app/contents/info.plist") || names.contains("mac duo.app/contents/info.plist")),
              (names.contains("mac fold.app/contents/macos/macfold") || names.contains("mac duo.app/contents/macos/macduo")) else { throw reject() }
        return entries
    }
}

/// The backup remains intact until the new app confirms it launched successfully.
public enum UpdateReplacement {
    public static func install(staged: URL, destination: URL, backup: URL,
                               launchAndConfirm: () throws -> Void) throws {
        let files = FileManager.default
        guard !files.fileExists(atPath:backup.path), files.fileExists(atPath:destination.path),
              files.fileExists(atPath:staged.path) else { throw UpdateError.invalid("The installation location changed. Please download the update manually.") }
        try files.moveItem(at:destination,to:backup)
        do {
            try files.moveItem(at:staged,to:destination)
            try launchAndConfirm()
        } catch {
            // Move the failed candidate back out before restoring the known working app.
            // Never delete the backup when a restoration fails.
            if files.fileExists(atPath:destination.path) { try files.moveItem(at:destination,to:staged) }
            try files.moveItem(at:backup,to:destination)
            throw error
        }
    }
}
