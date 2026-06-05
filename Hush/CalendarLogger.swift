import Foundation
import EventKit
import os.log

// Writes one timed event per finished focus session to the user's default
// calendar. Write-only access (macOS 14+) so Hush can add but never read.
// Fail-open: any error -> os_log + silent no-op, focus end never blocks.
@available(macOS 14, *)
final class CalendarLogger {
    enum Access { case notDetermined, denied, writeOnlyOrBetter }

    private let store = EKEventStore()
    private let log = OSLog(subsystem: Bundle.main.bundleIdentifier!, category: "CalendarLogger")

    var access: Access {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined:
            return .notDetermined
        case .denied, .restricted:
            return .denied
        case .writeOnly, .fullAccess:
            return .writeOnlyOrBetter
        @unknown default:
            return .denied
        }
    }

    // raw status string for the Settings diagnostic line
    var statusDescription: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .fullAccess: return "fullAccess"
        case .writeOnly: return "writeOnly"
        case .authorized: return "authorized"
        @unknown default: return "unknown"
        }
    }

    // readable under write-only access; nil means EventKit gave us nowhere to write
    func defaultCalendarTitle() -> String? {
        store.defaultCalendarForNewEvents?.title
    }

    // call when the user flips the toggle on. completion on main with granted + raw error text.
    func requestAccess(_ completion: @escaping (Bool, String?) -> Void) {
        store.requestWriteOnlyAccessToEvents { granted, error in
            if let error {
                os_log("CalendarLogger: access request failed %{public}@",
                       log: self.log, type: .error, error.localizedDescription)
            }
            DispatchQueue.main.async { completion(granted, error?.localizedDescription) }
        }
    }

    func log(start: Date, end: Date, appName: String?, completion: ((String) -> Void)? = nil) {
        func report(_ note: String, type: OSLogType = .info) {
            os_log("CalendarLogger: %{public}@", log: log, type: type, note)
            if let completion {
                DispatchQueue.main.async { completion(note) }
            }
        }

        guard access == .writeOnlyOrBetter else {
            report("skip, not authorized (\(statusDescription))")
            return
        }
        guard end > start else {
            report("skip, end <= start")
            return
        }

        DispatchQueue.global(qos: .utility).async { [self] in
            guard let calendar = store.defaultCalendarForNewEvents else {
                report("no default calendar for new events (write-only gave none)", type: .error)
                return
            }

            let duration = Self.compactDurationLabel(from: start, to: end)
            let title: String
            if let appName, !appName.isEmpty {
                let fmt = String(localized: "calendar.event.title.withApp",
                                 comment: "Calendar event title with app; %1 duration, %2 app")
                title = String(format: fmt, duration, appName)
            } else {
                let fmt = String(localized: "calendar.event.title.noApp",
                                 comment: "Calendar event title without app; %1 duration")
                title = String(format: fmt, duration)
            }

            let event = EKEvent(eventStore: store)
            event.title = title
            event.startDate = start
            event.endDate = end
            event.availability = .free
            event.notes = String(localized: "calendar.event.notes", comment: "Calendar event notes body")
            event.calendar = calendar

            do {
                try store.save(event, span: .thisEvent, commit: true)
                report("saved \"\(title)\" to \(calendar.title)")
            } catch {
                report("save failed: \(error.localizedDescription)", type: .error)
            }
        }
    }

    // short label for titles: 50m, 1h, 1h 30m
    static func compactDurationLabel(from start: Date, to end: Date) -> String {
        let minutes = max(1, Int((end.timeIntervalSince(start) / 60).rounded()))
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        let rem = minutes % 60
        if rem == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(rem)m"
    }
}
