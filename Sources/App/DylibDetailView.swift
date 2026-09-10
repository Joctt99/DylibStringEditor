import SwiftUI

// MARK: - Dylib 详情 + 字符串编辑

struct DylibDetailView: View {
    let entry: IPAEntry
    @EnvironmentObject var appModel: AppModel
    @StateObject private var viewModel = DylibDetailViewModel()

    var body: some View {
        VStack(spacing: 0) {
            // 信息卡
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.displayName)
                        .font(.headline)
                    Text("路径：\(entry.zipPath)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("架构：\(viewModel.archNames.joined(separator: ", "))")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("批量替换") {
                    viewModel.showBatchReplace = true
                }
                .buttonStyle(.bordered)
            }
            .padding()
            .background(Color(.systemBackground))

            Divider()

            // 搜索 + 统计
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.gray)
                TextField("搜索字符串", text: $viewModel.searchText)
                    .textFieldStyle(.plain)
                if !viewModel.searchText.isEmpty {
                    Button(action: { viewModel.searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(8)
            .background(Color(.systemGray6))
            .cornerRadius(8)
            .padding(.horizontal)
            .padding(.vertical, 8)

            HStack {
                Text("共 \(viewModel.filteredStrings.count) / \(viewModel.allStrings.count) 条")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            // 列表
            if viewModel.isLoading {
                ProgressView("解析字符串中...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.errorMessage != nil {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundColor(.orange)
                    Text(viewModel.errorMessage!)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(viewModel.filteredStrings, id: \.fileOffset) { str in
                        StringRow(string: str, onEdit: {
                            viewModel.editingString = str
                        })
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(entry.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.load(from: appModel.currentData(for: entry))
        }
        .sheet(item: $viewModel.editingString) { str in
            StringEditSheet(
                original: str,
                onSave: { newVal in
                    viewModel.replaceString(str, with: newVal) { success, err in
                        if success {
                            appModel.setModifiedData(viewModel.modifiedData ?? entry.data, for: entry)
                        } else if let e = err {
                            viewModel.errorMessage = e
                        }
                    }
                }
            )
        }
        .sheet(isPresented: $viewModel.showBatchReplace) {
            BatchReplaceSheet(
                strings: viewModel.allStrings,
                onApply: { replacements in
                    viewModel.applyBatchReplace(replacements) { success, err in
                        if success {
                            appModel.setModifiedData(viewModel.modifiedData ?? entry.data, for: entry)
                        } else if let e = err {
                            viewModel.errorMessage = e
                        }
                    }
                }
            )
        }
        .alert("错误", isPresented: Binding(
            get: { viewModel.alertMessage != nil },
            set: { if !$0 { viewModel.alertMessage = nil } }
        )) {
            Button("确定") { viewModel.alertMessage = nil }
        } message: {
            Text(viewModel.alertMessage ?? "")
        }
    }
}

// MARK: - ViewModel

@MainActor
final class DylibDetailViewModel: ObservableObject {
    @Published var allStrings: [MachOString] = []
    @Published var searchText = ""
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var alertMessage: String?
    @Published var editingString: MachOString?
    @Published var showBatchReplace = false
    @Published var modifiedData: Data?

    private var editor: MachOStringEditor?
    private var originalData: Data?

    var archNames: [String] { editor?.archNames ?? [] }

    var filteredStrings: [MachOString] {
        guard !searchText.isEmpty else { return allStrings }
        return allStrings.filter { $0.value.localizedCaseInsensitiveContains(searchText) }
    }

    func load(from data: Data) {
        self.originalData = data
        self.isLoading = true
        self.errorMessage = nil
        self.modifiedData = nil
        self.allStrings = []
        Task.detached(priority: .userInitiated) {
            do {
                let ed = try MachOStringEditor(data: data)
                let list = ed.listStrings()
                await MainActor.run {
                    self.editor = ed
                    self.allStrings = list
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

    /// 单条替换
    func replaceString(_ str: MachOString, with newVal: String, completion: @escaping (Bool, String?) -> Void) {
        let current = modifiedData ?? originalData
        guard let current = current else {
            completion(false, "数据未加载")
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                let ed = try MachOStringEditor(data: current)
                let newData = try ed.applyReplacement(str.value, newVal)
                await MainActor.run {
                    self.modifiedData = newData
                    // 重新解析字符串列表
                    self.editor = try? MachOStringEditor(data: newData)
                    self.allStrings = self.editor?.listStrings() ?? []
                    completion(true, nil)
                }
            } catch {
                await MainActor.run {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }

    /// 批量替换
    func applyBatchReplace(_ replacements: [MachOReplacement], completion: @escaping (Bool, String?) -> Void) {
        let current = modifiedData ?? originalData
        guard let current = current else {
            completion(false, "数据未加载")
            return
        }
        Task.detached(priority: .userInitiated) {
            do {
                let ed = try MachOStringEditor(data: current)
                let newData = try ed.applyReplacements(replacements)
                await MainActor.run {
                    self.modifiedData = newData
                    self.editor = try? MachOStringEditor(data: newData)
                    self.allStrings = self.editor?.listStrings() ?? []
                    completion(true, nil)
                }
            } catch {
                await MainActor.run {
                    completion(false, error.localizedDescription)
                }
            }
        }
    }
}

// MARK: - String Row

struct StringRow: View {
    let string: MachOString
    let onEdit: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.quote")
                .foregroundColor(string.encoding == .utf8 ? .blue : .orange)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(string.value)
                    .font(.body)
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text("\(string.section)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text("\(string.byteLength) B")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    if string.encoding == .utf16le {
                        Text("UTF-16")
                            .font(.caption2)
                            .foregroundColor(.orange)
                    }
                }
            }
            Spacer()
            Button(action: onEdit) {
                Image(systemName: "pencil")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onEdit)
    }
}
