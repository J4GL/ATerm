import Foundation
import Testing
import ATermCore

struct RouteCase: CustomTestStringConvertible, Sendable {
    let name: String
    let reply: String
    let route: Route

    var testDescription: String { name }
}

private func commandObject(_ commands: [(String, String)]) -> String {
    let items = commands.map { #"{"command":"\#($0.0)","explanation":"\#($0.1)"}"# }.joined(separator: ",")
    return #"{"mode":"command","commands":[\#(items)],"goal":""}"#
}

private let routeCases: [RouteCase] = [
    RouteCase(name: "commands", reply: commandObject([("du -sh * | sort -h", "Sizes"), ("rm -rf tmp", "Clean")]),
              route: .commands([CommandSuggestion(command: "du -sh * | sort -h", explanation: "Sizes", risk: nil),
                                CommandSuggestion(command: "rm -rf tmp", explanation: "Clean",
                                                  risk: CommandRisk.assess("rm -rf tmp"))])),
    RouteCase(name: "fenced, five commands",
              reply: "```json\n" + commandObject((1...5).map { ("echo \($0)", "Say \($0)") }) + "\n```",
              route: .commands((1...4).map { CommandSuggestion(command: "echo \($0)", explanation: "Say \($0)", risk: nil) })),
    RouteCase(name: "multi-line command dropped",
              reply: commandObject([("git fetch\\ngit reset --hard", "Two lines"), ("git pull", "Pull")]),
              route: .commands([CommandSuggestion(command: "git pull", explanation: "Pull", risk: nil)])),
    RouteCase(name: "agent in prose", reply: #"Sure! {"mode":"agent","commands":[],"goal":"GET / returns 2xx"} Done."#,
              route: .agent(goal: "GET / returns 2xx")),
]

@Test("ASSIST-ROUTE-001 a request is classified as commands to run or a goal for the agent", arguments: routeCases)
func ASSIST_ROUTE_001(_ testCase: RouteCase) async throws {
    let client = ScriptedChatClient([.text(testCase.reply)])
    let route = try await Router(client: client, model: "m/x").route(prompt: "find big files", environment: "ENV")
    #expect(route == testCase.route)
    #expect(testCase.route != .commands([]))
    let request = try #require(client.requests.first)
    #expect(client.requests.count == 1)
    #expect(request.model == "m/x")
    #expect(request.temperature == 0)
    #expect(request.sessionID == nil)
    #expect(request.responseFormat == Router.responseFormat)
    #expect(request.tools.isEmpty)
    #expect(request.reasoningEffort == nil)
    let low = ScriptedChatClient([.text(testCase.reply)])
    _ = try await Router(client: low, model: "m/x", reasoningEffort: "low").route(prompt: "find big files",
                                                                                   environment: "ENV")
    #expect(low.requests.first?.reasoningEffort == "low")
    #expect(request.messages == [.system(AgentPrompts.router + "\n\n" + "ENV"), .user("find big files")])
    #expect(Router.responseFormat["json_schema"]?["strict"] == .bool(true))
    #expect(Router.responseFormat["json_schema"]?["schema"]?["required"]
        == .array([.string("mode"), .string("commands"), .string("goal")]))
}

@Test("ASSIST-ROUTE-002 an invalid reply is corrected once then reported")
func ASSIST_ROUTE_002() async throws {
    let client = ScriptedChatClient([.text("I think you should run ls"), .text(commandObject([("ls", "List")]))])
    let route = try await Router(client: client, model: "m/x").route(prompt: "list", environment: "ENV")
    #expect(route == .commands([CommandSuggestion(command: "ls", explanation: "List", risk: nil)]))
    #expect(client.requests.count == 2)
    let first = client.requests[0].messages
    let second = client.requests[1].messages
    #expect(Array(second.prefix(first.count)) == first)
    #expect(second.count == first.count + 2)
    #expect(second[first.count] == ChatMessage(role: .assistant, content: "I think you should run ls"))
    #expect(second[first.count + 1].role == .user)
    #expect(second[first.count + 1].content.contains("JSON object"))

    let failing = ScriptedChatClient([.text("nope"), .text(#"{"mode":"command","commands":[],"goal":""}"#)])
    await #expect {
        _ = try await Router(client: failing, model: "m/x").route(prompt: "list", environment: "ENV")
    } throws: { error in
        if case AssistantError.invalidResponse = error { true } else { false }
    }
    #expect(failing.requests.count == 2)
}
