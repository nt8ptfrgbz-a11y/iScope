import Foundation

public enum ArtifactImporter {
    public static func load(_ source: URL) throws -> ImportedArtifact {
        let fm = FileManager.default
        var temporary: URL?
        do {
            let root: URL
            if ["ipa", "zip"].contains(source.pathExtension.lowercased()) {
                try validateArchive(source)
                let destination = fm.temporaryDirectory.appendingPathComponent("iScope-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: destination, withIntermediateDirectories: true)
                temporary = destination
                _ = try ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", source.path, destination.path])
                root = destination
            } else { root = source }

            var directory: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &directory) else { throw ScopeError.invalid("文件不存在。") }
            let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
            var files: [URL] = []
            if directory.boolValue {
                guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else {
                    throw ScopeError.invalid("无法读取应用目录。")
                }
                for case let url as URL in enumerator {
                    try Task.checkCancellation()
                    let values = try url.resourceValues(forKeys: Set(keys))
                    if values.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    if values.isRegularFile == true { files.append(url) }
                    guard files.count <= 100_000 else { throw ScopeError.invalid("应用文件过多（上限 100,000）。") }
                }
            } else { files = [root] }

            let infoURL = files.filter { $0.lastPathComponent == "Info.plist" && $0.deletingLastPathComponent().pathExtension == "app" }
                .sorted { $0.pathComponents.count < $1.pathComponents.count }.first
            let info = infoURL.flatMap { try? Data(contentsOf: $0) }.flatMap {
                (try? PropertyListSerialization.propertyList(from: $0, format: nil)) as? [String: Any]
            }
            let executable = info?["CFBundleExecutable"] as? String
            let mainURL = infoURL.flatMap { url in executable.map { url.deletingLastPathComponent().appendingPathComponent($0) } }
            var images: [BinaryImage] = []
            for (index, url) in files.enumerated() {
                if index % 128 == 0 { try Task.checkCancellation() }
                guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
                let prefix = try? handle.read(upToCount: 4)
                try? handle.close()
                guard let prefix, prefix.count == 4 else { continue }
                let magic = prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
                guard [0xfeedfacf, 0xfeedface, 0xcffaedfe, 0xcefaedfe, 0xbebafeca, 0xbfbafeca, 0xcafebabe, 0xcafebabf].contains(magic) else { continue }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                let slices = try MachContainer.slices(data)
                let path = directory.boolValue ? String(url.path.dropFirst(root.path.count + 1)) : url.lastPathComponent
                images.append(BinaryImage(url: url, relativePath: path, size: UInt64(data.count), architectures: slices.map(\.name), isMainExecutable: url == mainURL || !directory.boolValue))
            }
            guard !images.isEmpty else { throw ScopeError.invalid("未找到 Mach-O。请选择脱壳 IPA、.app 目录、Framework 或 Mach-O 文件。") }
            images.sort { lhs, rhs in lhs.isMainExecutable != rhs.isMainExecutable ? lhs.isMainExecutable : lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending }
            return ImportedArtifact(sourceURL: source, name: (info?["CFBundleDisplayName"] as? String) ?? (info?["CFBundleName"] as? String) ?? source.deletingPathExtension().lastPathComponent,
                                    bundleIdentifier: info?["CFBundleIdentifier"] as? String, version: info?["CFBundleShortVersionString"] as? String, images: images, temporaryDirectory: temporary)
        } catch {
            if let temporary { try? fm.removeItem(at: temporary) }
            throw error
        }
    }

    /// Validate central-directory paths and expansion size before invoking the system extractor.
    static func validateArchive(_ url: URL) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let r = try BinaryReader(data: data)
        guard data.count >= 22 else { throw ScopeError.invalid("IPA/ZIP 文件不完整。") }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1) {
            if try r.u32(offset) == 0x06054b50, offset + 22 + Int(try r.u16(offset + 20)) == data.count { end = offset; break }
        }
        guard let end else { throw ScopeError.invalid("找不到 ZIP 目录。") }
        let entries = Int(try r.u16(end + 10))
        guard try r.u16(end + 4) == 0, try r.u16(end + 6) == 0, try r.u16(end + 8) == entries,
              entries > 0, entries < 65_535 else { throw ScopeError.invalid("暂不支持分卷、空归档或 ZIP64 IPA。") }
        var cursor = Int(try r.u32(end + 16))
        let directoryStart = cursor
        let directorySize = Int(try r.u32(end + 12))
        guard cursor <= end, directorySize <= end - cursor else { throw ScopeError.invalid("ZIP 目录越界。") }
        let directoryEnd = cursor + directorySize
        var expanded: UInt64 = 0
        var seen = Set<String>()
        for _ in 0..<entries {
            try Task.checkCancellation()
            guard r.contains(cursor, 46), try r.u32(cursor) == 0x02014b50 else { throw ScopeError.invalid("ZIP 条目无效。") }
            let nameSize = Int(try r.u16(cursor + 28))
            let extraSize = Int(try r.u16(cursor + 30)), commentSize = Int(try r.u16(cursor + 32))
            let recordSize = 46 + nameSize + extraSize + commentSize
            guard r.contains(cursor, recordSize), cursor <= directoryEnd, recordSize <= directoryEnd - cursor else { throw ScopeError.invalid("ZIP 条目截断。") }
            let nameData = data.subdata(in: (cursor + 46)..<(cursor + 46 + nameSize))
            guard let name = String(data: nameData, encoding: .utf8), !name.isEmpty,
                  !name.hasPrefix("/"), !name.contains("\\"), !name.contains("\0"), !name.contains(":"),
                  !name.split(separator: "/").contains(".."), !name.split(separator: "/").contains("."),
                  seen.insert(name.precomposedStringWithCanonicalMapping.lowercased()).inserted else {
                throw ScopeError.invalid("ZIP 包含不安全、重复或无法识别的路径。")
            }
            let mode = (try r.u32(cursor + 38)) >> 16
            guard mode & 0xf000 != 0xa000 else { throw ScopeError.invalid("IPA 包含符号链接，无法安全导入；请解包后选择 .app。") }
            guard try r.u16(cursor + 8) & 1 == 0 else { throw ScopeError.invalid("不支持加密 ZIP。") }
            let size = UInt64(try r.u32(cursor + 24))
            guard size < 0xffffffff else { throw ScopeError.invalid("暂不支持 ZIP64 条目。") }
            let local = Int(try r.u32(cursor + 42)), compressed = Int(try r.u32(cursor + 20))
            guard try r.u16(cursor + 34) == 0, r.contains(local, 30), try r.u32(local) == 0x04034b50 else {
                throw ScopeError.invalid("ZIP 本地条目无效。")
            }
            let localNameSize = Int(try r.u16(local + 26)), localExtraSize = Int(try r.u16(local + 28))
            let headerSize = 30 + localNameSize + localExtraSize
            guard r.contains(local, headerSize), local <= directoryStart, headerSize <= directoryStart - local,
                  compressed <= directoryStart - local - headerSize,
                  try r.u16(local + 6) == r.u16(cursor + 8), try r.u16(local + 8) == r.u16(cursor + 10),
                  data.subdata(in: (local + 30)..<(local + 30 + localNameSize)) == nameData else {
                throw ScopeError.invalid("ZIP 本地路径、大小或标记与目录不一致。")
            }
            expanded += size
            guard expanded <= 12 * 1024 * 1024 * 1024 else { throw ScopeError.invalid("IPA 解包大小超过 12 GB。") }
            cursor += recordSize
        }
        guard cursor == directoryEnd else { throw ScopeError.invalid("ZIP 目录长度不一致。") }
    }
}
