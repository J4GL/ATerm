import Foundation
import Testing
import ATermCore

/// Polls `condition` on the main actor until it holds or `timeout` seconds elapse.
@MainActor
func eventuallyOnMain(timeout: Double = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

/// An agent in a temporary directory with a scripted client, recording its events.
@MainActor
final class AgentFixture {
    let directory: TemporaryDirectory
    let outputs: TemporaryDirectory
    let client: ScriptedChatClient
    let agent: Agent
    var events: [Agent.Event] = []
    var approvals: [(command: String, reason: String)] = []

    init(_ steps: [ScriptedChatClient.Step], model: String = "m/x", systemPrompt: String = "SYSTEM",
         secrets: [KnownSecret] = [], approval: @escaping @MainActor () async -> Bool = { true },
         configure: (inout Agent.Configuration) -> Void = { _ in }) throws {
        directory = try TemporaryDirectory()
        outputs = try TemporaryDirectory()
        client = ScriptedChatClient(steps)
        var configuration = Agent.Configuration(model: model)
        configure(&configuration)
        let runner = makeRunner(in: directory, outputs: outputs)
        var recordEvent: (@MainActor (Agent.Event) -> Void)?
        var recordApproval: (@MainActor (String, String) -> Void)?
        agent = Agent(client: client, configuration: configuration, systemPrompt: systemPrompt, runner: runner,
                      redactor: SecretRedactor(knownSecrets: secrets),
                      approve: { command, reason in
                          recordApproval?(command, reason)
                          return await approval()
                      },
                      onEvent: { recordEvent?($0) })
        recordEvent = { [unowned self] in events.append($0) }
        recordApproval = { [unowned self] in approvals.append(($0, $1)) }
    }

    /// Tool messages of a request, by call id.
    func toolMessages(_ request: ChatRequest) -> [String: String] {
        toolMessages(in: request.messages)
    }

    func toolMessages(in messages: [ChatMessage]) -> [String: String] {
        Dictionary(messages.filter { $0.role == .tool }.map { ($0.toolCallID ?? "", $0.content) }) { $1 }
    }
}

@Test("ASSIST-AGENT-001 the first request carries the goal the context and exactly two tools") @MainActor
func ASSIST_AGENT_001() async throws {
    let prompt = AgentPrompts.system(goal: "G1", environment: "ENV", projectInstructions: "PI")
    let fixture = try AgentFixture([.text("Done.\nGOAL MET")], systemPrompt: prompt,
                                   secrets: [KnownSecret(name: "API_TOKEN", value: "supersecret-123")])
    let outcome = await fixture.agent.run("fix it supersecret-123")
    #expect(outcome == .finished(.goalMet))
    #expect(fixture.events.last == .ended(.finished(.goalMet), message: "Done.\nGOAL MET"))

    let request = try #require(fixture.client.requests.first)
    #expect(fixture.client.requests.count == 1)
    #expect(request.model == "m/x")
    #expect(request.tools == [AgentPrompts.bashTool, AgentPrompts.searchTool])
    #expect(OpenRouterClient.body(for: request)["tool_choice"] as? String == "auto")
    #expect(request.messages.count == 2)
    let system = request.messages[0]
    #expect(system.role == .system)
    for needle in ["G1", "ENV", "PI", "GOAL MET", "GOAL NOT MET", "NEED INPUT", "sed -i ''"] {
        #expect(system.content.contains(needle), "\(needle)")
    }
    #expect(request.messages[1] == .user("fix it <API_TOKEN_1:15chars>"))
    let session = try #require(request.sessionID)
    #expect(isLowercaseUUID(session), "\(session)")

    fixture.client.enqueue(.text("More.\nGOAL MET"))
    #expect(await fixture.agent.run("and more") == .finished(.goalMet))
    #expect(fixture.client.requests.count == 2)
    #expect(fixture.client.requests.last?.sessionID == session)

    let other = try AgentFixture([.text("Done.\nGOAL MET")], systemPrompt: prompt)
    _ = await other.agent.run("go")
    let otherSession = try #require(other.client.requests.first?.sessionID)
    #expect(isLowercaseUUID(otherSession), "\(otherSession)")
    #expect(otherSession != session)
    #expect((fixture.client.requests + other.client.requests).allSatisfy { $0.reasoningEffort == nil })

    let thinking = try AgentFixture([.text("Done.\nGOAL MET")], systemPrompt: prompt,
                                    configure: { $0.reasoningEffort = "high" })
    _ = await thinking.agent.run("go")
    #expect(thinking.client.requests.first?.reasoningEffort == "high")
}

private func isLowercaseUUID(_ text: String) -> Bool {
    UUID(uuidString: text) != nil && text == text.lowercased()
}

enum ToolLoopCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case toolCalls, goalNotMet, needsInput, noStatusTwice

    var testDescription: String { rawValue }
}

@Test("ASSIST-AGENT-002 tool calls run in order and the run ends on a status line", arguments: ToolLoopCase.allCases)
@MainActor
func ASSIST_AGENT_002(_ testCase: ToolLoopCase) async throws {
    switch testCase {
    case .toolCalls:
        try await toolCallsRunInOrder()
    case .goalNotMet:
        let fixture = try AgentFixture([.text("Tried.\n**GOAL NOT MET**")])
        #expect(await fixture.agent.run("go") == .finished(.goalNotMet))
        #expect(fixture.client.requests.count == 1)
    case .needsInput:
        let fixture = try AgentFixture([.text("Which port?\nNeed input.")])
        #expect(await fixture.agent.run("go") == .finished(.needInput))
        #expect(fixture.client.requests.count == 1)
    case .noStatusTwice:
        let fixture = try AgentFixture([.text("x"), .text("y")])
        #expect(await fixture.agent.run("go") == .finished(nil))
        #expect(fixture.client.requests.count == 2)
    }
}

@MainActor
private func toolCallsRunInOrder() async throws {
    let fixture = try AgentFixture([
        .calls([bashCall("c1", "echo one > f.txt; cat f.txt"),
                ToolCall(id: "c2", name: "search", arguments: #"{"pattern":"one"}"#),
                ToolCall(id: "c3", name: "bash", arguments: "{not json"),
                ToolCall(id: "c4", name: "nope", arguments: "{}")], content: "Checking."),
        .text("All good"),
        .text("Verified.\nGOAL MET"),
    ])
    let outcome = await fixture.agent.run("make f")
    #expect(outcome == .finished(.goalMet))
    #expect(fixture.client.requests.count == 3)

    let second = fixture.client.requests[1].messages
    let assistant = second[second.count - 5]
    #expect(assistant.role == .assistant)
    #expect(assistant.content == "Checking.")
    #expect(assistant.toolCalls.map(\.id) == ["c1", "c2", "c3", "c4"])
    #expect(second.suffix(4).map(\.toolCallID) == ["c1", "c2", "c3", "c4"])
    let tools = fixture.toolMessages(fixture.client.requests[1])
    #expect(tools["c1"]?.hasPrefix("Exit code: 0") == true)
    #expect(tools["c1"]?.hasSuffix("Output:\none") == true)
    #expect(tools["c2"] == "f.txt:1:one")
    #expect(tools["c3"]?.hasPrefix("Error: invalid arguments for bash") == true)
    #expect(tools["c4"] == #"Error: unknown tool "nope". Available tools: bash, search."#)

    let third = fixture.client.requests[2].messages
    #expect(third[third.count - 2] == ChatMessage(role: .assistant, content: "All good", reasoningModel: "m/x"))
    let reminder = try #require(third.last)
    #expect(reminder.role == .user)
    for status in ["GOAL MET", "GOAL NOT MET", "NEED INPUT"] {
        #expect(reminder.content.contains(status))
    }

    let events = fixture.events.filter {
        if case .thinking = $0 { return false }
        if case .reasoning = $0 { return false }
        return true
    }
    #expect(events == [
        .text("Checking."),
        .commandStarted(id: "c1", command: "echo one > f.txt; cat f.txt"),
        .commandOutput(Data("one\n".utf8)),
        .commandFinished(id: "c1", exitCode: 0, timedOut: false),
        .searchStarted(id: "c2", request: SearchRequest(pattern: "one")),
        .searchFinished(id: "c2", summary: "1 match"),
        .toolFailed(id: "c3", message: "invalid arguments for bash"),
        .toolFailed(id: "c4", message: "unknown tool nope"),
        .text("All good"),
        .text("Verified.\nGOAL MET"),
        .ended(.finished(.goalMet), message: "Verified.\nGOAL MET"),
    ])
}

@Test("ASSIST-AGENT-003 a risky command waits for the user's approval", arguments: [false, true]) @MainActor
func ASSIST_AGENT_003(_ approved: Bool) async throws {
    let fixture = try AgentFixture([.calls([bashCall("c1", "rm -rf build")]), .text("ok\nGOAL MET")],
                                   approval: { approved })
    try fixture.directory.makeDirectory("build")
    #expect(await fixture.agent.run("clean") == .finished(.goalMet))
    #expect(fixture.approvals.count == 1)
    #expect(fixture.approvals.first?.command == "rm -rf build")
    #expect(fixture.approvals.first?.reason.isEmpty == false)
    let result = fixture.toolMessages(fixture.client.requests[1])["c1"]
    if approved {
        #expect(!fixture.directory.exists("build"))
        #expect(result?.hasPrefix("Exit code: 0") == true)
    } else {
        #expect(fixture.directory.exists("build"))
        #expect(result == "The user denied this command. Do not run it again; find another way or ask the user.")
    }
}

@Test("ASSIST-AGENT-004 repeated calls and the step budget are signalled and the step limit ends the run") @MainActor
func ASSIST_AGENT_004() async throws {
    let fixture = try AgentFixture([
        .calls([bashCall("c1", "echo same")]),
        .calls([bashCall("c2", "echo same")]),
        .calls([bashCall("c3", "echo same")]),
        .calls([bashCall("c4", "echo four"), bashCall("c5", "echo five")]),
    ], configure: { configuration in
        configuration.maxToolCalls = 4
        configuration.budgetWarningAt = 3
    })
    #expect(await fixture.agent.run("go") == .stepLimit)
    #expect(fixture.client.requests.count == 4)
    let results = fixture.toolMessages(in: fixture.agent.messages)
    #expect(results["c1"]?.contains("[Warning") == false)
    #expect(results["c2"]?.contains("[Warning") == false)
    let third = try #require(results["c3"])
    #expect(third.hasSuffix("\n\n[Warning: this exact call ran 3 times in a row. Change your approach.]"
        + "\n\n[Warning: 1 tool call left in this run. Verify the goal and conclude.]"))
    #expect(results["c4"]?.hasSuffix("Output:\nfour") == true)
    #expect(results["c5"] == "Not run: the step limit of 4 tool calls was reached.")
}

@Test("ASSIST-AGENT-005 old tool outputs are cleared to keep the context small") @MainActor
func ASSIST_AGENT_005() async throws {
    let cleared = "[Output cleared to save context — re-run the command if you need it]"
    let printA = "head -c 240 < /dev/zero | tr '\\0' a"
    let small = try AgentFixture((1...4).map { .calls([bashCall("c\($0)", printA + " # \($0)")]) } + [.text("done\nGOAL MET")], configure: {
        $0.protectedOutputTokens = 100
        $0.minimumPruneTokens = 50
    })
    #expect(await small.agent.run("go") == .finished(.goalMet))
    #expect(small.toolMessages(small.client.requests[1])["c1"]?.hasSuffix(String(repeating: "a", count: 240)) == true)
    let fifth = small.toolMessages(small.client.requests[4])
    #expect(fifth["c1"] == cleared && fifth["c2"] == cleared && fifth["c3"] == cleared)
    #expect(fifth["c4"]?.hasSuffix(String(repeating: "a", count: 240)) == true)
    let calls = small.client.requests[4].messages.filter { $0.role == ChatMessage.Role.assistant }.flatMap { $0.toolCalls }
    #expect(calls.count == 4)

    let overflow = try AgentFixture((1...5).map { .calls([bashCall("c\($0)", "echo \($0)")]) }
        + [.failure(.contextLengthExceeded("too long")), .text("done\nGOAL MET")])
    #expect(await overflow.agent.run("go") == .finished(.goalMet))
    #expect(overflow.client.requests.count == 7)
    let retried = overflow.toolMessages(overflow.client.requests[6])
    #expect(retried["c1"] == cleared && retried["c2"] == cleared)
    #expect(["c3", "c4", "c5"].allSatisfy { retried[$0]?.hasPrefix("Exit code: 0") == true })

    let big = try AgentFixture([.calls([bashCall("c1", "yes aaaaaaaaaa | head -n 100")]),
                                .text("done\nGOAL MET")], configure: {
        $0.protectedOutputTokens = 100
        $0.minimumPruneTokens = 50
    })
    #expect(await big.agent.run("go") == .finished(.goalMet))
    let latest = big.toolMessages(big.client.requests[1])["c1"] ?? ""
    #expect(latest.hasSuffix("aaaaaaaaaa"))
    #expect(latest.utf8.count > 400)

    let failing = try AgentFixture((1...5).map { .calls([bashCall("c\($0)", "echo \($0)")]) }
        + [.failure(.contextLengthExceeded("too long")), .failure(.contextLengthExceeded("too long"))])
    #expect(await failing.agent.run("go") == .failed(.contextLengthExceeded("too long")))
}

@Test("ASSIST-AGENT-006 reasoning is sent back with the messages it belongs to") @MainActor
func ASSIST_AGENT_006() async throws {
    let details: [JSONValue] = [.object(["type": .string("reasoning.text"), "text": .string("r1"), "index": .number(0)])]
    let fixture = try AgentFixture([
        .calls([bashCall("c1", "echo hi")], reasoningDetails: details),
        .text("Done\nGOAL MET"),
        .text("Again\nGOAL MET"),
    ])
    #expect(await fixture.agent.run("go") == .finished(.goalMet))
    #expect(await fixture.agent.run("again") == .finished(.goalMet))
    for request in fixture.client.requests.dropFirst() {
        let assistant = try #require(request.messages.first { $0.role == .assistant })
        #expect(assistant.reasoningDetails == details)
        #expect(assistant.reasoningModel == "m/x")
    }
    #expect(fixture.client.requests[2].messages.last == .user("again"))
}

enum StopMoment: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case duringCommand, duringApproval, duringStream

    var testDescription: String { rawValue }
}

@Test("ASSIST-AGENT-007 stopping ends the run at once", arguments: StopMoment.allCases) @MainActor
func ASSIST_AGENT_007(_ moment: StopMoment) async throws {
    let step: ScriptedChatClient.Step = switch moment {
    case .duringCommand: .calls([bashCall("c1", "sleep 30")])
    case .duringApproval: .calls([bashCall("c1", "rm -rf build")])
    case .duringStream: .hang
    }
    let fixture = try AgentFixture([step], approval: {
        try? await Task.sleep(nanoseconds: 60_000_000_000)
        return true
    })
    try fixture.directory.makeDirectory("build")
    let task = Task { await fixture.agent.run("go") }
    let started = await eventuallyOnMain(timeout: 5) {
        switch moment {
        case .duringCommand: fixture.events.contains { if case .commandStarted = $0 { true } else { false } }
        case .duringApproval: fixture.approvals.count == 1
        case .duringStream: fixture.client.requests.count == 1
        }
    }
    #expect(started)
    try await Task.sleep(nanoseconds: 200_000_000)
    let cancelled = Date()
    task.cancel()
    #expect(await task.value == .stopped)
    #expect(Date().timeIntervalSince(cancelled) < 5)
    #expect(fixture.client.requests.count == 1)
    let history = fixture.agent.messages
    switch moment {
    case .duringCommand:
        #expect(history.last == .tool(id: "c1", content: "Stopped by the user."))
        let group = try #require(fixture.agent.lastProcessGroup)
        #expect(await processGroupIsGone(group))
    case .duringApproval:
        #expect(fixture.directory.exists("build"))
    case .duringStream:
        #expect(history.map(\.role) == [.system, .user])
    }
}
