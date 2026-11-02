import Foundation
import TaflCore

/// Watches the config file's directory, and the directory of every file its links lead to, so a
/// replaced file, a replaced link and a replaced target all arrive as a change. Where a
/// directory does not exist yet, the nearest one that does is watched instead. The file the
/// path finally leads to is watched as well, because an editor may write it in place.
/// After every event the chain is resolved again and the watches are made anew.
final class ConfigWatcher {
    private let path: String
    private let onChange: () -> Void
    private var sources: [any DispatchSourceFileSystemObject] = []

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
    }

    func start() {
        arm()
    }

    func stop() {
        disarm()
    }

    private func fired() {
        arm()
        onChange()
    }

    private func arm() {
        disarm()
        let manager = FileManager.default
        let directories = ConfigWatchTargets.directories(
            configPath: path, readLink: { try? manager.destinationOfSymbolicLink(atPath: $0) })
        var watched: [String] = []
        for directory in directories {
            let existing = nearestExisting(directory)
            if !watched.contains(existing) { watched.append(existing) }
        }
        let file = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        if manager.fileExists(atPath: file), !watched.contains(file) { watched.append(file) }
        for item in watched { watch(item) }
    }

    private func disarm() {
        for source in sources { source.cancel() }
        sources = []
    }

    private func nearestExisting(_ directory: String) -> String {
        var current = directory
        while current != "/", !FileManager.default.fileExists(atPath: current) {
            current = (current as NSString).deletingLastPathComponent
        }
        return current
    }

    private func watch(_ item: String) {
        let descriptor = open(item, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
            queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.fired() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        sources.append(source)
    }
}
