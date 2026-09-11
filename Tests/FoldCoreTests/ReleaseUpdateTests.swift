import Foundation
import CryptoKit
import Testing
import zlib
@testable import FoldCore

@Test func translocatedIdentityRequiresMatchingBundleVersionAndExecutableBytes() {
    let digest = String(repeating:"a",count:64)
    let expected = UpdateBundleIdentity(bundleIdentifier:"local.lidflow.mac",version:ReleaseVersion("0.1.12")!,executableHash:digest)
    #expect(expected.matches(bundleIdentifier:"local.lidflow.mac",version:"v0.1.12",executableHash:digest))
    #expect(!expected.matches(bundleIdentifier:"other.app",version:"0.1.12",executableHash:digest))
    #expect(!expected.matches(bundleIdentifier:"local.lidflow.mac",version:"0.1.11",executableHash:digest))
    #expect(!expected.matches(bundleIdentifier:"local.lidflow.mac",version:"0.1.12",executableHash:String(repeating:"b",count:64)))
    #expect(!expected.matches(bundleIdentifier:nil,version:"0.1.12",executableHash:digest))
}

@Test func helperByteCopyDoesNotInheritDownloadMetadataOrAlterCandidateQuarantine() throws {
    let root = try temporaryFolder();defer { try? FileManager.default.removeItem(at:root) }
    let source = root.appendingPathComponent("Source.app",isDirectory:true), helper = root.appendingPathComponent("Installer.app",isDirectory:true), candidate = root.appendingPathComponent("candidate")
    let executable = source.appendingPathComponent("Contents/MacOS/MacDuo")
    try FileManager.default.createDirectory(at:executable.deletingLastPathComponent(),withIntermediateDirectories:true)
    try Data("trusted running helper bytes".utf8).write(to:executable)
    try FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath:executable.path)
    try Data("sealed Info.plist fixture".utf8).write(to:source.appendingPathComponent("Contents/Info.plist"))
    try Data("downloaded candidate".utf8).write(to:candidate)
    let quarantine = "0081;12345678;Mac Duo;fixture"
    for file in [source,executable,candidate] {
        let result = quarantine.withCString { setxattr(file.path,"com.apple.quarantine",$0,strlen($0),0,0) }
        #expect(result == 0)
    }
    try UpdateHandoff.writeHelperBundle(from:source,to:helper)
    let helperExecutable = helper.appendingPathComponent("Contents/MacOS/MacDuo")
    #expect(try Data(contentsOf:executable) == Data(contentsOf:helperExecutable))
    #expect(try Data(contentsOf:source.appendingPathComponent("Contents/Info.plist")) == Data(contentsOf:helper.appendingPathComponent("Contents/Info.plist")))
    #expect(getxattr(helper.path,"com.apple.quarantine",nil,0,0,0) == -1)
    #expect(getxattr(helperExecutable.path,"com.apple.quarantine",nil,0,0,0) == -1)
    #expect(getxattr(source.path,"com.apple.quarantine",nil,0,0,0) > 0)
    #expect(getxattr(candidate.path,"com.apple.quarantine",nil,0,0,0) > 0)
    #expect((try FileManager.default.attributesOfItem(atPath:helperExecutable.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    #expect(throws: (any Error).self) { try UpdateHandoff.writeHelperBundle(from:source,to:helper) }
}

@Test func helperMustBeAliveAndAcknowledgeBeforeTheAppCanQuit() async throws {
    try await UpdateHandoff.waitUntilReady(isRunning:{ true },hasAcknowledged:{ true })
    await #expect(throws: (any Error).self) {
        try await UpdateHandoff.waitUntilReady(isRunning:{ false },hasAcknowledged:{ true })
    }
    await #expect(throws: (any Error).self) {
        try await UpdateHandoff.waitUntilReady(timeout:0.01,isRunning:{ true },hasAcknowledged:{ false })
    }
}

@Test func releaseVersionsCompareNumericallyAndRejectUnstableOrInjectedTags() {
    #expect(ReleaseVersion("v0.1.12")! > ReleaseVersion("0.1.9")!)
    #expect(ReleaseVersion("13.0") == ReleaseVersion("13.0.0"))
    #expect(ReleaseVersion("1.10.0")! > ReleaseVersion("1.2.99")!)
    for value in ["", "v", "1", "1..2", "1.2.3-beta", "1.2/../../x", "1.2;touch /tmp/x", "1.2\n", "١.٢", "1.2.3.4.5"] {
        #expect(ReleaseVersion(value) == nil)
    }
}

private func release(_ tag: String = "v0.1.12", draft: Bool = false, prerelease: Bool = false,
                     zipURL: String? = nil, size: Int = 2048, duplicate: Bool = false) throws -> Data {
    let prefix = "https://github.com/DhananjayBhosale/MacDuo/releases/download/\(tag)/"
    let zip: [String:Any] = ["name":ReleaseUpdate.archiveName,"size":size,"browser_download_url":zipURL ?? prefix+ReleaseUpdate.archiveName]
    var assets: [[String:Any]] = [zip,["name":ReleaseUpdate.checksumName,"size":160,"browser_download_url":prefix+ReleaseUpdate.checksumName]]
    if duplicate { assets.append(zip) }
    return try JSONSerialization.data(withJSONObject:["tag_name":tag,"draft":draft,"prerelease":prerelease,"assets":assets])
}

@Test func onlyNewerStableOfficialReleaseAssetsAreSelected() throws {
    let latest = try ReleaseUpdate.newerRelease(data:release(),installed:"0.1.11")
    #expect(latest?.tag == "v0.1.12")
    #expect(try ReleaseUpdate.newerRelease(data:release(),installed:"0.1.12") == nil)
    #expect(try ReleaseUpdate.newerRelease(data:release(),installed:"0.2.0") == nil)
    #expect(throws: (any Error).self) { try ReleaseUpdate.newerRelease(data:release(draft:true),installed:"0.1.11") }
    #expect(throws: (any Error).self) { try ReleaseUpdate.newerRelease(data:release(prerelease:true),installed:"0.1.11") }
    for url in ["http://github.com/DhananjayBhosale/MacDuo/releases/download/v0.1.12/Mac-Duo-mac.zip",
                "https://github.com.evil.test/DhananjayBhosale/MacDuo/releases/download/v0.1.12/Mac-Duo-mac.zip",
                "https://github.com/other/MacDuo/releases/download/v0.1.12/Mac-Duo-mac.zip",
                "https://github.com/DhananjayBhosale/MacDuo/releases/download/v0.1.11/Mac-Duo-mac.zip",
                "https://github.com/DhananjayBhosale/MacDuo/releases/download/v0.1.12/Mac-Duo-mac.zip?redirect=bad"] {
        #expect(throws: (any Error).self) { try ReleaseUpdate.newerRelease(data:release(zipURL:url),installed:"0.1.11") }
    }
    #expect(throws: (any Error).self) { try ReleaseUpdate.newerRelease(data:release(size:ReleaseUpdate.maximumArchiveBytes+1),installed:"0.1.11") }
    #expect(throws: (any Error).self) { try ReleaseUpdate.newerRelease(data:release(duplicate:true),installed:"0.1.11") }
}

@Test func checksumRequiresExactlyOneMatchingNamedArchive() throws {
    let data = Data("fixture archive".utf8)
    let hash = SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
    let valid = Data("\(hash)  Mac-Duo-mac.zip\n".utf8)
    try ReleaseUpdate.verifyChecksum(archive:data,manifest:valid)
    try ReleaseUpdate.verifyChecksum(archive:data,manifest:Data("\(hash) *Mac-Duo-mac.zip\n".utf8))
    #expect(throws: (any Error).self) { try ReleaseUpdate.verifyChecksum(archive:Data("tampered".utf8),manifest:valid) }
    #expect(throws: (any Error).self) { try ReleaseUpdate.verifyChecksum(archive:data,manifest:valid+valid) }
    #expect(throws: (any Error).self) { try ReleaseUpdate.verifyChecksum(archive:data,manifest:Data("\(hash)  Other.zip\n".utf8)) }
}

private struct ZipEntry {
    var name: String
    var content = Data("fixture".utf8)
    var mode: UInt32 = 0o100644
    var flags: UInt16 = 0
    var localName: String? = nil
    var expanded: UInt32? = nil
    var method: UInt16 = 0
    var checksum: UInt32? = nil
}
private func zip(_ entries: [ZipEntry]) -> Data {
    func append16(_ value: UInt16, to data: inout Data) { var n = value.littleEndian;withUnsafeBytes(of:&n) { data.append(contentsOf:$0) } }
    func append32(_ value: UInt32, to data: inout Data) { var n = value.littleEndian;withUnsafeBytes(of:&n) { data.append(contentsOf:$0) } }
    var data = Data(), central = Data()
    for entry in entries {
        let name = Data(entry.name.utf8), localName = Data((entry.localName ?? entry.name).utf8)
        let offset = UInt32(data.count), size = UInt32(entry.content.count), expanded = entry.expanded ?? size
        let checksum = entry.checksum ?? entry.content.withUnsafeBytes { UInt32(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(entry.content.count))) }
        append32(0x04034b50,to:&data);append16(20,to:&data);append16(entry.flags,to:&data);append16(entry.method,to:&data)
        append32(0,to:&data);append32(checksum,to:&data);append32(size,to:&data);append32(expanded,to:&data)
        append16(UInt16(localName.count),to:&data);append16(0,to:&data);data.append(localName);data.append(entry.content)
        append32(0x02014b50,to:&central);append16(0x0314,to:&central);append16(20,to:&central);append16(entry.flags,to:&central);append16(entry.method,to:&central)
        append32(0,to:&central);append32(checksum,to:&central);append32(size,to:&central);append32(expanded,to:&central)
        append16(UInt16(name.count),to:&central);append16(0,to:&central);append16(0,to:&central);append16(0,to:&central);append16(0,to:&central)
        append32(entry.mode << 16,to:&central);append32(offset,to:&central);central.append(name)
    }
    let directory = UInt32(data.count);data.append(central)
    append32(0x06054b50,to:&data);append16(0,to:&data);append16(0,to:&data)
    append16(UInt16(entries.count),to:&data);append16(UInt16(entries.count),to:&data)
    append32(UInt32(central.count),to:&data);append32(directory,to:&data);append16(0,to:&data)
    return data
}
private let requiredEntries = [ZipEntry(name:"Mac Duo.app/Contents/Info.plist"),
                               ZipEntry(name:"Mac Duo.app/Contents/MacOS/MacDuo",mode:0o100755)]
private func temporaryFolder() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true).resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at:url,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    return url
}

@Test func archiveRejectsTraversalSymlinksSpecialFilesAndHeaderMismatch() throws {
    try UpdateArchive.validate(zip(requiredEntries))
    let unsafeEntries = [ZipEntry(name:"../outside"),ZipEntry(name:"/tmp/outside"),
                         ZipEntry(name:"Mac Duo.app/../../outside"),ZipEntry(name:"Mac Duo.app//file"),
                         ZipEntry(name:"Mac Duo.app/Contents\\outside"),ZipEntry(name:"Mac Duo.app/file:stream"),
                         ZipEntry(name:"Mac Duo.app/Contents/link",mode:0o120777),
                         ZipEntry(name:"Mac Duo.app/Contents/socket",mode:0o140777),
                         ZipEntry(name:"Mac Duo.app/Contents/setuid",mode:0o104755),
                         ZipEntry(name:"Mac Duo.app/Contents/encrypted",flags:1),
                         ZipEntry(name:"Mac Duo.app/Contents/mismatch",localName:"../escape"),
                         ZipEntry(name:"Mac Duo.app/Contents/bomb",expanded:200*1024*1024),
                         ZipEntry(name:"Mac Duo.app/Contents/Info.plist")]
    for entry in unsafeEntries {
        #expect(throws: (any Error).self) { try UpdateArchive.validate(zip(requiredEntries+[entry])) }
    }
    let truncated = zip(requiredEntries).dropLast(1)
    #expect(throws: (any Error).self) { try UpdateArchive.validate(Data(truncated)) }
}

@Test func extractionChecksActualSizeCRCAndRefusesExistingOrLinkedDestination() throws {
    let root = try temporaryFolder();defer { try? FileManager.default.removeItem(at:root) }
    try UpdateArchive.extract(zip(requiredEntries),into:root)
    #expect(try Data(contentsOf:root.appendingPathComponent("Mac Duo.app/Contents/Info.plist")) == Data("fixture".utf8))
    #expect(FileManager.default.isExecutableFile(atPath:root.appendingPathComponent("Mac Duo.app/Contents/MacOS/MacDuo").path))
    #expect(throws: (any Error).self) { try UpdateArchive.extract(zip(requiredEntries),into:root) }
    for entry in [ZipEntry(name:"Mac Duo.app/Contents/oversized",expanded:1),
                  ZipEntry(name:"Mac Duo.app/Contents/corrupt",checksum:0),
                  ZipEntry(name:"Mac Duo.app/Contents/deflate",method:8)] {
        let destination = try temporaryFolder();defer { try? FileManager.default.removeItem(at:destination) }
        #expect(throws: (any Error).self) { try UpdateArchive.extract(zip(requiredEntries+[entry]),into:destination) }
    }
    let link = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at:link,withDestinationURL:root)
    #expect(throws: (any Error).self) { try UpdateArchive.extract(zip(requiredEntries),into:link) }
}

@Test func compressedArchiveIsBoundedAndDecodedExactly() throws {
    let content = Data(repeating:42,count:4000)
    var compressed = Data(count:5000)
    let size = compressed.withUnsafeMutableBytes { output in content.withUnsafeBytes { input -> Int in
        var stream = z_stream()
        stream.next_in = UnsafeMutablePointer(mutating:input.bindMemory(to:Bytef.self).baseAddress!);stream.avail_in = uInt(content.count)
        stream.next_out = output.bindMemory(to:Bytef.self).baseAddress!;stream.avail_out = uInt(output.count)
        guard deflateInit2_(&stream,Z_DEFAULT_COMPRESSION,Z_DEFLATED,-MAX_WBITS,8,Z_DEFAULT_STRATEGY,ZLIB_VERSION,Int32(MemoryLayout<z_stream>.size)) == Z_OK else { return 0 }
        defer { deflateEnd(&stream) }
        guard deflate(&stream,Z_FINISH) == Z_STREAM_END else { return 0 }
        return Int(stream.total_out)
    } }
    compressed.count = size
    let crc = content.withUnsafeBytes { UInt32(crc32(0,$0.bindMemory(to:Bytef.self).baseAddress,uInt(content.count))) }
    var entry = ZipEntry(name:"Mac Duo.app/Contents/compressed",content:compressed,expanded:4000,method:8,checksum:crc)
    let root = try temporaryFolder();defer { try? FileManager.default.removeItem(at:root) }
    try UpdateArchive.extract(zip(requiredEntries+[entry]),into:root)
    #expect(try Data(contentsOf:root.appendingPathComponent(entry.name)) == content)
    let small = try temporaryFolder();defer { try? FileManager.default.removeItem(at:small) }
    entry.expanded = 20
    #expect(throws: (any Error).self) { try UpdateArchive.extract(zip(requiredEntries+[entry]),into:small) }
}

@Test func failedRelaunchRestoresOriginalAndSuccessfulRelaunchKeepsBackup() throws {
    let root = try temporaryFolder();defer { try? FileManager.default.removeItem(at:root) }
    let old = root.appendingPathComponent("Mac Duo.app"), candidate = root.appendingPathComponent("candidate"), backup = root.appendingPathComponent("backup")
    try Data("old".utf8).write(to:old);try Data("new".utf8).write(to:candidate)
    #expect(throws: (any Error).self) {
        try UpdateReplacement.install(staged:candidate,destination:old,backup:backup) { throw UpdateError.invalid("Fixture launch failure") }
    }
    #expect(try Data(contentsOf:old) == Data("old".utf8))
    #expect(try Data(contentsOf:candidate) == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath:backup.path))
    var launched = false
    try UpdateReplacement.install(staged:candidate,destination:old,backup:backup) { launched = true }
    #expect(launched)
    #expect(try Data(contentsOf:old) == Data("new".utf8))
    #expect(try Data(contentsOf:backup) == Data("old".utf8))
    #expect(throws: (any Error).self) { try UpdateReplacement.install(staged:old,destination:backup,backup:old) {} }
}
