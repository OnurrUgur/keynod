import SwiftUI

struct RequestsView: View {
    @EnvironmentObject private var model: PhoneModel
    @State private var confirmUnpair = false
    @State private var highlighted: UUID?

    private var macName: String { model.pairedMac?.name.visibleText ?? "your Mac" }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Paired with \(macName)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        notices
                        RemoteModeCard(mode: model.mode, isChanging: model.modeChanging) { on in
                            Task { await model.setRemote(on) }
                        }
                        MacCommandsRow(isSending: model.commandSending, awakeUntil: model.awakeUntil) { action in
                            Task { await model.sendCommand(action) }
                        }
                        if model.requests.isEmpty {
                            ContentUnavailableView(
                                "Nothing to approve",
                                systemImage: "checkmark.shield",
                                description: Text("When your Mac asks for a secret or Claude Code needs approval, it shows up here and as a notification."))
                                .containerRelativeFrame(.vertical) { height, _ in height * 0.5 }
                        } else {
                            ForEach(model.requests) { item in
                                Group {
                                    if item.request.isQuestion {
                                        QuestionCard(item: item,
                                                     isBusy: model.busy.contains(item.id),
                                                     isHighlighted: highlighted == item.id,
                                                     approve: { Task { await model.approve(item.id) } },
                                                     deny: { Task { await model.deny(item.id) } },
                                                     answer: { choice, text in
                                                         Task { await model.answer(item.id, choice: choice, text: text) }
                                                     })
                                    } else {
                                        RequestCard(item: item,
                                                    isBusy: model.busy.contains(item.id),
                                                    isHighlighted: highlighted == item.id,
                                                    approve: { Task { await model.approve(item.id) } },
                                                    deny: { Task { await model.deny(item.id) } })
                                    }
                                }
                                .id(item.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 24)
                }
                .scrollDismissesKeyboard(.interactively)
                .refreshable { await model.refresh() }
                .onAppear { scrollToFocus(proxy) }
                .onChange(of: model.focusedRequest) { scrollToFocus(proxy) }
                .onChange(of: model.requests) { scrollToFocus(proxy) }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Keynod")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Unpair from \(macName)…", role: .destructive) { confirmUnpair = true }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("More")
                }
            }
            .confirmationDialog("Unpair from \(macName)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { Task { await model.unpair() } }
            } message: {
                Text("This iPhone will stop approving requests. To finish, also unpair it in Keynod Settings on your Mac.")
            }
            .overlay(alignment: .bottom) {
                if let text = model.banner { BannerView(text: text) }
            }
            .animation(.snappy, value: model.banner)
            .onChange(of: model.banner) { _, text in
                if let text { AccessibilityNotification.Announcement(text).post() }
            }
        }
    }

    @ViewBuilder private var notices: some View {
        if !model.notificationsAllowed {
            Notice(symbol: "bell.slash",
                   text: "Notifications are off, so Keynod can't alert you when your Mac asks.",
                   button: "Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        }
        if let problem = model.notificationProblem {
            Notice(symbol: "exclamationmark.triangle", text: problem, button: "Try Again") {
                Task { await model.ensureSubscriptions() }
            }
        }
        if let problem = model.syncProblem {
            Notice(symbol: "icloud.slash", text: problem)
        }
    }

    private func scrollToFocus(_ proxy: ScrollViewProxy) {
        guard let id = model.focusedRequest, model.requests.contains(where: { $0.id == id }) else { return }
        model.focusedRequest = nil
        highlighted = id
        withAnimation { proxy.scrollTo(id, anchor: .top) }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if highlighted == id { highlighted = nil }
        }
    }
}

private struct RemoteModeCard: View {
    let mode: LinkMode?
    let isChanging: Bool
    let change: (Bool) -> Void

    private var isOn: Bool { mode?.remote ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { isOn }, set: change)) {
                Label("Remote mode", systemImage: "iphone.radiowaves.left.and.right")
                    .font(.headline)
            }
            .disabled(isChanging)
            Text(isOn
                 ? "Your Mac sends requests only here; Touch ID on the Mac stays quiet."
                 : "Your Mac asks with Touch ID. Turn this on when you step away.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let mode {
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    let when = min(mode.at, context.date).formatted(.relative(presentation: .named))
                    Text("Changed on \(mode.by == "mac" ? "Mac" : "iPhone") · \(when)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .keynodCard()
    }
}

private struct MacCommandsRow: View {
    let isSending: Bool
    let awakeUntil: Date?
    let send: (String) -> Void
    @State private var confirmSleep = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label("Mac", systemImage: "desktopcomputer")
                    .font(.headline)
                Spacer(minLength: 8)
                Button { send("lock") } label: {
                    Label("Lock", systemImage: "lock")
                }
                Button { confirmSleep = true } label: {
                    Label("Sleep", systemImage: "moon.zzz")
                }
            }
            if let awakeUntil {
                Button { send("awake-off") } label: {
                    Label("Awake until \(LinkAwake.clock(awakeUntil))", systemImage: "moon.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button { send("awake-on") } label: {
                    Label("Keep awake overnight", systemImage: "moon")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .buttonStyle(.bordered)
        .disabled(isSending)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .keynodCard()
        .confirmationDialog("Put Mac to sleep?", isPresented: $confirmSleep, titleVisibility: .visible) {
            Button("Sleep", role: .destructive) { send("sleep") }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Running tasks and agent sessions will pause.")
        }
    }
}

private struct RequestCard: View {
    let item: PhoneModel.PendingRequest
    let isBusy: Bool
    let isHighlighted: Bool
    let approve: () -> Void
    let deny: () -> Void

    private var request: LinkRequest { item.request }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                KindBadge(kind: request.kind)
                Spacer()
                TimeLeft(expires: request.expires)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: request.who.visibleText)
                    .font(.title3.weight(.semibold))
                Text(verbatim: request.command.visibleText)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                DetailRow(symbol: "folder", text: request.cwd.visibleText)
                if request.items.isEmpty {
                    if !request.summary.isEmpty {
                        DetailRow(symbol: summarySymbol, text: request.summary.visibleText)
                    }
                } else {
                    ForEach(request.items, id: \.field) { secretItem in
                        DetailRow(symbol: "key", text: "\(secretItem.secret.visibleText) · \(secretItem.label.visibleText)")
                    }
                }
            }
            Text(verbatim: "from \(request.macName.visibleText)")
                .font(.caption)
                .foregroundStyle(.secondary)
            actions
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .keynodCard()
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor, lineWidth: isHighlighted ? 2 : 0)
        )
        .animation(.default, value: isHighlighted)
    }

    private var summarySymbol: String {
        switch request.kind {
        case "create": return "plus.circle"
        case "delete": return "trash"
        default: return "key"
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                denyButton
                approveButton
            }
            VStack(spacing: 10) {
                approveButton
                denyButton
            }
        }
        .controlSize(.large)
        .disabled(isBusy)
    }

    private var approveButton: some View {
        Button(action: approve) {
            Group {
                if isBusy {
                    ProgressView()
                } else {
                    let name = PhoneModel.biometryName
                    Label("Approve with \(name)", systemImage: name == "Touch ID" ? "touchid" : "faceid")
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
    }

    private var denyButton: some View {
        Button(role: .destructive, action: deny) {
            Text("Deny")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }
}

struct KindBadge: View {
    let kind: String

    private var style: (title: String, symbol: String, tint: Color) {
        switch kind {
        case "run": return ("Run", "terminal", .blue)
        case "inject": return ("Inject", "square.and.arrow.down", .indigo)
        case "get": return ("Get", "eye", .orange)
        case "create": return ("New secret", "plus.circle", .green)
        case "delete": return ("Delete secret", "trash", .red)
        case "permission": return ("Permission", "lock.shield", .orange)
        case "reply": return ("Reply", "bubble.left.and.bubble.right", .purple)
        case "decide": return ("Decision", "questionmark.bubble", .blue)
        case "code": return ("Code", "number.square", .pink)
        default: return (kind.visibleText.capitalized, "questionmark.circle", .gray)
        }
    }

    var body: some View {
        Label(style.title, systemImage: style.symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(style.tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(style.tint.opacity(0.15), in: Capsule())
    }
}

struct TimeLeft: View {
    let expires: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 5)) { context in
            let seconds = expires.timeIntervalSince(context.date)
            Label(text(seconds), systemImage: "clock")
                .font(.caption.weight(.medium))
                .foregroundStyle(seconds < 120 ? Color.orange : Color.secondary)
        }
    }

    private func text(_ seconds: TimeInterval) -> String {
        if seconds <= 0 { return "Expired" }
        if seconds < 60 { return "Less than 1 min left" }
        return "\(Int(seconds / 60)) min left"
    }
}

struct DetailRow: View {
    let symbol: String
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(verbatim: text)
                .font(.subheadline)
        }
    }
}

private struct Notice: View {
    let symbol: String
    let text: String
    var button: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(.orange)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: text)
                    .font(.subheadline)
                if let button {
                    Button(button, action: action)
                        .font(.subheadline.weight(.semibold))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

struct BannerView: View {
    let text: String
    var isError = false

    var body: some View {
        Text(verbatim: text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(isError ? Color.red : Color.primary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

extension View {
    func keynodCard() -> some View {
        background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
