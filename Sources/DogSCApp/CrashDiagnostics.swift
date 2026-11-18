import Foundation

/// Writes the reason for an abnormal exit to DogSC's own log folder before the
/// process dies. The system crash reporter is not available in every
/// environment, so a hard exit otherwise leaves no trace at all and a report of
/// "the app just closed" cannot be acted on.
enum CrashDiagnostics {
    nonisolated(unsafe) private static var fileDescriptor: Int32 = -1
    nonisolated(unsafe) private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true

        let folder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
            .first?
            .appendingPathComponent("Logs")
            .appendingPathComponent("DogSC")
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fileURL = folder.appendingPathComponent("crash.log")
        fileDescriptor = open(fileURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fileDescriptor >= 0 else { return }

        NSSetUncaughtExceptionHandler { exception in
            CrashDiagnostics.emit(
                """
                UNCAUGHT EXCEPTION \(exception.name.rawValue): \(exception.reason ?? "-")
                \(exception.callStackSymbols.joined(separator: "\n"))
                """
            )
        }

        let fatalHandler: @convention(c) (Int32) -> Void = { received in
            CrashDiagnostics.emit(
                "FATAL SIGNAL \(received)\n"
                    + Thread.callStackSymbols.joined(separator: "\n")
            )
            // Restore the default action and re-raise so the platform still
            // handles the exit exactly as it would without us.
            signal(received, SIG_DFL)
            raise(received)
        }
        for number in [SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP] {
            _ = signal(number, fatalHandler)
        }
    }

    /// Uses the raw `write` call so the message survives a handler that runs
    /// while the runtime is already tearing down.
    private static func emit(_ message: String) {
        guard fileDescriptor >= 0 else { return }
        let line = "\n===== \(Date()) =====\n\(message)\n"
        line.withCString { pointer in
            _ = Darwin.write(fileDescriptor, pointer, strlen(pointer))
        }
    }
}
