import Foundation

// MARK: - Mach-O 注入器
//
// 往 Mach-O 主二进制中插入 LC_LOAD_DYLIB 加载命令，实现 dylib 注入。
// 同时支持 fat binary（多架构切片），会对每个切片都插入。
//
// 原理：
//   1. 在 load commands 区域末尾追加新的 LC_LOAD_DYLIB
//   2. 更新 mach_header 的 ncmds / sizeofcmds
//   3. 由于 load commands 区域变大，所有 segment data 的文件偏移都要后移，
//      因此更新所有 LC_SEGMENT(_64) 的 fileoff 以及每个 section 的 offset
//   4. 把 segment data 整体后移 delta 字节

public enum MachOInjectorError: Error, CustomStringConvertible {
    case notMachO
    case malformedHeader
    case unsupportedFat64
    case segmentNotFound(String)
    case loadCommandOutOfRange

    public var description: String {
        switch self {
        case .notMachO: return "不是 Mach-O 文件"
        case .malformedHeader: return "Mach-O 头部损坏"
        case .unsupportedFat64: return "暂不支持 fat_64"
        case .segmentNotFound(let s): return "未找到 segment: \(s)"
        case .loadCommandOutOfRange: return "load command 越界"
        }
    }
}

public final class MachOInjector {

    // MARK: - Mach-O 常量

    private let LC_SEGMENT: UInt32 = 0x01
    private let LC_SEGMENT_64: UInt32 = 0x19
    private let LC_LOAD_DYLIB: UInt32 = 0x0C

    private let MH_MAGIC: UInt32 = 0xFEEDFACE
    private let MH_MAGIC_64: UInt32 = 0xFEEDFACF
    private let FAT_MAGIC: UInt32 = 0xCAFEBABE
    private let FAT_MAGIC_64: UInt32 = 0xCAFEBABF

    public init() {}

    // MARK: - 公开 API

    /// 往 Mach-O 数据中注入一个 dylib 加载命令。
    /// - Parameters:
    ///   - data: 原始 Mach-O 数据（thin 或 fat）
    ///   - dylibPath: dylib 的运行时路径，如 "@executable_path/Plugin.dylib"
    /// - Returns: 修改后的 Mach-O 数据
    public func injectDylib(data: Data, dylibPath: String) throws -> Data {
        AppLog.shared.write("MachOInjector.injectDylib: path=\(dylibPath), dataSize=\(data.count)")
        guard data.count >= 4 else { throw MachOInjectorError.notMachO }

        let magic = data.readUInt32LE(at: 0) ?? 0
        let magicBE = data.readUInt32BE(at: 0) ?? 0

        if magic == MH_MAGIC || magic == MH_MAGIC_64 {
            return try injectThin(data: data, dylibPath: dylibPath)
        } else if magicBE == FAT_MAGIC || magicBE == FAT_MAGIC_64 {
            return try injectFat(data: data, dylibPath: dylibPath, magicBE: magicBE)
        } else {
            throw MachOInjectorError.notMachO
        }
    }

    // MARK: - Thin Mach-O 注入

    private func injectThin(data: Data, dylibPath: String) throws -> Data {
        guard let magic = data.readUInt32LE(at: 0) else { throw MachOInjectorError.notMachO }
        let is64: Bool
        switch magic {
        case MH_MAGIC: is64 = false
        case MH_MAGIC_64: is64 = true
        default: throw MachOInjectorError.notMachO
        }

        let headerSize = is64 ? 32 : 28
        guard data.count >= headerSize else { throw MachOInjectorError.malformedHeader }

        guard let ncmds = data.readUInt32LE(at: 16),
              let sizeofcmds = data.readUInt32LE(at: 20) else {
            throw MachOInjectorError.malformedHeader
        }

        AppLog.shared.write("  thin: is64=\(is64), ncmds=\(ncmds), sizeofcmds=\(sizeofcmds)")

        // 构建 LC_LOAD_DYLIB 命令
        let dylibCmd = buildLoadDylibCommand(dylibPath: dylibPath)
        let cmdSize = dylibCmd.count
        let delta = cmdSize

        // 新文件 = header + 原 load commands + 新 LC_LOAD_DYLIB + segment data（后移 delta）
        var result = Data()

        // 1. 拷贝 header（修改 ncmds 和 sizeofcmds）
        var header = data.subdata(in: 0..<headerSize)
        let newNcmds = ncmds + 1
        let newSizeofcmds = sizeofcmds + UInt32(delta)
        header.writeUInt32LE(newNcmds, at: 16)
        header.writeUInt32LE(newSizeofcmds, at: 20)
        result.append(header)

        // 2. 拷贝原 load commands（更新所有 LC_SEGMENT 的 fileoff 和 section offset）
        let cmdsStart = headerSize
        let cmdsEnd = cmdsStart + Int(sizeofcmds)
        var cmdCursor = cmdsStart
        for _ in 0..<Int(ncmds) {
            guard cmdCursor + 8 <= cmdsEnd,
                  let cmd = data.readUInt32LE(at: cmdCursor),
                  let cmdsize = data.readUInt32LE(at: cmdCursor + 4) else {
                throw MachOInjectorError.malformedHeader
            }
            let cmdEnd = cmdCursor + Int(cmdsize)
            guard cmdEnd <= cmdsEnd else { throw MachOInjectorError.loadCommandOutOfRange }

            var cmdData = data.subdata(in: cmdCursor..<cmdEnd)

            // 更新 LC_SEGMENT / LC_SEGMENT_64 的 fileoff 和 section offset
            if cmd == LC_SEGMENT_64 {
                try updateSegment64(&cmdData, delta: delta)
            } else if cmd == LC_SEGMENT {
                try updateSegment(&cmdData, delta: delta)
            }

            result.append(cmdData)
            cmdCursor = cmdEnd
        }

        // 3. 追加新的 LC_LOAD_DYLIB
        result.append(dylibCmd)

        // 4. 拷贝 segment data（原样拷贝，因为我们已经更新了 fileoff）
        //    segment data 从 cmdsEnd 开始
        if cmdsEnd < data.count {
            result.append(data.subdata(in: cmdsEnd..<data.count))
        }

        AppLog.shared.write("  thin 注入完成: 原大小=\(data.count), 新大小=\(result.count), delta=\(delta)")
        return result
    }

    // MARK: - Fat Mach-O 注入

    private func injectFat(data: Data, dylibPath: String, magicBE: UInt32) throws -> Data {
        let is64 = (magicBE == FAT_MAGIC_64)
        if is64 {
            AppLog.shared.write("  fat_64 暂不支持，尝试按 fat_32 处理")
            // fat_64 也可以处理，但 arch record 格式不同。这里先尝试 fat_32 解析
            // 大多数 iOS IPA 是 fat_32
        }

        guard let nfat = data.readUInt32BE(at: 4) else { throw MachOInjectorError.malformedHeader }
        AppLog.shared.write("  fat: nfat=\(nfat)")

        // 解析每个 arch record
        struct ArchRecord {
            let cputype: UInt32
            let cpusubtype: UInt32
            let offset: UInt32
            let size: UInt32
            let align: UInt32
        }
        var archs: [ArchRecord] = []
        let archRecSize = 20
        for i in 0..<Int(nfat) {
            let recOff = 8 + i * archRecSize
            guard recOff + archRecSize <= data.count else { throw MachOInjectorError.malformedHeader }
            guard let cpu = data.readUInt32BE(at: recOff),
                  let sub = data.readUInt32BE(at: recOff + 4),
                  let off = data.readUInt32BE(at: recOff + 8),
                  let sz = data.readUInt32BE(at: recOff + 12),
                  let al = data.readUInt32BE(at: recOff + 16) else {
                throw MachOInjectorError.malformedHeader
            }
            archs.append(ArchRecord(cputype: cpu, cpusubtype: sub, offset: off, size: sz, align: al))
        }

        // 对每个切片注入
        var newSlices: [Data] = []
        for arch in archs {
            let sliceStart = Int(arch.offset)
            let sliceEnd = sliceStart + Int(arch.size)
            guard sliceEnd <= data.count else { throw MachOInjectorError.malformedHeader }
            let sliceData = data.subdata(in: sliceStart..<sliceEnd)
            let newSlice = try injectThin(data: sliceData, dylibPath: dylibPath)
            newSlices.append(newSlice)
        }

        // 重新组装 fat binary
        // 对齐：每个切片需要按 align 对齐（align 是 2 的幂的指数）
        var result = Data()
        // fat header: magic(4) + nfat(4) = 8 字节
        result.appendUInt32BE(magicBE)
        result.appendUInt32BE(nfat)

        // 计算每个切片的偏移和大小
        var currentOffset = 8 + Int(nfat) * archRecSize
        var newArchs: [(offset: UInt32, size: UInt32)] = []
        for (i, slice) in newSlices.enumerated() {
            let align = Int(archs[i].align)
            let alignment = 1 << align
            // 对齐到 alignment
            let alignedOffset = (currentOffset + alignment - 1) & ~(alignment - 1)
            let padSize = alignedOffset - currentOffset
            // 预留填充
            currentOffset = alignedOffset + slice.count
            newArchs.append((offset: UInt32(alignedOffset), size: UInt32(slice.count)))
            _ = padSize
        }

        // 写入 arch records
        for (i, arch) in newArchs.enumerated() {
            result.appendUInt32BE(archs[i].cputype)
            result.appendUInt32BE(archs[i].cpusubtype)
            result.appendUInt32BE(arch.offset)
            result.appendUInt32BE(arch.size)
            result.appendUInt32BE(archs[i].align)
        }

        // 写入切片数据（带对齐填充）
        currentOffset = 8 + Int(nfat) * archRecSize
        for (i, slice) in newSlices.enumerated() {
            let align = Int(archs[i].align)
            let alignment = 1 << align
            let alignedOffset = (currentOffset + alignment - 1) & ~(alignment - 1)
            let padSize = alignedOffset - currentOffset
            if padSize > 0 {
                result.append(Data(count: padSize))
            }
            result.append(slice)
            currentOffset = alignedOffset + slice.count
        }

        AppLog.shared.write("  fat 注入完成: 原大小=\(data.count), 新大小=\(result.count)")
        return result
    }

    // MARK: - 构建 LC_LOAD_DYLIB 命令

    /// 构建 LC_LOAD_DYLIB 命令字节
    /// dylib_command 结构：
    ///   cmd          (4)  = LC_LOAD_DYLIB
    ///   cmdsize      (4)  = 24 + nameSize (4 字节对齐)
    ///   name.offset  (4)  = 24 (name 在命令中的偏移)
    ///   timestamp    (4)  = 0
    ///   current_ver  (4)  = 0x10000 (1.0.0)
    ///   compat_ver   (4)  = 0x10000 (1.0.0)
    ///   name         (N)  = null-terminated string, padded to 4-byte alignment
    private func buildLoadDylibCommand(dylibPath: String) -> Data {
        var cmd = Data()
        // name 字符串 + null terminator
        var nameBytes = Array(dylibPath.utf8)
        nameBytes.append(0)  // null terminator
        // 4 字节对齐
        let paddedNameSize = (nameBytes.count + 3) & ~3
        let padding = paddedNameSize - nameBytes.count

        let cmdsize: UInt32 = 24 + UInt32(paddedNameSize)

        cmd.appendUInt32LE(LC_LOAD_DYLIB)
        cmd.appendUInt32LE(cmdsize)
        cmd.appendUInt32LE(24)              // name.offset
        cmd.appendUInt32LE(0)               // timestamp
        cmd.appendUInt32LE(0x00010000)      // current_version = 1.0.0
        cmd.appendUInt32LE(0x00010000)      // compatibility_version = 1.0.0
        cmd.append(contentsOf: nameBytes)
        if padding > 0 {
            cmd.append(contentsOf: [UInt8](repeating: 0, count: padding))
        }
        return cmd
    }

    // MARK: - 更新 LC_SEGMENT_64

    /// 更新 segment_command_64 的 fileoff 和所有 section 的 offset
    private func updateSegment64(_ cmdData: inout Data, delta: Int) throws {
        // segment_command_64:
        //   cmd(4) cmdsize(4) segname(16) vmaddr(8) vmsize(8) fileoff(8) filesize(8) ...
        //   maxprot(4) initprot(4) nsects(4) flags(4)  = 72 字节
        guard cmdData.count >= 72 else { throw MachOInjectorError.loadCommandOutOfRange }

        // fileoff 在 offset 40（8 字节）
        if let fileoff = cmdData.readUInt64LE(at: 40) {
            cmdData.writeUInt64LE(fileoff + UInt64(delta), at: 40)
        }

        // nsects 在 offset 64
        guard let nsects = cmdData.readUInt32LE(at: 64) else { return }
        let sectionRecSize = 80
        var secCursor = 72
        for _ in 0..<Int(nsects) {
            guard secCursor + sectionRecSize <= cmdData.count else { break }
            // section_64: offset 在 +48（8 字节）
            if let offset = cmdData.readUInt64LE(at: secCursor + 48) {
                cmdData.writeUInt64LE(offset + UInt64(delta), at: secCursor + 48)
            }
            secCursor += sectionRecSize
        }
    }

    // MARK: - 更新 LC_SEGMENT (32-bit)

    private func updateSegment(_ cmdData: inout Data, delta: Int) throws {
        // segment_command:
        //   cmd(4) cmdsize(4) segname(16) vmaddr(4) vmsize(4) fileoff(4) filesize(4) ...
        //   maxprot(4) initprot(4) nsects(4) flags(4)  = 56 字节
        guard cmdData.count >= 56 else { throw MachOInjectorError.loadCommandOutOfRange }

        // fileoff 在 offset 32（4 字节）
        if let fileoff = cmdData.readUInt32LE(at: 32) {
            cmdData.writeUInt32LE(fileoff + UInt32(delta), at: 32)
        }

        // nsects 在 offset 48
        guard let nsects = cmdData.readUInt32LE(at: 48) else { return }
        let sectionRecSize = 68
        var secCursor = 56
        for _ in 0..<Int(nsects) {
            guard secCursor + sectionRecSize <= cmdData.count else { break }
            // section: offset 在 +40（4 字节）
            if let offset = cmdData.readUInt32LE(at: secCursor + 40) {
                cmdData.writeUInt32LE(offset + UInt32(delta), at: secCursor + 40)
            }
            secCursor += sectionRecSize
        }
    }
}

// MARK: - Data 小端写入扩展

internal extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(value & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 24) & 0xff))
    }
    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xff))
        append(UInt8((value >> 16) & 0xff))
        append(UInt8((value >> 8) & 0xff))
        append(UInt8(value & 0xff))
    }
    mutating func appendUInt64LE(_ value: UInt64) {
        for i in 0..<8 {
            append(UInt8((value >> (8 * i)) & 0xff))
        }
    }
    mutating func writeUInt32LE(_ value: UInt32, at offset: Int) {
        guard offset >= 0, offset + 4 <= count else { return }
        self[offset] = UInt8(value & 0xff)
        self[offset + 1] = UInt8((value >> 8) & 0xff)
        self[offset + 2] = UInt8((value >> 16) & 0xff)
        self[offset + 3] = UInt8((value >> 24) & 0xff)
    }
    mutating func writeUInt64LE(_ value: UInt64, at offset: Int) {
        guard offset >= 0, offset + 8 <= count else { return }
        for i in 0..<8 {
            self[offset + i] = UInt8((value >> (8 * i)) & 0xff)
        }
    }
}
