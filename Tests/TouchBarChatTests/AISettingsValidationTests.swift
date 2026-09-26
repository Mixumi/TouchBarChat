import Foundation
import Testing

@testable import TouchBarChat

/// URL validation is pure: these tests do not read or modify the real Keychain.
@MainActor
struct AISettingsValidationTests {
    @Test
    func acceptsExactHTTPSChatCompletionsURL() throws {
        let input = "https://api.example.test/custom/v1/chat/completions"
        let endpoint = try AISettingsStore.validateEndpoint(input)
        #expect(endpoint.absoluteString == input)
    }

    @Test(arguments: [
        "http://localhost:11434/v1/chat/completions",
        "http://127.0.0.1:11434/v1/chat/completions",
        "http://[::1]:11434/v1/chat/completions",
    ])
    func acceptsLoopbackHTTP(_ input: String) throws {
        let endpoint = try AISettingsStore.validateEndpoint(input)
        #expect(endpoint.scheme == "http")
        #expect(endpoint.path == "/v1/chat/completions")
    }

    @Test
    func rejectsRemotePlainHTTP() {
        do {
            _ = try AISettingsStore.validateEndpoint("http://api.example.test/v1/chat/completions")
            Issue.record("Expected the remote plain-HTTP endpoint to be rejected")
        } catch AISettingsError.insecureEndpoint {
            // Expected: credentials and personal profile must not use remote HTTP.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func rejectsQueryParametersThatCouldContainSecrets() {
        do {
            _ = try AISettingsStore.validateEndpoint("https://api.example.test/v1/chat/completions?api_key=secret")
            Issue.record("Expected URL query parameters to be rejected")
        } catch AISettingsError.endpointContainsQuery {
            // Expected: API keys belong in the secure Keychain-backed field.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func rejectsUserInfoInURL() {
        do {
            _ = try AISettingsStore.validateEndpoint("https://user:secret@api.example.test/v1/chat/completions")
            Issue.record("Expected URL user-info to be rejected")
        } catch AISettingsError.endpointInvalid {
            // Expected: a password embedded in the URL could leak through settings.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func rejectsHostOnlyURLWithoutEndpointPath() {
        do {
            _ = try AISettingsStore.validateEndpoint("https://api.example.test")
            Issue.record("Expected a complete endpoint URL")
        } catch AISettingsError.endpointInvalid {
            // Expected: the app does not append /v1/chat/completions implicitly.
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
