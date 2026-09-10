import SwiftUI

@main
struct DylibStringEditorApp: App {
    @StateObject private var appModel = AppModel()

    init() {
        AppLog.shared.write("=== App 启动 ===")
        AppLog.shared.write("日志文件路径: \(AppLog.shared.logFilePath)")

        NSSetUncaughtExceptionHandler { exception in
            let msg = "Uncaught exception: \(exception.name.rawValue)\nreason: \(exception.reason ?? "")\nstack:\n\(exception.callStackSymbols.prefix(12).joined(separator: "\n"))"
            AppLog.shared.write(msg)
        }
        signal(SIGABRT) { _ in
            AppLog.shared.write("Signal SIGABRT received")
        }
        signal(SIGSEGV) { _ in
            AppLog.shared.write("Signal SIGSEGV received")
        }
        signal(SIGBUS) { _ in
            AppLog.shared.write("Signal SIGBUS received")
        }
        signal(SIGILL) { _ in
            AppLog.shared.write("Signal SIGILL received")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
        }
    }
}
