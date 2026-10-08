# Assistant contract — OpenRouter, tools, statuses, context, secrets

Shared by the assistant specs. Code lives in `Sources/ATermCore/Assistant/`
(pure Foundation/Darwin) and is wired into the app by
`Sources/ATermApp/AssistantController.swift` and `AgentTab.swift`.

## Flow

1. The user holds ⌘ and types a request in the assistant bar of a shell pane.
2. The **router** asks the model to classify it: `command` (one command line
   to run now, with alternatives) or `agent` (a task needing several steps,
   with a verifiable goal).
3. `command`: the suggestions are shown; the chosen one runs in that pane.
4. `agent`: a new **agent tab** runs the **agent loop** until the model ends
   its turn with a status line. The tab stays an agent console: a reply
   continues the same conversation.
5. Apart from the bar, while a line is typed at the zsh prompt and the
   history has no suggestion for it, the **completer** proposes how the line
   ends (see [Suggestions](../app/suggestions.md)).

## OpenRouter API subset

- Request: `POST {endpoint}/chat/completions`, default endpoint
  `https://openrouter.ai/api/v1`, default model
  `dots-studio/dots-3-note-preview:free` (user defaults `AssistantEndpoint`,
  `AssistantModel`).
- Headers: `Authorization: Bearer <key>`, `Content-Type: application/json`,
  `X-OpenRouter-Title: ATerm`.
- Body: `model`, `messages`, `stream: true`, and when used `tools` (sent on
  every agent request), `tool_choice: "auto"`, `response_format`,
  `temperature`, `session_id`.
- `session_id`: a lowercase UUID created with the agent conversation and sent
  on each of its requests, replies included, so OpenRouter keeps routing
  them to the same provider and its prompt cache from the first request.
  The router sends none: its one-off requests share nothing to cache.
- Messages: `{role: "system"|"user", content}`;
  `{role: "assistant", content, tool_calls?: [{id, type: "function", function: {name, arguments}}], reasoning_details? | reasoning?}`;
  `{role: "tool", tool_call_id, content}`. Reasoning is sent back only on
  messages produced by the current model.
- Stream: server-sent events. `data: <json>` lines carry chunks
  `{choices: [{delta: {content?, reasoning?, reasoning_details?, tool_calls?: [{index, id?, function: {name?, arguments?}}]}, finish_reason?}], usage?, error?}`;
  lines starting with `:` are comments; `data: [DONE]` ends the stream.
  Tool call fragments are joined by `index`; `reasoning_details` fragments
  are merged by `index` (`text`, `summary` and `data` concatenated, the first
  non-empty `id`, `signature`, `format` and `type` kept).
- Errors: an HTTP error body or a chunk carrying `{error: {code, message, metadata?}}`.

| Failure | Result |
|---|---|
| no key | `missingAPIKey` |
| 401 | `unauthorized(message)` |
| 402 | `insufficientCredits(message)` |
| 400 whose message or `metadata.error_type` mentions the context length | `contextLengthExceeded(message)` |
| other 400, 403 | `badRequest(message)` |
| 429 | retried; `rateLimited(message)` when retries are exhausted or when the quota resets more than 60 s later (`X-RateLimit-Reset`, in ms since 1970) or the message mentions `per-day` |
| 408, 500, 502, 503, 504, network error, reply with no content and no tool call | retried; then `server(status, message)`, `network(message)` or `emptyReply` |
| error chunk after content was streamed | `server(code, message)`, not retried |

Retries: at most 4, before any content is delivered, waiting the configured
delays (default 0.5, 1, 2, 4 s, plus up to 10 % jitter) or `Retry-After`
seconds when the response gives one of 60 or less. Streams idle for 120 s
fail with `network`.

## Router

System message: the classification instructions followed by the
environment block. User message: the request. `temperature: 0` and:

```json
{"type": "json_schema", "json_schema": {"name": "route", "strict": true, "schema": {
  "type": "object", "additionalProperties": false,
  "required": ["mode", "commands", "goal"],
  "properties": {
    "mode": {"type": "string", "enum": ["command", "agent"]},
    "commands": {"type": "array", "items": {"type": "object", "additionalProperties": false,
      "required": ["command", "explanation"],
      "properties": {"command": {"type": "string"}, "explanation": {"type": "string"}}}},
    "goal": {"type": "string"}}}}}
```

The reply's JSON object may be wrapped in a code fence or in prose; the first
`{`…last `}` span is decoded. At most 4 commands are kept, empty ones dropped.

## Completer

System message: the completion instructions followed by the environment
block. User message: the line typed so far. `temperature: 0` and:

```json
{"type": "json_schema", "json_schema": {"name": "completion", "strict": true, "schema": {
  "type": "object", "additionalProperties": false,
  "required": ["command"],
  "properties": {"command": {"type": "string"}}}}}
```

The reply's JSON object may be wrapped in a code fence or in prose; the first
`{`…last `}` span is decoded. Its `command`, without trailing spaces or line
breaks, is the completed line when it starts with the typed line, is longer,
holds no control character and has at most 500 bytes; otherwise nothing is
suggested. One request is sent, never retried: a late completion is useless.

## Agent tools

Exactly two tools, as the model sees them:

- `bash` — parameters `command` (string, required) and `timeout` (integer
  seconds, default 120, clamped to 1…600). Description: runs the command with
  bash, non-interactive, no TTY, stdin closed, stdout and stderr merged; the
  working directory persists between calls, variables do not; start servers
  in the background with their output redirected; long outputs keep their
  first and last lines and name the file holding the full output; risky
  commands wait for the user's approval; secrets appear as placeholders to be
  used verbatim.
- `search` — parameters `pattern` (string, required), `path`, `glob` (one or
  more globs separated by spaces, `!` excludes), `ignore_case`, `literal`,
  `context` (0…10) and `limit` (default 100, at most 1000). Description:
  searches file contents like ripgrep.

A `bash` result for the model reads:

```text
Exit code: 0                      (or: Timed out after 120 s; the process group was killed)
Wall time: 0.4 s
Working directory: /new/dir       (only when the command changed it)
<notice>                          (only when there is one, e.g. a vanished working directory)
Output:
…                                 ((no output) when empty)
```

Model output of a command: escape sequences removed, each line reduced to
the text after its last carriage return, secrets redacted, then truncated
when it has more than 400 lines or 24 KiB: the first ≤ 100 lines within
8 KiB, then `[Showing lines 1-A and B-N of N. Full output: <file>]`, then the
last ≤ 300 lines within 16 KiB. Lines longer than 500 characters end with
`... [truncated]`.

## Agent statuses

The final message of a run (a reply without tool calls) ends with a line
reading `GOAL MET`, `GOAL NOT MET` or `NEED INPUT` (case, surrounding
spaces, `*`, `` ` `` and a final `.` ignored). A run without that line is
asked once to continue; a run can also end as `stepLimit` (60 tool calls),
`stopped` or `failed`.

## Environment block

```text
<environment>
os: macOS <version> (<build>), <arch>
host: <host name>
user: <login> (<full name>), home <home>
shell: <login shell>; commands run with <bash path> <bash version>
locale: <locale identifier>; languages: <preferred languages>
date: <ISO 8601 date and time with offset> (<time zone identifier>)
cwd: <directory>
git: <root> on branch <branch>      (only inside a git work tree)
entries: <up to 60 sorted names, directories ending with />
tools: <names found on PATH among a fixed list>
terminal: <cols>x<rows>, running <foreground program>
</environment>
<recent_terminal_output>
<up to 50 lines>
</recent_terminal_output>
```

Recent output: the last 50 logical lines (wrapped rows joined) of the main
screen and scrollback up to the cursor line, trailing blank lines removed;
the visible screen when the alternate screen is active.

## Secrets

- Placeholder: `<NAME_N:Lchars>` — `NAME` is the secret's variable or key
  name, or its kind (uppercase, other characters as `_`), `N` counts the
  distinct secrets of the conversation from 1, `L` is the value's length.
  The same value always gets the same placeholder within a conversation.
- A secret name is a variable or key name with a part (split on `_`, `-`,
  `.` and lower→upper case changes) equal to TOKEN, SECRET, SECRETS, PASSWORD,
  PASSWD, PASS, KEY, APIKEY, CREDENTIAL, CREDENTIALS, AUTH, PRIVATE, SESSION,
  COOKIE or DSN.
- A candidate value has 8 characters or more and is not a path (`/`, `~/`,
  `./`), a number or `true`/`false`.
- Shell-safe characters: letters, digits and `_.,:@%+=/~-`.
