import Foundation

// MARK: - Mach-O 字节布局常量

private let FAT_MAGIC: UInt32 = 0xCAFEBABE
private let FAT_MAGIC_64: UInt32 = 0xCAFEBABF
private let FAT_CIGAM: UInt32 = 0xBEBAFECA      // big-endian fat
private let FAT_CIGAM_64: UInt32 = 0xBFBAFECA

private let MH_MAGIC: UInt32 = 0xFEEDFACE
private let MH_MAGIC_64: UInt32 = 0xFEEDFACF

private let LC_SEGMENT: UInt32 = 0x01
private let LC_SEGMENT_64: UInt32 = 0x19

private let CPU_TYPE_ARM: Int32 = 0x0000000C
private let CPU_TYPE_ARM64: Int32 = 0x0100000C
private let CPU_TYPE_X86: Int32 = 0x00000007
private let CPU_TYPE_X86_64: Int32 = 0x01000007

// MARK: - Data 小端读写辅助

internal extension Data {
    /// 从 self 的 offset 处读取一个小端 UInt32
    func readUInt32LE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let v = UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
        return v
    }
    /// 从 self 的 offset 处读取一个大端 UInt32（fat header 是大端）
    func readUInt32BE(at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let b0 = UInt32(self[offset]) << 24
        let b1 = UInt32(self[offset + 1]) << 16
        let b2 = UInt32(self[offset + 2]) << 8
        let b3 = UInt32(self[offset + 3])
        return b0 | b1 | b2 | b3
    }
    /// 从 self 的 offset 处读取一个小端 UInt64
    func readUInt64LE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(self[offset + i]) << (8 * i)
        }
        return v
    }
    /// 从 self 的 offset 处读取一个大端 UInt64（fat_arch_64 的 offset/size 是大端）
    func readUInt64BE(at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        var v: UInt64 = 0
        for i in 0..<8 {
            v = (v << 8) | UInt64(self[offset + i])
        }
        return v
    }
    /// 从 self 的 offset 处读取一个小端 Int32
    func readInt32LE(at offset: Int) -> Int32? {
        guard let u = readUInt32LE(at: offset) else { return nil }
        return Int32(bitPattern: u)
    }
    /// 从 offset 处读取 length 字节的 C 字符串（null-terminated）
    func readCString(at offset: Int, maxLength: Int) -> String? {
        guard offset >= 0, offset < count else { return nil }
        var end = offset
        while end < min(offset + maxLength, count), self[end] != 0 {
            end += 1
        }
        let raw = subdata(in: offset..<end)
        return String(data: raw, encoding: .utf8)
    }
    /// 把字节写入指定 offset（不改变大小）
    mutating func writeBytes(_ bytes: [UInt8], at offset: Int) {
        guard offset >= 0, offset + bytes.count <= count else { return }
        for (i, b) in bytes.enumerated() {
            self[offset + i] = b
        }
    }
    /// 填充 0
    mutating func zeroFill(at offset: Int, length: Int) {
        guard offset >= 0, offset + length <= count else { return }
        for i in 0..<length {
            self[offset + i] = 0
        }
    }
}

// MARK: - Fat / Mach-O 解析

/// 单架构 Mach-O 的解析结果。`sliceOffset` 是该切片在整个文件中的起始偏移。
internal struct MachOBinary {
    let sliceIndex: Int
    let sliceOffset: Int          // 在整个文件里的偏移
    let sliceSize: Int
    let is64Bit: Bool
    let headerSize: Int          // mach_header(_64) 大小：28 或 32
    let cputype: Int32
    let cpusubtype: Int32
    let sections: [ParsedSection]

    var archName: String {
        switch cputype {
        case CPU_TYPE_ARM: return "arm"
        case CPU_TYPE_ARM64: return "arm64"
        case CPU_TYPE_X86: return "x86"
        case CPU_TYPE_X86_64: return "x86_64"
        default: return "cpu_\(cputype)"
        }
    }

    internal struct ParsedSection {
        let segment: String
        let section: String
        let dataOffset: Int    // 在整个文件中的偏移（= sliceOffset + section.offset）
        let size: Int
        /// 字符串编码：UTF-8 null-terminated 单字节结尾 vs UTF-16LE 双字节结尾
        let encoding: MachOStringEncoding
    }

    /// 解析整个 Data，自动识别 fat / thin。返回所有切片。
    /// - fat_header 的 magic 总是大端存储，所以 fat 用 readUInt32BE 判定
    /// - thin Mach-O 的 magic 按 native 字节序存储；arm64 / x86_64 都是小端，
    ///   所以 thin 用 readUInt32LE 判定
    static func parseAll(data: Data) throws -> [MachOBinary] {
        guard data.count >= 4 else { throw MachOStringEditorError.notMachO }
        // 先按大端读 magic，判断 fat
        if let be = data.readUInt32BE(at: 0),
           be == FAT_MAGIC || be == FAT_CIGAM || be == FAT_MAGIC_64 || be == FAT_CIGAM_64 {
            return try parseFat(data: data, magicBE: be)
        }
        // 再按小端读 magic，判断 thin（arm64 / x86_64 主流）
        if let le = data.readUInt32LE(at: 0), le == MH_MAGIC || le == MH_MAGIC_64 {
            return [try parseThin(data: data, sliceOffset: 0, sliceSize: data.count, sliceIndex: 0)]
        }
        throw MachOStringEditorError.notMachO
    }

    private static func parseFat(data: Data, magicBE magic: UInt32) throws -> [MachOBinary] {
        guard let nfat = data.readUInt32BE(at: 4) else { throw MachOStringEditorError.malformedHeader }
        let is64 = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64)
        let archRecSize = is64 ? 32 : 20
        var binaries: [MachOBinary] = []
        for i in 0..<Int(nfat) {
            let recOff = 8 + i * archRecSize
            guard recOff + archRecSize <= data.count else { throw MachOStringEditorError.malformedHeader }
            // 注意：fat_arch 字段在大端；cputype/cpusubtype 这里只读取校验存在，
            // 真正用于 archName 的是切片内部 mach_header 里的小端 cputype
            guard data.readUInt32BE(at: recOff) != nil,
                  data.readUInt32BE(at: recOff + 4) != nil,
                  let size = data.readUInt32BE(at: recOff + 12) else {
                throw MachOStringEditorError.malformedHeader
            }
            let offset: UInt32
            if let off = data.readUInt32BE(at: recOff + 8) { offset = off } else { throw MachOStringEditorError.malformedHeader }
            // 64 位偏移要看 64 位字段
            let finalOffset: Int
            if is64 {
                guard let off64 = data.readUInt64BE(at: recOff + 8) else { throw MachOStringEditorError.malformedHeader }
                finalOffset = Int(off64)
            } else {
                finalOffset = Int(offset)
            }
            let finalSize = Int(size)
            let bin = try parseThin(data: data, sliceOffset: finalOffset, sliceSize: finalSize, sliceIndex: i)
            binaries.append(bin)
        }
        return binaries
    }

    private static func parseThin(data: Data, sliceOffset: Int, sliceSize: Int, sliceIndex: Int) throws -> MachOBinary {
        guard sliceOffset + 4 <= data.count else { throw MachOStringEditorError.notMachO }
        // 这里 magic 是小端
        guard let magic = data.readUInt32LE(at: sliceOffset) else { throw MachOStringEditorError.notMachO }
        let is64: Bool
        switch magic {
        case MH_MAGIC: is64 = false
        case MH_MAGIC_64: is64 = true
        default: throw MachOStringEditorError.notMachO
        }
        let headerSize = is64 ? 32 : 28
        guard sliceOffset + headerSize <= data.count else { throw MachOStringEditorError.malformedHeader }
        guard let cputype = data.readInt32LE(at: sliceOffset + 4),
              let _ = data.readInt32LE(at: sliceOffset + 8),
              let ncmds = data.readUInt32LE(at: sliceOffset + 16),
              let sizeofcmds = data.readUInt32LE(at: sliceOffset + 20) else {
            throw MachOStringEditorError.malformedHeader
        }

        var sections: [ParsedSection] = []
        // load commands 从 header 后开始
        var cmdCursor = sliceOffset + headerSize
        let cmdsEnd = cmdCursor + Int(sizeofcmds)
        guard cmdsEnd <= data.count else { throw MachOStringEditorError.malformedHeader }
        for _ in 0..<Int(ncmds) {
            guard cmdCursor + 8 <= cmdsEnd,
                  let cmd = data.readUInt32LE(at: cmdCursor),
                  let cmdsize = data.readUInt32LE(at: cmdCursor + 4) else {
                throw MachOStringEditorError.malformedLoadCommand(index: -1)
            }
            if cmdsize == 0 { throw MachOStringEditorError.malformedLoadCommand(index: -1) }
            if cmd == LC_SEGMENT_64 || cmd == LC_SEGMENT {
                let segIs64 = (cmd == LC_SEGMENT_64)
                let segNameOff = cmdCursor + 8
                let segName = data.readCString(at: segNameOff, maxLength: 16) ?? ""
                let nsects: UInt32
                let segHdrSize: Int
                if segIs64 {
                    // segment_command_64 总长 72；nsects 在 offset 64
                    guard let n = data.readUInt32LE(at: cmdCursor + 64) else {
                        throw MachOStringEditorError.malformedLoadCommand(index: -1)
                    }
                    nsects = n
                    segHdrSize = 72
                } else {
                    // segment_command 总长 56；nsects 在 offset 48
                    guard let n = data.readUInt32LE(at: cmdCursor + 48) else {
                        throw MachOStringEditorError.malformedLoadCommand(index: -1)
                    }
                    nsects = n
                    segHdrSize = 56
                }
                let sectionRecSize = segIs64 ? 80 : 68
                var secCursor = cmdCursor + segHdrSize
                for _ in 0..<Int(nsects) {
                    guard secCursor + sectionRecSize <= cmdCursor + Int(cmdsize) else {
                        throw MachOStringEditorError.malformedLoadCommand(index: -1)
                    }
                    let sectName = data.readCString(at: secCursor, maxLength: 16) ?? ""
                    let sectSegName = data.readCString(at: secCursor + 16, maxLength: 16) ?? ""
                    // section_64: offset 在 +48, size 在 +40
                    // section:    offset 在 +40, size 在 +36
                    let sizeOff: Int
                    let offOff: Int
                    if segIs64 {
                        sizeOff = secCursor + 40
                        offOff = secCursor + 48
                    } else {
                        sizeOff = secCursor + 36
                        offOff = secCursor + 40
                    }
                    guard let secSize = segIs64 ? data.readUInt64LE(at: sizeOff) : data.readUInt32LE(at: sizeOff),
                          let secOff = segIs64 ? data.readUInt64LE(at: offOff) : data.readUInt32LE(at: offOff) else {
                        throw MachOStringEditorError.malformedLoadCommand(index: -1)
                    }
                    if let enc = MachOStringEncoding.detect(forSegment: sectSegName, section: sectName) {
                        let absOffset = sliceOffset + Int(secOff)
                        sections.append(ParsedSection(
                            segment: sectSegName,
                            section: sectName,
                            dataOffset: absOffset,
                            size: Int(secSize),
                            encoding: enc
                        ))
                    }
                    secCursor += sectionRecSize
                }
            }
            cmdCursor += Int(cmdsize)
        }
        return MachOBinary(
            sliceIndex: sliceIndex,
            sliceOffset: sliceOffset,
            sliceSize: sliceSize,
            is64Bit: is64,
            headerSize: headerSize,
            cputype: cputype,
            cpusubtype: 0,
            sections: sections
        )
    }
}
