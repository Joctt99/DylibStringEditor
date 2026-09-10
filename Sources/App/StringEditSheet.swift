import SwiftUI

// MARK: - 单条字符串编辑 Sheet

struct StringEditSheet: View {
    let original: MachOString
    let onSave: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newValue: String
    @State private var errorMessage: String?

    init(original: MachOString, onSave: @escaping (String) -> Void) {
        self.original = original
        self.onSave = onSave
        _newValue = State(initialValue: original.value)
    }

    private var newByteLength: Int {
        newValue.data(using: original.encoding == .utf8 ? .utf8 : .utf16LittleEndian)?.count ?? 0
    }

    private var isValid: Bool {
        newByteLength > 0 && newByteLength <= original.byteLength
    }

    var body: some View {
        NavigationView {
            Form {
                Section("原字符串") {
                    Text(original.value)
                        .textSelection(.enabled)
                }

                Section("原字符串信息") {
                    LabeledContent("Section", value: original.section)
                    LabeledContent("编码", value: original.encoding == .utf8 ? "UTF-8" : "UTF-16LE")
                    LabeledContent("原字节长度", value: "\(original.byteLength) B")
                    LabeledContent("所在切片", value: "\(original.sliceArch) #\(original.sliceIndex)")
                }

                Section("新字符串") {
                    TextField("输入新内容", text: $newValue)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    HStack {
                        Text("新字节长度：\(newByteLength) B")
                            .foregroundColor(isValid ? .secondary : .red)
                        Spacer()
                        if !isValid && newByteLength > 0 {
                            Text("超长 \(!isValid ? newByteLength - original.byteLength : 0) B")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    if !isValid {
                        Text("新字符串字节长度不能超过原字符串（\(original.byteLength) B）。超出部分无法写入。")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }

                if let err = errorMessage {
                    Section {
                        Text(err)
                            .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("编辑字符串")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        guard isValid else {
                            errorMessage = "新字符串长度无效"
                            return
                        }
                        onSave(newValue)
                        dismiss()
                    }
                    .disabled(!isValid)
                }
            }
        }
    }
}
