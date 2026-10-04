import Foundation
import Yams
// CYaml is the libyaml module shipped by the pinned Yams product. Its event
// parser lets us enforce limits before Yams recursively constructs a tree.
internal import CYaml

public enum PluginEvent: String, Codable, Sendable, CaseIterable {
    case streamStarted = "stream.started"
    case streamEnded = "stream.ended"
}

public enum PluginRuntime: String, Codable, Sendable, CaseIterable {
    case bash, python, swift
}

public enum PluginFieldType: String, Codable, Sendable, CaseIterable {
    case string, secret, boolean, integer, choice
}

public struct PluginStreamContext: Codable, Sendable, Equatable {
    public var sessionID: String
    public var hostID: String
    public var hostName: String
    public var appID: Int
    public var appName: String
    public var endReason: String?

    public init(sessionID: String, hostID: String, hostName: String, appID: Int,
                appName: String, endReason: String? = nil) {
        self.sessionID = sessionID
        self.hostID = hostID
        self.hostName = hostName
        self.appID = appID
        self.appName = appName
        self.endReason = endReason
    }
}

public struct PluginField: Codable, Sendable, Equatable {
    public var id: String
    public var label: String
    public var type: PluginFieldType
    public var description: String?
    public var defaultValue: String?
    public var required: Bool
    public var options: [String]

    public init(id: String, label: String, type: PluginFieldType,
                description: String? = nil, defaultValue: String? = nil,
                required: Bool = false, options: [String] = []) {
        self.id = id
        self.label = label
        self.type = type
        self.description = description
        self.defaultValue = defaultValue
        self.required = required
        self.options = options
    }

    enum CodingKeys: String, CodingKey {
        case id, label, type, description, required, options
        case defaultValue = "default"
    }
}

public struct PluginHook: Codable, Sendable, Equatable {
    public var event: PluginEvent
    public var hostID: String?
    public var appID: Int?
    public var appName: String?
    public var runtime: PluginRuntime
    public var script: String
    public var timeoutSeconds: Int

    public init(event: PluginEvent, hostID: String? = nil, appID: Int? = nil,
                appName: String? = nil, runtime: PluginRuntime, script: String,
                timeoutSeconds: Int = 30) {
        self.event = event
        self.hostID = hostID
        self.appID = appID
        self.appName = appName
        self.runtime = runtime
        self.script = script
        self.timeoutSeconds = timeoutSeconds
    }

    /// All supplied filters must match exactly. No filters matches any stream.
    public func matches(event: PluginEvent, context: PluginStreamContext) -> Bool {
        self.event == event
            && (hostID == nil || hostID == context.hostID)
            && (appID == nil || appID == context.appID)
            && (appName == nil || appName == context.appName)
    }

    enum CodingKeys: String, CodingKey {
        case event, runtime, script
        case hostID = "host_id"
        case appID = "app_id"
        case appName = "app_name"
        case timeoutSeconds = "timeout_seconds"
    }
}

/// A reviewed plugin definition. Parsing does not fetch files or execute code.
public struct PluginManifest: Codable, Sendable, Equatable {
    public static let maximumByteCount = 256 * 1024
    public static let maximumScriptByteCount = 64 * 1024
    public static let maximumFieldValueByteCount = 4 * 1024

    public var schemaVersion: Int
    public var id: String
    public var name: String
    public var description: String?
    public var fields: [PluginField]
    public var hooks: [PluginHook]

    public init(schemaVersion: Int = 1, id: String, name: String, description: String? = nil,
                fields: [PluginField] = [], hooks: [PluginHook]) {
        self.schemaVersion = schemaVersion
        self.id = id
        self.name = name
        self.description = description
        self.fields = fields
        self.hooks = hooks
    }

    enum CodingKeys: String, CodingKey {
        case id, name, description, fields, hooks
        case schemaVersion = "schema_version"
    }

    public static func parse(data: Data) throws -> PluginManifest {
        guard !data.isEmpty, data.count <= maximumByteCount else {
            throw PluginValidationError.invalidManifest("The YAML file must be between 1 byte and 256 KiB.")
        }
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw PluginValidationError.invalidManifest("The YAML file must use UTF-8 encoding.")
        }
        try preflight(data: data)
        let root: Node
        do {
            guard let parsed = try Yams.compose(yaml: yaml, .default, .default, .utf8) else {
                throw PluginValidationError.invalidManifest("The YAML file must contain a plugin definition.")
            }
            root = parsed
        } catch let error as PluginValidationError {
            throw error
        } catch {
            // Parser descriptions include document excerpts. Never pass them to
            // the UI or logs: plugin source can contain credentials.
            throw PluginValidationError.invalidManifest("The file is not valid YAML, or contains duplicate keys.")
        }
        let manifest = try decode(root)
        try manifest.validate()
        return manifest
    }

    /// Also validate persisted or programmatically constructed definitions.
    public func validate() throws {
        guard schemaVersion == 1 else {
            throw PluginValidationError.invalidManifest("Only plugin schema_version 1 is supported.")
        }
        guard Self.isIdentifier(id) else {
            throw PluginValidationError.invalidManifest("Plugin IDs must be lowercase snake_case, with at most 64 characters.")
        }
        try Self.checkText(name, maximum: 256, emptyAllowed: false)
        if let description { try Self.checkText(description, maximum: 4 * 1024) }
        guard fields.count <= 32, (1...16).contains(hooks.count) else {
            throw PluginValidationError.invalidManifest("A plugin permits at most 32 fields and requires 1 to 16 hooks.")
        }
        var identifiers = Set<String>()
        for field in fields {
            guard Self.isIdentifier(field.id), identifiers.insert(field.id).inserted else {
                throw PluginValidationError.invalidManifest("Field IDs must be unique lowercase snake_case, with at most 64 characters.")
            }
            try Self.checkText(field.label, maximum: 256, emptyAllowed: false)
            if let description = field.description { try Self.checkText(description, maximum: 4 * 1024) }
            if field.type == .secret, field.defaultValue != nil {
                throw PluginValidationError.invalidManifest("Secret fields cannot define defaults; configure them in Swiftlight.")
            }
            if field.type == .choice {
                guard (1...64).contains(field.options.count), Set(field.options).count == field.options.count else {
                    throw PluginValidationError.invalidManifest("Choice fields require 1 to 64 unique options.")
                }
                for option in field.options { try Self.checkText(option, maximum: 256, emptyAllowed: false) }
            } else if !field.options.isEmpty {
                throw PluginValidationError.invalidManifest("Only choice fields may define options.")
            }
            if let defaultValue = field.defaultValue { try Self.validate(value: defaultValue, field: field) }
        }
        for hook in hooks {
            guard (1...300).contains(hook.timeoutSeconds) else {
                throw PluginValidationError.invalidManifest("Hook timeout_seconds must be between 1 and 300.")
            }
            try Self.checkText(hook.script, maximum: Self.maximumScriptByteCount, emptyAllowed: false)
            if let hostID = hook.hostID { try Self.checkText(hostID, maximum: 256, emptyAllowed: false) }
            if let appName = hook.appName { try Self.checkText(appName, maximum: 1024, emptyAllowed: false) }
            if let appID = hook.appID, appID < 0 {
                throw PluginValidationError.invalidManifest("Hook app_id must be nonnegative.")
            }
        }
    }

    /// Returns only declared, valid values with manifest defaults applied.
    /// Optional empty boolean, integer or choice fields are omitted.
    public func validatedValues(_ values: [String: String]) throws -> [String: String] {
        try validate()
        let known = Set(fields.map(\.id))
        guard values.keys.allSatisfy(known.contains) else {
            throw PluginValidationError.invalidManifest("Configuration includes an undeclared field.")
        }
        var result = [String: String]()
        var byteCount = 0
        for field in fields {
            let supplied = values[field.id]
            let value = supplied.flatMap { $0.isEmpty ? nil : $0 } ?? field.defaultValue
            guard let value else {
                if field.required { throw PluginValidationError.invalidValue(fieldID: field.id, reason: "A value is required.") }
                continue
            }
            if value.isEmpty, !field.required, field.type != .string, field.type != .secret { continue }
            try Self.validate(value: value, field: field)
            byteCount += value.utf8.count
            guard byteCount <= 64 * 1024 else {
                throw PluginValidationError.invalidManifest("Plugin configuration must not exceed 64 KiB.")
            }
            result[field.id] = value
        }
        return result
    }
}

/// Messages contain schema facts and validated field IDs, never script/value
/// contents or parser excerpts.
public enum PluginValidationError: Error, LocalizedError, Sendable, Equatable {
    case invalidManifest(String)
    case invalidValue(fieldID: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidManifest(let reason): return reason
        case .invalidValue(let fieldID, let reason): return "Field '\(fieldID)': \(reason)"
        }
    }
}

private extension PluginManifest {
    static func isIdentifier(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count), let first = text.utf8.first,
              (97...122).contains(first) else { return false }
        return text.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
    }

    static func checkText(_ text: String, maximum: Int, emptyAllowed: Bool = true) throws {
        guard text.utf8.count <= maximum, !text.contains("\0"),
              emptyAllowed || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginValidationError.invalidManifest("A text value is empty, contains a null character, or exceeds its schema limit.")
        }
    }

    static func validate(value: String, field: PluginField) throws {
        guard value.utf8.count <= maximumFieldValueByteCount, !value.contains("\0") else {
            throw PluginValidationError.invalidValue(fieldID: field.id, reason: "Values permit at most 4 KiB and cannot contain a null character.")
        }
        if field.required, value.isEmpty {
            throw PluginValidationError.invalidValue(fieldID: field.id, reason: "A value is required.")
        }
        switch field.type {
        case .string, .secret: break
        case .boolean:
            guard value == "true" || value == "false" else {
                throw PluginValidationError.invalidValue(fieldID: field.id, reason: "Use true or false.")
            }
        case .integer:
            let digits = value.hasPrefix("-") ? value.utf8.dropFirst() : value.utf8.dropFirst(0)
            guard !digits.isEmpty, digits.allSatisfy({ (48...57).contains($0) }), Int64(value) != nil else {
                throw PluginValidationError.invalidValue(fieldID: field.id, reason: "Use a decimal 64-bit integer.")
            }
        case .choice:
            guard field.options.contains(value) else {
                throw PluginValidationError.invalidValue(fieldID: field.id, reason: "Choose one of the declared options.")
            }
        }
    }

    static func decode(_ root: Node) throws -> PluginManifest {
        let object = try mapping(root, keys: ["schema_version", "id", "name", "description", "fields", "hooks"])
        let fields = try object["fields"].map { try sequence($0).map(decodeField) } ?? []
        let hooks = try sequence(required("hooks", in: object)).map(decodeHook)
        return PluginManifest(schemaVersion: try integer(required("schema_version", in: object)),
                              id: try string(required("id", in: object)),
                              name: try string(required("name", in: object)),
                              description: try object["description"].map(string), fields: fields, hooks: hooks)
    }

    static func decodeField(_ node: Node) throws -> PluginField {
        let object = try mapping(node, keys: ["id", "label", "type", "description", "default", "required", "options"])
        guard let type = try PluginFieldType(rawValue: string(required("type", in: object))) else {
            throw PluginValidationError.invalidManifest("Unsupported plugin field type.")
        }
        return PluginField(id: try string(required("id", in: object)),
                           label: try string(required("label", in: object)), type: type,
                           description: try object["description"].map(string),
                           defaultValue: try object["default"].map(string),
                           required: try object["required"].map(boolean) ?? false,
                           options: try object["options"].map { try sequence($0).map(string) } ?? [])
    }

    static func decodeHook(_ node: Node) throws -> PluginHook {
        let object = try mapping(node, keys: ["event", "host_id", "app_id", "app_name", "runtime", "script", "timeout_seconds"])
        guard let event = try PluginEvent(rawValue: string(required("event", in: object))),
              let runtime = try PluginRuntime(rawValue: string(required("runtime", in: object))) else {
            throw PluginValidationError.invalidManifest("Unsupported plugin event or runtime.")
        }
        return PluginHook(event: event, hostID: try object["host_id"].map(string),
                          appID: try object["app_id"].map(integer), appName: try object["app_name"].map(string),
                          runtime: runtime, script: try string(required("script", in: object)),
                          timeoutSeconds: try object["timeout_seconds"].map(integer) ?? 30)
    }

    static func mapping(_ node: Node, keys: Set<String>) throws -> [String: Node] {
        guard case .mapping(let mapping) = node else {
            throw PluginValidationError.invalidManifest("Expected a YAML mapping.")
        }
        var result = [String: Node]()
        for pair in mapping {
            let key = try string(pair.key)
            guard keys.contains(key), result[key] == nil else {
                throw PluginValidationError.invalidManifest("The YAML file contains an unknown or duplicate key.")
            }
            result[key] = pair.value
        }
        return result
    }

    static func sequence(_ node: Node) throws -> [Node] {
        guard case .sequence(let sequence) = node else {
            throw PluginValidationError.invalidManifest("Expected a YAML list.")
        }
        return Array(sequence)
    }

    static func required(_ key: String, in object: [String: Node]) throws -> Node {
        guard let node = object[key] else {
            throw PluginValidationError.invalidManifest("The YAML file is missing a required schema key.")
        }
        return node
    }

    static func string(_ node: Node) throws -> String {
        guard case .scalar(let scalar) = node, node.tag == Tag(.str) else {
            throw PluginValidationError.invalidManifest("Expected a YAML string. Quote boolean and numeric field defaults.")
        }
        return scalar.string
    }

    static func integer(_ node: Node) throws -> Int {
        guard case .scalar(let scalar) = node, node.tag == Tag(.int),
              !scalar.string.isEmpty, scalar.string.utf8.allSatisfy({ (48...57).contains($0) }),
              let value = Int(scalar.string) else {
            throw PluginValidationError.invalidManifest("Expected a nonnegative decimal YAML integer.")
        }
        return value
    }

    static func boolean(_ node: Node) throws -> Bool {
        guard case .scalar(let scalar) = node, node.tag == Tag(.bool),
              scalar.string == "true" || scalar.string == "false" else {
            throw PluginValidationError.invalidManifest("Expected a YAML boolean using true or false.")
        }
        return scalar.string == "true"
    }

    /// libyaml reads events iteratively without constructing recursive Node
    /// values, so untrusted source cannot exhaust the Swift stack first.
    static func preflight(data: Data) throws {
        var parser = yaml_parser_t()
        guard yaml_parser_initialize(&parser) == 1 else {
            throw PluginValidationError.invalidManifest("Unable to initialize the YAML parser.")
        }
        defer { yaml_parser_delete(&parser) }
        try data.withUnsafeBytes { bytes in
            let input = bytes.bindMemory(to: UInt8.self)
            yaml_parser_set_encoding(&parser, YAML_UTF8_ENCODING)
            yaml_parser_set_input_string(&parser, input.baseAddress!, input.count)
            var depth = 0
            var nodes = 0
            var documents = 0
            while true {
                var event = yaml_event_t()
                guard yaml_parser_parse(&parser, &event) == 1 else {
                    throw PluginValidationError.invalidManifest("The file is not valid YAML.")
                }
                defer { yaml_event_delete(&event) }
                switch event.type {
                case YAML_STREAM_END_EVENT: return
                case YAML_DOCUMENT_START_EVENT:
                    documents += 1
                    guard documents == 1 else {
                        throw PluginValidationError.invalidManifest("Only one YAML document is permitted.")
                    }
                case YAML_ALIAS_EVENT:
                    throw PluginValidationError.invalidManifest("YAML aliases and anchors are not supported in plugin definitions.")
                case YAML_MAPPING_START_EVENT:
                    guard event.data.mapping_start.anchor == nil, event.data.mapping_start.tag == nil else {
                        throw PluginValidationError.invalidManifest("YAML anchors and explicit tags are not supported in plugin definitions.")
                    }
                    depth += 1
                    nodes += 1
                case YAML_SEQUENCE_START_EVENT:
                    guard event.data.sequence_start.anchor == nil, event.data.sequence_start.tag == nil else {
                        throw PluginValidationError.invalidManifest("YAML anchors and explicit tags are not supported in plugin definitions.")
                    }
                    depth += 1
                    nodes += 1
                case YAML_MAPPING_END_EVENT, YAML_SEQUENCE_END_EVENT: depth -= 1
                case YAML_SCALAR_EVENT:
                    guard event.data.scalar.anchor == nil, event.data.scalar.tag == nil else {
                        throw PluginValidationError.invalidManifest("YAML anchors and explicit tags are not supported in plugin definitions.")
                    }
                    nodes += 1
                default: break
                }
                guard depth <= 16, nodes <= 4096 else {
                    throw PluginValidationError.invalidManifest("The YAML file exceeds its nesting or node limit.")
                }
            }
        }
    }
}
