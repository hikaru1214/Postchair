import Foundation

protocol BackendProcessManaging: Actor {
    func startIfNeeded() async throws
    func stopOwnedProcess() async
}

actor BackendProcessManager: BackendProcessManaging {
    private let serverHost = "127.0.0.1"
    private let serverPort = 8000
    private var ownedProcess: Process?

    func startIfNeeded() async throws {
        if try await isHealthy() {
            return
        }
        if ownedProcess?.isRunning == true {
            try await waitForHealthyServer()
            return
        }

        let process = Process()
        process.currentDirectoryURL = try backendRootURL()
        process.executableURL = try pythonExecutableURL()
        process.arguments = [
            "-m", "uvicorn", "postchair_server:app",
            "--host", serverHost,
            "--port", "\(serverPort)",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        ownedProcess = process

        try await waitForHealthyServer()

        try Self.validateLaunchState(
            isHealthy: try await isHealthy(),
            processIsRunning: process.isRunning,
            stderrText: readPipe(stderr)
        )
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
        let url = URL(string: "http://\(serverHost):\(serverPort)/health")!
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

    private func waitForHealthyServer() async throws {
        for _ in 0 ..< 30 {
            if try await isHealthy() {
                return
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func backendRootURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["POSTCHAIR_BACKEND_ROOT"], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured, isDirectory: true)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("postchair_server.py").path) {
                return url
            }
            throw BackendProcessError.launchFailed(
                "POSTCHAIR_BACKEND_ROOT に postchair_server.py が見つかりません: \(configured)"
            )
        }

        let currentDirectoryURL = URL(
            fileURLWithPath: FileManager.default.currentDirectoryPath,
            isDirectory: true
        )
        if FileManager.default.fileExists(
            atPath: currentDirectoryURL.appendingPathComponent("postchair_server.py").path
        ) {
            return currentDirectoryURL
        }

        throw BackendProcessError.launchFailed(
            "バックエンドのルートが見つかりません。Xcode の Environment Variables に POSTCHAIR_BACKEND_ROOT を設定してください。"
        )
    }

    private func pythonExecutableURL() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let configured = environment["POSTCHAIR_PYTHON_PATH"], !configured.isEmpty {
            let url = URL(fileURLWithPath: configured)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
            throw BackendProcessError.launchFailed(
                "POSTCHAIR_PYTHON_PATH が実行可能ではありません: \(configured)"
            )
        }

        let backendRootURL = try backendRootURL()
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

    static func validateLaunchState(
        isHealthy: Bool,
        processIsRunning: Bool,
        stderrText: String
    ) throws {
        if isHealthy {
            return
        }
        if processIsRunning {
            throw BackendProcessError.launchFailed("バックエンドは起動中ですが、ヘルスチェックに応答しませんでした。")
        }
        throw BackendProcessError.launchFailed(stderrText)
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
