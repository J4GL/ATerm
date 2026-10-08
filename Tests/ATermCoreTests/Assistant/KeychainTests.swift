import Foundation
import Testing
import ATermCore

@Test("ASSIST-KEY-001 the key is saved in read from and removed from the keychain")
func ASSIST_KEY_001() throws {
    let store = KeychainAPIKeyStore(service: "gl.j4.ATerm.tests.\(UUID().uuidString)", account: "OpenRouter API Key")
    defer { store.delete() }
    #expect(store.load() == nil)
    try store.save("key-one")
    #expect(store.load() == "key-one")
    try store.save("key-two")
    #expect(store.load() == "key-two")
    store.delete()
    #expect(store.load() == nil)

    let empty = MemoryAPIKeyStore()
    let environment = ["OPENROUTER_API_KEY": "env-key"]
    #expect(APIKeySource(store: empty, environmentFallback: true, environment: environment).key() == "env-key")
    #expect(APIKeySource(store: empty, environmentFallback: false, environment: environment).key() == nil)
}
