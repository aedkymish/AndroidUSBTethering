import Foundation

public enum CommandError: Error, LocalizedError {
    case failed(command: String, status: Int32, output: String)

    public var errorDescription: String? {
        switch self {
        case let .failed(command, status, output): return "\(command) exited with \(status): \(output)"
        }
    }
}

/// Runs system tools (`ifconfig`, `route`, `scutil`). Injected so tests can record calls.
public protocol CommandRunning {
    @discardableResult
    func run(_ executable: String, _ arguments: [String], input: String?) throws -> String
}

public extension CommandRunning {
    @discardableResult
    func run(_ executable: String, _ arguments: [String]) throws -> String {
        try run(executable, arguments, input: nil)
    }
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    @discardableResult
    public func run(_ executable: String, _ arguments: [String], input: String?) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        let inputPipe = Pipe()
        if input != nil { process.standardInput = inputPipe }
        try process.run()
        if let input {
            inputPipe.fileHandleForWriting.write(Data(input.utf8))
            try? inputPipe.fileHandleForWriting.close()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CommandError.failed(command: ([executable] + arguments).joined(separator: " "),
                                      status: process.terminationStatus, output: text)
        }
        return text
    }
}
