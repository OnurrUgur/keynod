import ImageIO
import SwiftUI
import UIKit

extension LinkRequest {
    var needsFaceID: Bool { !isQuestion || kind == "permission" }
}

extension String {
    var visibleBody: String {
        let lines = replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var result = String.UnicodeScalarView()
        for scalar in lines.unicodeScalars {
            switch scalar.value {
            case 0x0A: result.append(scalar)
            case 0x09: result.append(" ")
            case 0x200E, 0x200F, 0x202A...0x202E, 0x2066...0x2069: break
            default: if scalar.properties.generalCategory != .control { result.append(scalar) }
            }
        }
        return String(result)
    }
}

struct QuestionCard: View {
    let item: PhoneModel.PendingRequest
    let isBusy: Bool
    let isHighlighted: Bool
    let approve: () -> Void
    let deny: () -> Void
    let answer: (_ choice: String?, _ text: String?) -> Void

    private var request: LinkRequest { item.request }

    var body: some View {
        switch request.kind {
        case "permission":
            PermissionCard(request: request, isBusy: isBusy, isHighlighted: isHighlighted,
                           approve: approve, deny: deny)
        case "reply":
            ReplyCard(request: request, images: item.images, isBusy: isBusy, isHighlighted: isHighlighted, answer: answer)
        case "code":
            CodeCard(request: request, isBusy: isBusy, isHighlighted: isHighlighted, answer: answer)
        default:
            DecideCard(request: request, images: item.images, isBusy: isBusy, isHighlighted: isHighlighted, answer: answer)
        }
    }
}

// MARK: - Permission

private struct PermissionCard: View {
    let request: LinkRequest
    let isBusy: Bool
    let isHighlighted: Bool
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        QuestionFrame(request: request, title: "Claude requests permission", isHighlighted: isHighlighted) {
            ProjectLine(request: request)
            VStack(alignment: .leading, spacing: 8) {
                if !request.command.isEmpty {
                    Text(verbatim: request.command.visibleText)
                        .font(.system(.footnote, design: .monospaced).weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                if !request.summary.isEmpty {
                    DetailRow(symbol: "wrench.and.screwdriver", text: request.summary.visibleText)
                }
            }
            if let body = request.body, !body.isEmpty {
                MessageBox(text: body, maxHeight: 180, monospaced: true)
            }
            actions
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { denyButton; allowButton }
            VStack(spacing: 10) { allowButton; denyButton }
        }
        .controlSize(.large)
        .disabled(isBusy)
    }

    private var allowButton: some View {
        Button(action: approve) {
            Group {
                if isBusy {
                    ProgressView()
                } else {
                    let name = PhoneModel.biometryName
                    Label("Allow with \(name)", systemImage: name == "Touch ID" ? "touchid" : "faceid")
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
            Text("Deny").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
    }
}

// MARK: - Quick answers

extension LinkRequest {
    var choices: [String] { (options ?? []).filter { !Self.quickAnswers.contains($0) } }
    static let quickAnswers = ["Continue", "Stop"]
}

struct QuickAnswers: View {
    let request: LinkRequest
    let isBusy: Bool
    let answer: (String?, String?) -> Void

    var body: some View {
        let present = LinkRequest.quickAnswers.filter { (request.options ?? []).contains($0) }
        if !present.isEmpty {
            HStack(spacing: 10) {
                ForEach(present, id: \.self) { option in
                    Button { answer(option, nil) } label: {
                        Text(verbatim: option).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(option == "Stop" ? .red : .accentColor)
                }
            }
            .controlSize(.large)
            .disabled(isBusy)
        }
    }
}

// MARK: - Decide

private struct DecideCard: View {
    let request: LinkRequest
    let images: [Data]
    let isBusy: Bool
    let isHighlighted: Bool
    let answer: (String?, String?) -> Void
    @State private var text = ""

    private var typed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var asksForText: Bool { request.input == "text" }
    private var question: String { request.summary.isEmpty ? request.command : request.summary }

    var body: some View {
        QuestionFrame(request: request, title: question.isEmpty ? "Decision requested" : question.visibleText,
                      isHighlighted: isHighlighted) {
            ProjectLine(request: request)
            if let body = request.body, !body.isEmpty {
                MessageBox(text: body, maxHeight: 260)
            }
            QuestionImageRow(images: images)
            if let options = request.options, !options.isEmpty {
                VStack(spacing: 10) {
                    ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                        Button { answer(option, nil) } label: {
                            Text(verbatim: option.visibleText).frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .controlSize(.large)
                .disabled(isBusy)
            }
            if asksForText {
                AnswerField(prompt: "Type your own answer…", text: $text)
                    .disabled(isBusy)
                SendButton(isBusy: isBusy, isEmpty: typed.isEmpty) { answer(nil, typed) }
            }
        }
    }
}

// MARK: - Code

private struct CodeCard: View {
    let request: LinkRequest
    let isBusy: Bool
    let isHighlighted: Bool
    let answer: (String?, String?) -> Void
    @State private var code = ""
    @FocusState private var focused: Bool

    private var typed: String { code.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        QuestionFrame(request: request,
                      title: request.summary.isEmpty ? "Verification code" : request.summary.visibleText,
                      isHighlighted: isHighlighted) {
            ProjectLine(request: request)
            TextField("Enter code", text: $code)
                .textContentType(.oneTimeCode)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .font(.system(.title2, design: .monospaced))
                .focused($focused)
                .onSubmit(send)
                .padding(12)
                .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .disabled(isBusy)
            SendButton(isBusy: isBusy, isEmpty: typed.isEmpty, action: send)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(400))
            focused = true
        }
        .onChange(of: isHighlighted) { _, on in if on { focused = true } }
    }

    private func send() {
        guard !typed.isEmpty, !isBusy else { return }
        answer(nil, typed)
    }
}

// MARK: - Shared Pieces

struct QuestionFrame<Content: View>: View {
    let request: LinkRequest
    let title: String
    let isHighlighted: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                KindBadge(kind: request.kind)
                Spacer()
                TimeLeft(expires: request.expires)
            }
            Text(verbatim: title)
                .font(.title3.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            content
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
}

struct MessageBox: View {
    let text: String
    let maxHeight: CGFloat
    var monospaced = false

    var body: some View {
        ScrollView {
            Group {
                if monospaced {
                    Text(verbatim: text.visibleBody).font(.system(.footnote, design: .monospaced))
                } else {
                    MarkdownText(text: text.visibleBody)
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(maxHeight: maxHeight)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let line):
                    Text(inline(line))
                        .font(level == 1 ? .title3.weight(.bold) : level == 2 ? .headline : .callout.weight(.semibold))
                        .padding(.top, level <= 2 ? 6 : 2)
                        .accessibilityAddTraits(.isHeader)
                case .item(let indent, let marker, let line):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).font(.callout).foregroundStyle(.secondary)
                        Text(inline(line)).font(.callout)
                    }
                    .padding(.leading, CGFloat(indent) * 14)
                case .paragraph(let line):
                    Text(inline(line)).font(.callout)
                case .code(let block):
                    PreviewBlock(text: block)
                }
            }
        }
    }

    private enum Block { case heading(Int, String), item(Int, String, String), paragraph(String), code(String) }

    private var blocks: [Block] {
        var result: [Block] = []
        var inCode = false
        var code: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if inCode { result.append(.code(code.joined(separator: "\n"))); code = [] }
                inCode.toggle()
                continue
            }
            if inCode { code.append(String(raw)); continue }
            let indent = min(2, (raw.prefix { $0 == " " }.count) / 2)
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                result.append(.heading(level, line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("\u{2022} ") {
                result.append(.item(indent, "\u{2022}", String(line.dropFirst(2))))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                result.append(.item(indent, String(line[...dot]), line[line.index(after: dot)...].trimmingCharacters(in: .whitespaces)))
            } else {
                result.append(.paragraph(line))
            }
        }
        if inCode, !code.isEmpty { result.append(.code(code.joined(separator: "\n"))) }
        return result
    }

    private func inline(_ line: String) -> AttributedString {
        (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(line)
    }
}

struct AnswerField: View {
    let prompt: String
    @Binding var text: String

    var body: some View {
        TextField(prompt, text: $text, axis: .vertical)
            .lineLimit(2...6)
            .padding(12)
            .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct SendButton: View {
    let isBusy: Bool
    let isEmpty: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if isBusy { ProgressView() } else { Text("Send") }
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isBusy || isEmpty)
    }
}

// MARK: - Pictures

struct QuestionImageRow: View {
    let images: [Data]
    @State private var openAt: Int?

    var body: some View {
        if !images.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(images.indices, id: \.self) { index in
                            Button { openAt = index } label: { Thumbnail(data: images[index]) }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Image \(index + 1) of \(images.count)")
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                Label(images.count == 1 ? "Tap to view full screen" : "\(images.count) images — tap to view full screen",
                      systemImage: "photo")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .fullScreenCover(isPresented: Binding(get: { openAt != nil }, set: { if !$0 { openAt = nil } })) {
                ImageViewer(images: images, start: openAt ?? 0)
            }
        }
    }
}

struct Thumbnail: View {
    let data: Data
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Color(.tertiarySystemGroupedBackground).frame(width: 120) }
        }
        .frame(height: 170)
        .background(Color(.tertiarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(.separator), lineWidth: 0.5))
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.55), in: Circle())
                .padding(6)
                .accessibilityHidden(true)
        }
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: data.count) {
            let data = data
            image = await Task.detached(priority: .userInitiated) { Self.decode(data, maxPixel: 720) }.value
        }
    }

    nonisolated static func decode(_ data: Data, maxPixel: Int) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary).map { UIImage(cgImage: $0) }
    }
}

struct ImageViewer: View {
    let images: [Data]
    @State var start: Int
    @Environment(\.dismiss) private var dismiss

    init(images: [Data], start: Int) {
        self.images = images
        _start = State(initialValue: start)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $start) {
                ForEach(images.indices, id: \.self) { index in
                    ZoomableImage(data: images[index]).tag(index).ignoresSafeArea()
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .ignoresSafeArea()
            Button("Close") { dismiss() }
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.black.opacity(0.55), in: Capsule())
                .padding(16)
        }
    }
}

private struct ZoomableImage: UIViewRepresentable {
    let data: Data
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 5
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.backgroundColor = .clear
        scroll.contentInsetAdjustmentBehavior = .never
        let imageView = UIImageView(image: UIImage(data: data))
        imageView.contentMode = .scaleAspectFit
        imageView.isUserInteractionEnabled = true
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.addSubview(imageView)
        context.coordinator.imageView = imageView
        context.coordinator.scroll = scroll
        let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
        double.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(double)
        return scroll
    }

    func updateUIView(_ scroll: UIScrollView, context: Context) {
        if scroll.zoomScale == 1 { context.coordinator.imageView?.frame = scroll.bounds }
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scroll: UIScrollView?
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
        @objc func doubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll else { return }
            if scroll.zoomScale > 1.01 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: imageView)
                let scale: CGFloat = 3
                let size = CGSize(width: scroll.bounds.width / scale, height: scroll.bounds.height / scale)
                scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                       width: size.width, height: size.height), animated: true)
            }
        }
    }
}
