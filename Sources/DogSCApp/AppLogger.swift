import Foundation
import os

public final class AppLogger: @unchecked Sendable {
    public static let shared = AppLogger()
    
    private let queue = DispatchQueue(label: "cn.laogou.dogsc.applogger", qos: .utility)
    private var fileHandle: FileHandle?
    private let dateFormatter: DateFormatter
    public let logFileURL: URL
    
    private init() {
        let logsFolder = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs")
            .appendingPathComponent("DogSC")
        try? FileManager.default.createDirectory(at: logsFolder, withIntermediateDirectories: true)
        
        let fileURL = logsFolder.appendingPathComponent("dogsc.log")
        self.logFileURL = fileURL
        
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        
        self.fileHandle = try? FileHandle(forWritingTo: fileURL)
        _ = try? fileHandle?.seekToEnd()
        
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        log(level: "INIT", category: "App", "=== DogSC Logger initialized at \(fileURL.path) ===")
    }
    
    public func log(
        level: String = "INFO",
        category: String = "General",
        _ message: String,
        file: String = #fileID,
        line: Int = #line
    ) {
        let now = Date()
        let timestamp = dateFormatter.string(from: now)
        let fileName = (file as NSString).lastPathComponent
        let formatted = "\(timestamp) [\(level)] [\(category)] [\(fileName):\(line)] \(message)\n"
        
        // Output to stderr so it shows in Xcode / terminal
        fputs(formatted, stderr)
        
        queue.async { [weak self] in
            guard let self, let handle = self.fileHandle else { return }
            if let data = formatted.data(using: .utf8) {
                try? handle.write(contentsOf: data)
                try? handle.synchronize()
            }
        }
    }
}

public func appLog(
    _ message: String,
    level: String = "INFO",
    category: String = "App",
    file: String = #fileID,
    line: Int = #line
) {
    AppLogger.shared.log(level: level, category: category, message, file: file, line: line)
}
