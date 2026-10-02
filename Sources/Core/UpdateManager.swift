import AppKit
import Observation

/// In-app updater: asks GitHub for this repo's latest release, and — if it's
/// newer than the running version — downloads its zipped `.app`, swaps it in
/// over the installed one and relaunches. Entirely user-initiated from
/// Settings; nothing here runs on its own at launch.
///
/// The swap itself can't be done by the running app (it would be replacing
/// its own executable), so it hands off to a tiny detached shell script that
/// waits for this process to exit, moves the new bundle into place (keeping
/// the old one as a backup until the move succeeds), and reopens it. Quitting
/// goes through the normal `NSApp.terminate`, so `applicationWillTerminate`
/// still restores the real Dock first, exactly as on any other quit.
@MainActor
@Observable
final class UpdateManager {
    static let shared = UpdateManager()

    enum Status: Equatable {
        case idle
        case checking
        case upToDate
        case available(version: String, notes: String)
        case downloading(progress: Double)
        case installing
        case failed(String)
    }

    private(set) var status: Status = .idle

    private static let repository = "Kosnix/TaskBarForMac"
    private var pendingAssetURL: URL?

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Running from `.build/…` (a bare executable, not an `.app` bundle) —
    /// there's no installed copy to replace, so only checking makes sense.
    var canInstallInPlace: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    var isBusy: Bool {
        switch status {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }
        let tagName: String
        let body: String?
        let assets: [Asset]
    }

    private struct UpdateError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    // MARK: - Checking

    func checkForUpdates() async {
        guard !isBusy else { return }
        status = .checking
        pendingAssetURL = nil
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("TaskBarForMac/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 20

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                throw UpdateError(message: L("update.error.server"))
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let release = try decoder.decode(Release.self, from: data)

            let remoteVersion = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            guard Self.isVersion(remoteVersion, newerThan: currentVersion) else {
                status = .upToDate
                return
            }
            // Prefer the dedicated app zip; any zip is better than nothing.
            let asset = release.assets.first { $0.name.hasSuffix("-macOS.zip") }
                ?? release.assets.first { $0.name.hasSuffix(".zip") }
            guard let asset else {
                throw UpdateError(message: L("update.error.no_asset"))
            }
            pendingAssetURL = asset.browserDownloadUrl
            status = .available(version: remoteVersion, notes: release.body ?? "")
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    /// Numeric, component-by-component ("1.10.0" > "1.9.0"), missing
    /// components counting as 0.
    private static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    func installAvailableUpdate() async {
        guard case .available = status, let assetURL = pendingAssetURL else { return }
        guard canInstallInPlace else {
            status = .failed(L("update.error.not_installed"))
            return
        }
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            status = .failed(L("update.error.not_writable"))
            return
        }

        status = .downloading(progress: 0)
        let fileManager = FileManager.default
        let workDirectory = fileManager.temporaryDirectory.appendingPathComponent("TaskBarForMacUpdate-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            let zipURL = workDirectory.appendingPathComponent("update.zip")
            try await download(assetURL, to: zipURL)

            status = .installing
            let extractedDirectory = workDirectory.appendingPathComponent("extracted", isDirectory: true)
            try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
            try await Task.detached {
                try Self.run("/usr/bin/ditto", ["-x", "-k", zipURL.path, extractedDirectory.path])
            }.value

            let newApp = extractedDirectory.appendingPathComponent(destination.lastPathComponent)
            guard let newBundle = Bundle(url: newApp), newBundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw UpdateError(message: L("update.error.invalid_package"))
            }
            // Catches a truncated/corrupted download before it replaces a
            // working install with a broken one.
            try await Task.detached {
                try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
            }.value

            try handOffToReplacementScript(newApp: newApp, destination: destination, workDirectory: workDirectory)
            NSApp.terminate(nil)
        } catch {
            try? fileManager.removeItem(at: workDirectory)
            status = .failed(error.localizedDescription)
        }
    }

    private func download(_ url: URL, to fileURL: URL) async throws {
        let userAgent = "TaskBarForMac/\(currentVersion)"
        try await Self.streamDownload(url, to: fileURL, userAgent: userAgent) { progress in
            Task { @MainActor in
                // Ignore a straggler that lands after the download already finished.
                if case .downloading = UpdateManager.shared.status {
                    UpdateManager.shared.status = .downloading(progress: progress)
                }
            }
        }
    }

    /// Off the main actor on purpose: iterating a download byte by byte on
    /// it would starve the UI for the whole transfer.
    nonisolated private static func streamDownload(
        _ url: URL,
        to fileURL: URL,
        userAgent: String,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError(message: L("update.error.server"))
        }
        let expected = response.expectedContentLength
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }

        var buffer = Data()
        var received: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            received += 1
            if buffer.count >= 64 * 1024 {
                try handle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if expected > 0 { onProgress(min(1, Double(received) / Double(expected))) }
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
    }

    nonisolated private static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError(message: L("update.error.invalid_package"))
        }
    }

    private func handOffToReplacementScript(newApp: URL, destination: URL, workDirectory: URL) throws {
        let script = """
        #!/bin/bash
        PID="$1"; NEW="$2"; DEST="$3"; WORK="$4"
        for _ in $(seq 1 150); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.2
        done
        BACKUP="$DEST.updating-old"
        rm -rf "$BACKUP"
        if mv "$DEST" "$BACKUP"; then
            if mv "$NEW" "$DEST"; then
                rm -rf "$BACKUP"
            else
                mv "$BACKUP" "$DEST"
            fi
        fi
        xattr -dr com.apple.quarantine "$DEST" 2>/dev/null
        open "$DEST"
        rm -rf "$WORK"
        """
        let scriptURL = workDirectory.appendingPathComponent("replace.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier), newApp.path, destination.path, workDirectory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
