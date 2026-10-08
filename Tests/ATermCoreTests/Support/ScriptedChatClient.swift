import Foundation
import ATermCore

/// A chat client answering scripted replies in order and recording the requests.
final class ScriptedChatClient: ChatClient, @unchecked Sendable {
    enum Step {
        case reply(ChatReply)
        case failure(AssistantError)
        /// A stream that never ends (until the task is cancelled).
        case hang
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var recorded: [ChatRequest] = []

    init(_ steps: [Step]) {
        self.steps = steps
    }

    var requests: [ChatRequest] { lock.withLock { recorded } }

    func enqueue(_ step: Step) { lock.withLock { steps.append(step) } }

    func complete(_ request: ChatRequest, onDelta: @escaping @Sendable (ChatDelta) -> Void) async throws -> ChatReply {
        let step = lock.withLock { () -> Step? in
            recorded.append(request)
            return steps.isEmpty ? nil : steps.removeFirst()
        }
        switch step {
        case .reply(let reply):
            if !reply.reasoning.isEmpty { onDelta(.reasoning(reply.reasoning)) }
            if !reply.content.isEmpty { onDelta(.content(reply.content)) }
            return reply
        case .failure(let error):
            throw error
        case .hang:
            try await Task.sleep(nanoseconds: 120_000_000_000)
            throw CancellationError()
        case nil:
            throw AssistantError.invalidResponse("no scripted reply")
        }
    }
}

extension ScriptedChatClient.Step {
    static func text(_ content: String) -> Self { .reply(ChatReply(content: content)) }

    static func calls(_ calls: [ToolCall], content: String = "", reasoningDetails: [JSONValue] = []) -> Self {
        .reply(ChatReply(content: content, reasoningDetails: reasoningDetails, toolCalls: calls,
                         finishReason: "tool_calls"))
    }
}

func bashCall(_ id: String, _ command: String) -> ToolCall {
    let arguments = try! JSONSerialization.data(withJSONObject: ["command": command])
    return ToolCall(id: id, name: "bash", arguments: String(decoding: arguments, as: UTF8.self))
}
