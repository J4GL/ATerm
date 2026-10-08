import Foundation
import Testing
import ATermCore

struct CompletionCase: CustomTestStringConvertible, Sendable {
    let name: String
    let reply: String
    let completion: String?

    var testDescription: String { name }
}

private let completionCases: [CompletionCase] = [
    CompletionCase(name: "completed", reply: #"{"command":"git push origin main"}"#, completion: "git push origin main"),
    CompletionCase(name: "fenced", reply: "```json\n" + #"{"command":"git push origin main"}"# + "\n```",
                   completion: "git push origin main"),
    CompletionCase(name: "trailing spaces and line break", reply: #"{"command":"git pull --rebase \n"}"#,
                   completion: "git pull --rebase"),
    CompletionCase(name: "nothing longer", reply: #"{"command":"git pu"}"#, completion: nil),
    CompletionCase(name: "another line", reply: #"{"command":"push origin main"}"#, completion: nil),
    CompletionCase(name: "line break inside", reply: #"{"command":"git push\nrm -rf x"}"#, completion: nil),
    CompletionCase(name: "too long", reply: #"{"command":"git push "# + String(repeating: "x", count: 500) + #""}"#,
                   completion: nil),
    CompletionCase(name: "prose", reply: "I would run git push", completion: nil),
]

@Test("ASSIST-COMPLETE-001 the model completes the line being typed or nothing is suggested",
      arguments: completionCases)
func ASSIST_COMPLETE_001(_ testCase: CompletionCase) async throws {
    let client = ScriptedChatClient([.text(testCase.reply)])
    let completion = try await CommandCompleter(client: client, model: "m/x").complete(line: "git pu",
                                                                                       environment: "ENV")
    #expect(completion == testCase.completion)
    let request = try #require(client.requests.first)
    #expect(client.requests.count == 1)
    #expect(request.model == "m/x")
    #expect(request.temperature == 0)
    #expect(request.sessionID == nil)
    #expect(request.responseFormat == CommandCompleter.responseFormat)
    #expect(request.tools.isEmpty)
    #expect(request.reasoningEffort == nil)
    #expect(request.messages == [.system(AgentPrompts.completer + "\n\n" + "ENV"), .user("git pu")])
    #expect(CommandCompleter.responseFormat["json_schema"]?["name"] == .string("completion"))
    #expect(CommandCompleter.responseFormat["json_schema"]?["strict"] == .bool(true))
    #expect(CommandCompleter.responseFormat["json_schema"]?["schema"]?["required"] == .array([.string("command")]))
    let low = ScriptedChatClient([.text(testCase.reply)])
    _ = try await CommandCompleter(client: low, model: "m/x", reasoningEffort: "low").complete(line: "git pu",
                                                                                               environment: "ENV")
    #expect(low.requests.first?.reasoningEffort == "low")

    let failing = ScriptedChatClient([.failure(.rateLimited("slow down")), .text(testCase.reply)])
    await #expect(throws: AssistantError.rateLimited("slow down")) {
        _ = try await CommandCompleter(client: failing, model: "m/x").complete(line: "git pu", environment: "ENV")
    }
    #expect(failing.requests.count == 1)
}
