import SwiftUI
import UIKit

// MARK: - Visual language

enum KnockDesign {
    // These values mirror the shared Knock Knock design brief. The app is
    // intentionally warm and friendly, but the decision queue stays calm and
    // structured enough for a technical operator to scan quickly.
    static let canvas = Color(red: 0.969, green: 0.961, blue: 0.949)
    static let card = Color.white.opacity(0.97)
    static let ink = Color(red: 0.122, green: 0.114, blue: 0.141)
    static let muted = Color(red: 0.435, green: 0.416, blue: 0.463)
    static let coral = Color(red: 1.0, green: 0.361, blue: 0.302)
    static let coralSoft = Color(red: 1.0, green: 0.91, blue: 0.885)
    static let mint = Color(red: 0.224, green: 0.788, blue: 0.541)
    static let mintSoft = Color(red: 0.88, green: 0.97, blue: 0.925)
    static let lavender = Color(red: 0.42, green: 0.30, blue: 0.76)
    static let lavenderSoft = Color(red: 0.929, green: 0.914, blue: 1.0)
    static let skySoft = Color(red: 0.867, green: 0.933, blue: 1.0)
    static let border = Color(red: 0.90, green: 0.88, blue: 0.86)
}

struct KnockCard<Content: View>: View {
    let content: Content
    let padding: CGFloat

    init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(KnockDesign.card)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(KnockDesign.border, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.035), radius: 10, y: 4)
    }
}

/// A tiny vector mascot keeps the app personable without shipping a raster
/// asset. It stays crisp at every Dynamic Type size and on older iOS devices.
struct KnockMascot: View {
    var size: CGFloat = 82

    var body: some View {
        ZStack {
            Circle()
                .fill(KnockDesign.lavenderSoft)
            Circle()
                .fill(Color.white.opacity(0.66))
                .frame(width: size * 0.78, height: size * 0.78)
                .offset(x: -size * 0.07, y: -size * 0.07)
            RoundedRectangle(cornerRadius: size * 0.21, style: .continuous)
                .fill(KnockDesign.coral)
                .frame(width: size * 0.48, height: size * 0.57)
                .offset(y: size * 0.05)
            HStack(spacing: size * 0.09) {
                Circle()
                    .fill(Color.white)
                    .frame(width: size * 0.085, height: size * 0.085)
                Circle()
                    .fill(Color.white)
                    .frame(width: size * 0.085, height: size * 0.085)
            }
            .offset(y: size * 0.01)
            Capsule()
                .fill(KnockDesign.ink.opacity(0.72))
                .frame(width: size * 0.17, height: size * 0.045)
                .offset(y: size * 0.16)
            Circle()
                .fill(KnockDesign.mint)
                .frame(width: size * 0.10, height: size * 0.10)
                .overlay(Circle().stroke(Color.white, lineWidth: 2))
                .offset(x: size * 0.30, y: -size * 0.27)
        }
        .frame(width: size, height: size)
        .overlay {
            Circle().stroke(Color.white.opacity(0.72), lineWidth: 1)
        }
        .accessibilityLabel("Knock Knock")
    }
}

struct AgentGlyph: View {
    let seed: String
    var size: CGFloat = 44

    private var index: Int {
        seed.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % 7 }
    }

    private var symbol: String {
        ["terminal.fill", "sparkles", "shippingbox.fill", "curlybraces", "cube.fill", "wand.and.stars", "circle.grid.2x2.fill"][index]
    }

    private var tint: Color {
        [KnockDesign.ink, KnockDesign.lavender, KnockDesign.mint, Color.blue, Color.indigo, KnockDesign.coral, Color.teal][index]
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(tint.opacity(0.12))
            Image(systemName: symbol)
                .font(.system(size: size * 0.38, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

enum DecisionRisk: String {
    case low
    case medium
    case high

    init(actionRisk raw: String) {
        switch raw.lowercased() {
        case "destructive", "high": self = .high
        case "medium": self = .medium
        default: self = .low
        }
    }

    init(session: Session) {
        let descriptorRisks = session.actionDescriptors.map { DecisionRisk(actionRisk: $0.risk) }
        if descriptorRisks.contains(.high) {
            self = .high
        } else if descriptorRisks.contains(.medium) || session.needsUser {
            self = .medium
        } else {
            self = .low
        }
    }

    var title: String { rawValue.capitalized + " risk" }

    var color: Color {
        switch self {
        case .low: return KnockDesign.mint
        case .medium: return Color.orange
        case .high: return KnockDesign.coral
        }
    }

    var background: Color {
        switch self {
        case .low: return KnockDesign.mintSoft
        case .medium: return Color.orange.opacity(0.13)
        case .high: return KnockDesign.coralSoft
        }
    }
}

struct RiskBadge: View {
    let risk: DecisionRisk

    var body: some View {
        Text(risk.title)
            .font(.caption2.weight(.bold))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(risk.color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(risk.background)
            .clipShape(Capsule())
    }
}

struct ConnectionPill: View {
    let state: BridgeConnectionState

    private var tint: Color {
        switch state {
        case .connected: return KnockDesign.mint
        case .unavailable: return KnockDesign.coral
        case .unknown: return KnockDesign.muted
        }
    }

    private var fill: Color {
        switch state {
        case .connected: return KnockDesign.mintSoft
        case .unavailable: return KnockDesign.coralSoft
        case .unknown: return KnockDesign.skySoft
        }
    }

    var body: some View {
        Label(state == .connected ? "Connected" : state == .unavailable ? "Offline" : "Checking", systemImage: state.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(fill)
            .clipShape(Capsule())
            .accessibilityLabel(state.title)
    }
}

struct ExpiryPill: View {
    let value: String

    var body: some View {
        if let date = parsedDate(value) {
            let expired = date < Date()
            HStack(spacing: 5) {
                Image(systemName: expired ? "clock.badge.xmark" : "clock")
                if expired {
                    Text("Expired")
                } else {
                    Text("Expires")
                    Text(date, style: .relative)
                }
            }
            .font(.caption2.weight(.semibold))
            .lineLimit(1)
            .allowsTightening(true)
            .minimumScaleFactor(0.78)
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(expired ? KnockDesign.coral : KnockDesign.muted)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background((expired ? KnockDesign.coralSoft : KnockDesign.skySoft).opacity(0.9))
            .clipShape(Capsule())
        }
    }
}

struct ProductionErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(KnockDesign.coral)
            Text(message)
                .font(.caption.weight(.semibold))
                .foregroundStyle(KnockDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
            }
            .foregroundStyle(KnockDesign.muted)
            .accessibilityLabel("Dismiss error")
        }
        .padding(12)
        .background(KnockDesign.coralSoft)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(KnockDesign.coral.opacity(0.22), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 12, y: 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("error.banner")
    }
}

struct FilterChip: View {
    let title: String
    let count: Int?
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title)
                    .lineLimit(1)
                if let count {
                    Text("\(count)")
                        .font(.caption2.weight(.heavy))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(selected ? Color.white.opacity(0.24) : KnockDesign.lavenderSoft)
                        .clipShape(Capsule())
                }
            }
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: true, vertical: false)
            .foregroundStyle(selected ? Color.white : KnockDesign.ink)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(selected ? KnockDesign.coral : Color.white.opacity(0.82))
            .overlay {
                Capsule().stroke(selected ? Color.clear : KnockDesign.border, lineWidth: 1)
            }
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("filter.\(title)")
    }
}

struct InboxHeader: View {
    let waitingCount: Int
    let connectionState: BridgeConnectionState

    private var summary: String {
        waitingCount == 0
            ? "Your agents can keep moving."
            : "Answer here and the exact agent session will continue."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                KnockMascot(size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Decision inbox")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KnockDesign.muted)
                    Text(waitingCount == 0 ? "All clear" : "Needs your attention")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(KnockDesign.ink)
                }
                Spacer(minLength: 6)
                ConnectionPill(state: connectionState)
            }

            HStack(alignment: .bottom, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(waitingCount == 0 ? "Nothing is blocked" : "\(waitingCount) waiting")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .foregroundStyle(KnockDesign.ink)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(KnockDesign.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: waitingCount == 0 ? "checkmark.seal.fill" : "hand.raised.fill")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(waitingCount == 0 ? KnockDesign.mint : KnockDesign.coral)
                    .padding(11)
                    .background(Color.white.opacity(0.72))
                    .clipShape(Circle())
                    .accessibilityHidden(true)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(waitingCount == 0 ? KnockDesign.lavenderSoft : KnockDesign.coralSoft)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(waitingCount == 0 ? "Decision inbox. All clear." : "Decision inbox. \(waitingCount) decision(s) waiting for you.")
    }
}

struct DashboardMetric: View {
    let title: String
    let value: Int
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(value)")
                    .font(.headline.weight(.bold).monospacedDigit())
                    .foregroundStyle(KnockDesign.ink)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(KnockDesign.muted)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct DashboardStatsStrip: View {
    let waitingCount: Int
    let activeCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: 0) {
            DashboardMetric(
                title: "Needs me",
                value: waitingCount,
                symbol: "hand.raised.fill",
                tint: KnockDesign.coral
            )
            Divider()
                .frame(height: 30)
                .padding(.horizontal, 10)
            DashboardMetric(
                title: "Active",
                value: activeCount,
                symbol: "bolt.fill",
                tint: KnockDesign.lavender
            )
            Divider()
                .frame(height: 30)
                .padding(.horizontal, 10)
            DashboardMetric(
                title: "Sessions",
                value: totalCount,
                symbol: "tray.full.fill",
                tint: Color.blue
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(KnockDesign.card)
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(KnockDesign.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct LocalVoiceCommandCard: View {
    @ObservedObject var controller: LocalVoiceCommandController

    var body: some View {
        KnockCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    Image(systemName: controller.state.isListening ? "waveform" : "mic.fill")
                        .foregroundStyle(KnockDesign.coral)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("On-device voice")
                            .font(.subheadline.weight(.bold))
                        Text(stateDescription)
                            .font(.caption)
                            .foregroundStyle(KnockDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                Text(controller.transcript.isEmpty ? "Hold the button and speak a command." : controller.transcript)
                    .font(.caption)
                    .foregroundStyle(controller.transcript.isEmpty ? KnockDesign.muted : KnockDesign.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack {
                    Image(systemName: controller.state.isListening ? "mic.circle.fill" : "mic.circle")
                    Text(controller.state.isListening ? "Release to submit" : "Hold to talk")
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(controller.state.isListening ? KnockDesign.lavender : KnockDesign.coral)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .onLongPressGesture(minimumDuration: 0, maximumDistance: 44, pressing: { pressing in
                    if pressing {
                        controller.start()
                    } else {
                        controller.stop()
                    }
                }, perform: {})
                .accessibilityLabel("Push to talk")
                .accessibilityHint("Hold to speak a command. Release to submit it for backend validation.")
            }
        }
    }

    private var stateDescription: String {
        switch controller.state {
        case .idle: return "Gemma intent parsing is ready."
        case .requestingPermissions: return "Waiting for microphone permission…"
        case .listening: return "Listening with voice activity detection…"
        case .processing: return "Understanding locally, then validating with the backend…"
        case .clarificationRequired: return "I need a clearer date, person, amount, or intent."
        case let .submitted(commandID): return "Submitted \(commandID)."
        case let .failed(message): return message
        }
    }
}

private extension LocalVoiceCommandController.State {
    var isListening: Bool {
        if case .listening = self { return true }
        return false
    }
}

struct DashboardHero: View {
    let waitingCount: Int
    let activeCount: Int
    let totalCount: Int
    let connectionState: BridgeConnectionState

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(Color.white.opacity(0.30))
                .frame(width: 168, height: 168)
                .offset(x: 58, y: -68)

            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 10) {
                    KnockMascot(size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Control room")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(KnockDesign.muted)
                            .textCase(.uppercase)
                        Text(waitingCount == 0 ? "All agents are moving" : "Your attention is needed")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(KnockDesign.ink)
                    }
                    Spacer(minLength: 6)
                    ConnectionPill(state: connectionState)
                }

                HStack(alignment: .center, spacing: 14) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(waitingCount == 0 ? "0" : "\(waitingCount)")
                            .font(.system(size: 40, weight: .heavy, design: .rounded))
                            .foregroundStyle(KnockDesign.ink)
                            .monospacedDigit()
                        Text(waitingCount == 0 ? "decisions waiting" : "decision\(waitingCount == 1 ? "" : "s") waiting")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KnockDesign.ink)
                        Text(waitingCount == 0
                             ? "Nothing is blocking your agents right now."
                             : "Answer once and the exact session continues.")
                            .font(.caption)
                            .foregroundStyle(KnockDesign.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: waitingCount == 0 ? "sparkles" : "hand.raised.fill")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(waitingCount == 0 ? KnockDesign.mint : KnockDesign.coral)
                        .frame(width: 54, height: 54)
                        .background(Color.white.opacity(0.78))
                        .clipShape(Circle())
                        .accessibilityHidden(true)
                }
            }
            .padding(18)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(waitingCount == 0 ? KnockDesign.lavenderSoft : KnockDesign.coralSoft)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Dashboard. \(waitingCount) decision(s) waiting, \(activeCount) active, \(totalCount) total sessions.")
    }
}

struct DashboardSearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KnockDesign.muted)
            TextField("Find an agent or task", text: $text)
                .font(.subheadline)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityIdentifier("inbox.search")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(KnockDesign.muted.opacity(0.75))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(KnockDesign.card)
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(KnockDesign.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct DashboardAttentionSection: View {
    let sessions: [Session]
    let agentLabels: [String: String]

    private var displayedSessions: [Session] {
        Array(sessions.prefix(3))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Needs you now")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(KnockDesign.ink)
                    Text("These sessions are paused until you answer.")
                        .font(.caption)
                        .foregroundStyle(KnockDesign.muted)
                }
                Spacer(minLength: 8)
                Text("\(sessions.count)")
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(KnockDesign.coral)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(KnockDesign.coralSoft)
                    .clipShape(Capsule())
            }

            KnockCard(padding: 0) {
                VStack(spacing: 0) {
                    ForEach(Array(displayedSessions.enumerated()), id: \.element.id) { index, session in
                        NavigationLink(destination: ProductionDecisionDetailView(sessionId: session.session_id)) {
                            DashboardDecisionRow(
                                session: session,
                                agentLabel: agentLabels[session.agent_id] ?? session.agent_id
                            )
                            .padding(.horizontal, 14)
                            .padding(.vertical, 13)
                        }
                        .buttonStyle(.plain)

                        if index < displayedSessions.count - 1 {
                            Divider()
                                .padding(.leading, 68)
                        }
                    }
                }
            }
        }
    }
}

struct DashboardDecisionRow: View {
    let session: Session
    let agentLabel: String

    var body: some View {
        HStack(spacing: 11) {
            AgentGlyph(seed: session.agent_id, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.title ?? session.skill_id)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(KnockDesign.ink)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text("\(agentLabel) · \(session.skill_id)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(KnockDesign.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(session.progress_message ?? session.summary_text ?? "Waiting for your decision")
                    .font(.caption)
                    .foregroundStyle(KnockDesign.muted)
                    .lineLimit(1)
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 7) {
                RiskBadge(risk: DecisionRisk(session: session))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(KnockDesign.muted)
            }
        }
    }
}

struct SessionDirectoryHeader: View {
    let count: Int
    let selectedAgentLabel: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "tray.full.fill")
                .font(.title3.weight(.bold))
                .foregroundStyle(KnockDesign.lavender)
                .padding(11)
                .background(KnockDesign.lavenderSoft)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text("Session library")
                    .font(.headline.weight(.bold))
                    .foregroundStyle(KnockDesign.ink)
                Text("\(count) session\(count == 1 ? "" : "s") · \(selectedAgentLabel)")
                    .font(.caption)
                    .foregroundStyle(KnockDesign.muted)
            }
            Spacer()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KnockDesign.skySoft.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

struct InboxFilterBar: View {
    @Binding var selection: SessionFilter
    let counts: [SessionFilter: Int]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SessionFilter.allCases) { filter in
                Button {
                    selection = filter
                } label: {
                    HStack(spacing: 5) {
                        Text(filter.title)
                            .lineLimit(1)
                        Text("\(counts[filter, default: 0])")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(selection == filter ? Color.white.opacity(0.22) : KnockDesign.lavenderSoft)
                            .clipShape(Capsule())
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(selection == filter ? Color.white : KnockDesign.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
                .background(selection == filter ? KnockDesign.coral : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .accessibilityLabel("\(filter.title), \(counts[filter, default: 0])")
                .accessibilityIdentifier("filter.\(filter.rawValue)")
                .accessibilityAddTraits(selection == filter ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.white.opacity(0.72))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(KnockDesign.border, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
    }
}

struct AgentPickerRow: View {
    let agents: [Agent]
    let selectedAgentId: String?
    let onSelect: (String?) -> Void

    private var selectedTitle: String {
        guard let selectedAgentId,
              let agent = agents.first(where: { $0.agent_id == selectedAgentId })
        else { return "All agents" }
        return agent.displayLabel
    }

    var body: some View {
        Menu {
            Button {
                onSelect(nil)
            } label: {
                Label("All agents", systemImage: selectedAgentId == nil ? "checkmark" : "person.3")
            }
            Divider()
            ForEach(agents) { agent in
                Button {
                    onSelect(agent.agent_id)
                } label: {
                    Label(agent.displayLabel, systemImage: selectedAgentId == agent.agent_id ? "checkmark" : "person")
                }
            }
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "person.2.fill")
                    .foregroundStyle(KnockDesign.lavender)
                Text(selectedTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KnockDesign.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(KnockDesign.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(KnockDesign.lavenderSoft.opacity(0.72))
            .overlay {
                Capsule()
                    .stroke(KnockDesign.border, lineWidth: 1)
            }
            .clipShape(Capsule())
        }
        .accessibilityLabel("Agent filter: \(selectedTitle)")
    }
}

private func parsedDate(_ value: String) -> Date? {
    guard !value.isEmpty else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

private func actionTitle(_ key: String) -> String {
    switch key {
    case "rollback": return "Rollback"
    case "ack": return "Acknowledge"
    default: return key.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private func actionSymbol(_ key: String) -> String {
    switch key {
    case "rollback": return "arrow.uturn.backward.circle.fill"
    case "ack": return "checkmark.circle.fill"
    default: return "hand.tap.fill"
    }
}

// MARK: - App shell and onboarding

struct ProductionKnockOverlay: View {
    let knock: AppStore.KnockAlert
    let onOpenSession: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.58).ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    KnockMascot(size: 58)
                    Spacer()
                    Image(systemName: "bell.badge.fill")
                        .font(.title2)
                        .foregroundStyle(KnockDesign.coral)
                }
                Text("A decision is waiting")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(KnockDesign.ink)
                Text(knock.title)
                    .font(.headline)
                    .foregroundStyle(KnockDesign.ink)
                Text(knock.body)
                    .font(.subheadline)
                    .foregroundStyle(KnockDesign.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Button(action: onOpenSession) {
                    Text(knock.sessionId == nil ? "Got it" : "Review decision")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                }
                .buttonStyle(.borderedProminent)
                .tint(KnockDesign.coral)
                .accessibilityIdentifier("knock.review")
                Button("Later", action: onDismiss)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(KnockDesign.muted)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("knock.later")
            }
            .padding(24)
            .frame(maxWidth: 360)
            .background(KnockDesign.canvas)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 30, y: 14)
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent needs your decision")
    }
}

struct ProductionLoginView: View {
    @EnvironmentObject private var store: AppStore
    // Debug builds use the local fixture values for simulator regression;
    // Release/TestFlight builds intentionally resolve this to an empty string.
    @State private var password = DemoConfig.password
    // A Release/TestFlight install has no bundled credentials, so guide a new
    // user toward account creation first. Debug fixtures keep the sign-in path.
    @State private var isCreatingAccount = DemoConfig.email.isEmpty
    @State private var showServer = false

    var body: some View {
        NavigationView {
            ZStack {
                KnockDesign.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        VStack(alignment: .leading, spacing: 12) {
                            KnockMascot(size: 84)
                            Text(isCreatingAccount ? "Create your\nKnock Knock account" : "Welcome to\nKnock Knock")
                                .font(.system(size: 34, weight: .bold, design: .rounded))
                                .foregroundStyle(KnockDesign.ink)
                            Text("A clear, trusted decision inbox for your coding agents, not a chat app.")
                                .font(.body)
                                .foregroundStyle(KnockDesign.muted)
                        }
                        .padding(.top, 26)

                        KnockCard {
                            VStack(alignment: .leading, spacing: 16) {
                                Label(
                                    isCreatingAccount ? "Create your bridge account" : "Sign in to your bridge",
                                    systemImage: isCreatingAccount ? "person.badge.plus" : "person.crop.circle.fill"
                                )
                                    .font(.headline)
                                Text(
                                    isCreatingAccount
                                        ? "Choose a new Knock Knock password. It is separate from Apple, TestFlight, and Codex."
                                        : "Use the password you created for Knock Knock."
                                )
                                    .font(.footnote)
                                    .foregroundStyle(KnockDesign.muted)
                                TextField("Email", text: $store.email)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.emailAddress)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.roundedBorder)
                                SecureField("Password", text: $password)
                                    .textFieldStyle(.roundedBorder)
                                Button {
                                    guard store.applyApiBase() else { return }
                                    guard password.count >= 8 else {
                                        store.errorMessage = "Password must be at least 8 characters."
                                        return
                                    }
                                    Task {
                                        if isCreatingAccount {
                                            await store.register(password: password)
                                        } else {
                                            await store.login(password: password)
                                        }
                                    }
                                } label: {
                                    HStack {
                                        if store.isAuthenticating { ProgressView().tint(.white) }
                                        Text(
                                            store.isAuthenticating
                                                ? (isCreatingAccount ? "Creating…" : "Connecting…")
                                                : (isCreatingAccount ? "Create account" : "Continue")
                                        )
                                    }
                                    .font(.headline)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 13)
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(KnockDesign.coral)
                                .disabled(store.isAuthenticating)
                                .accessibilityIdentifier("login.submit")
                            }
                        }

                        Button {
                            isCreatingAccount.toggle()
                            password = ""
                            store.dismissError()
                        } label: {
                            Text(
                                isCreatingAccount
                                    ? "Already have an account? Sign in"
                                    : "New to Knock Knock? Create an account"
                            )
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KnockDesign.lavender)
                            .frame(maxWidth: .infinity)
                        }
                        .accessibilityIdentifier("login.modeToggle")

                        DisclosureGroup("Advanced connection", isExpanded: $showServer) {
                            VStack(alignment: .leading, spacing: 10) {
                                TextField("API base URL", text: $store.apiBase)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.roundedBorder)
                                #if !DEBUG
                                Button("Reset to production server") {
                                    store.apiBase = DemoConfig.defaultApiBase
                                    _ = store.applyApiBase()
                                }
                                .font(.subheadline.weight(.semibold))
                                .accessibilityIdentifier("login.useProductionDefaults")
                                #endif
                                #if DEBUG
                                if !DemoConfig.defaultApiBase.isEmpty {
                                    Button("Use local development defaults") {
                                        store.email = DemoConfig.email
                                        store.apiBase = DemoConfig.defaultApiBase
                                        password = DemoConfig.password
                                        store.applyApiBase()
                                    }
                                    .font(.subheadline.weight(.semibold))
                                }
                                #endif
                                Text("Use the current backend URL. A physical iPhone must use the Mac's current LAN address; production builds require HTTPS.")
                                    .font(.caption)
                                    .foregroundStyle(KnockDesign.muted)
                            }
                            .padding(.top, 10)
                        }
                        .padding(.horizontal, 4)

                        if let error = store.errorMessage {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(KnockDesign.coral)
                        }

                        HStack(spacing: 8) {
                            Image(systemName: "lock.fill")
                            Text("Your decision is routed only to the agent session that requested it.")
                        }
                        .font(.caption)
                        .foregroundStyle(KnockDesign.muted)
                        .padding(.horizontal, 4)
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 30)
                }
            }
            .navigationTitle("")
            .navigationBarHidden(true)
            .navigationViewStyle(.stack)
        }
    }
}

enum ProductionDestination: Hashable {
    case dashboard
    case sessions
    case devPush
    case settings
}

struct ProductionDrawerRow: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let selected: Bool
    let badge: String?
    let action: () -> Void

    init(
        title: String,
        subtitle: String? = nil,
        symbol: String,
        selected: Bool = false,
        badge: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.selected = selected
        self.badge = badge
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(selected ? KnockDesign.coral : KnockDesign.muted)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(KnockDesign.ink)
                        .lineLimit(1)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(KnockDesign.muted)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 6)
                if let badge {
                    Text(badge)
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .foregroundStyle(selected ? KnockDesign.coral : KnockDesign.muted)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(selected ? KnockDesign.coralSoft : KnockDesign.canvas)
                        .clipShape(Capsule())
                }
                if selected {
                    Circle()
                        .fill(KnockDesign.coral)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? KnockDesign.coralSoft : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ProductionDrawerSessionRow: View {
    let session: Session
    let agentLabel: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AgentGlyph(seed: session.agent_id, size: 31)
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title ?? session.skill_id)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KnockDesign.ink)
                        .lineLimit(1)
                    HStack(spacing: 4) {
                        Text(agentLabel ?? session.agent_id)
                        Text("·")
                        Text(session.stateTitle)
                    }
                    .font(.caption2)
                    .foregroundStyle(KnockDesign.muted)
                    .lineLimit(1)
                }
                Spacer(minLength: 3)
                if session.needsUser {
                    Image(systemName: "hand.raised.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(KnockDesign.coral)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(KnockDesign.muted.opacity(0.65))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open (session.title ?? session.skill_id)")
    }
}

struct ProductionDrawer: View {
    @EnvironmentObject private var store: AppStore

    let selectedDestination: ProductionDestination
    let onClose: () -> Void
    let onSelect: (ProductionDestination) -> Void
    let onSelectAgent: (String?) -> Void
    let onOpenSession: (Session) -> Void

    private var waitingCount: Int {
        store.sessions.filter(\.needsUser).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                KnockMascot(size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Knock Knock")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(KnockDesign.ink)
                    Text("Your agent control room")
                        .font(.caption)
                        .foregroundStyle(KnockDesign.muted)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(KnockDesign.muted)
                        .padding(9)
                        .background(KnockDesign.canvas)
                        .clipShape(Circle())
                }
                .accessibilityLabel("Close navigation")
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 15)

            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("WORKSPACE")
                            .font(.caption2.weight(.heavy))
                            .tracking(1.2)
                            .foregroundStyle(KnockDesign.muted)
                            .padding(.horizontal, 12)
                        ProductionDrawerRow(
                            title: "Dashboard",
                            subtitle: "A calm overview of every agent",
                            symbol: "square.grid.2x2.fill",
                            selected: selectedDestination == .dashboard,
                            action: { onSelect(.dashboard) }
                        )
                        .accessibilityIdentifier("drawer.dashboard")
                        ProductionDrawerRow(
                            title: "All sessions",
                            subtitle: "Browse the full decision history",
                            symbol: "tray.full.fill",
                            selected: selectedDestination == .sessions,
                            badge: store.sessions.isEmpty ? nil : "\(store.sessions.count)",
                            action: { onSelect(.sessions) }
                        )
                        .accessibilityIdentifier("drawer.sessions")
                    }

                    if !store.agents.isEmpty {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text("AGENTS")
                                    .font(.caption2.weight(.heavy))
                                    .tracking(1.2)
                                    .foregroundStyle(KnockDesign.muted)
                                Spacer()
                                Text("\(store.agents.count)")
                                    .font(.caption2.weight(.bold).monospacedDigit())
                                    .foregroundStyle(KnockDesign.muted)
                            }
                            .padding(.horizontal, 12)

                            ProductionDrawerRow(
                                title: "All agents",
                                subtitle: "Show the whole workspace",
                                symbol: "person.3.fill",
                                selected: store.selectedAgentId == nil && selectedDestination == .dashboard,
                                badge: waitingCount == 0 ? nil : "\(waitingCount)",
                                action: {
                                    onSelectAgent(nil)
                                    onSelect(.dashboard)
                                }
                            )
                            .accessibilityIdentifier("drawer.agent.all")

                            ForEach(store.agents) { agent in
                                let count = store.sessions.filter { $0.agent_id == agent.agent_id }.count
                                ProductionDrawerRow(
                                    title: agent.displayLabel,
                                    subtitle: agent.host_label,
                                    symbol: "circle.grid.2x2.fill",
                                    selected: store.selectedAgentId == agent.agent_id && selectedDestination == .dashboard,
                                    badge: count == 0 ? nil : "\(count)",
                                    action: {
                                        onSelectAgent(agent.agent_id)
                                        onSelect(.dashboard)
                                    }
                                )
                                .accessibilityIdentifier("drawer.agent.\(agent.agent_id)")
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("RECENT SESSIONS")
                                .font(.caption2.weight(.heavy))
                                .tracking(1.2)
                                .foregroundStyle(KnockDesign.muted)
                            Spacer()
                            Text("\(store.sessions.count)")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(KnockDesign.muted)
                        }
                        .padding(.horizontal, 12)

                        if store.sessions.isEmpty {
                            Text("Your connected agents will appear here.")
                                .font(.caption)
                                .foregroundStyle(KnockDesign.muted)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(store.sessions) { session in
                                ProductionDrawerSessionRow(
                                    session: session,
                                    agentLabel: store.agents.first { $0.agent_id == session.agent_id }?.displayLabel,
                                    action: { onOpenSession(session) }
                                )
                            }
                        }
                    }

                    #if targetEnvironment(simulator)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("DEVELOPMENT")
                            .font(.caption2.weight(.heavy))
                            .tracking(1.2)
                            .foregroundStyle(KnockDesign.muted)
                            .padding(.horizontal, 12)
                        ProductionDrawerRow(
                            title: "Dev push inbox",
                            subtitle: "Simulator notification fixtures",
                            symbol: "bell.badge.fill",
                            selected: selectedDestination == .devPush,
                            action: { onSelect(.devPush) }
                        )
                        .accessibilityIdentifier("drawer.dev-push")
                    }
                    #endif
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 14)
            }

            Divider()
                .overlay(KnockDesign.border)

            VStack(alignment: .leading, spacing: 5) {
                ProductionDrawerRow(
                    title: "Settings",
                    subtitle: "Pairing, notifications, diagnostics",
                    symbol: "gearshape.fill",
                    selected: selectedDestination == .settings,
                    action: { onSelect(.settings) }
                )
                .accessibilityIdentifier("drawer.settings")
                Text(store.email)
                    .font(.caption2)
                    .foregroundStyle(KnockDesign.muted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, 15)
                    .padding(.bottom, 13)
            }
            .padding(.top, 8)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(KnockDesign.card)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(KnockDesign.border)
                .frame(width: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Knock Knock navigation")
    }
}

struct ProductionMainShellView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedDestination: ProductionDestination = .dashboard
    @State private var drawerOpen = false

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                mainContent

                if drawerOpen {
                    Color.black.opacity(0.34)
                        .ignoresSafeArea()
                        .onTapGesture { closeDrawer() }
                        .accessibilityLabel("Close navigation")

                    ProductionDrawer(
                        selectedDestination: selectedDestination,
                        onClose: closeDrawer,
                        onSelect: selectDestination,
                        onSelectAgent: store.selectAgent,
                        onOpenSession: openSessionFromDrawer
                    )
                    .frame(width: min(326, proxy.size.width * 0.86))
                    .shadow(color: .black.opacity(0.18), radius: 24, x: 10, y: 0)
                    .transition(.move(edge: .leading))
                }
            }
        }
        .tint(KnockDesign.coral)
        .onChange(of: store.openSessionId) { newValue in
            if newValue != nil { selectedDestination = .dashboard }
        }
        .overlay(alignment: .top) {
            if let error = store.errorMessage {
                ProductionErrorBanner(message: error) {
                    store.dismissError()
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.errorMessage)
    }

    @ViewBuilder
    private var mainContent: some View {
        switch selectedDestination {
        case .dashboard:
            ProductionInboxView(mode: .dashboard, onOpenDrawer: openDrawer)
        case .sessions:
            ProductionInboxView(mode: .allSessions, onOpenDrawer: openDrawer)
        case .devPush:
            ProductionPushInboxView(onOpenDrawer: openDrawer)
        case .settings:
            ProductionSettingsView(onOpenDrawer: openDrawer)
        }
    }

    private func openDrawer() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            drawerOpen = true
        }
    }

    private func closeDrawer() {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            drawerOpen = false
        }
    }

    private func selectDestination(_ destination: ProductionDestination) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            selectedDestination = destination
            drawerOpen = false
        }
    }

    private func openSessionFromDrawer(_ session: Session) {
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
            selectedDestination = .dashboard
            drawerOpen = false
        }
        Task { await store.openSession(session.session_id) }
    }
}

// MARK: - Inbox

enum ProductionInboxMode {
    case dashboard
    case allSessions

    var navigationTitle: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .allSessions: return "All sessions"
        }
    }
}

struct ProductionInboxView: View {
    @EnvironmentObject private var store: AppStore
    let mode: ProductionInboxMode
    let onOpenDrawer: () -> Void

    @State private var sessionFilter: SessionFilter
    @State private var searchText = ""

    init(mode: ProductionInboxMode = .dashboard, onOpenDrawer: @escaping () -> Void = {}) {
        self.mode = mode
        self.onOpenDrawer = onOpenDrawer
        _sessionFilter = State(initialValue: .all)
    }

    private var agentSessions: [Session] {
        guard let selectedAgentId = store.selectedAgentId else { return store.sessions }
        return store.sessions.filter { $0.agent_id == selectedAgentId }
    }

    private var waiting: [Session] { agentSessions.filter(\.needsUser) }

    private var visibleSessions: [Session] {
        let matcher = SessionSearchMatcher(query: searchText)
        return agentSessions.filter { session in
            guard session.matches(sessionFilter) else { return false }
            let agent = store.agents.first { $0.agent_id == session.agent_id }
            return matcher.matches(session, agent: agent)
        }
    }

    private var requestedSession: Session? {
        guard let id = store.openSessionId else { return nil }
        return store.sessions.first { $0.session_id == id }
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .top) {
                KnockDesign.canvas.ignoresSafeArea()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if mode == .dashboard {
                            DashboardHero(
                                waitingCount: waiting.count,
                                activeCount: agentSessions.filter(\.isActive).count,
                                totalCount: agentSessions.count,
                                connectionState: store.connectionState
                            )
                            DashboardStatsStrip(
                                waitingCount: waiting.count,
                                activeCount: agentSessions.filter(\.isActive).count,
                                totalCount: agentSessions.count
                            )
                            if let voiceController = store.voiceController {
                                LocalVoiceCommandCard(controller: voiceController)
                            }
                        } else {
                            SessionDirectoryHeader(
                                count: visibleSessions.count,
                                selectedAgentLabel: selectedAgentLabel
                            )
                        }

                        if store.connectionState == .unavailable {
                            KnockCard(padding: 14) {
                                HStack(spacing: 12) {
                                    Image(systemName: "wifi.exclamationmark")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(KnockDesign.coral)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Bridge is offline")
                                            .font(.subheadline.weight(.bold))
                                        Text("Showing your last synced decisions.")
                                            .font(.caption)
                                            .foregroundStyle(KnockDesign.muted)
                                    }
                                    Spacer()
                                    Button {
                                        Task { await store.refresh() }
                                    } label: {
                                        Label("Retry", systemImage: "arrow.clockwise")
                                            .font(.caption.weight(.bold))
                                    }
                                    .accessibilityIdentifier("inbox.retry")
                                }
                            }
                        }

                        if !store.pendingOperations.isEmpty {
                            KnockCard(padding: 14) {
                                HStack(spacing: 10) {
                                    Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                        .foregroundStyle(KnockDesign.lavender)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text("Pending sync")
                                            .font(.subheadline.weight(.bold))
                                        Text("\(store.pendingOperations.count) answer(s) will send when the bridge is reachable.")
                                            .font(.caption)
                                            .foregroundStyle(KnockDesign.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    Spacer()
                                }
                            }
                        }

                        if !waiting.isEmpty {
                            DashboardAttentionSection(
                                sessions: waiting,
                                agentLabels: agentLabels
                            )
                        }

                        DashboardSearchField(text: $searchText)

                        if store.agents.count > 1 {
                            HStack {
                                AgentPickerRow(
                                    agents: store.agents,
                                    selectedAgentId: store.selectedAgentId,
                                    onSelect: store.selectAgent
                                )
                                Spacer(minLength: 0)
                            }
                        }

                        InboxFilterBar(
                            selection: $sessionFilter,
                            counts: [
                                .needsUser: waiting.count,
                                .active: agentSessions.filter(\.isActive).count,
                                .all: agentSessions.count
                            ]
                        )

                        if visibleSessions.isEmpty {
                            ProductionEmptyState(
                                title: emptyTitle,
                                symbol: searchText.isEmpty ? (sessionFilter == .needsUser ? "checkmark.seal.fill" : "tray") : "magnifyingglass",
                                description: emptyDescription,
                                actionTitle: searchText.isEmpty && sessionFilter == .all ? "Refresh" : "Show all"
                            ) {
                                if !searchText.isEmpty {
                                    searchText = ""
                                } else if sessionFilter != .all {
                                    sessionFilter = .all
                                } else {
                                    Task { await store.refresh() }
                                }
                            }
                        } else {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(sessionFilter == .needsUser ? "Needs your attention" : "Recent sessions")
                                        .font(.headline.weight(.bold))
                                    Text("Tap a session to see the context and answer.")
                                        .font(.caption)
                                        .foregroundStyle(KnockDesign.muted)
                                }
                                Spacer()
                                Text("\(visibleSessions.count)")
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(KnockDesign.muted)
                            }
                            .padding(.top, 3)
                            ForEach(visibleSessions) { session in
                                NavigationLink(destination: ProductionDecisionDetailView(sessionId: session.session_id)) {
                                    ProductionSessionCard(
                                        session: session,
                                        agentLabel: store.agents.first { $0.agent_id == session.agent_id }?.displayLabel
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 28)
                }
                .refreshable { await store.refresh() }

                if store.isRefreshing && !store.hasLoadedData {
                    VStack(spacing: 10) {
                        ProgressView()
                            .tint(KnockDesign.coral)
                        Text("Loading your inbox")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(KnockDesign.muted)
                    }
                    .padding(18)
                    .background(KnockDesign.card)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 16, y: 7)
                }
            }
            .navigationTitle(mode.navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onOpenDrawer) {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel("Open navigation")
                    .accessibilityIdentifier("drawer.open")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await store.refresh() } } label: {
                        Image(systemName: store.isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    }
                    .disabled(store.isRefreshing)
                    .accessibilityLabel("Refresh inbox")
                }
            }
            .background {
                if let requestedSession {
                    NavigationLink(
                        destination: ProductionDecisionDetailView(sessionId: requestedSession.session_id),
                        isActive: Binding(
                            get: { store.openSessionId == requestedSession.session_id },
                            set: { if !$0 { store.openSessionId = nil } }
                        )
                    ) { EmptyView() }
                        .hidden()
                }
            }
            .navigationViewStyle(.stack)
        }
    }

    private var emptyTitle: String {
        if !searchText.isEmpty { return "Nothing matches" }
        switch sessionFilter {
        case .needsUser: return "Nothing needs you"
        case .active: return "No active sessions"
        case .all: return "No sessions yet"
        }
    }

    private var emptyDescription: String {
        if !searchText.isEmpty { return "Try an agent, skill, or task name." }
        switch sessionFilter {
        case .needsUser: return "Your agents will appear here when they need a decision."
        case .active: return "No agent is working on a bridge session right now."
        case .all: return "Connect an agent to start your first decision session."
        }
    }

    private var selectedAgentLabel: String {
        guard let selectedAgentId = store.selectedAgentId,
              let agent = store.agents.first(where: { $0.agent_id == selectedAgentId })
        else { return "All agents" }
        return agent.displayLabel
    }

    private var agentLabels: [String: String] {
        Dictionary(uniqueKeysWithValues: store.agents.map { ($0.agent_id, $0.displayLabel) })
    }
}

struct ProductionSessionCard: View {
    let session: Session
    let agentLabel: String?

    var body: some View {
        KnockCard(padding: 14) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top, spacing: 10) {
                    AgentGlyph(seed: session.agent_id, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.title ?? session.skill_id)
                            .font(.headline.weight(.bold))
                            .foregroundStyle(KnockDesign.ink)
                            .lineLimit(2)
                            .truncationMode(.tail)
                        HStack(spacing: 5) {
                            Text(agentLabel ?? session.agent_id)
                            Circle()
                                .fill(KnockDesign.muted.opacity(0.55))
                                .frame(width: 3, height: 3)
                            Text(session.skill_id)
                        }
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(KnockDesign.muted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .allowsTightening(true)
                    }
                    Spacer(minLength: 6)
                    VStack(alignment: .trailing, spacing: 5) {
                        if let date = parsedDate(session.updated_at) {
                            Text(date, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(KnockDesign.muted)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        Image(systemName: session.stateSymbol)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(session.needsUser ? KnockDesign.coral : KnockDesign.muted)
                    }
                }

                Text(session.progress_message ?? session.summary_text ?? "Agent session")
                    .font(.subheadline)
                    .foregroundStyle(KnockDesign.muted)
                    .lineLimit(2)
                    .truncationMode(.tail)

                if !session.needsUser {
                    if let percent = session.progress_percent, percent >= 0 {
                        HStack(spacing: 8) {
                            ProgressView(value: min(percent, 100), total: 100)
                                .tint(KnockDesign.lavender)
                            Text("\(Int(percent))%")
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(KnockDesign.muted)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Progress")
                        .accessibilityValue("\(Int(percent)) percent")
                    } else if session.progress_status == "started" || session.progress_status == "running" {
                        HStack(spacing: 8) {
                            ProgressView()
                                .tint(KnockDesign.lavender)
                            Text("Working…")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(KnockDesign.muted)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Agent working")
                    }
                }

                HStack(alignment: .center, spacing: 8) {
                    SessionStateBadge(session: session)
                    RiskBadge(risk: DecisionRisk(session: session))
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(KnockDesign.muted)
                }

                if session.needsUser {
                    ExpiryPill(value: session.expires_at)
                }
            }
        }
    }
}

struct SessionStateBadge: View {
    let session: Session

    private var title: String {
        switch session.state {
        case "needs_user": return "Needs me"
        case "awaiting_confirm": return "Confirm"
        case "running", "started": return "Working"
        case "queued": return "Queued"
        case "claimed": return "Claimed"
        default: return session.stateTitle
        }
    }

    private var tint: Color {
        if session.needsUser { return KnockDesign.coral }
        if session.isTerminal { return KnockDesign.mint }
        return KnockDesign.lavender
    }

    private var fill: Color {
        if session.needsUser { return KnockDesign.coralSoft }
        if session.isTerminal { return KnockDesign.mintSoft }
        return KnockDesign.lavenderSoft
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(tint)
                .frame(width: 5, height: 5)
            Text(title)
                .lineLimit(1)
        }
        .font(.caption2.weight(.bold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(fill)
        .clipShape(Capsule())
        .accessibilityLabel("Status: \(session.stateTitle)")
    }
}

struct ProductionEmptyState: View {
    let title: String
    let symbol: String
    let description: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        KnockCard {
            VStack(spacing: 12) {
                ZStack {
                    KnockMascot(size: 62)
                    Image(systemName: symbol)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(KnockDesign.lavender)
                        .padding(7)
                        .background(Color.white)
                        .clipShape(Circle())
                        .offset(x: 24, y: 22)
                }
                Text(title)
                    .font(.headline)
                    .foregroundStyle(KnockDesign.ink)
                Text(description)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(KnockDesign.muted)
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(KnockDesign.coral)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
        }
    }
}

// MARK: - Decision detail

struct ProductionDecisionDetailView: View {
    @EnvironmentObject private var store: AppStore
    let sessionId: String
    @State private var pendingActionId: String?
    @State private var showConfirm = false

    private var session: Session? { store.sessions.first { $0.session_id == sessionId } }
    private var history: [HistoryEntry] { store.historyBySession[sessionId] ?? [] }
    private var messages: [SessionMessage] { store.messagesBySession[sessionId] ?? [] }
    private var retrievals: [RetrievalItem] { store.retrievalsBySession[sessionId] ?? [] }

    var body: some View {
        ZStack {
            KnockDesign.canvas.ignoresSafeArea()
            ScrollView {
                if let session {
                    VStack(alignment: .leading, spacing: 14) {
                        ProductionDecisionHero(session: session)
                        HStack {
                            ExpiryPill(value: session.expires_at)
                            Spacer()
                            if let updated = parsedDate(session.updated_at) {
                                Text("Updated")
                                    .font(.caption2)
                                    .foregroundStyle(KnockDesign.muted)
                                Text(updated, style: .relative)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(KnockDesign.muted)
                            }
                        }
                        .padding(.horizontal, 4)
                        ProductionAgentContext(session: session)
                        if !session.needsUser {
                            if let percent = session.progress_percent, percent >= 0 {
                                KnockCard {
                                    VStack(alignment: .leading, spacing: 8) {
                                        HStack {
                                            Text("Agent progress")
                                                .font(.subheadline.weight(.semibold))
                                            Spacer()
                                            Text("\(Int(percent))%")
                                                .font(.caption.weight(.bold))
                                                .foregroundStyle(KnockDesign.lavender)
                                        }
                                        ProgressView(value: min(percent, 100), total: 100)
                                            .tint(KnockDesign.lavender)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            } else if session.progress_status == "started" || session.progress_status == "running" {
                                KnockCard {
                                    HStack(spacing: 10) {
                                        ProgressView()
                                            .tint(KnockDesign.lavender)
                                        Text("Agent working…")
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(KnockDesign.muted)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        if let summary = session.summary_text {
                            KnockCard {
                                VStack(alignment: .leading, spacing: 9) {
                                    Label("What the agent needs", systemImage: "text.alignleft")
                                        .font(.headline)
                                    Text(summary)
                                        .font(.body)
                                        .foregroundStyle(KnockDesign.ink)
                                    if let voice = session.voice_script, !voice.isEmpty {
                                        Text(voice)
                                            .font(.caption)
                                            .foregroundStyle(KnockDesign.muted)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !session.facts.isEmpty {
                            KnockCard {
                                VStack(alignment: .leading, spacing: 10) {
                                    Label("Relevant context", systemImage: "list.bullet.rectangle.portrait")
                                        .font(.headline)
                                    ForEach(session.facts.keys.sorted(), id: \.self) { key in
                                        DetailLine(
                                            label: key.replacingOccurrences(of: "_", with: " ").capitalized,
                                            value: session.facts[key]?.displayValue ?? "None"
                                        )
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        if !history.isEmpty {
                            ProductionHistoryTimeline(entries: history)
                        }
                        if !messages.isEmpty {
                            ProductionMessageTimeline(messages: messages)
                        }
                        if !retrievals.isEmpty {
                            ProductionRetrievalSources(items: retrievals)
                        }
                        if session.needsUser {
                            ProductionActionCard(session: session, pendingAction: $pendingActionId, showConfirm: $showConfirm)
                        } else {
                            KnockCard {
                                HStack(spacing: 12) {
                                    Image(systemName: session.stateSymbol)
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(session.isTerminal ? KnockDesign.mint : KnockDesign.lavender)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(session.stateTitle)
                                            .font(.headline)
                                        Text(statusCopy(for: session))
                                            .font(.caption)
                                            .foregroundStyle(KnockDesign.muted)
                                    }
                                }
                            }
                        }
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                DetailLine(label: "Session", value: session.session_id)
                                DetailLine(label: "Agent", value: session.agent_id)
                                DetailLine(label: "Skill", value: session.skill_id)
                                if let chat = session.chat_id, !chat.isEmpty {
                                    DetailLine(label: "Chat", value: chat)
                                }
                            }
                            .padding(.top, 10)
                        } label: {
                            Label("Exact routing", systemImage: "arrow.triangle.branch")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(KnockDesign.ink)
                        }
                        .padding(.horizontal, 4)
                        Text("Your answer is routed only to this exact agent session.")
                            .font(.caption)
                            .foregroundStyle(KnockDesign.muted)
                            .padding(.horizontal, 4)
                    }
                    .padding(18)
                } else {
                    ProductionEmptyState(
                        title: "Session unavailable",
                        symbol: "questionmark.folder.fill",
                        description: "This decision may have expired or been removed.",
                        actionTitle: "Refresh"
                    ) { Task { await store.refresh() } }
                    .padding(18)
                }
            }
        }
        .navigationTitle("Decision")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: sessionId) {
            await store.loadSessionDetail(for: sessionId)
            await store.loadHistory(for: sessionId)
            await store.loadMessages(for: sessionId)
        }
        .confirmationDialog("Confirm destructive action?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button("Confirm and continue", role: .destructive) {
                guard let session, let id = pendingActionId else { return }
                Task { await store.confirm(session: session, actionId: id, confirm: true) }
            }
            Button("Choose another action") {
                guard let session, let id = pendingActionId else { return }
                Task { await store.confirm(session: session, actionId: id, confirm: false) }
            }
            Button("Not now", role: .cancel) {
                pendingActionId = nil
            }
        } message: {
            Text("This action may change data or block the agent. Confirm only if you want the agent to continue with it.")
        }
    }

    private func statusCopy(for session: Session) -> String {
        switch session.state {
        case "queued": return "Your decision is with the agent now."
        case "expired": return "This request expired before it could be completed."
        case "failed": return "The agent reported a failure."
        case "cancelled": return "This decision was cancelled."
        default: return "This session will update here as the agent continues."
        }
    }
}

struct ProductionHistoryTimeline: View {
    let entries: [HistoryEntry]

    var body: some View {
        KnockCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Decision history", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                ForEach(entries) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(KnockDesign.lavender)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(entry.title)
                                .font(.subheadline.weight(.semibold))
                            if let date = parsedDate(entry.created_at) {
                                Text(date, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(KnockDesign.muted)
                            }
                        }
                        Spacer()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProductionMessageTimeline: View {
    let messages: [SessionMessage]

    var body: some View {
        KnockCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                    .font(.headline)
                ForEach(messages) { message in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(message.role.capitalized)
                            .font(.caption.weight(.bold))
                            .foregroundStyle(KnockDesign.lavender)
                        Text(message.content)
                            .font(.subheadline)
                            .foregroundStyle(KnockDesign.ink)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProductionRetrievalSources: View {
    let items: [RetrievalItem]

    var body: some View {
        KnockCard {
            VStack(alignment: .leading, spacing: 9) {
                Label("Sources", systemImage: "link")
                    .font(.headline)
                ForEach(items) { item in
                    if let url = URL(string: item.url) {
                        Link(destination: url) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(KnockDesign.ink)
                                if let snippet = item.snippet, !snippet.isEmpty {
                                    Text(snippet)
                                        .font(.caption)
                                        .foregroundStyle(KnockDesign.muted)
                                        .lineLimit(2)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProductionDecisionHero: View {
    let session: Session

    var body: some View {
        let risk = DecisionRisk(session: session)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                AgentGlyph(seed: session.agent_id, size: 50)
                Spacer()
                RiskBadge(risk: risk)
            }
            Text(session.needsUser ? "Needs your decision" : session.stateTitle)
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text(session.title ?? session.skill_id)
                .font(.headline)
                .lineLimit(2)
            HStack(spacing: 7) {
                Circle().fill(session.needsUser ? Color.white : KnockDesign.mint).frame(width: 8, height: 8)
                Text(session.needsUser ? "Blocking agent progress" : "Agent session is active")
                    .font(.caption.weight(.semibold))
            }
            if !session.needsUser {
                if let percent = session.progress_percent, percent >= 0 {
                    ProgressView(value: min(percent, 100), total: 100)
                        .tint(KnockDesign.lavender)
                } else if session.progress_status == "started" || session.progress_status == "running" {
                    ProgressView()
                        .tint(KnockDesign.lavender)
                        .accessibilityLabel("Agent working")
                }
            }
        }
        .foregroundStyle(session.needsUser ? Color.white : KnockDesign.ink)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(session.needsUser ? KnockDesign.coral : KnockDesign.lavenderSoft)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct ProductionAgentContext: View {
    let session: Session

    var body: some View {
        KnockCard {
            VStack(alignment: .leading, spacing: 11) {
                Text("Requested by")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KnockDesign.muted)
                HStack(spacing: 10) {
                    AgentGlyph(seed: session.agent_id, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(session.agent_id)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Text(session.skill_id)
                            .font(.caption)
                            .foregroundStyle(KnockDesign.muted)
                    }
                    Spacer()
                    Text("Exact session")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(KnockDesign.mint)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ProductionActionCard: View {
    @EnvironmentObject private var store: AppStore
    let session: Session
    @Binding var pendingAction: String?
    @Binding var showConfirm: Bool

    var body: some View {
        KnockCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Choose an action")
                    .font(.headline)
                Text("Your choice will be sent back to this agent.")
                    .font(.caption)
                    .foregroundStyle(KnockDesign.muted)
                let descriptors = session.actionDescriptors
                if descriptors.isEmpty {
                    Label("No actions are available right now.", systemImage: "clock.badge.exclamationmark")
                        .font(.subheadline)
                        .foregroundStyle(KnockDesign.muted)
                    Button("Refresh decision") {
                        Task { await store.refresh() }
                    }
                    .font(.subheadline.weight(.semibold))
                }
                ForEach(descriptors) { descriptor in
                    let key = descriptor.action_key
                    let title = descriptor.title?.isEmpty == false
                        ? descriptor.title!
                        : actionTitle(key)
                    let risk = DecisionRisk(actionRisk: descriptor.risk)
                    Button {
                        Task {
                            if let response = await store.reply(session: session, actionKey: key), response.needs_confirm == true {
                                pendingAction = response.action.action_id
                                showConfirm = true
                            }
                        }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: actionSymbol(key))
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(risk.color)
                                .frame(width: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(KnockDesign.ink)
                                if descriptor.confirm_required {
                                    Text("Requires a second confirmation")
                                        .font(.caption2)
                                        .foregroundStyle(KnockDesign.muted)
                                }
                            }
                            Spacer()
                            if store.actionInFlight == key {
                                ProgressView()
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.bold))
                                    .foregroundStyle(KnockDesign.muted)
                            }
                        }
                        .padding(13)
                        .background(risk.background)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(store.actionInFlight != nil)
                    .accessibilityIdentifier("decision.action.\(key)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct DetailLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(KnockDesign.muted)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(KnockDesign.ink)
        }
        .font(.caption.monospaced())
    }
}

// MARK: - Settings and pairing

struct ProductionSettingsView: View {
    @EnvironmentObject private var store: AppStore
    var onOpenDrawer: () -> Void = {}
    @State private var showAdvanced = false
    @State private var showSignOut = false
    @State private var apiDraft = ""
    @State private var codeCopied = false

    var body: some View {
        NavigationView {
            ZStack {
                KnockDesign.canvas.ignoresSafeArea()
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .center, spacing: 12) {
                            KnockMascot(size: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Your control room")
                                    .font(.system(size: 27, weight: .bold, design: .rounded))
                                Text("Keep agents connected and ready.")
                                    .font(.caption)
                                    .foregroundStyle(KnockDesign.muted)
                            }
                            Spacer(minLength: 8)
                            Text(DemoConfig.buildLabel)
                                .font(.caption2.weight(.bold).monospacedDigit())
                                .foregroundStyle(KnockDesign.muted)
                        }
                        .padding(.top, 3)

                        KnockCard(padding: 14) {
                            HStack(spacing: 12) {
                                Image(systemName: store.connectionState == .connected ? "checkmark.circle.fill" : "wifi.exclamationmark")
                                    .font(.title2)
                                    .foregroundStyle(store.connectionState == .connected ? KnockDesign.mint : KnockDesign.coral)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(store.connectionState == .connected ? "Connection healthy" : "Connection needs attention")
                                        .font(.headline)
                                    if let refreshed = store.lastRefreshAt {
                                        HStack(spacing: 4) {
                                            Text("Last synced")
                                            Text(refreshed, style: .relative)
                                        }
                                    } else {
                                        Text("No successful sync yet")
                                    }
                                }
                                .font(.caption)
                                .foregroundStyle(KnockDesign.muted)
                                Spacer()
                                ConnectionPill(state: store.connectionState)
                            }
                        }

                        KnockCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 13) {
                                HStack(spacing: 8) {
                                    Image(systemName: "link.circle.fill")
                                        .foregroundStyle(KnockDesign.lavender)
                                    Text("Connect an agent")
                                        .font(.headline.weight(.bold))
                                }
                                Text("Pair Codex, Cursor, or Paperclip once. Your phone answer will return to the exact session that asked.")
                                    .font(.subheadline)
                                    .foregroundStyle(KnockDesign.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let code = store.pairingCode {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("One-time code")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(KnockDesign.muted)
                                        HStack(spacing: 10) {
                                            Text(code)
                                                .font(.system(size: 28, weight: .bold, design: .monospaced))
                                                .foregroundStyle(KnockDesign.lavender)
                                                .textSelection(.enabled)
                                                .accessibilityLabel("Pairing code \(code)")
                                            Spacer()
                                            Button {
                                                UIPasteboard.general.string = code
                                                codeCopied = true
                                            } label: {
                                                Image(systemName: codeCopied ? "checkmark" : "doc.on.doc")
                                                    .font(.subheadline.weight(.bold))
                                                    .foregroundStyle(KnockDesign.lavender)
                                                    .padding(9)
                                                    .background(Color.white.opacity(0.72))
                                                    .clipShape(Circle())
                                            }
                                            .accessibilityLabel(codeCopied ? "Pairing code copied" : "Copy pairing code")
                                        }
                                        if let expires = store.pairingExpiresAt {
                                            HStack(spacing: 4) {
                                                Text("Expires")
                                                if let date = parsedDate(expires) {
                                                    Text(date, style: .relative)
                                                } else {
                                                    Text(expires)
                                                }
                                            }
                                            .font(.caption2)
                                            .foregroundStyle(KnockDesign.muted)
                                        }
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(KnockDesign.lavenderSoft)
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                }
                                Button {
                                    Task { await store.createPairingCode() }
                                } label: {
                                    HStack {
                                        if store.isCreatingPairingCode { ProgressView() }
                                        Text(store.isCreatingPairingCode ? "Generating…" : store.pairingCode == nil ? "Generate pairing code" : "Generate a new code")
                                        Spacer()
                                        Image(systemName: "arrow.right")
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(13)
                                    .background(KnockDesign.coral)
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                }
                                .disabled(store.isCreatingPairingCode)
                                .accessibilityIdentifier("pairing.generate")
                                .accessibilityHint("Creates a short-lived code for connecting an agent skill")
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        KnockCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack(spacing: 8) {
                                    Image(systemName: "bell.badge.fill")
                                        .foregroundStyle(KnockDesign.coral)
                                    Text("Notifications")
                                        .font(.headline.weight(.bold))
                                }
                                HStack {
                                    Text(store.notificationStatusText)
                                    Spacer()
                                    Image(systemName: store.notificationStatusText.contains("authorized") ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                        .foregroundStyle(store.notificationStatusText.contains("authorized") ? KnockDesign.mint : Color.orange)
                                }
                                .font(.subheadline)
                                .foregroundStyle(KnockDesign.muted)
                                Button("Check notification settings") { store.refreshNotificationStatus() }
                                    .font(.subheadline.weight(.semibold))
                                Button("Enable notifications") { store.requestNotificationsAgain() }
                                    .font(.subheadline.weight(.semibold))
                                Button("Open iPhone Settings") {
                                    if let url = URL(string: UIApplication.openSettingsURLString) {
                                        UIApplication.shared.open(url)
                                    }
                                }
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(KnockDesign.lavender)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        KnockCard(padding: 16) {
                            VStack(alignment: .leading, spacing: 10) {
                                HStack(spacing: 8) {
                                    Image(systemName: "waveform.and.mic")
                                        .foregroundStyle(KnockDesign.lavender)
                                    Text("On-device voice")
                                        .font(.headline.weight(.bold))
                                }
                                Text("Download the signed Gemma command model once. Push-to-talk then keeps audio local and sends only a validated CommandEnvelope.")
                                    .font(.subheadline)
                                    .foregroundStyle(KnockDesign.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(store.voiceModelStatus)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(store.voiceController == nil ? KnockDesign.muted : KnockDesign.mint)
                                Button {
                                    Task { await store.prepareLocalVoiceModel() }
                                } label: {
                                    HStack {
                                        if store.voiceModelStatus.hasPrefix("Preparing") { ProgressView() }
                                        Text(store.voiceController == nil ? "Prepare voice model" : "Refresh voice model")
                                        Spacer()
                                        Image(systemName: "arrow.down.circle")
                                    }
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .padding(13)
                                    .background(KnockDesign.lavender)
                                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                                }
                                .disabled(store.voiceModelStatus.hasPrefix("Preparing"))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        DisclosureGroup("Advanced diagnostics", isExpanded: $showAdvanced) {
                            VStack(alignment: .leading, spacing: 9) {
                                DetailLine(label: "API", value: store.apiBase)
                                DetailLine(label: "Account", value: store.email)
                                DetailLine(label: "Agents", value: "\(store.agents.count)")
                                DetailLine(label: "Sessions", value: "\(store.sessions.count)")
                                DetailLine(label: "Dev pushes", value: "\(store.pushes.count)")
                                DetailLine(label: "Saved retries", value: "\(store.pendingOperations.count)")
                                TextField("API base URL", text: $apiDraft)
                                    .textInputAutocapitalization(.never)
                                    .keyboardType(.URL)
                                    .autocorrectionDisabled()
                                    .textFieldStyle(.roundedBorder)
                                Button("Save server URL and retry") {
                                    store.apiBase = apiDraft
                                    if store.applyApiBase() {
                                        Task { await store.refresh() }
                                    }
                                }
                                .font(.subheadline.weight(.semibold))
                                if let diagnostics = store.notificationDiagnostics {
                                    Text(diagnostics.bannerStatusText)
                                        .font(.caption)
                                        .foregroundStyle(diagnostics.bannerReady ? KnockDesign.mint : Color.orange)
                                }
                                Button("Test in-app knock") { store.showTestKnockPopup() }
                                    .font(.subheadline.weight(.semibold))
                                Toggle("Simulate headphones", isOn: $store.headphonesSimulated)
                            }
                            .padding(.top, 10)
                        }
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 4)

                        Button {
                            Task { await store.refresh() }
                        } label: {
                            HStack {
                                if store.isRefreshing { ProgressView() }
                                Text(store.isRefreshing ? "Refreshing…" : "Refresh now")
                            }
                            .frame(maxWidth: .infinity)
                        }
                            .font(.subheadline.weight(.semibold))
                            .disabled(store.isRefreshing)
                        Button("Sign out", role: .destructive) { showSignOut = true }
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .padding(18)
                    .padding(.bottom, 28)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onOpenDrawer) {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel("Open navigation")
                    .accessibilityIdentifier("drawer.open")
                }
            }
            .navigationViewStyle(.stack)
            .onAppear {
                if apiDraft.isEmpty { apiDraft = store.apiBase }
            }
            .confirmationDialog("Sign out of Knock Knock?", isPresented: $showSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { store.logout() }
                Button("Not now", role: .cancel) { }
            } message: {
                Text("Your saved connection will be removed from this device. You can sign in again later.")
            }
        }
    }
}

struct ProductionPushInboxView: View {
    @EnvironmentObject private var store: AppStore
    var onOpenDrawer: () -> Void = {}

    var body: some View {
        NavigationView {
            ZStack {
                KnockDesign.canvas.ignoresSafeArea()
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.pushes) { push in
                            KnockCard {
                                HStack(alignment: .top, spacing: 12) {
                                    Image(systemName: "bell.fill")
                                        .foregroundStyle(KnockDesign.coral)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(push.title).font(.headline)
                                        Text(push.body).font(.subheadline).foregroundStyle(KnockDesign.muted)
                                        Text(push.created_at).font(.caption2).foregroundStyle(KnockDesign.muted)
                                    }
                                    Spacer()
                                    if push.read_at == nil {
                                        Button("Read") {
                                            Task { await store.markPushRead(push) }
                                        }
                                        .font(.caption.weight(.semibold))
                                        .buttonStyle(.borderedProminent)
                                        .tint(KnockDesign.coral)
                                    }
                                }
                            }
                        }
                        if store.pushes.isEmpty {
                            ProductionEmptyState(
                                title: "No dev knocks",
                                symbol: "bell.slash.fill",
                                description: "Only needs_user decisions appear in this development inbox.",
                                actionTitle: "Refresh"
                            ) { Task { await store.refresh() } }
                        }
                    }
                    .padding(18)
                }
            }
            .navigationTitle("Dev Push")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: onOpenDrawer) {
                        Image(systemName: "sidebar.left")
                    }
                    .accessibilityLabel("Open navigation")
                    .accessibilityIdentifier("drawer.open")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Read all") {
                        Task { await store.markAllPushesRead() }
                    }
                    .font(.caption.weight(.semibold))
                }
            }
            .refreshable { await store.refresh() }
            .navigationViewStyle(.stack)
        }
    }
}
