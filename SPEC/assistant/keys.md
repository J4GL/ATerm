# Assistant — API key storage

The API key is pasted once by the user, in the assistant bar or in Settings
(⌘,, see [Settings](../app/settings.md)), and kept in the login keychain: `KeychainAPIKeyStore` in
`Sources/ATermCore/Assistant/APIKeyStore.swift`. The app reads it for every
request; `OPENROUTER_API_KEY` from the environment is the fallback. Settings'
Test button checks a key against the [model list](models.md). The app is
ad hoc signed, so macOS asks again for keychain access after each rebuild.

## ASSIST-KEY-001 — The key is saved in, read from and removed from the keychain

Implement: `KeychainAPIKeyStore` (service `gl.j4.ATerm`, account `OpenRouter API Key` in the app), used by `AssistantController` when the key is entered and by `APIKeySource.key()` before each request.
Uses: [Assistant contract](contract.md)

Test: unit · `Tests/ATermCoreTests/Assistant/KeychainTests.swift` · "ASSIST-KEY-001 the key is saved in read from and removed from the keychain"
- Given: a keychain store for a service name unique to the test run, holding nothing
- When: it is read
- Then: the key is nil
- When: `key-one` is saved, then read
- Then: the key is `key-one`
- When: `key-two` is saved, then read
- Then: the key is `key-two`
- When: the key is deleted, then read
- Then: the key is nil
- Given: a key source over an empty store, with the environment fallback on and `OPENROUTER_API_KEY=env-key`
- When: the key is asked for
- Then: it is `env-key`; with the fallback off, it is nil
