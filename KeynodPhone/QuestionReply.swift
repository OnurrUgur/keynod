import SwiftUI

extension LinkRequest {
    enum ReplyStyle: Equatable {
        case finished
        case question(multi: Bool)
        case plan
    }

    static let planCommand = "Plan approval"
    static let approvePlan = "Approve"

    var replyStyle: ReplyStyle {
        if command == Self.planCommand { return .plan }
        if command.hasPrefix("Multi-select") { return .question(multi: true) }
        if command.hasPrefix("Question:") || command == "Claude asks" { return .question(multi: false) }
        return .finished
    }

    var endingQuestion: String? {
        let text = (body ?? "").visibleBody
        let paragraphs = text.components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard let paragraph = paragraphs.last(where: { $0.contains("?") && !$0.hasPrefix("```") }) else { return nil }
        let lines = paragraph.split(separator: "\n").map(String.init)
        let end = lines.lastIndex { $0.contains("?") } ?? lines.count - 1
        var cleaned = lines[...end].joined(separator: " ").markdownStripped
        var sentences: [String] = []
        var current = ""
        for ch in cleaned {
            current.append(ch)
            if ch == "." || ch == "!" || ch == "?" || ch == ":" {
                sentences.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { sentences.append(current.trimmingCharacters(in: .whitespaces)) }
        if let last = sentences.lastIndex(where: { $0.contains("?") }) {
            cleaned = sentences[last...last].joined(separator: " ")
            if cleaned.count < 25, last > 0 { cleaned = sentences[(last - 1)...last].joined(separator: " ") }
        }
        return cleaned.count > 240 ? String(cleaned.prefix(240)) + "…" : cleaned
    }

    var planTitle: String {
        let first = (body ?? "").visibleBody.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
        let title = (first ?? summary).markdownStripped
        return title.isEmpty ? "Plan ready" : title
    }
}

extension String {
    var markdownStripped: String {
        var text = replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "*", with: "")
        text = text.trimmingCharacters(in: .whitespaces)
        while text.hasPrefix("#") { text.removeFirst() }
        if text.hasPrefix("- ") || text.hasPrefix("* ") { text.removeFirst(2) }
        return text.trimmingCharacters(in: .whitespaces)
    }
}

struct OptionDetail: Equatable {
    var about = ""
    var preview: String?
}

struct ParsedQuestion {
    var question: String
    var details: [String: OptionDetail] = [:]

    init(_ request: LinkRequest) {
        let body = (request.body ?? "").visibleBody
        var head = body
        var rest = ""
        if let marker = body.range(of: "\n\n• **") {
            head = String(body[..<marker.lowerBound])
            rest = String(body[marker.lowerBound...])
        }
        let question = head.trimmingCharacters(in: .whitespacesAndNewlines)
        self.question = question.isEmpty ? request.summary.visibleText : question

        let lines = rest.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if line.hasPrefix("• **"), let close = line.range(of: "**", range: line.index(line.startIndex, offsetBy: 4)..<line.endIndex) {
                let label = String(line[line.index(line.startIndex, offsetBy: 4)..<close.lowerBound])
                var about = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
                if about.hasPrefix(":") { about.removeFirst() }
                var detail = OptionDetail(about: about.trimmingCharacters(in: .whitespaces))
                if i + 1 < lines.count, lines[i + 1].trimmingCharacters(in: .whitespaces) == "```" {
                    var j = i + 2
                    var block: [String] = []
                    while j < lines.count, lines[j].trimmingCharacters(in: .whitespaces) != "```" {
                        block.append(lines[j])
                        j += 1
                    }
                    detail.preview = block.joined(separator: "\n")
                    i = j
                }
                details[label] = detail
            }
            i += 1
        }
    }

    func detail(for label: String) -> OptionDetail? {
        details[label] ?? details.first { $0.key.hasPrefix(label) || label.hasPrefix($0.key) }?.value
    }
}

struct PreviewBlock: View {
    let text: String
    var maxLines: Int?

    var body: some View {
        let all = text.components(separatedBy: "\n")
        let shown = maxLines.map { Array(all.prefix($0)) } ?? all
        VStack(alignment: .leading, spacing: 4) {
            ScrollView(.horizontal) {
                Text(verbatim: shown.joined(separator: "\n"))
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: true, vertical: true)
                    .padding(10)
                    .textSelection(.enabled)
            }
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollIndicators(.visible, axes: .horizontal)
            .background(Color(.systemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
            if shown.count < all.count {
                Text("+\(all.count - shown.count) more lines; open for full view")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct OptionList: View {
    let options: [String]
    let details: ParsedQuestion
    let multi: Bool
    @Binding var picked: [String]
    var surface = Color(.tertiarySystemGroupedBackground)
    var previewLines: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(multi ? "Select one or more" : "Choose one")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
            ForEach(options, id: \.self) { option in
                OptionRow(label: option, detail: details.detail(for: option), multi: multi,
                          selected: picked.contains(option), surface: surface, previewLines: previewLines) {
                    pick(option)
                }
            }
        }
    }

    private func pick(_ option: String) {
        if multi {
            if let i = picked.firstIndex(of: option) { picked.remove(at: i) } else { picked.append(option) }
        } else {
            picked = [option]
        }
    }
}

private struct OptionRow: View {
    let label: String
    let detail: OptionDetail?
    let multi: Bool
    let selected: Bool
    let surface: Color
    let previewLines: Int?
    let action: () -> Void

    private var symbol: String {
        multi ? (selected ? "checkmark.square.fill" : "square") : (selected ? "largecircle.fill.circle" : "circle")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: label.visibleText)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.leading)
                if let about = detail?.about, !about.isEmpty {
                    Text(verbatim: about)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
                if let preview = detail?.preview, !preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    PreviewBlock(text: preview, maxLines: previewLines)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(selected ? Color.accentColor : .clear, lineWidth: 2))
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onTapGesture(perform: action)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Select", action)
    }
}

struct ProjectLine: View {
    let request: LinkRequest

    var body: some View {
        let folder = (request.cwd as NSString).lastPathComponent
        let who = request.who.visibleText
        let text = [folder.isEmpty ? nil : folder.visibleText, who.isEmpty ? nil : who].compactMap { $0 }.joined(separator: " · ")
        if !text.isEmpty {
            Label(text, systemImage: "folder")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

struct ReplyCard: View {
    let request: LinkRequest
    let images: [Data]
    let isBusy: Bool
    let isHighlighted: Bool
    let answer: (String?, String?) -> Void
    @State private var open = false
    @State private var picked: [String] = []

    private var style: LinkRequest.ReplyStyle { request.replyStyle }

    var body: some View {
        Group {
            switch style {
            case .finished: finishedCard
            case .question(let multi): questionCard(multi: multi)
            case .plan: planCard
            }
        }
        .sheet(isPresented: $open) {
            ReplySheet(request: request, images: images, initialPicked: picked, answer: answer)
        }
    }

    private var finishedCard: some View {
        QuestionFrame(request: request, title: request.endingQuestion ?? "Claude finished and is waiting",
                      isHighlighted: isHighlighted) {
            ProjectLine(request: request)
            Button { open = true } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude's message")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: preview)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                    Label("Read full message", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .font(.footnote.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            QuestionImageRow(images: images)
            if !request.choices.isEmpty {
                Label("\(request.choices.count) options available", systemImage: "checklist")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button { open = true } label: {
                Label("Reply", systemImage: "bubble.left.and.text.bubble.right")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            QuickAnswers(request: request, isBusy: isBusy, answer: answer)
        }
        .disabled(isBusy)
    }

    private var preview: String {
        let body = request.body?.visibleBody ?? request.summary.visibleText
        var inCode = false
        var lines: [String] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if !inCode { lines.append(String(line).markdownStripped) }
        }
        return lines.joined(separator: "\n")
    }

    private func questionCard(multi: Bool) -> some View {
        let parsed = ParsedQuestion(request)
        return QuestionFrame(request: request, title: parsed.question.markdownStripped, isHighlighted: isHighlighted) {
            ProjectLine(request: request)
            QuestionImageRow(images: images)
            if !(request.options ?? []).isEmpty {
                OptionList(options: request.options ?? [], details: parsed, multi: multi, picked: $picked, previewLines: 8)
            }
            Button(action: sendPicked) {
                Text(picked.count > 1 ? "Send \(picked.count) choices" : "Send choice")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(picked.isEmpty)
            Button { open = true } label: {
                Label("Write a custom reply", systemImage: "text.bubble")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .disabled(isBusy)
    }

    private func sendPicked() {
        if picked.count == 1 {
            answer(picked[0], nil)
        } else if !picked.isEmpty {
            answer(nil, "Selected: " + picked.joined(separator: "; "))
        }
    }

    private var planCard: some View {
        QuestionFrame(request: request, title: request.planTitle, isHighlighted: isHighlighted) {
            ProjectLine(request: request)
            Button { open = true } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(verbatim: planPreview)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(6)
                        .multilineTextAlignment(.leading)
                    Label("Read full plan", systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                        .font(.footnote.weight(.medium))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            QuestionImageRow(images: images)
            Button { answer(LinkRequest.approvePlan, nil) } label: {
                Label("Approve", systemImage: "checkmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button { open = true } label: {
                Label("Request changes", systemImage: "pencil.and.list.clipboard")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
        }
        .disabled(isBusy)
    }

    private var planPreview: String {
        let lines = (request.body ?? "").visibleBody.split(separator: "\n", omittingEmptySubsequences: true).dropFirst()
        var inCode = false
        var kept: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); continue }
            if inCode { continue }
            let text = String(line).markdownStripped
            let raw = line.trimmingCharacters(in: .whitespaces)
            let numbered = raw.first?.isNumber ?? false
            kept.append(raw.hasPrefix("#") ? text : (numbered ? raw : "• " + text.replacingOccurrences(of: "• ", with: "")))
        }
        return kept.joined(separator: "\n")
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon.font(.caption2.weight(.bold))
        }
        .foregroundStyle(Color.accentColor)
    }
}

struct ReplySheet: View {
    let request: LinkRequest
    let images: [Data]
    let answer: (String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var picked: [String]
    @State private var text = ""
    @FocusState private var typing: Bool

    init(request: LinkRequest, images: [Data], initialPicked: [String], answer: @escaping (String?, String?) -> Void) {
        self.request = request
        self.images = images
        self.answer = answer
        _picked = State(initialValue: initialPicked)
    }

    private var style: LinkRequest.ReplyStyle { request.replyStyle }
    private var isPlan: Bool { style == .plan }
    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSend: Bool { !typed.isEmpty || !picked.isEmpty }
    private var showsPrimary: Bool { isPlan || !picked.isEmpty }
    private var multi: Bool {
        if case .question(let multi) = style { return multi }
        return true
    }
    private var title: String {
        switch style {
        case .plan: return "Plan Approval"
        case .question: return "Claude Asks"
        case .finished: return "Claude"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) { content }
                    .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { TimeLeft(expires: request.expires) }
            }
            .safeAreaInset(edge: .bottom) { composer }
        }
    }

    @ViewBuilder private var content: some View {
        switch style {
        case .question:
            let parsed = ParsedQuestion(request)
            Text(verbatim: parsed.question.visibleBody)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ProjectLine(request: request)
            QuestionImageRow(images: images)
            OptionList(options: request.options ?? [], details: parsed, multi: multi, picked: $picked,
                       surface: Color(.secondarySystemGroupedBackground))
        case .plan:
            Text(verbatim: request.planTitle)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            ProjectLine(request: request)
            MarkdownText(text: planBody)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            QuestionImageRow(images: images)
        case .finished:
            if let ending = request.endingQuestion {
                Text(verbatim: ending)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
            }
            ProjectLine(request: request)
            VStack(alignment: .leading, spacing: 8) {
                Text("Claude's message")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(.secondary)
                MarkdownText(text: request.body?.visibleBody ?? request.summary.visibleText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            QuestionImageRow(images: images)
            if !request.choices.isEmpty {
                OptionList(options: request.choices, details: ParsedQuestion(request), multi: true, picked: $picked,
                           surface: Color(.secondarySystemGroupedBackground))
            }
            QuickAnswers(request: request, isBusy: false) { choice, text in
                answer(choice, text)
                dismiss()
            }
        }
    }

    private var planBody: String {
        let lines = (request.body ?? request.summary).visibleBody.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.dropFirst().joined(separator: "\n")
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isPlan, !typed.isEmpty {
                Text("Your message will be sent as feedback instead of approving the plan.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if showsPrimary {
                Button(action: primary) {
                    Label(isPlan ? "Approve" : (picked.count > 1 ? "Send \(picked.count) choices" : "Send choice"),
                          systemImage: isPlan ? "checkmark" : "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(isPlan ? "Request changes or add feedback" : "Type your reply", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($typing)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                if !showsPrimary || isPlan {
                    Button(action: send) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.bold))
                            .frame(width: 40, height: 40)
                            .foregroundStyle(.white)
                            .background(typed.isEmpty && (isPlan || picked.isEmpty) ? Color(.systemGray3) : Color.accentColor, in: Circle())
                    }
                    .disabled(isPlan ? typed.isEmpty : !canSend)
                    .accessibilityLabel(isPlan ? "Send feedback" : "Send")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
    }

    private var composed: String {
        let ticked = isPlan || picked.isEmpty ? nil : "Selected: " + picked.joined(separator: "; ")
        return [ticked, typed.isEmpty ? nil : typed].compactMap { $0 }.joined(separator: "\n")
    }

    private func primary() {
        if isPlan {
            answer(typed.isEmpty ? LinkRequest.approvePlan : nil, typed.isEmpty ? nil : typed)
        } else {
            send()
        }
        dismiss()
    }

    private func send() {
        if !isPlan, picked.count == 1, typed.isEmpty {
            answer(picked[0], nil)
        } else {
            guard !composed.isEmpty else { return }
            answer(nil, composed)
        }
        dismiss()
    }
}
