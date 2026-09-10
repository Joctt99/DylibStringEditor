import Foundation
import Compression

// Compression framework 常量（Swift 未映射为枚举成员，用原始值）
private let CS_OP_DECODE = Int32(1)       // COMPRESSION_STREAM_DECODE
private let CS_ALGO_ZLIB = Int32(200)     // COMPRESSION_ZLIB
private let CS_STATUS_ERROR = Int32(-1)   // COMPRESSION_STATUS_ERROR
private let CS_STATUS_END = Int32(1)      // COMPRESSION_STATUS_END
private let CS_STATUS_OK = Int32(0)       // COMPRESSION_STATUS_OK
private let CS_FLAG_FINAL = Int32(1)      // COMPRESSION_STREAM_FINAL

// MARK: - ZIP 容器最小解析器
//
// 仅支持：
//   - Local file header (PK\x03\x04)
//   - 压缩方法 0 (stored) / 8 (deflate)
//   - COMPRESSION_ZLIB 解 raw DEFLATE（ZIP method 8）
//
// 不支持的特性（IPA 实际不会出现，遇到抛错）：
//   - ZIP64 / 加密 / LZMA / Zstd / Data descriptor (flag bit 3)

public enum ZIPReaderError: Error, CustomStringConvertible {
    case notZIP
    case truncated(at: Int)
    case unsupportedCompressionMethod(method: UInt16, filename: String)
    case unsupportedDataDescriptor(filename: String)
    case inflateFailed(filename: String)
    case crcMismatch(filename: String, expected: UInt32, actual: UInt32)

    public var description: String {
        switch self {
        case .notZIP: return "输入数据不是 ZIP 文件（未找到 local file header）"
        case .truncated(let at): return "ZIP 文件被截断（偏移 \(at)）"
        case .unsupportedCompressionMethod(let m, let n):
            return "不支持的压缩方法 \(m)（文件：\(n)），仅支持 0=stored / 8=deflate"
        case .unsupportedDataDescriptor(let n):
            return "条目使用了 data descriptor（flag bit 3），暂不支持（文件：\(n)）。请重新打包 IPA。"
        case .inflateFailed(let n): return "deflate 解压失败（文件：\(n)）"
        case .crcMismatch(let n, let e, let a):
            return "CRC 校验失败（文件：\(n)）：期望 0x\(String(e, radix: 16))，实际 0x\(String(a, radix: 16))"
        }
    }
}

public struct ZIPEntry {
    public let filename: String
    public let compressionMethod: UInt16     // 0=stored, 8=deflate
    public let uncompressedSize: UInt32
    public let crc32: UInt32
    public let dataOffset: Int
    public let compressedSize: UInt32
}

public struct ZIPReader {
    public let data: Data

    public init(data: Data) throws {
        guard data.count >= 4,
              data[0] == 0x50, data[1] == 0x4B, data[2] == 0x03, data[3] == 0x04 else {
            throw ZIPReaderError.notZIP
        }
        self.data = data
    }

    /// 扫描所有 local file header，返回条目清单
    public func listEntries() throws -> [ZIPEntry] {
        var entries: [ZIPEntry] = []
        var cursor = 0
        while cursor + 30 <= data.count {
            // local file header signature 0x04034b50
            guard data[cursor] == 0x50, data[cursor+1] == 0x4B,
                  data[cursor+2] == 0x03, data[cursor+3] == 0x04 else { break }

            let flags = data.readU16LE(at: cursor + 6) ?? 0
            let method = data.readU16LE(at: cursor + 8) ?? 0
            let crc = data.readU32LE(at: cursor + 14) ?? 0
            let compSize = data.readU32LE(at: cursor + 18) ?? 0
            let uncompSize = data.readU32LE(at: cursor + 22) ?? 0
            let fnLen = Int(data.readU16LE(at: cursor + 26) ?? 0)
            let extraLen = Int(data.readU16LE(at: cursor + 28) ?? 0)

            let nameStart = cursor + 30
            guard nameStart + fnLen + extraLen <= data.count else {
                throw ZIPReaderError.truncated(at: nameStart)
            }
            let nameData = data.subdata(in: nameStart..<(nameStart + fnLen))
            let filename = String(data: nameData, encoding: .utf8)
                ?? String(data: nameData, encoding: .ascii)
                ?? "<unreadable>"

            // data descriptor：size/crc 在数据末尾，本实现不扫描
            if (flags & 0x08) != 0 {
                throw ZIPReaderError.unsupportedDataDescriptor(filename: filename)
            }

            let dataOffset = nameStart + fnLen + extraLen
            entries.append(ZIPEntry(
                filename: filename,
                compressionMethod: method,
                uncompressedSize: uncompSize,
                crc32: crc,
                dataOffset: dataOffset,
                compressedSize: compSize
            ))
            cursor = dataOffset + Int(compSize)
        }
        return entries
    }

    /// 读取某条目解压后的数据，并校验 CRC32
    public func readData(for entry: ZIPEntry) throws -> Data {
        let dataEnd = entry.dataOffset + Int(entry.compressedSize)
        guard dataEnd <= data.count else {
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
            throw ZIPReaderError.unsupportedCompressionMethod(
                method: entry.compressionMethod, filename: entry.filename)
        }
        let crc = crc32(of: out)
        if crc != entry.crc32 {
            throw ZIPReaderError.crcMismatch(filename: entry.filename,
                                             expected: entry.crc32, actual: crc)
        }
        return out
    }

    // MARK: - Deflate 解压（Compression.framework stream API）

    /// 用 COMPRESSION_ZLIB stream 模式解 raw DEFLATE
    /// COMPRESSION_ZLIB 接受 raw DEFLATE 数据流（无 zlib header），正好对应 ZIP method 8
    static func inflateRawDeflate(_ src: Data, expectedSize: Int, filename: String) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 0)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 0)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, CS_OP_DECODE, CS_ALGO_ZLIB) != CS_STATUS_ERROR else {
            throw ZIPReaderError.inflateFailed(filename: filename)
        }
        defer { compression_stream_destroy(&stream) }

        // 用 expected size 预分配；ZIP 里的 uncompressed size 字段总是可信的，所以一次就够
        // 保险起见给 2 倍空间
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
            // 预分配不够，走扩容路径
            return try inflateWithGrowingBuffer(src: src, initialSize: Swift.max(expectedSize, 64), filename: filename)
        }
        return output.prefix(produced)
    }

    /// 扩容式解压：当一次性解压不够 buffer 时使用
    private static func inflateWithGrowingBuffer(src: Data, initialSize: Int, filename: String) throws -> Data {
        var stream = compression_stream(
            dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 0)!,
            dst_size: 0,
            src_ptr: UnsafePointer<UInt8>(bitPattern: 0)!,
            src_size: 0,
            state: nil
        )
        guard compression_stream_init(&stream, CS_OP_DECODE, CS_ALGO_ZLIB) != CS_STATUS_ERROR else {
            throw ZIPReaderError.inflateFailed(filename: filename)
        }
        defer { compression_stream_destroy(&stream) }

        var output = Data(count: initialSize)
        // 标记是否完成
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
                // 每轮重新获取 output 的可变指针
                output.withUnsafeMutableBytes { (outRaw: UnsafeMutableRawBufferPointer) in
                    guard let outBase = outRaw.bindMemory(to: UInt8.self).baseAddress else {
                        error = true
                        return
                    }
                    stream.dst_ptr = outBase + produced
                    stream.dst_size = outRaw.count - produced
                    if stream.dst_size == 0 {
                        // 需要扩容
                        return
                    }
                    let op = compression_stream_process(&stream, CS_FLAG_FINAL)
                    produced = outRaw.count - stream.dst_size
                    switch op {
                    case CS_STATUS_END: done = true
                    case CS_STATUS_ERROR: error = true
                    case CS_STATUS_OK:
                        if stream.dst_size == 0 {
                            // buffer 满，外层循环会扩容
                        }
                    default: error = true
                    }
                }
                if !done && !error && produced >= output.count {
                    // 扩容到 2 倍
                    let old = output.count
                    output.count = old * 2
                    if output.count > 512 * 1024 * 1024 {  // 512MB 上限
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
    // 标准 CRC32 (zlib 多项式 0xEDB88320)
    var crc: UInt32 = 0xFFFFFFFF
    for byte in data {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB88320 : (crc >> 1)
        }
    }
    return crc ^ 0xFFFFFFFF
}
