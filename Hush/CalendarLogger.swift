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

    // call when the user flips the toggle on. completion on main.
    func requestAccess(_ completion: @escaping (Bool) -> Void) {
        store.requestWriteOnlyAccessToEvents { granted, error in
            if let error {
                os_log("CalendarLogger: access request failed %{public}@",
                       log: self.log, type: .error, error.localizedDescription)
            }
            DispatchQueue.main.async { completion(granted) }
        }
    }

    func log(start: Date, end: Date, appName: String?) {
        guard access == .writeOnlyOrBetter else {
            os_log("CalendarLogger: skip log, not authorized", log: log, type: .info)
            return
        }
        guard end > start else {
            os_log("CalendarLogger: skip log, end <= start", log: log, type: .info)
            return
        }

        DispatchQueue.global(qos: .utility).async { [self] in
            guard let calendar = store.defaultCalendarForNewEvents else {
                os_log("CalendarLogger: no default calendar", log: log, type: .error)
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
            } catch {
                os_log("CalendarLogger: save failed %{public}@",
                       log: log, type: .error, error.localizedDescription)
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
