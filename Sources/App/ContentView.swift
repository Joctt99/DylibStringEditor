import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - App 全局状态

@MainActor
final class AppModel: ObservableObject {
    @Published var ipaData: Data?
    @Published var ipaFileName: String?
    @Published var entries: [IPAEntry] = []
    @Published var errorMessage: String?
    @Published var isLoading = false
    /// 导入流程诊断信息（用于定位"无反应/闪退"问题卡在哪一步）
    @Published var importDiag: String = "等待操作"
    /// 已加载的待注入 dylib 列表
    @Published var injectedDylibs: [InjectedDylib] = []

    /// 已修改的 dylib 数据缓存：zipPath -> modifiedData
    private(set) var modifiedDylibs: [String: Data] = [:]

    /// 待注入的 dylib
    struct InjectedDylib: Identifiable {
        let id = UUID()
        let name: String
        let data: Data
    }

    func loadIPA(_ data: Data, fileName: String) {
        self.ipaData = data
        self.ipaFileName = fileName
        self.entries = []
        self.modifiedDylibs.removeAll()
        self.errorMessage = nil
        self.isLoading = true
        self.importDiag = "正在解析 IPA（\(data.count) 字节）..."
        AppLog.shared.write("loadIPA 开始: fileName=\(fileName), dataSize=\(data.count)")
        let dataCopy = data
        Task.detached(priority: .userInitiated) {
            do {
                AppLog.shared.write("创建 IPAParser...")
                let parser = try IPAParser(data: dataCopy)
                AppLog.shared.write("IPAParser 创建成功，开始 listMachOEntries...")
                let list = try parser.listMachOEntries()
                AppLog.shared.write("listMachOEntries 完成: 找到 \(list.count) 个 Mach-O")
                await MainActor.run {
                    self.entries = list.sorted { $0.zipPath < $1.zipPath }
                    self.isLoading = false
                    self.importDiag = "解析完成：找到 \(list.count) 个 Mach-O"
                }
            } catch {
                AppLog.shared.write("解析失败: \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                    self.importDiag = "解析失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 获取某 entry 当前数据（可能已被修改）
    func currentData(for entry: IPAEntry) -> Data {
        if let d = modifiedDylibs[entry.zipPath] { return d }
        return entry.data
    }

    /// 保存对某 dylib 的修改
    func setModifiedData(_ data: Data, for entry: IPAEntry) {
        modifiedDylibs[entry.zipPath] = data
    }

    var modifiedEntries: [IPAEntry] {
        entries.filter { modifiedDylibs[$0.zipPath] != nil }
    }

    /// 组装修改后的完整 IPA 数据（替换被修改的 dylib）
    func buildModifiedIPA() throws -> Data {
        guard let original = ipaData else { throw ExportError.noIPALoaded }
        return try IPAExporter.buildModifiedIPA(original: original, modifiedDylibs: modifiedDylibs)
    }

    /// 添加待注入的 dylib
    func addInjectedDylib(name: String, data: Data) {
        // 去重：如果同名已存在则替换
        injectedDylibs.removeAll { $0.name == name }
        injectedDylibs.append(InjectedDylib(name: name, data: data))
        AppLog.shared.write("addInjectedDylib: \(name), size=\(data.count)")
    }

    /// 移除待注入的 dylib
    func removeInjectedDylib(_ dylib: InjectedDylib) {
        injectedDylibs.removeAll { $0.id == dylib.id }
    }

    /// 构建注入了 dylib 的 IPA（同时保留已修改的 dylib）
    func buildInjectedIPA() throws -> Data {
        guard let original = ipaData else { throw ExportError.noIPALoaded }
        guard !injectedDylibs.isEmpty else { throw ExportError.noDylibToInject }

        // 先构建修改后的 IPA（替换已修改的 dylib）
        let modifiedIPA: Data
        if !modifiedDylibs.isEmpty {
            modifiedIPA = try IPAExporter.buildModifiedIPA(original: original, modifiedDylibs: modifiedDylibs)
        } else {
            modifiedIPA = original
        }

        // 再注入 dylib
        var dylibDict: [String: Data] = [:]
        for d in injectedDylibs {
            dylibDict[d.name] = d.data
        }
        return try IPAExporter.buildIPAWithInjectedDylibs(original: modifiedIPA, injectedDylibs: dylibDict)
    }
}

enum ExportError: Error, LocalizedError {
    case noIPALoaded
    case noDylibToInject
    var errorDescription: String? {
        switch self {
        case .noIPALoaded: return "尚未加载 IPA"
        case .noDylibToInject: return "请先导入要注入的 dylib"
        }
    }
}

// MARK: - DocumentPicker（UIViewControllerRepresentable 标准包装，让 SwiftUI 管理生命周期）

struct DocumentPicker: UIViewControllerRepresentable {
    let contentTypes: [UTType]
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: contentTypes, asCopy: true)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.modalPresentationStyle = .formSheet
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void
        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
            super.init()
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            if let url = urls.first { onPick(url) } else { onCancel() }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var showPicker = false
    @State private var showDylibPicker = false
    @State private var showExporter = false
    @State private var searchText = ""

    var filteredEntries: [IPAEntry] {
        guard !searchText.isEmpty else { return appModel.entries }
        return appModel.entries.filter {
            $0.displayName.localizedCaseInsensitiveContains(searchText) ||
            $0.zipPath.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                // 顶部操作栏
                HStack(spacing: 8) {
                    Button {
                        appModel.importDiag = "按钮已点击，准备弹选择器..."
                        showPicker = true
                    } label: {
                        Label("导入 IPA", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)

                    if appModel.ipaData != nil {
                        Button {
                            showDylibPicker = true
                        } label: {
                            Label("导入 dylib", systemImage: "puzzlepiece.extension")
                        }
                        .buttonStyle(.bordered)
                    }

                    Spacer()

                    if !appModel.entries.isEmpty || !appModel.injectedDylibs.isEmpty {
                        Menu {
                            if !appModel.entries.isEmpty {
                                Button {
                                    Task { await exportModifiedIPA() }
                                } label: {
                                    Label("导出修改后 IPA", systemImage: "square.and.arrow.up")
                                }
                            }
                            if !appModel.injectedDylibs.isEmpty {
                                Button {
                                    Task { await exportInjectedIPA() }
                                } label: {
                                    Label("导出注入后 IPA", systemImage: "syringe")
                                }
                            }
                        } label: {
                            Label("导出", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()

                // 诊断信息（红字显示，用于定位"无反应/闪退"问题卡在哪一步）
                Text("诊断: \(appModel.importDiag)")
                    .font(.caption2)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 4)

                // IPA 文件名
                if let name = appModel.ipaFileName {
                    HStack {
                        Image(systemName: "cube.box")
                        Text(name)
                            .font(.caption)
                            .lineLimit(1)
                        Spacer()
                        if !appModel.modifiedEntries.isEmpty {
                            Text("已修改 \(appModel.modifiedEntries.count) 个")
                                .font(.caption)
                                .foregroundColor(.orange)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }

                // 已注入的 dylib 列表
                if !appModel.injectedDylibs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("待注入 dylib（\(appModel.injectedDylibs.count)）")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        ForEach(appModel.injectedDylibs) { dylib in
                            HStack {
                                Image(systemName: "puzzlepiece.extension")
                                    .foregroundColor(.purple)
                                Text(dylib.name)
                                    .font(.caption)
                                Text("\(dylib.data.count) B")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                Spacer()
                                Button {
                                    appModel.removeInjectedDylib(dylib)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                // 搜索框
                if !appModel.entries.isEmpty {
                    HStack {
                        Image(systemName: "magnifyingglass")
                            .foregroundColor(.gray)
                        TextField("搜索 Mach-O 文件名", text: $searchText)
                            .textFieldStyle(.plain)
                    }
                    .padding(8)
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }

                // 列表
                if appModel.isLoading {
                    ProgressView("解析 IPA 中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if appModel.entries.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(filteredEntries, id: \.zipPath) { entry in
                            NavigationLink(destination: DylibDetailView(entry: entry)) {
                                EntryRow(entry: entry, isModified: appModel.modifiedDylibs[entry.zipPath] != nil)
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Dylib 字符串编辑器")
            .sheet(isPresented: $showPicker) {
                DocumentPicker(
                    contentTypes: [
                        UTType("com.apple.itunes.ipa") ?? .archive,
                        .archive,
                        .zip,
                        .data,
                        .item
                    ],
                    onPick: { url in
                        handlePickedURL(url)
                    },
                    onCancel: {
                        appModel.importDiag = "用户取消了选择"
                    }
                )
            }
            .sheet(isPresented: $showDylibPicker) {
                DocumentPicker(
                    contentTypes: [
                        .data,
                        .item
                    ],
                    onPick: { url in
                        handlePickedDylib(url)
                    },
                    onCancel: {}
                )
            }
            .alert("错误", isPresented: Binding(
                get: { appModel.errorMessage != nil },
                set: { if !$0 { appModel.errorMessage = nil } }
            )) {
                Button("确定") { appModel.errorMessage = nil }
            } message: {
                Text(appModel.errorMessage ?? "")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "cube.box")
                .font(.system(size: 60))
                .foregroundColor(.gray)
            Text("还没有导入 IPA")
                .font(.headline)
            Text("点击左上角「导入 IPA」选择一个 .ipa 文件")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 处理选中文件（异步读取避免主线程阻塞/闪退）

    private func handlePickedURL(_ url: URL) {
        appModel.importDiag = "已选文件: \(url.lastPathComponent)，开始后台读取..."
        AppLog.shared.write("handlePickedURL: url=\(url.absoluteString), path=\(url.path)")
        let path = url.path
        let displayName = url.lastPathComponent
        Task.detached(priority: .userInitiated) {
            do {
                let fileURL = URL(fileURLWithPath: path)
                AppLog.shared.write("开始读取文件: \(path)")
                let data = try Data(contentsOf: fileURL, options: [.uncached])
                AppLog.shared.write("文件读取成功: \(data.count) 字节")
                await MainActor.run {
                    appModel.importDiag = "读取成功：\(data.count) 字节，开始解析..."
                    appModel.loadIPA(data, fileName: displayName)
                }
            } catch {
                AppLog.shared.write("文件读取失败: \(error.localizedDescription)")
                await MainActor.run {
                    appModel.importDiag = "读取失败: \(error.localizedDescription)"
                    appModel.errorMessage = "读取文件失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func exportIPA() async {
        await exportModifiedIPA()
    }

    /// 处理选中的 dylib 文件
    private func handlePickedDylib(_ url: URL) {
        let path = url.path
        let name = url.lastPathComponent
        AppLog.shared.write("handlePickedDylib: name=\(name), path=\(path)")
        Task.detached(priority: .userInitiated) {
            do {
                let fileURL = URL(fileURLWithPath: path)
                let data = try Data(contentsOf: fileURL, options: [.uncached])
                await MainActor.run {
                    appModel.addInjectedDylib(name: name, data: data)
                    appModel.importDiag = "已添加待注入 dylib: \(name) (\(data.count) 字节)"
                }
            } catch {
                AppLog.shared.write("dylib 读取失败: \(error.localizedDescription)")
                await MainActor.run {
                    appModel.errorMessage = "读取 dylib 失败：\(error.localizedDescription)"
                }
            }
        }
    }

    /// 导出修改后 IPA（替换已修改的 dylib）
    private func exportModifiedIPA() async {
        do {
            let data = try appModel.buildModifiedIPA()
            try shareIPA(data: data, suffix: "modified")
        } catch {
            appModel.errorMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    /// 导出注入后 IPA（注入 dylib 到主二进制）
    private func exportInjectedIPA() async {
        do {
            appModel.importDiag = "正在注入 dylib 并打包..."
            let data = try appModel.buildInjectedIPA()
            AppLog.shared.write("注入打包成功: \(data.count) 字节")
            appModel.importDiag = "注入打包成功"
            try shareIPA(data: data, suffix: "injected")
        } catch {
            AppLog.shared.write("注入导出失败: \(error.localizedDescription)")
            appModel.errorMessage = "注入导出失败：\(error.localizedDescription)"
        }
    }

    /// 分享 IPA
    private func shareIPA(data: Data, suffix: String) throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(suffix)_\(appModel.ipaFileName ?? "app.ipa")")
        try data.write(to: tempURL)
        if let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first }).first,
           let rootVC = window.rootViewController {
            let avc = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
            if let popover = avc.popoverPresentationController {
                popover.sourceView = rootVC.view
                popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
            }
            rootVC.present(avc, animated: true)
        }
    }
}

// MARK: - Entry Row

struct EntryRow: View {
    let entry: IPAEntry
    let isModified: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .foregroundColor(iconColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName)
                    .font(.body)
                    .foregroundColor(isModified ? .orange : .primary)
                Text(entry.zipPath)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if isModified {
                Image(systemName: "pencil.circle.fill")
                    .foregroundColor(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch entry.kind {
        case .dylib: return "puzzlepiece.extension"
        case .frameworkMainBinary: return "capsule"
        case .appMainBinary: return "app"
        case .otherMachO: return "cpu"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .dylib: return .blue
        case .frameworkMainBinary: return .purple
        case .appMainBinary: return .gray
        case .otherMachO: return .secondary
        }
    }
}
