import Foundation

actor BackendProcessManager {
    private let backendRootURL = URL(fileURLWithPath: "/Users/hikaru/code/Postchair", isDirectory: true)
    private let serverPort = 8765
    private var ownedProcess: Process?

    func startIfNeeded() async throws {
        if try await isHealthy() {
            return
        }
        if ownedProcess?.isRunning == true {
            return
        }

        let process = Process()
        process.currentDirectoryURL = backendRootURL
        process.executableURL = pythonExecutableURL()
        process.arguments = ["postchair_server.py", "--host", "127.0.0.1", "--port", "\(serverPort)"]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        ownedProcess = process

        for _ in 0 ..< 30 {
            if try await isHealthy() {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }

        if process.isRunning {
            throw BackendProcessError.launchFailed("バックエンドは起動しましたが、ヘルスチェックに応答しませんでした。")
        }
        throw BackendProcessError.launchFailed(readPipe(stderr))
    }

    func stopOwnedProcess() async {
        guard let process = ownedProcess else { return }
        if process.isRunning {
            process.terminate()
            try? await Task.sleep(for: .milliseconds(300))
            if process.isRunning {
                process.interrupt()
            }
        }
        ownedProcess = nil
    }

    private func isHealthy() async throws -> Bool {
        let url = URL(string: "http://127.0.0.1:\(serverPort)/health")!
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return false }
            return httpResponse.statusCode == 200
        } catch {
            return false
        }
    }

    private func pythonExecutableURL() -> URL {
        let venvPython = backendRootURL.appendingPathComponent(".venv/bin/python")
        if FileManager.default.fileExists(atPath: venvPython.path) {
            return venvPython
        }
        return URL(fileURLWithPath: "/usr/bin/python3")
    }

    private func readPipe(_ pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard !data.isEmpty else {
            return "バックエンドを起動できませんでした。"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

enum BackendProcessError: LocalizedError {
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .launchFailed(message):
            return message
        }
    }
}
