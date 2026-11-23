import CloudKit
import Foundation

/// How a question sent to the paired iPhone ended.
enum QuestionResult {
    /// A permission question approved with Face ID.
    case allowed
    case denied
    /// A choice and/or the user's own words (or a code), already decrypted.
    case answered(choice: String?, text: String?)
    /// Nobody answered before the request expired.
    case timedOut
    /// The question couldn't be asked, or was withdrawn.
    case unavailable(String)
}

extension PhoneLink {
    /// Asks the paired iPhone a question (Claude permission, reply, decision, or verification code)
    /// and waits for the signed answer. Cancelling the task withdraws the request.
    func question(kind: String, who: String, command: String, cwd: String, summary: String,
                  body: String?, options: [String]?, input: String?, images: [Data] = [],
                  timeout: TimeInterval) async -> QuestionResult {
        guard Link.questionKinds.contains(kind) else { return .unavailable("unknown question kind") }
        guard LinkCloud.shared.isConfigured else { return .unavailable("iCloud isn't configured for this build") }
        guard let phone = self.phone else { return .unavailable("no iPhone is paired") }
        guard await LinkCloud.shared.isAvailable() else { return .unavailable("iCloud isn't available") }

        let waiting: LinkWaiting
        do {
            waiting = try LinkFlow.makeRequest(macName: Self.macName, kind: kind, who: who, command: command, cwd: cwd,
                                               summary: summary, items: [], ttl: timeout, body: body, options: options,
                                               input: input, images: images, signer: try macSigner())
        } catch {
            return .unavailable("could not sign the request")
        }
        let request = waiting.request
        let names = [Link.requestName(request.id), Link.responseName(request.id)]

        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                             reason: "Waiting for an iPhone answer")
        defer { ProcessInfo.processInfo.endActivity(activity) }

        do {
            try await write(waiting, images: images, giveUp: { Task.isCancelled })
        } catch {
            await withdraw(names)
            return .unavailable(Self.cliMessage(for: error))
        }

        let open = PendingQuestions.shared
        open.register(request)
        func end(_ result: QuestionResult, byMac: Bool = false, taking down: [String]) async -> QuestionResult {
            open.finish(request.id, result: result, byMac: byMac)
            await withdraw(down)
            return result
        }

        while true {
            let fromMac = await Self.pauseWatching(Link.pollInterval, for: request.id)
            if Task.isCancelled { return await end(.unavailable("withdrawn"), taking: names) }
            if let fromMac { return await end(fromMac, byMac: true, taking: names) }
            guard self.phone == phone else { return await end(.unavailable("the iPhone was unpaired"), taking: names) }
            guard Date() < request.expires else { return await end(.timedOut, taking: names) }
            guard let response = try? await LinkCloud.shared.fetch(Link.responseName(request.id)),
                  let payload = response.data(Link.Field.payload),
                  let signature = response.data(Link.Field.signature) else { continue }
            do {
                let result: QuestionResult
                switch try LinkFlow.checkResponse(payload: payload, signature: signature, for: waiting, phone: phone) {
                case .approved: result = .allowed
                case .denied: result = .denied
                case .answered(let choice, let text): result = .answered(choice: choice, text: text)
                }
                return await end(result, taking: names)
            } catch {
                NSLog("%@", "Keynod iPhone: ignored an answer that didn't verify: \(error)")
                await withdraw([Link.responseName(request.id)])
            }
        }
    }

    private static func pauseWatching(_ seconds: TimeInterval, for id: UUID) async -> QuestionResult? {
        let step: TimeInterval = 0.2
        let end = Date().addingTimeInterval(seconds)
        while !Task.isCancelled {
            if let answer = PendingQuestions.shared.takeLocalAnswer(id) { return answer }
            let left = end.timeIntervalSinceNow
            guard left > 0 else { return nil }
            try? await pause(min(step, left))
        }
        return nil
    }
}
