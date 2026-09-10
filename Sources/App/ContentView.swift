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

    /// 已修改的 dylib 数据缓存：zipPath -> modifiedData
    private var modifiedDylibs: [String: Data] = [:]

    func loadIPA(_ data: Data, fileName: String) {
        self.ipaData = data
        self.ipaFileName = fileName
        self.entries = []
        self.modifiedDylibs.removeAll()
        self.errorMessage = nil
        self.isLoading = true
        Task.detached(priority: .userInitiated) {
            do {
                let parser = try IPAParser(data: data)
                let list = try parser.listMachOEntries()
                await MainActor.run {
                    self.entries = list.sorted { $0.zipPath < $1.zipPath }
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
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
}

enum ExportError: Error, LocalizedError {
    case noIPALoaded
    var errorDescription: String? { "尚未加载 IPA" }
}

// MARK: - 主界面

struct ContentView: View {
    @EnvironmentObject var appModel: AppModel
    @State private var showFileImporter = false
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
                HStack {
                    Button {
                        showFileImporter = true
                    } label: {
                        Label("导入 IPA", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)

                    Spacer()

                    if !appModel.entries.isEmpty {
                        Button {
                            Task { await exportIPA() }
                        } label: {
                            Label("导出 IPA", systemImage: "square.and.arrow.up")
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .padding()

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
            .fileImporter(
                isPresented: $showFileImporter,
                allowedContentTypes: [.data, .zip],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result)
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

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let _ = url.startAccessingSecurityScopedResource()
            defer { url.stopAccessingSecurityScopedResource() }
            do {
                let data = try Data(contentsOf: url)
                appModel.loadIPA(data, fileName: url.lastPathComponent)
            } catch {
                appModel.errorMessage = "读取文件失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            appModel.errorMessage = "导入失败：\(error.localizedDescription)"
        }
    }

    private func exportIPA() async {
        do {
            let data = try appModel.buildModifiedIPA()
            // 保存到 temp 并分享
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("modified_\(appModel.ipaFileName ?? "app.ipa")")
            try data.write(to: tempURL)
            // 用分享面板
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
        } catch {
            appModel.errorMessage = "导出失败：\(error.localizedDescription)"
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
