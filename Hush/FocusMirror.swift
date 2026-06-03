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
    private static let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "FocusMirror")

    private let onChange: () -> Void
    private var fileSource: DispatchSourceFileSystemObject?
    private(set) var lastReadError: String = ""
    private(set) var lastModesParseNote: String = ""

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        ensureWatching()
    }

    deinit { fileSource?.cancel() }

    // re-arm after FDA was granted; idempotent unless force is true
    func ensureWatching(force: Bool = false) {
        if force {
            fileSource?.cancel()
            fileSource = nil
        }
        if fileSource == nil {
            watchAssertionsFile()
        }
    }

    func checkFilesAccessible() -> Bool {
        lastReadError = ""
        for name in [Self.modesFile, Self.assertionsFile] {
            if let err = openError(for: name) {
                lastReadError = err
                os_log("FocusMirror: %{public}@", log: Self.log, type: .info, err)
                return false
            }
        }
        return true
    }

    func availableModes() -> [FocusMode] {
        lastModesParseNote = ""
        guard let json = readJSON(filename: Self.modesFile) else {
            os_log("FocusMirror: modes file read failed or not JSON", log: Self.log, type: .info)
            return []
        }
        guard let dataArray = json["data"] as? [[String: Any]] else {
            let keys = Array(json.keys)
            lastModesParseNote = "modes JSON missing data array (keys: \(keys.joined(separator: ", ")))"
            os_log("FocusMirror: modes JSON loaded but no 'data' array. top keys: %{public}@",
                   log: Self.log, type: .info, keys)
            return []
        }
        var modes: [FocusMode] = []
        for entry in dataArray {
            guard let configs = entry["modeConfigurations"] as? [String: [String: Any]] else { continue }
            for (key, config) in configs {
                guard let mode = config["mode"] as? [String: Any],
                      let name = mode["name"] as? String else { continue }
                // key is usually the mode id; macOS 15+ also stores modeIdentifier inside mode
                let id = (mode["modeIdentifier"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? key
                modes.append(FocusMode(id: id, name: name))
            }
        }
        if modes.isEmpty {
            lastModesParseNote = "0 modes parsed from \(dataArray.count) data entr\(dataArray.count == 1 ? "y" : "ies")"
            os_log("FocusMirror: %{public}@", log: Self.log, type: .info, lastModesParseNote)
        }
        return modes.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    func activeModeIdentifiers() -> Set<String> {
        guard let json = readJSON(filename: Self.assertionsFile) else {
            os_log("FocusMirror: assertions file read failed or not JSON", log: Self.log, type: .info)
            return []
        }
        guard let dataArray = json["data"] as? [[String: Any]] else {
            let keys = Array(json.keys)
            os_log("FocusMirror: assertions JSON loaded but no 'data' array. top keys: %{public}@",
                   log: Self.log, type: .info, keys)
            return []
        }
        var active: Set<String> = []
        for entry in dataArray {
            guard let records = entry["storeAssertionRecords"] as? [[String: Any]] else { continue }
            for record in records {
                guard let details = record["assertionDetails"] as? [String: Any] else { continue }
                if let modeId = details["assertionDetailsModeIdentifier"] as? String
                    ?? details["modeIdentifier"] as? String {
                    active.insert(modeId)
                }
            }
        }
        return active
    }

    private func openError(for filename: String) -> String? {
        let path = filePath(filename).path
        let fd = open(path, O_RDONLY)
        if fd >= 0 {
            close(fd)
            return nil
        }
        let err = String(cString: strerror(errno))
        return "\(filename): errno \(errno) (\(err))"
    }

    private func readJSON(filename: String) -> [String: Any]? {
        guard let data = readFileData(filename: filename), !data.isEmpty else { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            os_log("FocusMirror: %{public}@ is not valid JSON", log: Self.log, type: .info, filename)
            return nil
        }
        return obj
    }

    // open/read, not Data(contentsOf:). TCC grants FDA per syscall style;
    // mixing APIs can report readable but fail on read.
    private func readFileData(filename: String) -> Data? {
        let path = filePath(filename).path
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            let err = String(cString: strerror(errno))
            os_log("FocusMirror read open(%{public}@) failed: errno=%d (%{public}@)",
                   log: Self.log, type: .info, path, errno, err)
            return nil
        }
        defer { close(fd) }

        var data = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 {
                os_log("FocusMirror read(%{public}@) failed: errno=%d", log: Self.log, type: .info, path, errno)
                return nil
            }
            if n == 0 { break }
            data.append(contentsOf: buf[0..<n])
        }
        return data
    }

    private func filePath(_ filename: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(Self.dbPath)
            .appendingPathComponent(filename)
    }

    private func watchAssertionsFile() {
        fileSource?.cancel()
        fileSource = nil
        let path = filePath(Self.assertionsFile).path
        let fd = open(path, O_EVTONLY)
        guard fd != -1 else {
            os_log("FocusMirror watch open(%{public}@) failed: errno=%d", log: Self.log, type: .info, path, errno)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            let events = source.data
            self.onChange()
            if events.contains(.delete) || events.contains(.rename) {
                self.watchAssertionsFile()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileSource = source
    }
}
