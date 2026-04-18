import Foundation
import Darwin
import os.log

// one Mac Focus mode. id like "com.apple.donotdisturb.mode.default", name localized.
struct FocusMode: Identifiable, Hashable {
    let id: String
    let name: String
}

// Reads ~/Library/DoNotDisturb/DB JSONs directly. Tried INFocusStatusCenter
// first, won't work without an entitlement and you don't get mode names.
// Format is private, so any read failure -> empty result.
final class FocusMirror {
    private static let dbPath = "Library/DoNotDisturb/DB"
    private static let modesFile = "ModeConfigurations.json"
    private static let assertionsFile = "Assertions.json"

    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        ensureWatching()
    }

    deinit { fileSource?.cancel() }

    // re-arm after FDA was granted; idempotent
    func ensureWatching() {
        if fileSource == nil { watchAssertionsFile() }
    }

    func availableModes() -> [FocusMode] {
        guard let json = readJSON(filename: Self.modesFile),
              let dataArray = json["data"] as? [[String: Any]] else { return [] }
        var modes: [FocusMode] = []
        for entry in dataArray {
            guard let configs = entry["modeConfigurations"] as? [String: [String: Any]] else { continue }
            for (id, config) in configs {
                if let mode = config["mode"] as? [String: Any],
                   let name = mode["name"] as? String {
                    modes.append(FocusMode(id: id, name: name))
                }
            }
        }
        return modes.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func activeModeIdentifiers() -> Set<String> {
        guard let json = readJSON(filename: Self.assertionsFile),
              let dataArray = json["data"] as? [[String: Any]] else { return [] }
        var active: Set<String> = []
        for entry in dataArray {
            guard let records = entry["storeAssertionRecords"] as? [[String: Any]] else { continue }
            for record in records {
                if let details = record["assertionDetails"] as? [String: Any],
                   let modeId = details["assertionDetailsModeIdentifier"] as? String {
                    active.insert(modeId)
                }
            }
        }
        return active
    }

    // false usually means FDA missing. open() instead of isReadableFile
    // because the latter lies under TCC.
    var isReadable: Bool {
        let path = filePath(Self.assertionsFile).path
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return true
        }
        let err = String(cString: strerror(errno))
        os_log("FocusMirror open(%{public}@) failed: errno=%d (%{public}@)",
               log: OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "FocusMirror"),
               type: .info, path, errno, err)
        return false
    }

    var lastReadError: String {
        let path = filePath(Self.assertionsFile).path
        let fd = open(path, O_RDONLY)
        if fd >= 0 { close(fd); return "" }
        let err = String(cString: strerror(errno))
        return "errno \(errno): \(err)"
    }

    private func readJSON(filename: String) -> [String: Any]? {
        let url = filePath(filename)
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func filePath(_ filename: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Self.dbPath)
            .appendingPathComponent(filename)
    }

    private func watchAssertionsFile() {
        fileSource?.cancel()
        let path = filePath(Self.assertionsFile).path
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let events = source.data
            self.onChange()
            // atomic-replace invalidates our fd, re-arm
            if events.contains(.delete) || events.contains(.rename) {
                self.watchAssertionsFile()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }
}
