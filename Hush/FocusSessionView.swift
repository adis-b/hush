import SwiftUI

struct FocusSessionView: View {
    @ObservedObject var manager: RunningAppsManager

    @State private var now = Date()
    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let durations = [25, 50, 90]

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

    private var idleView: some View {
        HStack(alignment: .center, spacing: 6) {
            Text("Focus").fontWeight(.semibold)
            Spacer()
            ForEach(durations, id: \.self) { minutes in
                Button(action: { manager.startFocusSession(minutes: minutes) }) {
                    Text("\(minutes)m")
                        .font(.system(size: 11, weight: .medium))
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.primary.opacity(0.08))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())
            }
        }
    }

    private func runningView(endDate: Date) -> some View {
        _ = now
        let secondsRemaining = max(0, endDate.timeIntervalSince(Date()))
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
        }
    }
}
