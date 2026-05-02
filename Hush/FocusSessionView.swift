import SwiftUI

// idle = 25/50/90 buttons, running = countdown + Stop. no progress ring on purpose.
struct FocusSessionView: View {
    @ObservedObject var manager: RunningAppsManager

    // duplicated here (also in manager) so SwiftUI re-renders this row
    // when the user picks a new duration -> the dot moves
    @AppStorage("lastFocusDuration") private var lastFocusDuration: Int = 25

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let durations = [25, 50, 90]

    private func durationHelp(_ minutes: Int) -> String {
        switch minutes {
        case 25: return "25 min · one Pomodoro (Cirillo, 1987). After it ends, take a 5-min break."
        case 50: return "50 min · two pomodoros, a Deep Work block."
        case 90: return "90 min · one ultradian alertness cycle (Kleitman's basic rest-activity cycle)."
        default: return "Start a \(minutes)-minute focus session"
        }
    }

    var body: some View {
        Group {
            if let endDate = manager.focusSessionEndDate {
                runningView(endDate: endDate)
            } else {
                idleView
            }
        }
        .onReceive(tick) { date in
            if manager.focusSessionEndDate != nil {
                now = date
            }
        }
    }

    // .help() tooltips don't work in MenuBarExtra popups, so this
    // small label has to carry the framing
    private func durationLabel(_ minutes: Int) -> String {
        switch minutes {
        case 25: return "Pomodoro"
        case 50: return "Deep Work"
        case 90: return "Ultradian"
        default: return ""
        }
    }

    private var idleView: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Focus")
                .fontWeight(.semibold)
            Text("⌥⌘H")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Spacer()
            ForEach(durations, id: \.self) { minutes in
                let isLastUsed = (minutes == lastFocusDuration)
                Button(action: { manager.startFocusSession(minutes: minutes) }) {
                    VStack(spacing: 1) {
                        Text(durationLabel(minutes))
                            .font(.system(size: 8, weight: .regular))
                            .foregroundStyle(.secondary)
                        // dot marks which duration ⌥⌘H starts. always rendered
                        // (clear on the rest) so the text aligns across buttons
                        HStack(spacing: 3) {
                            Circle()
                                .fill(isLastUsed ? Color.hushDot : Color.clear)
                                .frame(width: 4, height: 4)
                                .accessibilityHidden(true)
                            Text("\(minutes)m")
                                .font(.system(size: 11, weight: .medium))
                        }
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.08))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
                .help(isLastUsed
                      ? "\(durationHelp(minutes)) ⌥⌘H starts this duration."
                      : durationHelp(minutes))
                .accessibilityLabel(isLastUsed
                                    ? "\(minutes) minute Focus session, ⌥⌘H starts this"
                                    : "\(minutes) minute Focus session")
            }
        }
        .help("⌥⌘H toggles the focus session")
    }

    private func runningView(endDate: Date) -> some View {
        _ = now // keep view re-rendering on tick
        // read live Date() so the first frame isn't stale (the @State `now`
        // only updates while a session is *already* running)
        let secondsRemaining = max(0, endDate.timeIntervalSince(Date()))
        // ceil() so a fresh 25-min session shows "25m", not "24m" half a sec later
        let minutesRemaining = max(1, Int(ceil(secondsRemaining / 60.0)))
        return HStack(spacing: 6) {
            Circle()
                .fill(Color.accentColor)
                .frame(width: 6, height: 6)
            Text("Focus  \(minutesRemaining)m")
                .fontWeight(.semibold)
                .monospacedDigit()
            Spacer()
            Button(action: { manager.cancelFocusSession() }) {
                Text("Stop")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(PlainButtonStyle())
            .help("⌥⌘H · Stop focus session")
        }
    }
}
