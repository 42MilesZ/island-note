import Foundation

/// Continuously persists plain text to `notes/scratch.txt`.
/// Debounced autosave (near real-time) plus synchronous flush on quit.
final class NoteStore {
    private let fileURL: URL
    private let queue = DispatchQueue(label: "island-note.store", qos: .utility)
    private var pending: String?
    private var saveWork: DispatchWorkItem?
    private let debounceInterval: TimeInterval = 0.18

    /// Fired after a successful save so the UI can show a subtle "saved" pulse.
    var onSaved: (() -> Void)?

    init(filename: String = "scratch.txt") {
        // Prefer <project>/notes/scratch.txt relative to the executable's project root
        // when running from source or from the packaged app inside the project tree.
        // Fallback: ~/Projects/island-note/notes/scratch.txt
        // Final fallback: ~/Library/Application Support/IslandNote/scratch.txt
        let fm = FileManager.default
        let candidates: [URL] = [
            Self.projectNotesDir().appendingPathComponent(filename),
            Self.defaultProjectNotesDir().appendingPathComponent(filename),
            Self.appSupportDir().appendingPathComponent(filename),
        ]

        var chosen = candidates[0]
        for url in candidates {
            let dir = url.deletingLastPathComponent()
            if fm.fileExists(atPath: dir.path) || (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil {
                chosen = url
                if fm.fileExists(atPath: url.path) || (try? "".write(to: url, atomically: true, encoding: .utf8)) != nil {
                    break
                }
            }
        }
        fileURL = chosen

        // Ensure file exists so first save is clean.
        if !fm.fileExists(atPath: fileURL.path) {
            try? "".write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }

    var path: String { fileURL.path }

    func load() -> String {
        (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
    }

    func save(_ text: String) {
        pending = text
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.flushSync()
        }
        saveWork = work
        queue.asyncAfter(deadline: .now() + debounceInterval, execute: work)
    }

    func flushSync() {
        saveWork?.cancel()
        saveWork = nil
        guard let text = pending else { return }
        pending = nil
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            DispatchQueue.main.async { [weak self] in
                self?.onSaved?()
            }
        } catch {
            NSLog("IslandNote save failed: \(error)")
        }
    }

    // MARK: - Paths

    private static func projectNotesDir() -> URL {
        // Walk up from the executable looking for Package.swift / notes/
        let exec = URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = exec.deletingLastPathComponent()
        for _ in 0..<6 {
            let notes = dir.appendingPathComponent("notes", isDirectory: true)
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return notes
            }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Projects/island-note/notes", isDirectory: true)
    }

    private static func defaultProjectNotesDir() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Projects/island-note/notes", isDirectory: true)
    }

    private static func appSupportDir() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("IslandNote", isDirectory: true)
    }
}
