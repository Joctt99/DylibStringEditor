import Foundation

// MARK: - 字符串编码

public enum MachOStringEncoding: Equatable {
    /// UTF-8 null-terminated（单字节 0x00 结尾）。覆盖 __cstring / __objc_methname 等
    case utf8
    /// UTF-16LE null-terminated（双字节 0x00 0x00 结尾）。覆盖 __ustring
    case utf16le

    internal var terminatorSize: Int {
        switch self {
        case .utf8: return 1
        case .utf16le: return 2
        }
    }

    internal func encode(_ string: String) -> Data? {
        switch self {
        case .utf8:
            return string.data(using: .utf8)
        case .utf16le:
            return string.data(using: .utf16LittleEndian)
        }
    }

    internal func decode(_ data: Data) -> String? {
        switch self {
        case .utf8:
            return String(data: data, encoding: .utf8)
        case .utf16le:
            return String(data: data, encoding: .utf16LittleEndian)
        }
    }

    /// 根据 (segment, section) 决定编码，未列入白名单的 section 返回 nil（视为不含可编辑字符串）
    internal static func detect(forSegment segment: String, section: String) -> MachOStringEncoding? {
        // __TEXT 段里的 C 串类 section：UTF-8
        let utf8Sections: Set<String> = [
            "__cstring",          // 标准 C 字符串
            "__objc_classname",   // ObjC 类名
            "__objc_methname",    // ObjC 方法名
            "__objc_methtype",    // ObjC 方法类型签名
            "__objc_methname2",   // 部分 Xcode 版本会有
            "__swift5_reflstr",   // Swift 反射字符串（可读，但慎改）
            "__swift5_proto",     // Swift 协议
        ]
        if segment == "__TEXT" && utf8Sections.contains(section) {
            return .utf8
        }
        // __ustring：UTF-16LE
        if segment == "__TEXT" && section == "__ustring" {
            return .utf16le
        }
        // 显式不编辑：__cfstring 是结构体数组（指向 __cstring），不动它
        return nil
    }
}

// MARK: - 对外类型

public struct MachOString: Equatable {
    public let segment: String
    public let section: String
    public let sliceIndex: Int
    public let sliceArch: String
    public let fileOffset: Int
    public let byteLength: Int      // 不含结尾 null
    public let encoding: MachOStringEncoding
    public let value: String
}

public struct MachOReplacement: Equatable {
    public let original: String
    public let replacement: String
    public init(original: String, replacement: String) {
        self.original = original
        self.replacement = replacement
    }
}

public enum MachOStringEditorError: Error, CustomStringConvertible {
    case notMachO
    case malformedHeader
    case malformedLoadCommand(index: Int)
    case encodingFailed(string: String)
    case newStringTooLong(slice: Int, arch: String, section: String, oldBytes: Int, newBytes: Int, original: String)
    case noMatch(replacement: MachOReplacement)
    case ambiguousMatch(replacement: MachOReplacement, count: Int)

    public var description: String {
        switch self {
        case .notMachO:
            return "输入数据不是 Mach-O 文件"
        case .malformedHeader:
            return "Mach-O header 解析失败"
        case .malformedLoadCommand(let i):
            return "load command \(i) 解析失败"
        case .encodingFailed(let s):
            return "字符串按目标编码失败：\(s)"
        case .newStringTooLong(let slice, let arch, let sec, let old, let new, let orig):
            return "[切片\(slice) \(arch)/\(sec)] 新串字节过长：\(new) > \(old)（原文：\(orig)）。新串必须不超原串字节长度。"
        case .noMatch(let r):
            return "未找到匹配字符串：\"\(r.original)\""
        case .ambiguousMatch(let r, let n):
            return "字符串\"\(r.original)\"匹配到 \(n) 处，但要求唯一。请用 applyReplacements 批量替换。"
        }
    }
}

// MARK: - MachOStringEditor

public final class MachOStringEditor {
    private let originalData: Data
    private let binaries: [MachOBinary]

    public init(data: Data) throws {
        self.originalData = data
        self.binaries = try MachOBinary.parseAll(data: data)
    }

    public var sliceCount: Int { binaries.count }
    public var archNames: [String] { binaries.map { $0.archName } }

    /// 列出所有切片、所有可编辑 section 中的字符串。
    /// 多个切片里相同字串会重复列出（偏移不同），便于上层按位置修改。
    public func listStrings() -> [MachOString] {
        var out: [MachOString] = []
        for bin in binaries {
            for sec in bin.sections {
                out.append(contentsOf: extractStrings(in: sec, data: originalData, slice: bin))
            }
        }
        return out
    }

    /// 按子串过滤
    public func search(needle: String) -> [MachOString] {
        listStrings().filter { $0.value.contains(needle) }
    }

    /// 批量替换：对每个 replacement，把所有切片所有 section 中**完全相等**的字串原值替换为新串。
    /// - 一次调用可传入多条替换
    /// - 新串字节长度必须 ≤ 原串字节长度（按各 section 的 encoding 计算），否则抛 newStringTooLong
    /// - 任何一条 replacement 没匹配到都抛 noMatch（便于上层核对输入）
    public func applyReplacements(_ replacements: [MachOReplacement]) throws -> Data {
        var working = originalData
        for r in replacements {
            try applySingle(replacement: r, data: &working)
        }
        return working
    }

    /// 单条替换便捷接口。默认 replaceAll=true（所有匹配都换）；
    /// 若 replaceAll=false 但匹配数 > 1，抛 ambiguousMatch，避免误改。
    public func applyReplacement(
        _ original: String,
        _ replacement: String,
        replaceAll: Bool = true
    ) throws -> Data {
        let r = MachOReplacement(original: original, replacement: replacement)
        if replaceAll {
            return try applyReplacements([r])
        }
        // 唯一性校验
        let count = listStrings().filter { $0.value == original }.count
        if count == 0 { throw MachOStringEditorError.noMatch(replacement: r) }
        if count > 1 { throw MachOStringEditorError.ambiguousMatch(replacement: r, count: count) }
        return try applyReplacements([r])
    }

    // MARK: - 内部

    private func applySingle(replacement r: MachOReplacement, data: inout Data) throws {
        // 预编码新串，按每种 encoding 各试一次（不同 section 可能不同编码）
        // 记录所有命中点
        struct Hit {
            let bin: MachOBinary
            let sec: MachOBinary.ParsedSection
            let strOffset: Int    // 字串在文件中的偏移（null 之前）
            let strLen: Int       // 字串字节数（不含 null）
        }
        var hits: [Hit] = []
        for bin in binaries {
            for sec in bin.sections {
                for (off, len) in iterateCStringOffsets(in: sec, data: data) {
                    let raw = data.subdata(in: off..<(off + len))
                    if let s = sec.encoding.decode(raw), s == r.original {
                        hits.append(Hit(bin: bin, sec: sec, strOffset: off, strLen: len))
                    }
                }
            }
        }
        if hits.isEmpty {
            throw MachOStringEditorError.noMatch(replacement: r)
        }

        // 应用替换
        for h in hits {
            guard let newBytes = h.sec.encoding.encode(r.replacement) else {
                throw MachOStringEditorError.encodingFailed(string: r.replacement)
            }
            let newLen = newBytes.count
            if newLen > h.strLen {
                throw MachOStringEditorError.newStringTooLong(
                    slice: h.bin.sliceIndex,
                    arch: h.bin.archName,
                    section: h.sec.section,
                    oldBytes: h.strLen,
                    newBytes: newLen,
                    original: r.original
                )
            }
            // 写入新串字节
            data.writeBytes(Array(newBytes), at: h.strOffset)
            // 剩余区域（含原 null 位）全部清 0，保证后续 null 终止符有效
            let padStart = h.strOffset + newLen
            let padEnd = h.strOffset + h.strLen + h.sec.encoding.terminatorSize
            data.zeroFill(at: padStart, length: padEnd - padStart)
        }
    }

    /// 提取某 section 里所有 C 字符串
    private func extractStrings(in sec: MachOBinary.ParsedSection, data: Data, slice: MachOBinary) -> [MachOString] {
        var out: [MachOString] = []
        for (off, len) in iterateCStringOffsets(in: sec, data: data) {
            let raw = data.subdata(in: off..<(off + len))
            if let s = sec.encoding.decode(raw) {
                out.append(MachOString(
                    segment: sec.segment,
                    section: sec.section,
                    sliceIndex: slice.sliceIndex,
                    sliceArch: slice.archName,
                    fileOffset: off,
                    byteLength: len,
                    encoding: sec.encoding,
                    value: s
                ))
            }
        }
        return out
    }

    /// 扫描一个 section 的字节范围，返回每个 C 字符串的 (起点偏移, 字节长度不含 null)
    /// - UTF-8: 遇 0x00 结束
    /// - UTF-16LE: 遇 0x00 0x00 结束（注意代理对的 0x00 字节不能误判，UTF-16LE 的 null 是双 0）
    private func iterateCStringOffsets(in sec: MachOBinary.ParsedSection, data: Data) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        let start = sec.dataOffset
        let end = sec.dataOffset + sec.size
        guard start >= 0, end <= data.count, start <= end else { return [] }
        var cursor = start
        switch sec.encoding {
        case .utf8:
            while cursor < end {
                // 跳过连续 null（多个串之间的对齐填充）
                while cursor < end, data[cursor] == 0 { cursor += 1 }
                guard cursor < end else { break }
                let s = cursor
                while cursor < end, data[cursor] != 0 { cursor += 1 }
                let len = cursor - s
                if len > 0 {
                    result.append((s, len))
                }
                // cursor 现在指向 null 或 end，下次循环会跳过 null
            }
        case .utf16le:
            while cursor < end {
                // 跳过连续的 null 对（0x00 0x00）
                while cursor + 1 < end, data[cursor] == 0, data[cursor + 1] == 0 { cursor += 2 }
                guard cursor + 1 < end else { break }
                let s = cursor
                while cursor + 1 < end {
                    if data[cursor] == 0, data[cursor + 1] == 0 { break }
                    cursor += 2
                }
                let len = cursor - s
                if len > 0 {
                    result.append((s, len))
                }
            }
        }
        return result
    }
}
