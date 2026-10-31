import Foundation
import StripEngine
import WindowCore

/// The config file on disk: finds it, writes the template, and reports every change to it.
///
/// Editors often replace a file instead of rewriting it, which would silently end a file-system
/// watch on the old inode. Polling the file's identity, size and modification time once a second
/// survives that, and the cost is one `stat` call.
@MainActor
final class ConfigFile {
    var onChange: [(StripConfig.Parsed) -> Void] = []

    private struct Signature: Equatable {
        var file: UInt
        var size: Int
        var modified: Date?
    }

    private var signature: Signature?
    private var timer: Timer?
    /// The config from the last read that worked, kept in force when a read fails.
    private var lastGood = StripConfig.parse("")

    static var url: URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("tinywm/config")
    }

    /// Reports every later change. Call `load` first for the initial read.
    func watch() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// Reads the file. A missing file means the defaults; one that cannot be read keeps the
    /// last good config and reports why.
    func load() -> StripConfig.Parsed {
        signature = Self.signature()
        let contents: Result<Data, Error>?
        do { contents = .success(try Data(contentsOf: Self.url)) } catch CocoaError.fileReadNoSuchFile {
            contents = nil
        } catch {
            contents = .failure(error)
        }
        let parsed = StripConfig.read(contents, previous: lastGood)
        if let whole = parsed.issues.first(where: { $0.line == 0 }) {
            Log.note("config", "\(Self.url.path): \(whole.message)")
        } else {
            lastGood = parsed
        }
        return parsed
    }

    func reload() {
        let parsed = load()
        for observer in onChange { observer(parsed) }
    }

    func write(_ edit: (String) -> String) throws {
        createIfMissing()
        let url = Self.url.resolvingSymlinksInPath()
        let text = try String(contentsOf: url, encoding: .utf8)
        try edit(text).write(to: url, atomically: true, encoding: .utf8)
        reload()
    }

    private func poll() {
        if Self.signature() != signature { reload() }
    }

    private static func signature() -> Signature? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Signature(file: (a[.systemFileNumber] as? UInt) ?? 0, size: (a[.size] as? Int) ?? 0,
                         modified: a[.modificationDate] as? Date)
    }

    private func createIfMissing() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Self.url.path) else { return }
        do {
            try fm.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try StripConfig.template.write(to: Self.url, atomically: true, encoding: .utf8)
        } catch {
            Log.note("config", "could not create \(Self.url.path): \(error)")
        }
    }

    /// Adds commented lines for the defaults the file does not list yet, such as new settings and
    /// bindings. Writes through a symlink, so a config kept in a dotfiles folder stays there.
    func addMissingDefaults() {
        let url = Self.url.resolvingSymlinksInPath()
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let updated = StripConfig.addingMissingDefaults(to: text) else { return }
        do { try updated.write(to: url, atomically: true, encoding: .utf8) } catch {
            Log.note("config", "could not add new defaults to \(url.path): \(error)")
        }
    }
}
