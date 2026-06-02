import Foundation

/// Runs a short-lived command to completion and captures its output. Used for
/// ECS resolution (design D6). Launches by absolute path with an injected PATH
/// env and arguments as an array — never through a shell (design D1). Pipes are
/// fully drained via `readToEnd` so there is no buffer deadlock (design D11).
struct CommandRunner {
    struct Result {
        let exitCode: Int32
        let stdout: String
        let stderr: String
    }

    enum RunError: LocalizedError {
        case launchFailed(String)
        var errorDescription: String? {
            switch self {
            case .launchFailed(let message): return message
            }
        }
    }

    /// Run off the main actor. Blocks the calling (background) thread until exit.
    static func run(executable: String, arguments: [String], environment: [String: String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(error.localizedDescription)
        }

        // Read fully before waiting to avoid a full-pipe deadlock.
        let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
        let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()

        return Result(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
