# App — Settings window

ATerm ▸ Settings… (⌘,) opens one app-modal Settings window
(`SettingsWindowController`, created by `AppDelegate.showSettings(_:)` and run
with `AppConfiguration.runModal`, `NSApp.runModal(for:)` in the app): the
terminal windows get no input until Save, Cancel or the close button ends it
(`AppConfiguration.stopModal`). It has three fields: the assistant's
**Endpoint** (an OpenAI-compatible chat completions base URL, OpenRouter's by
default), its **API Key** (a secure field, with a **Test** button and a status
line) and its **Model** (with completion from the model list). Save applies
them at once:

- The endpoint is saved in the user defaults (`AssistantEndpoint`, read by
  `AppConfiguration.standard(defaults:)` at launch) and used by the next
  request (`AssistantServices.setEndpoint(_:)`). An empty endpoint restores
  `OpenRouterClient.defaultEndpoint` and removes `AssistantEndpoint`. Any
  other value must be an `http` or `https` URL with a host, else Save and Test
  show `Invalid endpoint URL.`; it is the API's base URL, so a URL ending with
  `/chat/completions` (a trailing `/` aside) is refused with
  `Use the API base URL, without /chat/completions.`
- A non-empty key is saved in the key store ([Keys](../assistant/keys.md));
  an empty key field keeps the current key. The field never shows the stored
  key: its placeholder is `Saved in Keychain` when a key is found, else
  `Paste your API key`.
- The model is saved in the user defaults (`AssistantModel`) and used by the
  next request (`AssistantServices.setModel(_:)`). An empty model restores
  `OpenRouterClient.defaultModel` and removes `AssistantModel`.
- The **Reasoning** pop-up, under the model, offers `Default` (no level sent)
  and the levels of the model named in the model field, from the model list
  (`ModelInfo.reasoningEfforts`); a model with no known level offers `Default`
  only. The level is saved in the user defaults (`AssistantReasoningEffort`,
  removed for `Default`) and sent by the next requests, router and agent
  (`AssistantServices.setReasoningEffort(_:)`).
- The **Suggestions** box, `Complete commands with the model`, checked by
  default, turns on the model's completions at the zsh prompt
  ([Suggestions](suggestions.md)). Unchecked, it is saved in the user
  defaults (`AssistantSuggestions` false, removed when checked) and stops the
  next completion requests (`AssistantServices.setCommandCompletions(_:)`).

Test fetches the [model list](../assistant/models.md) from the endpoint and
with the key being edited (the key field, else the stored key), without saving
them, and shows the result or the error's message in the status line, which
shows at most 3 lines (the full text is its tooltip); the list is kept by `AssistantServices.models` for the model completion.
Typing in the model field lists, below it, the models whose id or name
contains the typed text, ignoring case, in the list's order; each row shows
the id and its `priceSummary`.

Every spec uses the assistant fixture of [Assistant](assistant.md); its fake
endpoint answers the model list requests with the replies the test queues.
Opening Settings with a known key loads the model list (APP-SETTINGS-006):
except in APP-SETTINGS-006, the fake answers that request with an empty list,
the spec waits for it, and the requests a spec counts exclude it.

## APP-SETTINGS-001 — ⌘, opens Settings showing the current endpoint, key state and model

Implement: `MainMenu` (ATerm ▸ Settings… ⌘,, no key item in the Shell menu), `AppDelegate.showSettings(_:)` and `SettingsWindowController`.
Uses: [App contract](contract.md), [Keys](../assistant/keys.md)

Test: e2e · `Tests/ATermE2ETests/SettingsTests.swift` · "APP-SETTINGS-001 command comma opens settings showing the current endpoint key state and model"
- Given: a window of the assistant fixture (key store holding `test-key`)
- When: ⌘, is pressed (through the main menu)
- Then: the settings window is open, titled `Settings`, its endpoint field reads the fake endpoint, its key field is empty with the placeholder `Saved in Keychain`, its model field reads `OpenRouterClient.defaultModel`, and no main menu item is titled `OpenRouter API Key…`
- When: ⌘, is pressed again
- Then: there is still one settings window
- Given: a window of the assistant fixture with an empty key store
- When: ⌘, is pressed
- Then: the key field is empty with the placeholder `Paste your API key`

## APP-SETTINGS-002 — Saving applies the endpoint, key and model to the next request and persists them

Implement: `SettingsWindowController` saving to `AppConfiguration.defaults`, the key store, `AssistantServices.setEndpoint(_:)` and `setModel(_:)`; `AppConfiguration.standard(defaults:)` reading `AssistantEndpoint` and `AssistantModel`; `Router` and `AgentTab` using `AssistantServices.model`.
Uses: [Keys](../assistant/keys.md), [Assistant](assistant.md)

Test: e2e · `Tests/ATermE2ETests/SettingsTests.swift` · "APP-SETTINGS-002 saving applies the endpoint key and model to the next request and persists them"
- Given: a window of the assistant fixture on fake A, and a second fake endpoint B
- When: ⌘, is pressed, the endpoint field set to B's endpoint, the key field to `key-3`, the model field to `m/new`, and Save clicked
- Then: the settings window is closed, the key store holds `key-3`, the defaults' `AssistantEndpoint` is B's endpoint and `AssistantModel` is `m/new`, and `AppConfiguration.standard(defaults:)` over those defaults has B's endpoint and the model `m/new`
- When: the bar is opened, `hi` typed and Return pressed
- Then: B received one request, with `Authorization: Bearer key-3` and the model `m/new`, and A received no chat request

## APP-SETTINGS-003 — An invalid endpoint is refused; empty fields restore the defaults

Implement: `SettingsWindowController` validating the endpoint before saving anything.

Test: e2e · `Tests/ATermE2ETests/SettingsTests.swift` · "APP-SETTINGS-003 an invalid endpoint is refused and empty fields restore the defaults"
- Given: a window of the assistant fixture whose settings window is open, for each endpoint value below, with `key-4` in the key field and `m/other` in the model field
- When: Save is clicked
- Then:

| Endpoint | Result |
|---|---|
| `not a url` | the window stays open showing `Invalid endpoint URL.`; the defaults have no `AssistantEndpoint` and no `AssistantModel`, the key store still holds `test-key`, the next request goes to the fake with the default model |
| `ftp://example.com/v1` | same as `not a url` |
| the fake endpoint followed by `/chat/completions/` | same as `not a url`, the window showing `Use the API base URL, without /chat/completions.` |
| (empty) | the window is closed; the defaults have no `AssistantEndpoint`, the assistant's endpoint is `OpenRouterClient.defaultEndpoint`, the key store holds `key-4`, the defaults' `AssistantModel` is `m/other` |

- Given: a window of the assistant fixture whose defaults hold `AssistantModel` `m/old`, its settings window open
- When: the model field is emptied and Save clicked
- Then: the defaults have no `AssistantModel` and the assistant's model is `OpenRouterClient.defaultModel`

## APP-SETTINGS-004 — Test checks the key being edited against the endpoint being edited

Implement: the Test button of `SettingsWindowController`, calling `AssistantServices.fetchModels(endpoint:key:)` and showing the result in the status line.
Uses: [Model list](../assistant/models.md), [Keys](../assistant/keys.md)

Test: e2e · `Tests/ATermE2ETests/SettingsTests.swift` · "APP-SETTINGS-004 test checks the key being edited against the endpoint being edited"
- Given: a window of the assistant fixture on fake A, a second fake endpoint B, the settings window open with B's endpoint typed in the endpoint field (not saved), for each case below
- When: the key field holds the key below, the fakes answer as below, and Test is clicked
- Then:

| Key field | B answers | Status | Requests |
|---|---|---|---|
| `key-5` | 200 with the models `a/one`, `b/two`, `c/three` | `✓ Key valid — 3 models` | one GET to B's `/models/user` with `Authorization: Bearer key-5`; none to A |
| (empty) | 200 with the models `a/one`, `b/two`, `c/three` | `✓ Key valid — 3 models` | one GET to B's `/models/user` with `Authorization: Bearer test-key` |
| `bad` | 401 `{"error":{"code":401,"message":"User not found."}}` | `✗ Invalid API key: User not found.` | one GET to B's `/models/user` |
| `key-5` | 404, then 200 with the model `a/one` on `/models` | `✓ 1 model (this endpoint does not check the key)` | GETs to B's `/models/user` then `/models` |
| `key-5` | 404 then 404, both an HTML page `<!DOCTYPE html><html>…</html>` | `✗ Request refused: HTTP 404 (not found)` | GETs to B's `/models/user` then `/models` |
| `key-5`, with B's endpoint followed by `/chat/completions` in the endpoint field | nothing | `✗ Use the API base URL, without /chat/completions.` | none |

In every case the key store still holds `test-key` and the defaults have no `AssistantEndpoint`.

- Given: a window of the assistant fixture with an empty key store, its settings window open
- When: Test is clicked with the key field empty
- Then: the status is `Enter an API key to test.` and no request was sent

## APP-SETTINGS-005 — The model field completes from the model list, with prices

Implement: the model completion of `SettingsWindowController`: a list under the model field filtered as the text changes, ↑/↓ to move, Return or a click to choose, Esc to dismiss.
Uses: [Model list](../assistant/models.md)

Test: e2e · `Tests/ATermE2ETests/SettingsTests.swift` · "APP-SETTINGS-005 the model field completes from the model list with prices"
- Given: a window of the assistant fixture whose settings window is open, Test clicked with the fake answering the models `anthropic/claude-a` (`Anthropic: Claude A`, 0.000003 / 0.0000003 / 0.000015), `openai/gpt-b` (`OpenAI: GPT B`, 0.000001 / none / 0.000004) and `x/claude-c` (`X: Claude C`, 0 / none / 0), and `✓ Key valid — 3 models` shown
- When: the model field is emptied and `CLAUDE` typed
- Then: the completion list is shown with two rows, `anthropic/claude-a` with `in $3.00 · cached $0.30 · out $15.00 /M`, then `x/claude-c` with `free`; no row is selected
- When: `gpt` replaces the text
- Then: the list shows one row, `openai/gpt-b` with `in $1.00 · cached — · out $4.00 /M`
- When: the text is emptied and `claude` typed, then ↓ ↓ and Return pressed
- Then: the model field reads `x/claude-c`, the list is hidden and the settings window is still open
- When: the text is emptied, `open` typed and Esc pressed
- Then: the list is hidden, the model field reads `open` and the settings window is still open
- When: `zzz` replaces the text
- Then: the list is hidden

## APP-SETTINGS-006 — Opening Settings with a known key loads the model list once

Implement: `SettingsWindowController` asking `AssistantServices.fetchModels(endpoint:key:)` when it opens with a key and no list is cached.
Uses: [Model list](../assistant/models.md)

Test: e2e · `Tests/ATermE2ETests/SettingsTests.swift` · "APP-SETTINGS-006 opening settings with a known key loads the model list once"
- Given: a window of the assistant fixture (key store holding `test-key`), the fake answering the models `a/one` and `b/two`
- When: ⌘, is pressed
- Then: one GET reached `/models/user`, and once answered typing `one` in the model field lists `a/one`; the status line is empty
- When: the settings window is closed and ⌘, pressed again
- Then: no other request was sent
- Given: a window of the assistant fixture with an empty key store
- When: ⌘, is pressed
- Then: no request is sent

## APP-SETTINGS-007 — Settings is app-modal until Save, Cancel or the close button

Implement: `AppDelegate.showSettings(_:)` running the window with `AppConfiguration.runModal` (`NSApp.runModal(for:)`), `SettingsWindowController` ending it with `AppConfiguration.stopModal` (`NSApp.stopModal()`) when the window closes; the completion panel works while modal.
Uses: [App contract](contract.md)

Test: e2e · `Tests/ATermModalTests/ModalTests.swift` · "APP-SETTINGS-007 settings is app modal until save cancel or the close button"
- Given: a window of the e2e fixture without API key, whose settings window is run by the app's own `runModal` and `stopModal` (a real modal loop, the settings window on screen), for each way out: Save, Cancel, the close button (`performClose`). Once a modal loop has run, AppKit later stops the test runner's main run loop, ending the process: this test is alone in its own test target.
- When: ⌘, is pressed
- Then: while the modal loop runs (checked from a timer firing inside it), `NSApp.modalWindow` is the settings window, which is visible, the terminal window does not work while modal (`worksWhenModal` false), and the alignment rect of every label, field, pop-up, check box and button lies at least 20 points inside each edge of the content view
- When: the settings window is left that way, from inside the loop
- Then: ⌘, has returned (the loop ended), `NSApp.modalWindow` is nil and the settings window is closed

## APP-SETTINGS-008 — Every control fits in the window, whatever the status

Implement: the layout of `SettingsWindowController`: the window's content size follows its constraints when the status changes; the status line wraps to at most 3 lines.

Test: e2e · `Tests/ATermE2ETests/SettingsTests.swift` · "APP-SETTINGS-008 every control fits in the window whatever the status"
- Given: a window of the assistant fixture whose settings window is open, for each status below: none; `✓ Key valid — 3 models`; the 401 message `✗ Invalid API key: ` followed by 600 × `x`
- When: Test is clicked (the fake answering accordingly) and the status shown
- Then: in the content view's coordinates, the frame of every label, field, pop-up, check box and button (Endpoint, API Key, Model, Reasoning, Suggestions labels, the three fields, the Reasoning pop-up, the Suggestions box, Test, the status line, Cancel, Save) lies inside the content view's bounds inset by 12 points, with no two of them overlapping; the status line is at most 3 lines high (its height ≤ 3 × its font's line height + 4); its tooltip is the full status; Save's right edge is 20 points from the content view's right edge and its bottom 20 points above the content view's bottom

## APP-SETTINGS-009 — The Reasoning pop-up offers the model's levels and the chosen one is sent

Implement: the Reasoning pop-up of `SettingsWindowController`, following the model field and the model list; `AssistantServices.setReasoningEffort(_:)` read by `AssistantController` (router) and `AgentTab` (agent); `AppConfiguration.standard(defaults:)` reading `AssistantReasoningEffort`; `AssistantServices.fetchModels` passing `AssistantConfiguration.modelCatalogURL` (`ModelCatalog.modelsDevURL` in the app; the assistant fixture has none unless a spec gives one).
Uses: [Model list](../assistant/models.md), [client](../assistant/client.md)

Test: e2e · `Tests/ATermE2ETests/SettingsTests.swift` · "APP-SETTINGS-009 the reasoning pop-up offers the model's levels and the chosen one is sent"
- Given: a window of the assistant fixture whose model catalog is served by the fake at `<fake endpoint>/catalog.json`; opening Settings loads the list: 404 on `models/user`, `{"data":[{"id":"space-bunny-free"},{"id":"plain"}]}` on `models`, and the catalog `{"opencode-go":{"api":"<fake endpoint>","models":{"space-bunny-free":{"reasoning_options":[{"type":"effort","values":["low","medium","high","xhigh","max"]}]}}}}`
- When: ⌘, is pressed and the list has loaded
- Then: the Reasoning pop-up offers `Default` only (the default model is not in the list)
- When: `space-bunny-free` is typed in the model field
- Then: the pop-up offers `Default`, `low`, `medium`, `high`, `xhigh`, `max`, with `Default` selected
- When: `high` is selected and Save clicked
- Then: the defaults' `AssistantReasoningEffort` is `high`, `AppConfiguration.standard(defaults:)` over them has the level `high`, and the next request (the bar's `hi`) has `"reasoning_effort":"high"`
- When: ⌘, is pressed again
- Then: the pop-up shows `high` selected
- When: `plain` replaces the model
- Then: the pop-up offers `Default` only, selected
- When: Save is clicked
- Then: the defaults have no `AssistantReasoningEffort` and the next request has no `reasoning_effort` key

## APP-SETTINGS-010 — The Suggestions box turns the model's completions on and off

Implement: the Suggestions box of `SettingsWindowController`; `AssistantServices.setCommandCompletions(_:)` read by `AssistantController.requestCompletion(of:)`; `AppConfiguration.standard(defaults:)` reading `AssistantSuggestions` into `AssistantConfiguration.commandCompletions`.
Uses: [Suggestions](suggestions.md)

Test: e2e · `Tests/ATermE2ETests/SettingsTests.swift` · "APP-SETTINGS-010 the suggestions box turns the model's completions on and off"
- Given: a window of the assistant fixture running the zsh fixture's shell of [Suggestions](suggestions.md), with an empty history, showing the prompt
- When: ⌘, is pressed
- Then: the Suggestions box `Complete commands with the model` is checked
- When: it is unchecked and Save clicked
- Then: the defaults' `AssistantSuggestions` is false and `AppConfiguration.standard(defaults:)` over them has the model's completions off; `ffmpeg -i` typed in the tab sends no request within 2 s
- When: ⌘, is pressed again
- Then: the box is unchecked
- When: it is checked and Save clicked, then ⌃U and `ffprobe -v` are typed in the tab
- Then: the defaults have no `AssistantSuggestions` and one completion request, for `ffprobe -v`, is sent within 3 s
