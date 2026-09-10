import SwiftUI

// MARK: - 批量替换 Sheet

struct BatchReplaceSheet: View {
    let strings: [MachOString]
    let onApply: ([MachOReplacement]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var replacements: [BatchItem] = [BatchItem()]

    struct BatchItem: Identifiable, Equatable {
        let id = UUID()
        var original: String = ""
        var replacement: String = ""
    }

    private var validReplacements: [MachOReplacement] {
        replacements.compactMap { item in
            guard !item.original.isEmpty, !item.replacement.isEmpty else { return nil }
            return MachOReplacement(original: item.original, replacement: item.replacement)
        }
    }

    var body: some View {
        NavigationView {
            Form {
                Section("替换规则") {
                    ForEach($replacements) { $item in
                        VStack(spacing: 8) {
                            HStack {
                                Text("原文")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 40, alignment: .leading)
                                TextField("原字符串", text: $item.original)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            HStack {
                                Text("新文")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .frame(width: 40, alignment: .leading)
                                TextField("新字符串", text: $item.replacement)
                                    .textInputAutocapitalization(.never)
                                    .autocorrectionDisabled()
                            }
                            if replacements.count > 1 {
                                HStack {
                                    Spacer()
                                    Button(role: .destructive) {
                                        if let idx = replacements.firstIndex(where: { $0.id == item.id }) {
                                            replacements.remove(at: idx)
                                        }
                                    } label: {
                                        Text("删除此规则")
                                            .font(.caption)
                                    }
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    Button {
                        replacements.append(BatchItem())
                    } label: {
                        Label("添加规则", systemImage: "plus.circle")
                    }
                }

                Section("提示") {
                    Text("• 新字符串字节长度必须 ≤ 原字符串字节长度\n• 一次可添加多条替换规则，全部满足才会执行\n• 所有匹配该原文的位置都会被替换（包括多架构切片）")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section("现有字符串（可参考）") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(strings.prefix(50), id: \.fileOffset) { s in
                                Text(s.value)
                                    .font(.caption)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            if strings.count > 50 {
                                Text("... 共 \(strings.count) 条")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .frame(maxHeight: 200)
                }
            }
            .navigationTitle("批量替换")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        onApply(validReplacements)
                        dismiss()
                    }
                    .disabled(validReplacements.isEmpty)
                }
            }
        }
    }
}
