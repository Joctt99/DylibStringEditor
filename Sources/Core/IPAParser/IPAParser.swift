import Foundation

// MARK: - IPA 解包 + Mach-O 定位
//
// IPA 本质是 ZIP。Payload/<App>.app/ 下包含：
//   - 主二进制（无扩展名，名为 App 名）
//   - *.dylib           （注入的 tweak / 插件）
//   - Frameworks/X.framework/X   （framework 主二进制，也是 Mach-O，可被注入）
//
// 本模块负责：
//   1) 解压 IPA（ZIPReader）
//   2) 列出所有 Mach-O 文件（按 magic 二次确认）
//   3) 区分 .dylib 后缀 / framework 主二进制 / 其他 Mach-O
//
// 不做：重打包、签名。这两步由后续模块处理。

public enum IPAParserError: Error, CustomStringConvertible {
    case zipReader(ZIPReaderError)
    case notMachO(path: String)

    public var description: String {
        switch self {
        case .zipReader(let e): return "IPA 解包失败：\(e)"
        case .notMachO(let p): return "文件不是 Mach-O：\(p)"
        }
    }
}

public struct IPAEntry {
    /// 在 ZIP 容器内的相对路径（如 "Payload/MyApp.app/libsubstrate.dylib"）
    public let zipPath: String
    /// 解压后的 Mach-O 数据
    public let data: Data
    /// 文件分类：dylib 后缀 / framework 主二进制 / app 主二进制 / 其他
    public let kind: Kind

    public enum Kind {
        case dylib                  // *.dylib
        case frameworkMainBinary    // Frameworks/X.framework/X
        case appMainBinary           // Payload/X.app/X
        case otherMachO              // 其他 Mach-O（如 .app 顶层的未知二进制）
    }

    /// 显示用短名（取 zipPath 最后一段）
    public var displayName: String {
        (zipPath as NSString).lastPathComponent
    }
}

public final class IPAParser {
    private let zip: ZIPReader

    public init(data: Data) throws {
        do {
            self.zip = try ZIPReader(data: data)
        } catch let e as ZIPReaderError {
            throw IPAParserError.zipReader(e)
        }
    }

    // MARK: - 对外 API

    /// 列出所有 Mach-O 条目。同时覆盖 .dylib 后缀和 framework 主二进制。
    /// 内部用 magic 二次校验，确保返回的文件确实是 Mach-O（避免误把 Info.plist 当二进制）
    public func listMachOEntries() throws -> [IPAEntry] {
        let entries = try zip.listEntries()
        var out: [IPAEntry] = []
        for entry in entries {
            // 路径初筛：跳过目录、明显的非二进制文件
            guard !entry.filename.hasSuffix("/"),
                  !entry.filename.hasSuffix(".plist"),
                  !entry.filename.hasSuffix(".nib"),
                  !entry.filename.hasSuffix(".strings"),
                  !entry.filename.hasSuffix(".car"),
                  !entry.filename.hasSuffix(".png"),
                  !entry.filename.hasSuffix(".ttf") else { continue }

            // 解压
            let rawData: Data
            do {
                rawData = try zip.readData(for: entry)
            } catch let e as ZIPReaderError {
                // 跳过无法解压的条目，但不中断整体流程
                // （IPA 里可能有奇怪的元数据文件）
                continue
            } catch {
                continue
            }
            // Mach-O magic 校验
            guard isMachOMagic(data: rawData) else { continue }

            let kind = classify(zipPath: entry.filename)
            out.append(IPAEntry(zipPath: entry.filename, data: rawData, kind: kind))
        }
        return out
    }

    /// 只返回 .dylib 后缀的 Mach-O 条目（最常用的 tweak 注入形式）
    public func listDylibs() throws -> [IPAEntry] {
        try listMachOEntries().filter { $0.kind == .dylib }
    }

    /// 只返回 framework 主二进制（如 Frameworks/MyFW.framework/MyFW）
    public func listFrameworkMainBinaries() throws -> [IPAEntry] {
        try listMachOEntries().filter { $0.kind == .frameworkMainBinary }
    }

    // MARK: - 内部

    /// 判定一个 Data 是否为 Mach-O（含 fat binary）
    /// - Fat: 0xCAFEBABE (BE) / 0xCAFEBABF (BE)
    /// - Thin: 0xFEEDFACE / 0xFEEDFACF (LE on arm64/x86_64)
    private func isMachOMagic(data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        // 用大端读：fat magic 是大端存储
        let b0 = UInt32(data[0]) << 24 | UInt32(data[1]) << 16 | UInt32(data[2]) << 8 | UInt32(data[3])
        if b0 == 0xCAFEBABE || b0 == 0xCAFEBABF { return true }
        // 用小端读：thin magic 是 native 字节序
        let l0 = UInt32(data[0]) | UInt32(data[1]) << 8 | UInt32(data[2]) << 16 | UInt32(data[3]) << 24
        if l0 == 0xFEEDFACE || l0 == 0xFEEDFACF { return true }
        return false
    }

    /// 根据 ZIP 内路径对文件分类
    private func classify(zipPath: String) -> IPAEntry.Kind {
        let path = zipPath as NSString
        let components = path.pathComponents as [String]
        let last = components.last ?? ""
        // 1) .dylib 后缀
        if last.hasSuffix(".dylib") {
            return .dylib
        }
        // 2) framework 主二进制：路径中含 X.framework/X
        //    components[i] == "Y.framework" && components[i+1] == "Y"
        for i in 0..<components.count - 1 {
            let cur = components[i]
            let nxt = components[i + 1]
            if cur.hasSuffix(".framework") {
                let fwName = (cur as NSString).deletingPathExtension
                if nxt == fwName {
                    return .frameworkMainBinary
                }
            }
        }
        // 3) app 主二进制：Payload/X.app/X
        //    components[i] == "X.app" && components[i+1] == "X"
        for i in 0..<components.count - 1 {
            let cur = components[i]
            let nxt = components[i + 1]
            if cur.hasSuffix(".app") {
                let appName = (cur as NSString).deletingPathExtension
                if nxt == appName {
                    return .appMainBinary
                }
            }
        }
        // 4) 其他 Mach-O（如单独的 Executable 文件）
        return .otherMachO
    }
}
