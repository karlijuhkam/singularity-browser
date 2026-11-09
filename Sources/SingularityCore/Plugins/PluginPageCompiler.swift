import CryptoKit
import Foundation

/// Turns a plugin's `page.ts` into the JavaScript that is injected into web pages.
///
/// Two steps, both blocking (call them off the main thread):
/// 1. `readVerified`: read `page.ts` and check it is byte for byte the file the latest scan
///    fingerprinted, so what runs in pages is what was approved (or, in development mode, what
///    the latest scan saw).
/// 2. `transpile`: hand that text to `Resources/plugin-host/transpile-page.ts`, run by the bundled
///    Bun inside the plugin sandbox (no network, no programs, only a throwaway folder writable).
///    It refuses imports and exports and strips the TypeScript types.
///
/// The app keeps the result in memory only, keyed by the plugin's fingerprint (never on disk in
/// the plugin's data folder, which the plugin's background program can write).
public enum PluginPageCompiler {
    /// page.ts files larger than this are refused.
    public static let maxSourceBytes = 1_000_000
    /// JavaScript output larger than this is refused.
    static let maxOutputBytes = 4_000_000
    static let timeout: TimeInterval = 20

    public enum Failure: Error, Equatable, Sendable {
        /// The file differs from the one the latest scan saw (it is being edited): try after the next scan.
        case changed
        case unreadable
        case tooLarge
        /// transpile-page.ts refused it; the text says why ("page.ts can't import other files…").
        case refused(String)
        /// Bun couldn't run, timed out or printed too much.
        case failed(String)

        /// For Settings → Plugins (after "Page script: ").
        public var userMessage: String {
            switch self {
            case .changed: return "page.ts changed while it was being read; it is read again after the next change"
            case .unreadable: return "page.ts couldn't be read"
            case .tooLarge: return "page.ts is larger than 1 MB"
            case .refused(let why): return why
            case .failed(let why): return "page.ts couldn't be prepared: \(why)"
            }
        }
    }

    /// The text of `<folder>/<script>` if its SHA-256 equals `expectedHash` (the scan's
    /// `fileHashes[script]`). `script` was validated by the manifest (relative, inside the folder).
    public static func readVerified(folder: URL, script: String, expectedHash: String?) -> Result<String, Failure> {
        let file = folder.appending(path: script)
        guard let data = try? Data(contentsOf: file) else { return .failure(.unreadable) }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard let expectedHash, hash == expectedHash else { return .failure(.changed) }
        guard data.count <= maxSourceBytes else { return .failure(.tooLarge) }
        guard let text = String(data: data, encoding: .utf8) else { return .failure(.unreadable) }
        return .success(text)
    }

    /// Runs transpile-page.ts on `source` and returns the JavaScript.
    /// - Parameters:
    ///   - runtime: the bundled Bun (`Contents/Helpers/bun`).
    ///   - hostFolder: the folder with transpile-page.ts and the empty bunfig.toml
    ///     (`Contents/Resources/plugin-host`).
    public static func transpile(source: String, runtime: URL, hostFolder: URL) -> Result<String, Failure> {
        let fm = FileManager.default
        // A fresh folder per run: <tmp>/in holds the copy of page.ts (read-only for Bun),
        // <tmp>/work is Bun's HOME and TMPDIR (its only writable place), <tmp>/out the results.
        let temp = fm.temporaryDirectory.appending(path: "singularity-page-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: temp) }
        let input = temp.appending(path: "in", directoryHint: .isDirectory)
        let work = temp.appending(path: "work", directoryHint: .isDirectory)
        let out = temp.appending(path: "out", directoryHint: .isDirectory)
        let stdoutFile = out.appending(path: "stdout")
        let stderrFile = out.appending(path: "stderr")
        do {
            for dir in [input, work.appending(path: "tmp"), out] {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
            try Data(source.utf8).write(to: input.appending(path: "page.ts"))
            for file in [stdoutFile, stderrFile] { try Data().write(to: file) }
        } catch {
            return .failure(.failed("couldn't create a temporary folder"))
        }

        let runtimePath: String, hostPath: String, inputPath: String, workPath: String
        do {
            // The sandbox compares real paths (/var is /private/var), as in PluginProcess.
            runtimePath = try PluginProcess.realPath(runtime)
            hostPath = try PluginProcess.realPath(hostFolder)
            inputPath = try PluginProcess.realPath(input)
            workPath = try PluginProcess.realPath(work)
        } catch {
            return .failure(.failed("Bun or the plugin host is missing"))
        }
        let profile = SandboxProfile.make(
            pluginFolder: URL(filePath: inputPath, directoryHint: .isDirectory),
            dataFolder: URL(filePath: workPath, directoryHint: .isDirectory),
            runtime: URL(filePath: runtimePath),
            extraReadable: [URL(filePath: hostPath, directoryHint: .isDirectory)])

        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/sandbox-exec")
        // Same flags as plugin background programs (see PluginProcess.start).
        process.arguments = ["-p", profile, runtimePath, "--config=" + hostPath + "/bunfig.toml", "--no-env-file",
                             "--no-install", "run", hostPath + "/transpile-page.ts", inputPath + "/page.ts"]
        process.currentDirectoryURL = URL(filePath: workPath, directoryHint: .isDirectory)
        process.environment = PluginProcess.environment(dataFolder: workPath)
        process.standardInput = FileHandle.nullDevice
        // Output goes to files, not pipes: nothing to drain while waiting, so no deadlock.
        guard let stdout = try? FileHandle(forWritingTo: stdoutFile),
              let stderr = try? FileHandle(forWritingTo: stderrFile) else {
            return .failure(.failed("couldn't create a temporary folder"))
        }
        process.standardOutput = stdout
        process.standardError = stderr

        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do {
            try process.run()
        } catch {
            return .failure(.failed("Bun couldn't start (\(error.localizedDescription))"))
        }
        try? stdout.close()
        try? stderr.close()
        if finished.wait(timeout: .now() + timeout) == .timedOut {
            kill(process.processIdentifier, SIGKILL)
            finished.wait()
            return .failure(.failed("Bun took longer than \(Int(timeout)) seconds"))
        }

        let errorText = (try? String(contentsOf: stderrFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            if process.terminationStatus == 1, !errorText.isEmpty {
                return .failure(.refused(String(errorText.prefix(500))))
            }
            return .failure(.failed("Bun exited with status \(process.terminationStatus) \(errorText.prefix(300))"))
        }
        let size = (try? fm.attributesOfItem(atPath: stdoutFile.path)[.size] as? Int) ?? 0
        guard size <= maxOutputBytes else { return .failure(.failed("the JavaScript is larger than 4 MB")) }
        guard let js = try? String(contentsOf: stdoutFile, encoding: .utf8) else {
            return .failure(.failed("Bun's output couldn't be read"))
        }
        return .success(js)
    }
}
