import Testing
import OpenCodePlatform
import OpenCodeRecorder
import OpenCodeUtil

@Suite("OpenCodeRecorder Redaction, Secrets & Comparison")
struct RedactionAndSecretsTests {
    @Test("redacts sensitive URL query parameters")
    func redactsSensitiveQueryParameters() {
        let actual = redactUrl(
            "https://example.test/path?key=secret-google-key&api_key=secret-openai-key&safe=value&X-Amz-Signature=secret-signature"
        )
        #expect(
            actual == "https://example.test/path?key=%5BREDACTED%5D&api_key=%5BREDACTED%5D&safe=value&X-Amz-Signature=%5BREDACTED%5D"
        )
    }

    @Test("redacts URL embedded username and password")
    func redactsUrlCredentials() {
        let actual = redactUrl("https://user:password@example.test/path?safe=value")
        #expect(actual == "https://%5BREDACTED%5D:%5BREDACTED%5D@example.test/path?safe=value")
    }

    @Test("applies custom URL transform after built-in redaction")
    func customUrlTransformAfterBuiltIn() {
        let actual = redactUrl(
            "https://example.test/accounts/real-account/path?key=secret-key",
            query: nil,
            transform: { $0.replacing("/accounts/real-account/", with: "/accounts/{account}/") }
        )
        #expect(actual == "https://example.test/accounts/{account}/path?key=%5BREDACTED%5D")
    }

    @Test("handles non-URL strings gracefully in redactUrl")
    func nonUrlPassthroughAndTransform() {
        #expect(redactUrl("/relative/path") == "/relative/path")
        #expect(redactUrl("/relative/secret", transform: { $0.replacing("secret", with: "safe") }) == "/relative/safe")
    }

    @Test("redacts sensitive headers when allow-listed and strips others")
    func redactsSensitiveHeaders() {
        let result = redactHeaders(
            [
                "Authorization": "Bearer secret-token",
                "Content-Type": "application/json",
                "X-Custom-Token": "custom-secret",
                "X-Api-Key": "secret-key",
                "X-Goog-Api-Key": "secret-google-key",
                "Cookie": "session=abc",
                "X-Unlisted": "drop-me",
            ],
            allow: ["authorization", "content-type", "x-api-key", "x-goog-api-key", "x-custom-token", "cookie"],
            redact: ["x-custom-token"]
        )
        #expect(result == [
            "authorization": "[REDACTED]",
            "content-type": "application/json",
            "cookie": "[REDACTED]",
            "x-api-key": "[REDACTED]",
            "x-custom-token": "[REDACTED]",
            "x-goog-api-key": "[REDACTED]",
        ])
    }

    @Test("redacts error requests without retaining headers or body")
    func redactsErrorRequest() {
        let request = HTTPRequest(
            method: "CUSTOM",
            url: "https://example.test/path?api_key=super-secret-key",
            headers: ["authorization": "Bearer super-secret"],
            body: Array("super-secret-body".utf8)
        )
        let sanitized = redactedErrorRequest(request)
        #expect(sanitized.method == "CUSTOM")
        #expect(sanitized.url == "https://example.test/path?api_key=%5BREDACTED%5D")
        #expect(sanitized.headers.isEmpty)
        #expect(sanitized.body == nil)
    }

    @Test("detects all secret patterns without returning secret values")
    func detectsSecretPatterns() {
        let env = DictionaryEnvironment(variables: [:])
        let cassette = Cassette(
            version: 1,
            interactions: [
                .http(HttpInteraction(
                    request: RequestSnapshot(
                        method: "POST",
                        url: "https://example.test/path?key=sk-123456789012345678901234",
                        headers: [:],
                        body: #"{"nested":"AIzaSyDHibiBRvJZLsFnPYPoiTwxY4ztQ55yqCE"}"#
                    ),
                    response: ResponseSnapshot(
                        status: 200,
                        headers: [:],
                        body: "Bearer abcdefghijklmnopqrstuvwxyz"
                    )
                )),
            ]
        )
        let findings = secretFindings(cassette, environment: env)
        #expect(findings == [
            SecretFinding(path: "interactions[0].request.url", reason: "API key"),
            SecretFinding(path: "interactions[0].request.body", reason: "Google API key"),
            SecretFinding(path: "interactions[0].response.body", reason: "bearer token"),
        ])

        // Additional patterns: Anthropic, AWS, GitHub, Private key
        let extra = secretFindings(
            PureJSONValue.object([
                ("anthropic", .string("sk-ant-api03-12345678901234567890")),
                ("aws", .string("AKIAIOSFODNN7EXAMPLE")),
                ("github", .string("ghp_1234567890abcdefghij123456")),
                ("pem", .string("-----BEGIN RSA PRIVATE KEY-----\nabc")),
            ]),
            environment: env
        )
        #expect(extra.contains(SecretFinding(path: "anthropic", reason: "Anthropic API key")))
        #expect(extra.contains(SecretFinding(path: "aws", reason: "AWS access key")))
        #expect(extra.contains(SecretFinding(path: "github", reason: "GitHub token")))
        #expect(extra.contains(SecretFinding(path: "pem", reason: "private key")))
    }

    @Test("detects secret-looking values inside metadata and from environment")
    func detectsSecretsInMetadataAndEnv() {
        let env = DictionaryEnvironment(variables: [
            "MY_SERVICE_TOKEN": "super-secret-env-token-9999",
            "SHORT_KEY": "short",
            "SAFE_TOKEN": "test-key",
            "REGULAR_VAR": "not-a-secret-env-name-12345",
        ])
        let cassette = Cassette(
            version: 1,
            metadata: [
                "token": .string("sk-123456789012345678901234"),
                "leaked": .string("prefix super-secret-env-token-9999 suffix"),
                "safe": .string("short test-key not-a-secret-env-name-12345"),
            ],
            interactions: []
        )
        let findings = secretFindings(cassette, environment: env)
        #expect(findings.contains(SecretFinding(path: "metadata.token", reason: "API key")))
        #expect(findings.contains(SecretFinding(path: "metadata.leaked", reason: "environment secret MY_SERVICE_TOKEN")))
        #expect(findings.count == 2)
    }

    @Test("redacts configured and common sensitive JSON fields and preserves untouched JSON verbatim")
    func redactsJsonFieldsAndPreservesUntouched() throws {
        let redactor = Redactor.make(RedactOptions(jsonFields: ["account_id"]))
        let request = redactor.request(RequestSnapshot(
            method: "POST",
            url: "https://example.test/path",
            headers: ["content-type": "application/json"],
            body: #"{"password":"secret-password","accessToken":"access-token","nested":{"account_id":"account-123","safe":"visible"}}"#
        ))
        let parsed = try #require(decodeJson(request.body))
        let expected = try #require(decodeJson(#"{"password":"[REDACTED]","accessToken":"[REDACTED]","nested":{"account_id":"[REDACTED]","safe":"visible"}}"#))
        #expect(canonicalizeJson(parsed) == canonicalizeJson(expected))

        let untouchedBody = "{\n  \"id\": 9007199254740993,\n  \"safe\": true\n}"
        let untouched = Redactor.make().request(RequestSnapshot(
            method: "POST",
            url: "https://example.test/path",
            headers: ["content-type": "application/json"],
            body: untouchedBody
        ))
        #expect(untouched.body == untouchedBody)
    }

    @Test("extends default header redaction and allow lists and composes redactors")
    func extendsHeaderRedactionAndComposes() {
        let base = Redactor.make(RedactOptions(
            headers: ["x-custom-token"],
            allowRequestHeaders: ["anthropic-version", "x-custom-token"]
        ))
        let composed = Redactor.compose(
            base.asPartial(),
            PartialRedactor(request: { snap in
                RequestSnapshot(
                    method: snap.method,
                    url: snap.url,
                    headers: snap.headers,
                    body: snap.body.replacing("usr_12345", with: "usr_redacted")
                )
            })
        )
        let result = composed.request(RequestSnapshot(
            method: "POST",
            url: "https://example.test/path",
            headers: [
                "authorization": "Bearer secret",
                "content-type": "application/json",
                "anthropic-version": "2023-06-01",
                "x-custom-token": "secret",
            ],
            body: "hello usr_12345"
        ))
        #expect(result.headers == [
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
            "x-custom-token": "[REDACTED]",
        ])
        #expect(result.body == "hello usr_redacted")
    }

    @Test("comparison helpers canonicalize JSON, detect records, and scrub safeText")
    func comparisonHelpers() throws {
        let a = try #require(jsonBody(#"{"b":1,"a":{"y":2,"x":3}}"#))
        let b = try #require(jsonBody(#"{"a":{"x":3,"y":2},"b":1}"#))
        #expect(isJsonRecord(a))
        #expect(!isJsonRecord(jsonBody("[1,2,3]")))
        #expect(jsonBody("not-json") == nil)
        #expect(canonicalizeJson(a) == canonicalizeJson(b))

        let env = DictionaryEnvironment(variables: [:])
        #expect(safeText(nil as PureJSONValue?, environment: env) == "undefined")
        #expect(safeText("Bearer abcdefghijklmnopqrstuvwxyz1234", environment: env) == "\"[REDACTED]\"")

        let longText = String(repeating: "a", count: 400)
        let rendered = safeText(longText, environment: env)
        #expect(rendered.hasSuffix("..."))
        #expect(rendered.utf16.count == 303)
    }
}
