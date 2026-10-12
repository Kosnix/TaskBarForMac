import AppKit
import Observation

/// What Music or Spotify is playing, for the taskbar's media button.
///
/// macOS no longer lets third-party apps read the system-wide "now playing"
/// (MediaRemote is closed to them), so this asks the two players that have a
/// scripting interface directly — which also covers the transport buttons.
/// Anything else (a browser tab, VLC…) simply doesn't show up. The first use
/// of each player raises macOS's usual "wants to control Music" prompt.
@MainActor
@Observable
final class NowPlayingStore {
    static let shared = NowPlayingStore()

    struct Track {
        var title: String
        var artist: String
        var isPlaying: Bool
        var player: Player
    }

    enum Player: CaseIterable {
        case music, spotify

        var bundleIdentifier: String { self == .music ? "com.apple.Music" : "com.spotify.client" }
        var appName: String { self == .music ? "Music" : "Spotify" }
    }

    private(set) var track: Track?

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private let queue = DispatchQueue(label: "nowplaying", qos: .utility)
    @ObservationIgnored private var isPolling = false

    func startPolling() {
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
        track = nil
    }

    private func poll() {
        guard !isPolling else { return }
        let running = Player.allCases.filter { player in
            NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == player.bundleIdentifier }
        }
        guard !running.isEmpty else {
            track = nil
            return
        }
        isPolling = true
        queue.async {
            // A player that's playing wins over one that's merely paused.
            let found = running.compactMap { Self.read($0) }
            let best = found.first(where: \.isPlaying) ?? found.first
            Task { @MainActor in
                self.isPolling = false
                self.track = best
            }
        }
    }

    func togglePlayPause() { command("playpause") }
    func next() { command("next track") }
    func previous() { command("previous track") }

    private func command(_ verb: String) {
        guard let player = track?.player else { return }
        queue.async {
            Self.run("tell application \"\(player.appName)\" to \(verb)")
            Task { @MainActor in self.poll() }
        }
    }

    private nonisolated static func read(_ player: Player) -> Track? {
        let script = """
        tell application "\(player.appName)"
            if player state is stopped then return ""
            return (name of current track) & "\\n" & (artist of current track) & "\\n" & ((player state is playing) as text)
        end tell
        """
        guard let output = run(script), !output.isEmpty else { return nil }
        let lines = output.components(separatedBy: "\n")
        guard lines.count >= 3 else { return nil }
        return Track(title: lines[0], artist: lines[1], isPlaying: lines[2] == "true", player: player)
    }

    @discardableResult
    private nonisolated static func run(_ source: String) -> String? {
        var error: NSDictionary?
        return NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
    }
}
