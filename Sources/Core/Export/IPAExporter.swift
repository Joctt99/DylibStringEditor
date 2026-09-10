import Foundation
import Compression

// MARK: - IPA 重打包
//
// 把修改后的 dylib 放回 IPA 对应位置，重新打成 ZIP（即 IPA）。
// 输出未签名，需要用户用全能签等工具重签名后才能安装。

struct IPAExporter {

    /// 基于原始 IPA 数据和修改后的 dylib，生成新的 IPA
    static func buildModifiedIPA(original: Data, modifiedDylibs: [String: Data]) throws -> Data {
        let zip = try ZIPReader(data: original)
        let entries = try zip.listEntries()

        var writer = ZIPWriter()
        for entry in entries {
            let data: Data
            if let mod = modifiedDylibs[entry.filename] {
                data = mod
            } else {
                data = try zip.readData(for: entry)
            }
            try writer.addFile(filename: entry.filename, data: data)
        }
        return writer.makeData()
    }

    /// 注入 dylib 到 IPA
    /// - Parameters:
    ///   - original: 原始 IPA 数据
    ///   - injectedDylibs: 要注入的 dylib 列表，key 为 dylib 文件名（如 "Plugin.dylib"），value 为 dylib 数据
    /// - Returns: 注入后的 IPA 数据
    static func buildIPAWithInjectedDylibs(original: Data, injectedDylibs: [String: Data]) throws -> Data {
        AppLog.shared.write("IPAExporter.buildIPAWithInjectedDylibs: \(injectedDylibs.count) 个 dylib")
        let zip = try ZIPReader(data: original)
        let entries = try zip.listEntries()

        // 找到主二进制（Payload/X.app/X）
        var mainBinaryEntry: ZIPEntry?
        var appDir: String?
        for entry in entries {
            let components = entry.filename.split(separator: "/")
            if components.count >= 2,
               components[0] == "Payload",
               components[1].hasSuffix(".app") {
                let appName = components[1].replacingOccurrences(of: ".app", with: "")
                if components.count == 3 && components[2] == appName {
                    mainBinaryEntry = entry
                    appDir = "Payload/\(components[1])"
                    AppLog.shared.write("  找到主二进制: \(entry.filename)")
                    break
                }
            }
        }

        guard let mainEntry = mainBinaryEntry, let appDir = appDir else {
            AppLog.shared.write("  未找到主二进制")
            throw NSError(domain: "IPAExporter", code: 1, userInfo: [NSLocalizedDescriptionKey: "未找到主二进制"])
        }

        // 读取主二进制数据
        var mainBinaryData = try zip.readData(for: mainEntry)

        // 对每个要注入的 dylib：
        // 1. 添加 LC_LOAD_DYLIB 到主二进制
        // 2. 将 dylib 文件添加到 .app 目录
        let injector = MachOInjector()
        for (dylibName, dylibData) in injectedDylibs {
            let dylibPath = "@executable_path/\(dylibName)"
            AppLog.shared.write("  注入 dylib: \(dylibName) -> \(dylibPath)")
            mainBinaryData = try injector.injectDylib(data: mainBinaryData, dylibPath: dylibPath)
        }

        // 重新打包：主二进制用修改后的数据，其他原样，追加新 dylib
        var writer = ZIPWriter()
        for entry in entries {
            if entry.filename == mainEntry.filename {
                try writer.addFile(filename: entry.filename, data: mainBinaryData)
            } else {
                let data = try zip.readData(for: entry)
                try writer.addFile(filename: entry.filename, data: data)
            }
        }
        // 追加注入的 dylib 到 .app 目录
        for (dylibName, dylibData) in injectedDylibs {
            let zipPath = "\(appDir)/\(dylibName)"
            AppLog.shared.write("  添加 dylib 到 IPA: \(zipPath)")
            try writer.addFile(filename: zipPath, data: dylibData)
        }

        return writer.makeData()
    }
}

// MARK: - ZIP 打包器（stored 方式，不压缩）
//
// 输出合法的 ZIP 文件，可被 iOS / Finder / 全能签 正确解压。
// 为简化实现，所有条目用 stored（method=0，不压缩）。

struct ZIPWriter {
    private var records: [LocalRecord] = []

    struct LocalRecord {
        let filename: String
        let data: Data
        let crc32: UInt32
        let offset: Int
    }

    mutating func addFile(filename: String, data: Data) throws {
        let rec = LocalRecord(
            filename: filename,
            data: data,
            crc32: InternalCRC32.calculate(data: data),
            offset: 0  // 后续计算
        )
        records.append(rec)
    }

    func makeData() -> Data {
        var out = Data()
        var centralDir = Data()
        var offset: Int = 0

        for rec in records {
            let fnData = filenameData(rec.filename)
            let compSize = rec.data.count
            let uncompSize = rec.data.count

            // Local file header
            var lfh = Data()
            lfh.append(contentsOf: [0x50, 0x4B, 0x03, 0x04])  // signature
            lfh.append(contentsOf: [0x0A, 0x00])                // version needed
            lfh.append(contentsOf: [0x00, 0x00])                // flags
            lfh.append(contentsOf: [0x00, 0x00])                // method = stored
            lfh.append(contentsOf: [0x00, 0x00, 0x00, 0x00])    // mod time / date (可选)
            lfh.append(uint32LE: rec.crc32)
            lfh.append(uint32LE: UInt32(compSize))
            lfh.append(uint32LE: UInt32(uncompSize))
            lfh.append(uint16LE: UInt16(fnData.count))
            lfh.append(contentsOf: [0x00, 0x00])                // extra field len
            lfh.append(fnData)
            out.append(lfh)
            out.append(rec.data)

            // Central directory entry
            var cde = Data()
            cde.append(contentsOf: [0x50, 0x4B, 0x01, 0x02])  // signature
            cde.append(contentsOf: [0x14, 0x00])               // version made by
            cde.append(contentsOf: [0x0A, 0x00])               // version needed
            cde.append(contentsOf: [0x00, 0x00])               // flags
            cde.append(contentsOf: [0x00, 0x00])               // method
            cde.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // mod time/date
            cde.append(uint32LE: rec.crc32)
            cde.append(uint32LE: UInt32(compSize))
            cde.append(uint32LE: UInt32(uncompSize))
            cde.append(uint16LE: UInt16(fnData.count))
            cde.append(contentsOf: [0x00, 0x00])               // extra len
            cde.append(contentsOf: [0x00, 0x00])               // comment len
            cde.append(contentsOf: [0x00, 0x00])               // disk number start
            cde.append(contentsOf: [0x00, 0x00])               // internal attrs
            cde.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // external attrs
            cde.append(uint32LE: UInt32(offset))               // local header offset
            cde.append(fnData)
            centralDir.append(cde)

            offset = out.count
        }

        let centralDirOffset = out.count
        out.append(centralDir)
        let centralDirSize = centralDir.count

        // End of central directory
        var eocd = Data()
        eocd.append(contentsOf: [0x50, 0x4B, 0x05, 0x06])        // signature
        eocd.append(contentsOf: [0x00, 0x00])                     // disk number
        eocd.append(contentsOf: [0x00, 0x00])                     // disk with cd
        eocd.append(uint16LE: UInt16(records.count))             // # entries on this disk
        eocd.append(uint16LE: UInt16(records.count))             // # total entries
        eocd.append(uint32LE: UInt32(centralDirSize))
        eocd.append(uint32LE: UInt32(centralDirOffset))
        eocd.append(contentsOf: [0x00, 0x00])                     // comment len
        out.append(eocd)

        return out
    }

    private func filenameData(_ filename: String) -> Data {
        // ZIP 规范要求路径用 "/" 分隔，不允许 "\"
        let normalized = filename.replacingOccurrences(of: "\\", with: "/")
        return normalized.data(using: .utf8) ?? Data()
    }
}

// MARK: - Data 小端写入辅助

private extension Data {
    mutating func append(uint16LE v: UInt16) {
        append(UInt8(v & 0xff))
        append(UInt8((v >> 8) & 0xff))
    }
    mutating func append(uint32LE v: UInt32) {
        append(UInt8(v & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 24) & 0xff))
    }
}

// MARK: - CRC32（与 ZIPReader 中的实现保持一致，避免符号冲突）

private enum InternalCRC32 {
    static func calculate(data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}
