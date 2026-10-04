import Foundation
import XCTest
@testable import SwiftlightPlugins

final class PluginManifestTests: XCTestCase {
    private let minimal = """
    schema_version: 1
    id: example_plugin
    name: Example plugin
    hooks:
      - event: stream.started
        runtime: bash
        script: |
          echo "$SWIFTLIGHT_EVENT"
    """

    private func parse(_ yaml: String) throws -> PluginManifest {
        try PluginManifest.parse(data: Data(yaml.utf8))
    }

    private func manifest(fields: [PluginField] = [], hooks: [PluginHook]? = nil) -> PluginManifest {
        PluginManifest(id: "example_plugin", name: "Example", fields: fields,
                       hooks: hooks ?? [PluginHook(event: .streamStarted, runtime: .bash, script: "true")])
    }

    func testParsesRealYAMLIncludingCommentsFlowListsAndLiteralScripts() throws {
        let parsed = try parse("""
        # A plugin can define fields and exact stream filters.
        schema_version: 1
        id: example_plugin
        name: "Example: plugin"
        description: >-
          Runs when a selected
          game starts.
        fields:
          - id: mode
            label: Mode
            type: choice
            options: ["quiet", "verbose"]
            default: "quiet"
          - id: retry_count
            label: Retry count
            type: integer
            default: "3"
          - id: enabled
            label: Enabled
            type: boolean
            default: "true"
            required: true
          - id: token
            label: Token
            type: secret
        hooks:
          - event: stream.started
            host_id: pc_1
            app_id: 42
            app_name: Example Game
            runtime: python
            timeout_seconds: 15
            script: |
              import os
              print(os.environ["SWIFTLIGHT_EVENT"])
          - event: stream.ended
            runtime: swift
            script: 'print("Finished")'
        """)
        XCTAssertEqual(parsed.id, "example_plugin")
        XCTAssertEqual(parsed.name, "Example: plugin")
        XCTAssertEqual(parsed.description, "Runs when a selected game starts.")
        XCTAssertEqual(parsed.fields[0].options, ["quiet", "verbose"])
        XCTAssertEqual(parsed.fields[3].type, .secret)
        XCTAssertEqual(parsed.hooks[0].hostID, "pc_1")
        XCTAssertEqual(parsed.hooks[0].appID, 42)
        XCTAssertEqual(parsed.hooks[0].timeoutSeconds, 15)
        XCTAssertTrue(parsed.hooks[0].script.contains("import os\nprint("))
        XCTAssertEqual(parsed.hooks[1].runtime, .swift)
        XCTAssertEqual(try parsed.validatedValues([:]), ["mode": "quiet", "retry_count": "3", "enabled": "true"])
    }

    func testAppliesMissingOptionalDefaults() throws {
        let parsed = try parse(minimal)
        XCTAssertNil(parsed.description)
        XCTAssertTrue(parsed.fields.isEmpty)
        XCTAssertEqual(parsed.hooks[0].timeoutSeconds, 30)
        XCTAssertNil(parsed.hooks[0].hostID)
        XCTAssertEqual(try parsed.validatedValues([:]), [:])
    }

    func testShippedExamplesParseThroughProductionSchemaWithoutSecretDefaults() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let examples = root.appendingPathComponent("docs/examples/plugins")
        let homeAssistant = try PluginManifest.parse(data: Data(contentsOf: examples.appendingPathComponent("home_assistant.yaml")))
        let virtualHere = try PluginManifest.parse(data: Data(contentsOf: examples.appendingPathComponent("virtual_here.yaml")))
        XCTAssertEqual(homeAssistant.id, "home_assistant")
        XCTAssertEqual(virtualHere.id, "virtual_here")
        XCTAssertTrue(homeAssistant.fields.contains { $0.id == "start_url" && $0.type == .secret && $0.required })
        for example in [homeAssistant, virtualHere] {
            XCTAssertTrue(example.fields.filter { $0.type == .secret }.allSatisfy { $0.defaultValue == nil })
            XCTAssertFalse(example.hooks.isEmpty)
        }
    }

    func testCodableRoundTripPreservesDefinitionAndContext() throws {
        let parsed = try parse(minimal)
        XCTAssertEqual(try JSONDecoder().decode(PluginManifest.self, from: JSONEncoder().encode(parsed)), parsed)
        let context = PluginStreamContext(sessionID: "session", hostID: "host", hostName: "Host", appID: 3,
                                          appName: "Game", endReason: "disconnected")
        XCTAssertEqual(try JSONDecoder().decode(PluginStreamContext.self, from: JSONEncoder().encode(context)), context)
    }

    func testMatchesAnyHostAndRequiresEveryProvidedFilter() {
        let context = PluginStreamContext(sessionID: "session", hostID: "host", hostName: "Host", appID: 3, appName: "Game")
        let any = PluginHook(event: .streamStarted, runtime: .bash, script: "true")
        XCTAssertTrue(any.matches(event: .streamStarted, context: context))
        XCTAssertFalse(any.matches(event: .streamEnded, context: context))
        let exact = PluginHook(event: .streamStarted, hostID: "host", appID: 3, appName: "Game", runtime: .bash, script: "true")
        XCTAssertTrue(exact.matches(event: .streamStarted, context: context))
        var other = context
        other.hostID = "other"
        XCTAssertFalse(exact.matches(event: .streamStarted, context: other))
        other = context
        other.appID = 4
        XCTAssertFalse(exact.matches(event: .streamStarted, context: other))
        other = context
        other.appName = "game"
        XCTAssertFalse(exact.matches(event: .streamStarted, context: other))
        other = context
        other.hostName = "Renamed Host"
        other.endReason = "failed"
        XCTAssertTrue(exact.matches(event: .streamStarted, context: other))
    }

    func testRejectsUnknownKeysAtEverySchemaLevel() {
        XCTAssertThrowsError(try parse(minimal + "\nextra: true"))
        XCTAssertThrowsError(try parse(minimal.replacingOccurrences(of: "runtime: bash", with: "runtime: bash\n    extra: true")))
        XCTAssertThrowsError(try parse(minimal + """

        fields:
          - id: mode
            label: Mode
            type: string
            extra: true
        """))
    }

    func testRejectsDuplicateKeysAndFieldIDs() {
        XCTAssertThrowsError(try parse(minimal + "\nname: Replacement"))
        let field = PluginField(id: "mode", label: "Mode", type: .string)
        XCTAssertThrowsError(try manifest(fields: [field, field]).validate())
    }

    func testRejectsUnsafeAndCaseCollidingIdentifiers() {
        for identifier in ["MODE", "9mode", "mode-value", "mode value", "mode\nvalue", "é", String(repeating: "a", count: 65)] {
            XCTAssertThrowsError(try manifest(fields: [PluginField(id: identifier, label: "Mode", type: .string)]).validate())
        }
        XCTAssertThrowsError(try parse(minimal.replacingOccurrences(of: "example_plugin", with: "Example")))
    }

    func testRejectsUnsupportedSchemaEventAndRuntime() {
        XCTAssertThrowsError(try parse(minimal.replacingOccurrences(of: "schema_version: 1", with: "schema_version: 2")))
        XCTAssertThrowsError(try parse(minimal.replacingOccurrences(of: "stream.started", with: "stream.paused")))
        XCTAssertThrowsError(try parse(minimal.replacingOccurrences(of: "runtime: bash", with: "runtime: ruby")))
    }

    func testRejectsImplicitBooleanAndNumericStringDefaults() {
        for defaultValue in ["true", "3", "null", "1.5"] {
            XCTAssertThrowsError(try parse(minimal + """

            fields:
              - id: option
                label: Option
                type: string
                default: \(defaultValue)
            """))
        }
        XCTAssertNoThrow(try parse(minimal + """

        fields:
          - id: option
            label: Option
            type: string
            default: "true"
        """))
    }

    func testRequiresCanonicalYAMLPrimitiveTypes() {
        XCTAssertThrowsError(try parse(minimal.replacingOccurrences(of: "schema_version: 1", with: "schema_version: '1'")))
        XCTAssertThrowsError(try parse(minimal + """

        fields:
          - id: option
            label: Option
            type: string
            required: yes
        """))
        XCTAssertThrowsError(try parse(minimal.replacingOccurrences(of: "runtime: bash", with: "runtime: bash\n    app_id: 0x2a")))
    }

    func testRequiredValuesDefaultsAndOptionalEmptyValues() throws {
        let definition = manifest(fields: [
            PluginField(id: "token", label: "Token", type: .secret, required: true),
            PluginField(id: "mode", label: "Mode", type: .string, defaultValue: "normal"),
            PluginField(id: "count", label: "Count", type: .integer),
            PluginField(id: "enabled", label: "Enabled", type: .boolean)
        ])
        XCTAssertThrowsError(try definition.validatedValues([:]))
        XCTAssertThrowsError(try definition.validatedValues(["token": ""]))
        XCTAssertEqual(try definition.validatedValues(["token": "private", "mode": "", "count": "", "enabled": ""]),
                       ["token": "private", "mode": "normal"])
        XCTAssertThrowsError(try definition.validatedValues(["token": "private", "unknown": "unexpected"]))
    }

    func testSecretDefaultsAreNotPersistedInDefinitions() {
        XCTAssertThrowsError(try manifest(fields: [PluginField(id: "token", label: "Token", type: .secret,
                                                              defaultValue: "secret")]).validate())
    }

    func testValidatesConfiguredTypesWithoutCoercion() throws {
        let definition = manifest(fields: [
            PluginField(id: "enabled", label: "Enabled", type: .boolean),
            PluginField(id: "count", label: "Count", type: .integer),
            PluginField(id: "mode", label: "Mode", type: .choice, options: ["quiet", "verbose"])
        ])
        XCTAssertEqual(try definition.validatedValues(["enabled": "false", "count": "-42", "mode": "quiet"]),
                       ["enabled": "false", "count": "-42", "mode": "quiet"])
        for value in ["yes", "1", "TRUE"] { XCTAssertThrowsError(try definition.validatedValues(["enabled": value])) }
        for value in ["1.5", "0x10", " 3", "9223372036854775808", "-"] {
            XCTAssertThrowsError(try definition.validatedValues(["count": value]))
        }
        XCTAssertThrowsError(try definition.validatedValues(["mode": "Quiet"]))
    }

    func testRejectsInvalidChoicesAndDefaults() {
        XCTAssertThrowsError(try manifest(fields: [PluginField(id: "mode", label: "Mode", type: .choice)]).validate())
        XCTAssertThrowsError(try manifest(fields: [PluginField(id: "mode", label: "Mode", type: .choice, options: ["a", "a"])]).validate())
        XCTAssertThrowsError(try manifest(fields: [PluginField(id: "mode", label: "Mode", type: .string, options: ["a"])]).validate())
        XCTAssertThrowsError(try manifest(fields: [PluginField(id: "mode", label: "Mode", type: .choice,
                                                              defaultValue: "b", options: ["a"])]).validate())
    }

    func testRejectsAliasesAnchorsExplicitTagsAndMultipleDocuments() {
        XCTAssertThrowsError(try parse(minimal.replacingOccurrences(of: "name: Example plugin", with: "name: &name Example plugin")))
        XCTAssertThrowsError(try parse(minimal.replacingOccurrences(of: "name: Example plugin", with: "name: *name")))
        XCTAssertThrowsError(try parse(minimal.replacingOccurrences(of: "name: Example plugin", with: "name: !!str Example plugin")))
        XCTAssertThrowsError(try parse(minimal + "\n---\n" + minimal))
        // Script metacharacters are scalar content, not YAML anchors or aliases.
        XCTAssertNoThrow(try parse(minimal.replacingOccurrences(of: "echo \"$SWIFTLIGHT_EVENT\"", with: "echo '*' '&' '[[' '#'")))
    }

    func testRejectsDeepOrLargeYAMLBeforeConstructingRecursiveNodes() {
        XCTAssertThrowsError(try parse("deep: " + String(repeating: "[", count: 20_000)
                                     + "value" + String(repeating: "]", count: 20_000)))
        XCTAssertThrowsError(try parse("nodes: [" + Array(repeating: "x", count: 4097).joined(separator: ",") + "]"))
        XCTAssertThrowsError(try PluginManifest.parse(data: Data(repeating: 32, count: PluginManifest.maximumByteCount + 1)))
        XCTAssertThrowsError(try PluginManifest.parse(data: Data([0xff])))
        XCTAssertThrowsError(try PluginManifest.parse(data: Data()))
    }

    func testRejectsExcessFieldHookAndScriptLimits() {
        let fields = (0..<33).map { PluginField(id: "field_\($0)", label: "Field", type: .string) }
        XCTAssertThrowsError(try manifest(fields: fields).validate())
        let hook = PluginHook(event: .streamStarted, runtime: .bash, script: "true")
        XCTAssertThrowsError(try manifest(hooks: Array(repeating: hook, count: 17)).validate())
        XCTAssertThrowsError(try manifest(hooks: []).validate())
        XCTAssertThrowsError(try manifest(hooks: [PluginHook(event: .streamStarted, runtime: .bash,
                                                            script: String(repeating: "x", count: PluginManifest.maximumScriptByteCount + 1))]).validate())
        for timeout in [0, 301] {
            XCTAssertThrowsError(try manifest(hooks: [PluginHook(event: .streamStarted, runtime: .bash,
                                                               script: "true", timeoutSeconds: timeout)]).validate())
        }
    }

    func testRejectsNullCharactersAndConfigurationByteLimits() {
        XCTAssertThrowsError(try manifest(hooks: [PluginHook(event: .streamStarted, runtime: .bash, script: "echo\0x")]).validate())
        let field = PluginField(id: "value", label: "Value", type: .string)
        XCTAssertThrowsError(try manifest(fields: [field]).validatedValues(["value": "\0"]))
        XCTAssertThrowsError(try manifest(fields: [field]).validatedValues(["value": String(repeating: "x", count: 4097)]))
        let fields = (0..<17).map { PluginField(id: "field_\($0)", label: "Field", type: .string) }
        let values = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, String(repeating: "x", count: 4096)) })
        XCTAssertThrowsError(try manifest(fields: fields).validatedValues(values))
    }

    func testMalformedYAMLErrorDoesNotExposeSourceOrSecrets() {
        XCTAssertThrowsError(try parse("name: private-secret\nbroken: [")) { error in
            XCTAssertTrue(error is PluginValidationError)
            XCTAssertFalse(error.localizedDescription.contains("private-secret"))
            XCTAssertFalse(error.localizedDescription.contains("broken"))
        }
    }
}
