import SwiftUI

@main
struct DylibStringEditorApp: App {
    @StateObject private var appModel = AppModel()

    init() {
        // 捕获未处理的 Objective-C 异常，写入 crash log 便于定位闪退原因
        NSSetUncaughtExceptionHandler { exception in
            let msg = "Uncaught exception: \(exception.name.rawValue)\nreason: \(exception.reason ?? "")\nstack: \(exception.callStackSymbols.prefix(8).joined(separator: "\n"))"
            let logPath = NSTemporaryDirectory() + "dylib_editor_crash.log"
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: logPath))
            NSLog("%@", msg)
        }
        // 捕获信号（EXC_BAD_ACCESS 等）— 简单记录
        signal(SIGABRT) { _ in
            let msg = "Signal SIGABRT received"
            let logPath = NSTemporaryDirectory() + "dylib_editor_crash.log"
            try? msg.data(using: .utf8)?.write(to: URL(fileURLWithPath: logPath))
            NSLog("%@", msg)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
    }
}
