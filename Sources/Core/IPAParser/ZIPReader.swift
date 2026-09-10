import Foundation
import Compression

// Compression framework 常量（Swift 未映射为枚举成员，用 rawValue 构造）
private let CS_OP_DECODE = compression_stream_operation(rawValue: 1)     // COMPRESSION_STREAM_DECODE
private let CS_ALGO_ZLIB = compression_algorithm(rawValue: 200)          // COMPRESSION_ZLIB
private let CS_STATUS_ERROR = compression_status(rawValue: -1)            // COMPRESSION_STATUS_ERROR
private let CS_STATUS_END = compression_status(rawValue: 1)               // COMPRESSION_STATUS_END
private let CS_STATUS_OK = compression_status(rawValue: 0)                // COMPRESSION_STATUS_OK
private let CS_FLAG_FINAL = Int32(1)                                      // COMPRESSION_STREAM_FINAL

// MARK: - 持久化日志

public final class AppLog {
    public static let shared = AppLog()
    private let queue = DispatchQueue(label: "applog.serial")
    private lazy var logURL: URL = {
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? fm.temporaryDirectory
        return docs.appendingPathComponent("dylib_editor.log")
    }()

    private init() {}

    public func write(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        queue.sync {
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path) {
                    if let handle = try? FileHandle(forWritingTo: logURL) {
                        _ = try? handle.seekToEnd()
                        try? handle.write(contentsOf: data)
                        try? handle.close()
                    }
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
        NSLog("%@", line.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public var logFilePath: String { logURL.path }
}

// MARK: - ZIP 容器解析器

public enum ZIPReaderError: Error, CustomStringConvertible {
    case notZIP
    case truncated(at: Int)
    case unsupportedCompressionMethod(method: UInt16, filename: String)
    case unsupportedDataDescriptor(filename: String)
    case inflateFailed(filename: String)
    case crcMismatch(filename: String, expected: UInt32, actual: UInt32)
    case centralDirectoryNotFound
    case noLocalFileHeader(filename: String)

    public var description: String {
        switch self {
        case .notZIP: return "输入数据不是 ZIP 文件"
        case .truncated(let at): return "ZIP 文件被截断（偏移 \(at)）"
        case .unsupportedCompressionMethod(let m, let n):
            return "不支持的压缩方法 \(m)（文件：\(n)），仅支持 0=stored / 8=deflate"
        case .unsupportedDataDescriptor(let n):
            return "条目使用了 data descriptor（文件：\(n)）"
        case .inflateFailed(let n): return "deflate 解压失败（文件：\(n)）"
        case .crcMismatch(let n, let e, let a):
            return "CRC 校验失败（文件：\(n)）：期望 0x\(String(e, radix: 16))，实际 0x\(String(a, radix: 16))"
        case .centralDirectoryNotFound: return "未找到 ZIP 中央目录"
        case .noLocalFileHeader(let n): return "未找到 \(n) 的 local file header"
        }
    }
}

public struct ZIPEntry {
    public let filename: String
    public let compressionMethod: UInt16
    public let uncompressedSize: UInt32
    public let crc32: UInt32
    public let dataOffset: Int          // 压缩数据在文件中的偏移
    public let compressedSize: UInt32
    public let hasDataDescriptor: Bool
}

public struct ZIPReader {
    public let data: Data

    public init(data: Data) throws {
        guard data.count >= 22 else { throw ZIPReaderError.notZIP }
        // ZIP 必须以 PK\x03\x04 开头（local file header）
        guard data[0] == 0x50, data[1] == 0x4B, data[2] == 0x03, data[3] == 0x04 else {
            throw ZIPReaderError.notZIP
        }
        self.data = data
        AppLog.shared.write("ZIPReader init: dataSize=\(data.count)")
    }

    /// 通过 Central Directory 扫描所有条目（支持 data descriptor）
    public func listEntries() throws -> [ZIPEntry] {
        AppLog.shared.write("listEntries: 开始扫描 Central Directory...")

        // 1. 找 EOCD (End of Central Directory Record): signature 0x06054b50
        //    EOCD 固定 22 字节，从文件末尾向前扫描
        var eocdOffset = -1
        let searchStart = data.count - 22
        let searchEnd = Swift.max(0, data.count - 65557) // comment 最多 65535 字节
        for i in stride(from: searchStart, through: searchEnd, by: -1) {
            if data.readU32LE(at: i) == 0x06054b50 {
                eocdOffset = i
                break
            }
        }
        guard eocdOffset >= 0 else {
            AppLog.shared.write("listEntries: 未找到 EOCD")
            throw ZIPReaderError.centralDirectoryNotFound
        }
        AppLog.shared.write("listEntries: EOCD at offset \(eocdOffset)")

        // 2. 从 EOCD 读取 Central Directory 偏移和条目数
        let cdCount = data.readU16LE(at: eocdOffset + 10) ?? 0
        let cdSize = data.readU32LE(at: eocdOffset + 12) ?? 0
        let cdOffset = data.readU32LE(at: eocdOffset + 16) ?? 0
        AppLog.shared.write("listEntries: cdCount=\(cdCount), cdSize=\(cdSize), cdOffset=\(cdOffset)")

        guard cdCount > 0 else { return [] }

        // 3. 遍历 Central Directory entries
        var entries: [ZIPEntry] = []
        var cursor = Int(cdOffset)
        for _ in 0..<Int(cdCount) {
            guard cursor + 46 <= data.count else {
                throw ZIPReaderError.truncated(at: cursor)
            }
            // Central Directory File Header signature 0x02014b50
            guard data.readU32LE(at: cursor) == 0x02014b50 else { break }

            let method = data.readU16LE(at: cursor + 10) ?? 0
            let crc = data.readU32LE(at: cursor + 16) ?? 0
            let compSize = data.readU32LE(at: cursor + 20) ?? 0
            let uncompSize = data.readU32LE(at: cursor + 24) ?? 0
            let fnLen = Int(data.readU16LE(at: cursor + 28) ?? 0)
            let extraLen = Int(data.readU16LE(at: cursor + 30) ?? 0)
            let commentLen = Int(data.readU16LE(at: cursor + 32) ?? 0)
            let localHeaderOffset = Int(data.readU32LE(at: cursor + 42) ?? 0)

            let nameStart = cursor + 46
            guard nameStart + fnLen <= data.count else {
                throw ZIPReaderError.truncated(at: nameStart)
            }
            let nameData = data.subdata(in: nameStart..<(nameStart + fnLen))
            let filename = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .ascii)
                ?? "<unreadable>"

            // 跳到下一个 CD entry
            cursor = nameStart + fnLen + extraLen + commentLen

            // 跳过目录
            if filename.hasSuffix("/") { continue }

            // 从 local file header 获取实际数据偏移（dataOffset = localHeaderOffset + 30 + fnLen + extraLen）
            guard localHeaderOffset + 30 <= data.count else {
                AppLog.shared.write("listEntries: \(filename) local header 截断")
                throw ZIPReaderError.truncated(at: localHeaderOffset)
            }
            guard data.readU32LE(at: localHeaderOffset) == 0x04034b50 else {
                AppLog.shared.write("listEntries: \(filename) 未找到 local file header")
                throw ZIPReaderError.noLocalFileHeader(filename: filename)
            }
            let localFnLen = Int(data.readU16LE(at: localHeaderOffset + 26) ?? 0)
            let localExtraLen = Int(data.readU16LE(at: localHeaderOffset + 28) ?? 0)
            let localFlags = data.readU16LE(at: localHeaderOffset + 6) ?? 0
            let hasDataDescriptor = (localFlags & 0x08) != 0
            let dataOffset = localHeaderOffset + 30 + localFnLen + localExtraLen

            AppLog.shared.write("  entry: \(filename), method=\(method), compSize=\(compSize), uncompSize=\(uncompSize), hasDD=\(hasDataDescriptor), dataOffset=\(dataOffset)")

            entries.append(ZIPEntry(
                filename: filename,
                compressionMethod: method,
                uncompressedSize: uncompSize,
                crc32: crc,
                dataOffset: dataOffset,
                compressedSize: compSize,
                hasDataDescriptor: hasDataDescriptor
            ))
        }

        AppLog.shared.write("listEntries: 共 \(entries.count) 个条目")
        return entries
    }

    /// 读取某条目解压后的数据
    public func readData(for entry: ZIPEntry) throws -> Data {
        let dataEnd = entry.dataOffset + Int(entry.compressedSize)
        guard dataEnd <= data.count else {
            AppLog.shared.write("readData: \(entry.filename) 数据截断, dataEnd=\(dataEnd), data.count=\(data.count)")
            throw ZIPReaderError.truncated(at: entry.dataOffset)
        }
        let compData = data.subdata(in: entry.dataOffset..<dataEnd)
        var out: Data
        switch entry.compressionMethod {
        case 0:        // stored
            out = compData
        case 8:        // deflate
            out = try Self.inflateRawDeflate(compData,
                                             expectedSize: Int(entry.uncompressedSize),
                                             filename: entry.filename)
        default:
            AppLog.shared.write("readData: \(entry.filename) 不支持的压缩方法 \(entry.compressionMethod)")
            throw ZIPReaderError.unsupportedCompressionMethod(
                method: entry.compressionMethod, filename: entry.filename)
        }
        // CRC 校验（data descriptor 时 CD 中的 crc 是正确的）
        let crc = crc32(of: out)
        if crc != entry.crc32 {
            AppLog.shared.write("readData: \(entry.filename) CRC 不匹配, expected=0x\(String(entry.crc32, radix: 16)), actual=0x\(String(crc, radix: 16))")
            throw ZIPReaderError.crcMismatch(filename: entry.filename,
                                             expected: entry.crc32, actual: crc)
        }
        return out
    }

    // MARK: - Deflate 解压

    static func inflateRawDeflate(_ src: Data, expectedSize: Int, filename: String) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, CS_OP_DECODE, CS_ALGO_ZLIB) != CS_STATUS_ERROR else {
            throw ZIPReaderError.inflateFailed(filename: filename)
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data(count: Swift.max(expectedSize * 2, 64))
        var produced = 0

        let ok: Bool = src.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) -> Bool in
            guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return false }
            stream.src_ptr = srcBase
            stream.src_size = srcRaw.count
            return output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) -> Bool in
                guard let outBase = outRaw.bindMemory(to: UInt8.self).baseAddress else { return false }
                stream.dst_ptr = outBase
                stream.dst_size = outRaw.count
                let op = compression_stream_process(&stream, CS_FLAG_FINAL)
                produced = outRaw.count - stream.dst_size
                return op == CS_STATUS_END
            }
        }
        if !ok {
            return try inflateWithGrowingBuffer(src: src, initialSize: Swift.max(expectedSize, 64), filename: filename)
        }
        return output.prefix(produced)
    }

    private static func inflateWithGrowingBuffer(src: Data, initialSize: Int, filename: String) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, CS_OP_DECODE, CS_ALGO_ZLIB) != CS_STATUS_ERROR else {
            throw ZIPReaderError.inflateFailed(filename: filename)
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data(count: initialSize)
        var done = false
        var error = false
        var produced = 0

        src.withUnsafeBytes { (srcRaw: UnsafeRawBufferPointer) in
            guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                error = true
                return
            }
            stream.src_ptr = srcBase
            stream.src_size = srcRaw.count

            while !done && !error {
                output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
                    guard let outBase = outRaw.bindMemory(to: UInt8.self).baseAddress else {
                        error = true
                        return
                    }
                    stream.dst_ptr = outBase + produced
                    stream.dst_size = outRaw.count - produced
                    if stream.dst_size == 0 { return }
                    let op = compression_stream_process(&stream, CS_FLAG_FINAL)
                    produced = outRaw.count - stream.dst_size
                    switch op {
                    case CS_STATUS_END: done = true
                    case CS_STATUS_ERROR: error = true
                    case CS_STATUS_OK: break
                    default: error = true
                    }
                }
                if !done && !error && produced >= output.count {
                    let old = output.count
                    output.count = old * 2
                    if output.count > 512 * 1024 * 1024 {
                        error = true
                    }
                }
            }
        }
        if error || !done {
            throw ZIPReaderError.inflateFailed(filename: filename)
        }
        return output.prefix(produced)
    }
}

// MARK: - 小端读 + CRC32

internal extension Data {
    func readU16LE(at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }
    func readU32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

internal func crc32(of data: Data) -> UInt32 {
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
        }
    }
    return crc ^ 0xFFFFFFFF
}
