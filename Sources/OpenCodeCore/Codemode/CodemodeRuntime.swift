import Foundation
import OpenCodePlatform
import OpenCodeSchema
import OpenCodeUtil
import Synchronization

/// Code Mode runtime layer: tools, namespaces, extensions, JSON Schema -> TypeScript renderer,
/// BM25 catalog search, static AST tool scanner (`scanTools`), hooks, resource budgets,
/// OpenAPI spec-to-tools compiler (strictly via `OpenCodePlatform.HTTPTransport`),
/// and console/warning output formatting compatible with `OpenCodeUtil.formatExecuteOutput`.
/// Ports 100% of `packages/codemode/src/codemode/*` (111 symbols).
public enum CodemodeEngine {
    // MARK: - ToolError (src/codemode/tool-error.ts)

    // parity: codemode/src/codemode/tool-error.ts#ToolError [status=implemented hash=54eea5e6e50d]
    public final class ToolError: Error, Sendable, CustomStringConvertible {
        public static let tag = "ToolError"
        public let message: String
        public let underlyingCause: String?

        public init(message: String, cause: String? = nil) {
            self.message = message
            self.underlyingCause = cause
        }

        public var description: String { message }
    }

    // parity: codemode/src/codemode/tool-error.ts#toolError [status=implemented hash=2115db29e5df]
    public static func toolError(_ message: String, cause: Error? = nil) -> ToolError {
        ToolError(message: message, cause: cause.map { String(describing: $0) })
    }

    // MARK: - Tool & Tools & Namespace (src/codemode/tool.ts, tools.ts, namespace.ts)

    public enum Tool {
        // parity: codemode/src/codemode/tool.ts#JsonSchema [status=implemented hash=aad078d779b7]
        public typealias JsonSchema = [String: JSONValue]

        // parity: codemode/src/codemode/tool.ts#SchemaType [status=adapted hash=e9a155f7264b]
        public enum SchemaType: Sendable {
            case jsonSchema(JsonSchema)
            case validated(schema: JsonSchema, decode: @Sendable (JSONValue) throws -> JSONValue)

            public var rawJsonSchema: JsonSchema {
                switch self {
                case .jsonSchema(let s), .validated(let s, _): return s
                }
            }
        }

        // parity: codemode/src/codemode/tool.ts#ToolContext [status=implemented hash=37fff0cbd965]
        public struct ToolContext: Equatable, Hashable, Sendable, Codable {
            public let key: String

            public init(key: String) {
                self.key = key
            }
        }

        // parity: codemode/src/codemode/tool.ts#ExecuteFn [status=implemented hash=8d4c252c35aa]
        public typealias ExecuteFn = @Sendable (JSONValue, ToolContext) async throws -> JSONValue

        // parity: codemode/src/codemode/tool.ts#Idempotent [status=implemented hash=c5371f5ba9e6]
        public struct Idempotent: Sendable {
            public let tag = "CodeModeIdempotent"
            public let execute: ExecuteFn

            public init(execute: @escaping ExecuteFn) {
                self.execute = execute
            }
        }

        // parity: codemode/src/codemode/tool.ts#DurableOptions [status=implemented hash=cbbfa718d069]
        public struct DurableOptions: Sendable {
            public let start: @Sendable (JSONValue, ToolContext) async throws -> JSONValue
            public let wait: @Sendable (JSONValue, ToolContext) async throws -> JSONValue
            public let cancel: @Sendable (JSONValue) async throws -> Void

            public init(
                start: @escaping @Sendable (JSONValue, ToolContext) async throws -> JSONValue,
                wait: @escaping @Sendable (JSONValue, ToolContext) async throws -> JSONValue,
                cancel: @escaping @Sendable (JSONValue) async throws -> Void
            ) {
                self.start = start
                self.wait = wait
                self.cancel = cancel
            }
        }

        // parity: codemode/src/codemode/tool.ts#Durable [status=implemented hash=b918c76642e7]
        public struct Durable: Sendable {
            public let tag = "CodeModeDurable"
            public let start: @Sendable (JSONValue, ToolContext) async throws -> JSONValue
            public let wait: @Sendable (JSONValue, ToolContext) async throws -> JSONValue
            public let cancel: @Sendable (JSONValue) async throws -> Void

            public init(options: DurableOptions) {
                self.start = options.start
                self.wait = options.wait
                self.cancel = options.cancel
            }
        }

        public enum ExecutionMode: Sendable {
            case standard(ExecuteFn)
            case idempotent(Idempotent)
            case durable(Durable)
        }

        // parity: codemode/src/codemode/tool.ts#Tool [status=implemented hash=b1eded127aee]
        public struct Definition: Sendable {
            public let tag = "CodeModeTool"
            public let description: String
            public let input: SchemaType
            public let freeform: Bool
            public let output: SchemaType?
            public let execute: ExecutionMode

            public init(
                description: String,
                input: SchemaType = .jsonSchema(["type": .string("object")]),
                freeform: Bool = false,
                output: SchemaType? = nil,
                execute: ExecutionMode
            ) {
                self.description = description
                self.input = input
                self.freeform = freeform
                self.output = output
                self.execute = execute
            }
        }

        // parity: codemode/src/codemode/tool.ts#Options [status=implemented hash=a163abca2528]
        public struct Options: Sendable {
            public let description: String
            public let input: SchemaType
            public let freeform: Bool
            public let output: SchemaType?
            public let execute: ExecutionMode

            public init(
                description: String,
                input: SchemaType = .jsonSchema(["type": .string("object")]),
                freeform: Bool = false,
                output: SchemaType? = nil,
                execute: ExecutionMode
            ) {
                self.description = description
                self.input = input
                self.freeform = freeform
                self.output = output
                self.execute = execute
            }

            public init(
                description: String,
                input: JsonSchema = ["type": .string("object")],
                freeform: Bool = false,
                output: JsonSchema? = nil,
                execute: @escaping ExecuteFn
            ) {
                self.description = description
                self.input = .jsonSchema(input)
                self.freeform = freeform
                self.output = output.map { .jsonSchema($0) }
                self.execute = .standard(execute)
            }
        }

        // parity: codemode/src/codemode/tool.ts#isTool [status=implemented hash=8273987a42fd]
        public static func isTool(_ entry: ToolsEntry?) -> Bool {
            if case .tool = entry { return true }
            return false
        }

        // parity: codemode/src/codemode/tool.ts#idempotent [status=implemented hash=2bff51af893b]
        public static func idempotent(_ execute: @escaping ExecuteFn) -> ExecutionMode {
            .idempotent(Idempotent(execute: execute))
        }

        // parity: codemode/src/codemode/tool.ts#durable [status=implemented hash=ce2fffd285af]
        public static func durable(_ options: DurableOptions) -> ExecutionMode {
            .durable(Durable(options: options))
        }

        // parity: codemode/src/codemode/tool.ts#make [status=implemented hash=a7213db0d912]
        public static func make(_ options: Options) -> Definition {
            Definition(
                description: options.description,
                input: options.input,
                freeform: options.freeform,
                output: options.output,
                execute: options.execute
            )
        }
    }

    public indirect enum ToolsEntry: Sendable {
        case tool(Tool.Definition)
        case namespace(Namespace.Definition)
        case group([String: ToolsEntry])
    }

    // parity: codemode/src/codemode/tools.ts#Tools [status=implemented hash=3798f453b5ba]
    public typealias Tools = [String: ToolsEntry]

    public enum Namespace {
        // parity: codemode/src/codemode/namespace.ts#Namespace [status=implemented hash=97faa5cea137]
        public struct Definition: Sendable {
            public let tag = "CodeModeNamespace"
            public let description: String?
            public let tools: Tools

            public init(description: String? = nil, tools: Tools) {
                self.description = description
                self.tools = tools
            }
        }

        // parity: codemode/src/codemode/namespace.ts#Options [status=implemented hash=b1177bc53b5b]
        public struct Options: Sendable {
            public let description: String?
            public let tools: Tools

            public init(description: String? = nil, tools: Tools) {
                self.description = description
                self.tools = tools
            }
        }

        // parity: codemode/src/codemode/namespace.ts#isNamespace [status=implemented hash=fbaa6f2f3a3a]
        public static func isNamespace(_ entry: ToolsEntry?) -> Bool {
            if case .namespace = entry { return true }
            return false
        }

        // parity: codemode/src/codemode/namespace.ts#make [status=implemented hash=a8d4cc09b31c]
        public static func make(_ options: Options) -> Definition {
            Definition(description: options.description, tools: options.tools)
        }
    }

    // MARK: - Extensions (src/codemode/extension.ts)

    public enum Extension {
        // parity: codemode/src/codemode/extension.ts#Snapshot [status=implemented hash=d8607566a4b1]
        public typealias Snapshot = CodemodeLanguage.Host.Snapshot

        // parity: codemode/src/codemode/extension.ts#Services [status=implemented hash=5db9d2c08cbd]
        public struct Services: Sendable {
            public init() {}
        }

        public final class MarkedFunction: Sendable {
            public let fn: @Sendable ([CodemodeLanguage.Value], CodemodeLanguage.Builtins) async throws -> CodemodeLanguage.Value
            public let isAsync: Bool
            public let isConstructible: Bool

            public init(
                isAsync: Bool = false,
                isConstructible: Bool = false,
                fn: @escaping @Sendable ([CodemodeLanguage.Value], CodemodeLanguage.Builtins) async throws -> CodemodeLanguage.Value
            ) {
                self.isAsync = isAsync
                self.isConstructible = isConstructible
                self.fn = fn
            }
        }

        public indirect enum GlobalItem: Sendable {
            case function(MarkedFunction)
            case object([String: GlobalItem])
            case constant(CodemodeLanguage.Value)
        }

        // parity: codemode/src/codemode/extension.ts#Extension [status=implemented hash=769ff6810793]
        public struct Definition: Sendable {
            public let name: String
            public let globals: [String: GlobalItem]
            public let modules: [String: String]?
            public let snapshot: Snapshot?

            public init(
                name: String,
                globals: [String: GlobalItem],
                modules: [String: String]? = nil,
                snapshot: Snapshot? = nil
            ) {
                self.name = name
                self.globals = globals
                self.modules = modules
                self.snapshot = snapshot
            }
        }

        // parity: codemode/src/codemode/extension.ts#make [status=implemented hash=953b7e0ec350]
        public static func make(
            name: String,
            globals: [String: GlobalItem],
            modules: [String: String]? = nil,
            snapshot: Snapshot? = nil
        ) -> Definition {
            Definition(name: name, globals: globals, modules: modules, snapshot: snapshot)
        }

        // parity: codemode/src/codemode/extension.ts#async [status=implemented hash=cb903b56af54]
        public static func async(
            _ fn: @escaping @Sendable ([CodemodeLanguage.Value], CodemodeLanguage.Builtins) async throws -> CodemodeLanguage.Value
        ) -> MarkedFunction {
            MarkedFunction(isAsync: true, isConstructible: false, fn: fn)
        }

        // parity: codemode/src/codemode/extension.ts#isAsync [status=implemented hash=685592d9b480]
        public static func isAsync(_ fn: MarkedFunction) -> Bool {
            fn.isAsync
        }

        // parity: codemode/src/codemode/extension.ts#constructible [status=implemented hash=4ed7ee0cfcae]
        public static func constructible(
            _ fn: @escaping @Sendable ([CodemodeLanguage.Value], CodemodeLanguage.Builtins) async throws -> CodemodeLanguage.Value
        ) -> MarkedFunction {
            MarkedFunction(isAsync: false, isConstructible: true, fn: fn)
        }

        // parity: codemode/src/codemode/extension.ts#isConstructible [status=implemented hash=dcedae430aa3]
        public static func isConstructible(_ fn: MarkedFunction) -> Bool {
            fn.isConstructible
        }
    }

    // MARK: - Tool Schema Renderer (src/codemode/tool-schema.ts)

    public enum ToolSchema {
        // parity: codemode/src/codemode/tool-schema.ts#identifierSegment [status=implemented hash=dac2671b1263]
        public static let identifierSegmentPattern: String = "^[A-Za-z_$][A-Za-z0-9_$]*$"

        public static func isIdentifierSegment(_ text: String) -> Bool {
            guard let first = text.unicodeScalars.first else { return false }
            let isStart = (first.value >= 0x41 && first.value <= 0x5A)
                || (first.value >= 0x61 && first.value <= 0x7A)
                || first == "_" || first == "$"
            guard isStart else { return false }
            for sc in text.unicodeScalars.dropFirst() {
                let ok = (sc.value >= 0x41 && sc.value <= 0x5A)
                    || (sc.value >= 0x61 && sc.value <= 0x7A)
                    || (sc.value >= 0x30 && sc.value <= 0x39)
                    || sc == "_" || sc == "$"
                if !ok { return false }
            }
            return true
        }

        private static func renderKey(_ name: String) -> String {
            isIdentifierSegment(name) ? name : CodemodeLanguage.jsonEscapeString(name)
        }

        private static func renderLiteral(_ value: JSONValue) -> String {
            CodemodeLanguage.serializeJsonCompact(value)
        }

        private static func definitionName(_ ref: String) -> String? {
            if ref.hasPrefix("#/$defs/") { return String(ref.dropFirst("#/$defs/".count)) }
            if ref.hasPrefix("#/definitions/") { return String(ref.dropFirst("#/definitions/".count)) }
            return nil
        }

        private static func docTags(_ schema: Tool.JsonSchema) -> [String] {
            var tags: [String] = []
            if case .bool(true) = schema["deprecated"] { tags.append("@deprecated") }
            if let def = schema["default"] { tags.append("@default \(renderLiteral(def))") }
            if case .string(let fmt) = schema["format"] { tags.append("@format \(fmt)") }
            let isInt = schema["type"] == .string("integer")
            if isInt { tags.append("@integer") }
            if let min = numberOf(schema["minimum"]), !(isInt && min == -9_007_199_254_740_991) { tags.append("@minimum \(CodemodeLanguage.formatJSNumber(min))") }
            if let max = numberOf(schema["maximum"]), !(isInt && max == 9_007_199_254_740_991) { tags.append("@maximum \(CodemodeLanguage.formatJSNumber(max))") }
            if let emin = numberOf(schema["exclusiveMinimum"]) { tags.append("@exclusiveMinimum \(CodemodeLanguage.formatJSNumber(emin))") }
            if let emax = numberOf(schema["exclusiveMaximum"]) { tags.append("@exclusiveMaximum \(CodemodeLanguage.formatJSNumber(emax))") }
            if let mul = numberOf(schema["multipleOf"]) { tags.append("@multipleOf \(CodemodeLanguage.formatJSNumber(mul))") }
            if let minL = numberOf(schema["minLength"]) { tags.append("@minLength \(CodemodeLanguage.formatJSNumber(minL))") }
            if let maxL = numberOf(schema["maxLength"]) { tags.append("@maxLength \(CodemodeLanguage.formatJSNumber(maxL))") }
            if case .string(let pat) = schema["pattern"] { tags.append("@pattern \(pat)") }
            if let minI = numberOf(schema["minItems"]) { tags.append("@minItems \(CodemodeLanguage.formatJSNumber(minI))") }
            if let maxI = numberOf(schema["maxItems"]) { tags.append("@maxItems \(CodemodeLanguage.formatJSNumber(maxI))") }
            if case .bool(true) = schema["uniqueItems"] { tags.append("@uniqueItems true") }
            return tags
        }

        private static func numberOf(_ val: JSONValue?) -> Double? {
            switch val {
            case .int(let i): return Double(i)
            case .double(let d): return d
            default: return nil
            }
        }

        private static func jsdoc(_ schema: Tool.JsonSchema, pad: String) -> String {
            let summary = docTags(schema).joined(separator: " ")
            let rawDesc: String = if case .string(let d) = schema["description"] { d } else { "" }
            var lines = rawDesc.split(separator: "\n", omittingEmptySubsequences: false).map {
                String($0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            }
            while let f = lines.first, f.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
            while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
            var content: [String]
            if !summary.isEmpty && lines.count == 1 {
                let first = lines[0]
                let inline = "\(first)\(first.hasSuffix(".") ? "" : ".") \(summary)"
                if pad.count + inline.count + 7 <= 120 {
                    content = [inline]
                } else {
                    content = lines + [summary]
                }
            } else {
                content = lines + (summary.isEmpty ? [] : [summary])
            }
            if content.isEmpty { return "" }
            let escaped = content.map { $0.replacingOccurrences(of: "*/", with: "* /") }
            if escaped.count == 1 && pad.count + escaped[0].count + 7 <= 120 {
                return "\(pad)/** \(escaped[0]) */\n"
            }
            let body = escaped.map { line in "\(pad) *\(line.isEmpty ? "" : " \(line)")" }.joined(separator: "\n")
            return "\(pad)/**\n\(body)\n\(pad) */\n"
        }

        private static func renderSchema(
            _ schema: Tool.JsonSchema,
            definitions: [String: Tool.JsonSchema],
            pretty: Bool,
            depth: Int = 0,
            seen: Set<String> = []
        ) -> String {
            if depth > 8 { return "unknown" }
            var defs = definitions
            if case .object(let d) = schema["definitions"] {
                for (k, v) in d { if case .object(let o) = v { defs[k] = o } }
            }
            if case .object(let d) = schema["$defs"] {
                for (k, v) in d { if case .object(let o) = v { defs[k] = o } }
            }
            if case .string(let ref) = schema["$ref"] {
                guard let name = definitionName(ref), let target = defs[name], !seen.contains(name) else {
                    return "unknown"
                }
                return renderSchema(target, definitions: defs, pretty: pretty, depth: depth, seen: seen.union([name]))
            }
            if let c = schema["const"] { return renderLiteral(c) }
            if case .array(let en) = schema["enum"] {
                return en.map(renderLiteral).joined(separator: " | ")
            }
            if case .array(let alts) = schema["anyOf"] ?? schema["oneOf"] {
                let members = alts.map { item -> String in
                    if case .object(let sub) = item {
                        return renderSchema(sub, definitions: defs, pretty: pretty, depth: depth + 1, seen: seen)
                    }
                    return "unknown"
                }
                if members.contains("unknown") { return "unknown" }
                return members.joined(separator: " | ")
            }
            if case .array(let all) = schema["allOf"] {
                let members = all.compactMap { item -> String? in
                    guard case .object(let sub) = item else { return nil }
                    let r = renderSchema(sub, definitions: defs, pretty: pretty, depth: depth + 1, seen: seen)
                    return r == "unknown" ? nil : r
                }
                if members.isEmpty { return "unknown" }
                return members.joined(separator: " & ")
            }
            if case .array(let typeList) = schema["type"] {
                return typeList.map { t in
                    var copy = schema
                    copy["type"] = t
                    return renderSchema(copy, definitions: defs, pretty: pretty, depth: depth + 1, seen: seen)
                }.joined(separator: " | ")
            }
            if case .string(let t) = schema["type"] {
                switch t {
                case "string": return "string"
                case "number", "integer": return "number"
                case "boolean": return "boolean"
                case "null": return "null"
                case "array":
                    let itemSchema: Tool.JsonSchema = if case .object(let s) = schema["items"] { s } else { [:] }
                    return "Array<\(renderSchema(itemSchema, definitions: defs, pretty: pretty, depth: depth + 1, seen: seen))>"
                default: break
                }
            }
            if schema["type"] == .string("object") || schema["properties"] != nil {
                var reqSet = Set<String>()
                if case .array(let req) = schema["required"] {
                    for r in req { if case .string(let s) = r { reqSet.insert(s) } }
                }
                var props: [(String, Tool.JsonSchema)] = []
                if case .object(let pDict) = schema["properties"] {
                    for k in pDict.keys.sorted() {
                        if case .object(let sub) = pDict[k] { props.append((k, sub)) }
                    }
                }
                let indexType: String?
                if case .object(let add) = schema["additionalProperties"] {
                    indexType = renderSchema(add, definitions: defs, pretty: pretty, depth: depth + 1, seen: seen)
                } else {
                    indexType = nil
                }
                func renderField(_ name: String, _ val: Tool.JsonSchema) -> String {
                    "\(renderKey(name))\(reqSet.contains(name) ? "" : "?"): \(renderSchema(val, definitions: defs, pretty: pretty, depth: depth + 1, seen: seen))"
                }
                if !pretty {
                    var fields = props.map { renderField($0.0, $0.1) }
                    if let indexType { fields.append("[key: string]: \(indexType)") }
                    return fields.isEmpty ? "{}" : "{ \(fields.joined(separator: "; ")) }"
                }
                if props.isEmpty && indexType == nil { return "{}" }
                let pad = String(repeating: "  ", count: depth + 1)
                var lines = props.map { "\(jsdoc($0.1, pad: pad))\(pad)\(renderField($0.0, $0.1))," }
                if let indexType { lines.append("\(pad)[key: string]: \(indexType),") }
                return "{\n\(lines.joined(separator: "\n"))\n\(String(repeating: "  ", count: depth))}"
            }
            return "unknown"
        }

        // parity: codemode/src/codemode/tool-schema.ts#toTypeScript [status=implemented hash=49e8a2205e3d]
        public static func toTypeScript(_ schema: Tool.SchemaType, decoded: Bool = false, pretty: Bool = false) -> String {
            _ = decoded
            return jsonSchemaToTypeScript(schema.rawJsonSchema, pretty: pretty)
        }

        // parity: codemode/src/codemode/tool-schema.ts#jsonSchemaToTypeScript [status=implemented hash=0bb6b289f1ff]
        public static func jsonSchemaToTypeScript(_ schema: Tool.JsonSchema, pretty: Bool = false) -> String {
            renderSchema(schema, definitions: [:], pretty: pretty)
        }

        // parity: codemode/src/codemode/tool-schema.ts#InputProperty [status=implemented hash=00050fd3cea7]
        public struct InputProperty: Equatable, Hashable, Sendable, Codable {
            public let name: String
            public let description: String?
            public let required: Bool

            public init(name: String, description: String?, required: Bool) {
                self.name = name
                self.description = description
                self.required = required
            }
        }

        // parity: codemode/src/codemode/tool-schema.ts#inputProperties [status=implemented hash=b25c31117ad4]
        public static func inputProperties(_ tool: Tool.Definition) -> [InputProperty] {
            let schema = tool.input.rawJsonSchema
            var req = Set<String>()
            if case .array(let rList) = schema["required"] {
                for r in rList { if case .string(let s) = r { req.insert(s) } }
            }
            guard case .object(let props) = schema["properties"] else { return [] }
            return props.keys.sorted().map { name in
                let desc: String?
                if case .object(let sub) = props[name], case .string(let d) = sub["description"] { desc = d }
                else { desc = nil }
                return InputProperty(name: name, description: desc, required: req.contains(name))
            }
        }

        // parity: codemode/src/codemode/tool-schema.ts#stringParameter [status=implemented hash=d4e46b6c17a1]
        public static func stringParameter(_ tool: Tool.Definition) -> (name: String, signature: String)? {
            guard tool.freeform else { return nil }
            let schema = tool.input.rawJsonSchema
            guard case .object(let props) = schema["properties"], props.count == 1,
                  let (name, rawField) = props.first,
                  case .object(let field) = rawField,
                  field["type"] == .string("string")
            else { return nil }
            if case .array(let req) = schema["required"], req.contains(.string(name)) {
                let label = isIdentifierSegment(name) ? name : "input"
                let type = renderSchema(field, definitions: [:], pretty: false)
                let doc = jsdoc(field, pad: "").replacingOccurrences(of: "\n$", with: " ", options: .regularExpression)
                return (name, "(\(doc)\(label): \(type))")
            }
            return nil
        }

        // parity: codemode/src/codemode/tool-schema.ts#inputTypeScript [status=implemented hash=54d2567e5fc8]
        public static func inputTypeScript(_ tool: Tool.Definition, pretty: Bool = false) -> String {
            toTypeScript(tool.input, decoded: false, pretty: pretty)
        }

        // parity: codemode/src/codemode/tool-schema.ts#isEmptyInput [status=implemented hash=75f08751e5d3]
        public static func isEmptyInput(_ tool: Tool.Definition) -> Bool {
            inputTypeScript(tool, pretty: false) == "{}"
        }

        // parity: codemode/src/codemode/tool-schema.ts#outputTypeScript [status=implemented hash=7a403e794b25]
        public static func outputTypeScript(_ tool: Tool.Definition, pretty: Bool = false) -> String {
            guard let out = tool.output else { return "void" }
            return toTypeScript(out, decoded: true, pretty: pretty)
        }

        // parity: codemode/src/codemode/tool-schema.ts#decodeInput [status=implemented hash=282c6ac89a02]
        public static func decodeInput(_ tool: Tool.Definition, _ value: JSONValue) throws -> JSONValue {
            if case .validated(_, let decode) = tool.input {
                return try decode(value)
            }
            return value
        }

        // parity: codemode/src/codemode/tool-schema.ts#decodeOutput [status=implemented hash=bd1e53f84dfa]
        public static func decodeOutput(_ tool: Tool.Definition, _ value: JSONValue) throws -> JSONValue {
            guard let out = tool.output else { return .null }
            if case .validated(_, let decode) = out {
                return try decode(value)
            }
            return value
        }
    }

    // MARK: - ToolRuntime & BM25 Search (src/codemode/tool-runtime.ts)

    public enum ToolRuntime {
        // parity: codemode/src/codemode/tool-runtime.ts#Services [status=implemented hash=bda32e1f53d4]
        public struct Services: Sendable {
            public init() {}
        }

        // parity: codemode/src/codemode/tool-runtime.ts#ToolCall [status=implemented hash=7ad59e1d3741]
        public struct ToolCall: Equatable, Hashable, Sendable, Codable {
            public let name: String

            public init(name: String) {
                self.name = name
            }
        }

        // parity: codemode/src/codemode/tool-runtime.ts#ToolInvocation [status=implemented hash=4fc8d53b5aa6]
        public struct ToolInvocation: Sendable {
            public let name: String
            public let input: JSONValue
            public let key: String

            public init(name: String, input: JSONValue, key: String) {
                self.name = name
                self.input = input
                self.key = key
            }
        }

        // parity: codemode/src/codemode/tool-runtime.ts#ExtensionInvocation [status=implemented hash=4436469102e0]
        public struct ExtensionInvocation: Sendable {
            public let `extension`: String
            public let name: String
            public let args: [CodemodeLanguage.Value]

            public init(extension ext: String, name: String, args: [CodemodeLanguage.Value]) {
                self.extension = ext
                self.name = name
                self.args = args
            }
        }

        // parity: codemode/src/codemode/tool-runtime.ts#CallResult [status=implemented hash=3da0f02fb325]
        public enum CallResult: Sendable {
            case success(JSONValue)
            case failure(String)
            case interrupted
        }

        // parity: codemode/src/codemode/tool-runtime.ts#Hooks [status=implemented hash=2710feb55d3e]
        public struct Hooks: Sendable {
            public let toolBefore: (@Sendable (ToolInvocation) async throws -> Void)?
            public let toolAfter: (@Sendable (ToolInvocation, CallResult) async -> Void)?
            public let extensionBefore: (@Sendable (ExtensionInvocation) async throws -> Void)?
            public let extensionAfter: (@Sendable (ExtensionInvocation, CallResult) async -> Void)?

            public init(
                toolBefore: (@Sendable (ToolInvocation) async throws -> Void)? = nil,
                toolAfter: (@Sendable (ToolInvocation, CallResult) async -> Void)? = nil,
                extensionBefore: (@Sendable (ExtensionInvocation) async throws -> Void)? = nil,
                extensionAfter: (@Sendable (ExtensionInvocation, CallResult) async -> Void)? = nil
            ) {
                self.toolBefore = toolBefore
                self.toolAfter = toolAfter
                self.extensionBefore = extensionBefore
                self.extensionAfter = extensionAfter
            }
        }

        // parity: codemode/src/codemode/tool-runtime.ts#hooked [status=implemented hash=7582d432211b]
        public static func hooked<Call: Sendable, A: Sendable>(
            _ call: Call,
            before: (@Sendable (Call) async throws -> Void)?,
            after: (@Sendable (Call, CallResult) async -> Void)?,
            toResult: (A) -> JSONValue = { _ in .null },
            run: () async throws -> A
        ) async throws -> A {
            if let before { try await before(call) }
            do {
                let value = try await run()
                if let after { await after(call, .success(toResult(value))) }
                return value
            } catch let intr as CodemodeLanguage.Interruption {
                if let after { await after(call, .interrupted) }
                throw intr
            } catch {
                if let after { await after(call, .failure(CodemodeLanguage.errorMessage(error))) }
                throw error
            }
        }

        // parity: codemode/src/codemode/tool-runtime.ts#ToolDescription [status=implemented hash=ae52bd8156a2]
        public struct ToolDescription: Equatable, Hashable, Sendable, Codable {
            public let path: String
            public let description: String
            public let signature: String

            public init(path: String, description: String, signature: String) {
                self.path = path
                self.description = description
                self.signature = signature
            }
        }

        // parity: codemode/src/codemode/tool-runtime.ts#toolExpression [status=implemented hash=8d3dc2266986]
        public static func toolExpression(_ path: String) -> String {
            "tools" + path.split(separator: ".", omittingEmptySubsequences: false).map { seg -> String in
                let s = String(seg)
                return ToolSchema.isIdentifierSegment(s) ? ".\(s)" : "[\(CodemodeLanguage.jsonEscapeString(s))]"
            }.joined()
        }

        // parity: codemode/src/codemode/tool-runtime.ts#searchSignature [status=implemented hash=034b1bf717e3]
        public static let searchSignature: String = """
        search(query: string | {
          query?: string,
          namespace?: string,
          /** @integer @exclusiveMinimum 0 */
          limit?: number,
          /** @integer @minimum 0 */
          offset?: number,
        }): {
          items: Array<{
              path: string,
              description: string,
              signature: string,
            }>,
          /** @integer @minimum 0 */
          remaining: number,
          next: {
              /** @integer @minimum 0 */
              offset: number,
            } | null,
        }
        """

        public final class ToolNode: @unchecked Sendable {
            public var tool: Tool.Definition?
            public var namespace: Namespace.Definition?
            public var children: [String: ToolNode] = [:]

            public init() {}
        }

        // parity: codemode/src/codemode/tool-runtime.ts#SearchEntry [status=implemented hash=cc940ee38076]
        public struct SearchEntry: Sendable {
            public let description: ToolDescription
            public let position: Int
            public let namespaceWords: [String]
            public let nameWords: [String]
            public let descriptionWords: [String]
            public let parameterWords: [String]
            public let namespaceDescriptionWords: [String]
            public let nameLength: Int

            public init(
                description: ToolDescription,
                position: Int,
                namespaceWords: [String],
                nameWords: [String],
                descriptionWords: [String],
                parameterWords: [String],
                namespaceDescriptionWords: [String],
                nameLength: Int
            ) {
                self.description = description
                self.position = position
                self.namespaceWords = namespaceWords
                self.nameWords = nameWords
                self.descriptionWords = descriptionWords
                self.parameterWords = parameterWords
                self.namespaceDescriptionWords = namespaceDescriptionWords
                self.nameLength = nameLength
            }
        }

        // parity: codemode/src/codemode/tool-runtime.ts#Prepared [status=implemented hash=a68d2a07884a]
        public struct Prepared: Sendable {
            public let root: ToolNode
            public let catalog: [ToolDescription]
            public let searchIndex: [SearchEntry]

            public init(root: ToolNode, catalog: [ToolDescription], searchIndex: [SearchEntry]) {
                self.root = root
                self.catalog = catalog
                self.searchIndex = searchIndex
            }
        }

        private static func splitWords(_ text: String) -> [String] {
            var expanded = ""
            let scalars = Array(text.unicodeScalars)
            for i in 0..<scalars.count {
                let sc = scalars[i]
                if i > 0 {
                    let prev = scalars[i - 1]
                    let prevLowerOrDigit = (prev.value >= 0x61 && prev.value <= 0x7A) || (prev.value >= 0x30 && prev.value <= 0x39)
                    let curUpper = sc.value >= 0x41 && sc.value <= 0x5A
                    if prevLowerOrDigit && curUpper { expanded.append(" ") }
                }
                expanded.unicodeScalars.append(sc)
            }
            return expanded.lowercased().split { ch in
                !(ch.isASCII && (ch.isLetter || ch.isNumber))
            }.map(String.init).filter { !$0.isEmpty }
        }

        private static func stem(_ word: String) -> String {
            if word.count > 4 && word.hasSuffix("ies") { return String(word.dropLast(3)) + "y" }
            if word.count > 4 && (word.hasSuffix("sses") || word.hasSuffix("shes") || word.hasSuffix("ches") || word.hasSuffix("xes") || word.hasSuffix("zes") || word.hasSuffix("uses")) {
                return String(word.dropLast(2))
            }
            if word.count > 2 && word.hasSuffix("s") && !word.hasSuffix("ss") && !word.hasSuffix("us") && !word.hasSuffix("is") {
                return String(word.dropLast(1))
            }
            return word
        }

        private static func searchWords(_ text: String) -> [String] {
            var words = splitWords(text)
            // Also include whole camelCase tokens
            let tokens = text.split { ch in !(ch.isASCII && (ch.isLetter || ch.isNumber)) }.map(String.init)
            for tok in tokens {
                let hasLower = tok.contains { $0 >= "a" && $0 <= "z" || $0 >= "0" && $0 <= "9" }
                let hasUpper = tok.contains { $0 >= "A" && $0 <= "Z" }
                if hasLower && hasUpper { words.append(tok.lowercased()) }
            }
            return words.map(stem)
        }

        // parity: codemode/src/codemode/tool-runtime.ts#prepare [status=implemented hash=e6009d08e9f0]
        public static func prepare(_ tools: Tools) -> Prepared {
            let root = ToolNode()
            func insert(into node: ToolNode, group: Tools) {
                for name in group.keys.sorted() {
                    guard let entry = group[name] else { continue }
                    var cur = node
                    for seg in name.split(separator: ".", omittingEmptySubsequences: false).map(String.init) where !seg.isEmpty {
                        if let existing = cur.children[seg] {
                            cur = existing
                        } else {
                            let created = ToolNode()
                            cur.children[seg] = created
                            cur = created
                        }
                    }
                    switch entry {
                    case .tool(let def):
                        cur.tool = def
                    case .namespace(let ns):
                        cur.namespace = ns
                        insert(into: cur, group: ns.tools)
                    case .group(let sub):
                        insert(into: cur, group: sub)
                    }
                }
            }
            insert(into: root, group: tools)

            var visible: [(path: String, tool: Tool.Definition, namespaces: [Namespace.Definition])] = []
            func flatten(_ node: ToolNode, path: [String], namespaces: [Namespace.Definition]) {
                let nextNs = node.namespace.map { namespaces + [$0] } ?? namespaces
                if let tool = node.tool {
                    visible.append((path: path.joined(separator: "."), tool: tool, namespaces: nextNs))
                }
                for key in node.children.keys.sorted() {
                    if let child = node.children[key] {
                        flatten(child, path: path + [key], namespaces: nextNs)
                    }
                }
            }
            flatten(root, path: [], namespaces: [])
            visible.sort { CodemodeLanguage.compareText($0.path, $1.path) < 0 }

            var descriptions: [ToolDescription] = []
            var entries: [SearchEntry] = []
            for (pos, item) in visible.enumerated() {
                let sigParam = ToolSchema.stringParameter(item.tool)?.signature
                    ?? (ToolSchema.isEmptyInput(item.tool) ? "()" : "(\(ToolSchema.inputTypeScript(item.tool, pretty: true)))")
                let signature = "\(toolExpression(item.path))\(sigParam): Promise<\(ToolSchema.outputTypeScript(item.tool, pretty: true))>"
                let desc = ToolDescription(path: item.path, description: item.tool.description, signature: signature)
                descriptions.append(desc)
                let segments = item.path.split(separator: ".").map(String.init)
                let name = segments.last ?? ""
                let nsParts = Array(segments.dropLast())
                entries.append(SearchEntry(
                    description: desc,
                    position: pos,
                    namespaceWords: nsParts.flatMap(searchWords),
                    nameWords: searchWords(name),
                    descriptionWords: searchWords(item.tool.description),
                    parameterWords: ToolSchema.inputProperties(item.tool).flatMap { searchWords($0.name) },
                    namespaceDescriptionWords: item.namespaces.compactMap(\.description).flatMap(searchWords),
                    nameLength: splitWords(name).count
                ))
            }
            return Prepared(root: root, catalog: descriptions, searchIndex: entries)
        }

        public static func rank(entries: [SearchEntry], query: String, index: [SearchEntry]) -> [SearchEntry] {
            let terms = searchWords(query)
            if terms.isEmpty {
                return entries.sorted { CodemodeLanguage.compareText($0.description.path, $1.description.path) < 0 }
            }
            let nDocs = Double(max(1, index.count))
            let avgName = max(1.0, Double(index.reduce(0) { $0 + $1.nameWords.count }) / nDocs)
            let avgNs = max(1.0, Double(index.reduce(0) { $0 + $1.namespaceWords.count }) / nDocs)
            let avgDesc = max(1.0, Double(index.reduce(0) { $0 + $1.descriptionWords.count }) / nDocs)
            let avgParam = max(1.0, Double(index.reduce(0) { $0 + $1.parameterWords.count }) / nDocs)
            let avgNsDesc = max(1.0, Double(index.reduce(0) { $0 + $1.namespaceDescriptionWords.count }) / nDocs)
            let k1 = 1.2
            let b = 0.75
            let brevityBoost = 0.5
            let prefixWeight = 0.3

            // Build postings: word -> [(pos, weight)]
            var postings: [String: [(Int, Double)]] = [:]
            for entry in index {
                var wMap: [String: Double] = [:]
                func addField(_ words: [String], fieldWeight: Double, avgLen: Double) {
                    let norm = fieldWeight / (1.0 - b + b * Double(words.count) / avgLen)
                    for w in words { wMap[w, default: 0] += norm }
                }
                addField(entry.nameWords, fieldWeight: 3.0, avgLen: avgName)
                addField(entry.namespaceWords, fieldWeight: 2.0, avgLen: avgNs)
                addField(entry.descriptionWords, fieldWeight: 1.0, avgLen: avgDesc)
                addField(entry.namespaceDescriptionWords, fieldWeight: 0.4, avgLen: avgNsDesc)
                addField(entry.parameterWords, fieldWeight: 0.3, avgLen: avgParam)
                for (w, wt) in wMap { postings[w, default: []].append((entry.position, wt)) }
            }
            let sortedVocab = postings.keys.sorted()
            let allowed = Set(entries.map(\.position))
            var scores: [Int: Double] = [:]

            for term in terms {
                var matchedTerms: [(String, Double)] = [(term, 1.0)]
                if term.count >= 4 {
                    for w in sortedVocab where w != term && w.hasPrefix(term) {
                        matchedTerms.append((w, prefixWeight))
                    }
                }
                var bestForTerm: [Int: Double] = [:]
                for (word, factor) in matchedTerms {
                    guard let list = postings[word] else { continue }
                    let df = Double(list.count)
                    let idf = log(1.0 + (nDocs - df + 0.5) / (df + 0.5))
                    for (pos, wt) in list where allowed.contains(pos) {
                        let sc = (factor * idf * wt * (k1 + 1.0)) / (wt + k1)
                        if sc > (bestForTerm[pos] ?? 0) { bestForTerm[pos] = sc }
                    }
                }
                for (pos, sc) in bestForTerm { scores[pos, default: 0] += sc }
            }

            return scores.map { pos, sc -> (SearchEntry, Double) in
                let entry = index[pos]
                let boosted = sc * (1.0 + brevityBoost / Double(max(1, entry.nameLength)))
                return (entry, boosted)
            }.sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                return CodemodeLanguage.compareText(a.0.description.path, b.0.description.path) < 0
            }.map(\.0)
        }

        public static func performSearch(
            prepared: Prepared,
            query: String = "",
            namespace: String? = nil,
            limit: Int = 10,
            offset: Int = 0
        ) -> JSONValue {
            var ns = namespace
            if let currentNs = ns, !prepared.searchIndex.contains(where: { $0.description.path.hasPrefix("tools.") }) {
                if currentNs == "tools" { ns = nil }
                else if currentNs.hasPrefix("tools.") { ns = String(currentNs.dropFirst("tools.".count)) }
            }
            let scoped: [SearchEntry]
            if let ns {
                scoped = prepared.searchIndex.filter { $0.description.path == ns || $0.description.path.hasPrefix("\(ns).") }
            } else {
                scoped = prepared.searchIndex
            }
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let pathQuery = trimmed.hasPrefix("tools.") ? String(trimmed.dropFirst("tools.".count)) : trimmed
            let ranked: [SearchEntry]
            if !pathQuery.isEmpty,
               let exact = scoped.first(where: { $0.description.path == pathQuery || toolExpression($0.description.path) == trimmed })
            {
                ranked = [exact]
            } else {
                ranked = rank(entries: scoped, query: pathQuery, index: prepared.searchIndex)
            }
            let safeOffset = max(0, offset)
            let safeLimit = max(1, limit)
            let slice = safeOffset < ranked.count ? Array(ranked[safeOffset..<min(ranked.count, safeOffset + safeLimit)]) : []
            let items: [JSONValue] = slice.map { entry in
                .object([
                    "path": .string(toolExpression(entry.description.path)),
                    "description": .string(entry.description.description),
                    "signature": .string(entry.description.signature),
                ])
            }
            let remaining = max(0, ranked.count - safeOffset - slice.count)
            let nextVal: JSONValue = remaining > 0 ? .object(["offset": .int(Int64(safeOffset + slice.count))]) : .null
            return .object([
                "items": .array(items),
                "remaining": .int(Int64(remaining)),
                "next": nextVal,
            ])
        }

        // parity: codemode/src/codemode/tool-runtime.ts#toolCalls [status=implemented hash=e110d8159c38]
        public static func toolCalls(_ metadata: JSONValue) -> [ToolCall] {
            guard case .object(let dict) = metadata,
                  case .array(let list) = dict["calls"]
            else { return [] }
            return list.compactMap { item in
                guard case .object(let obj) = item, case .string(let name) = obj["name"] else { return nil }
                return ToolCall(name: name)
            }
        }

        private static func lookupNode(_ root: ToolNode, segments: [String]) -> ToolNode? {
            var cur: ToolNode? = root
            for seg in segments {
                cur = cur?.children[seg]
            }
            return cur
        }

        // parity: codemode/src/codemode/tool-runtime.ts#globals [status=implemented hash=6fde1ee9ddfb]
        public static func globals(
            prepared: Prepared,
            hooks: Hooks,
            run: CodemodeLanguage.Run,
            maxToolCalls: Int?
        ) -> [String: CodemodeLanguage.HostGlobalValue] {
            let stateLock = Mutex<(maxToolCalls: Int?, calls: [(name: String, key: String)])>((maxToolCalls, []))

            @Sendable func syncMetadataLocked(_ snapshot: (maxToolCalls: Int?, calls: [(name: String, key: String)])) {
                let callsJson: [JSONValue] = snapshot.calls.map { .object(["name": .string($0.name), "key": .string($0.key)]) }
                run.metadata = .object([
                    "maxToolCalls": snapshot.maxToolCalls.map { .int(Int64($0)) } ?? .null,
                    "calls": .array(callsJson),
                ])
            }
            stateLock.withLock { syncMetadataLocked($0) }

            @Sendable func admit(name: String, key: String, again: Bool) throws {
                try stateLock.withLock { s in
                    if again && s.calls.contains(where: { $0.key == key }) { return }
                    if let limit = s.maxToolCalls, s.calls.count >= limit {
                        throw CodemodeLanguage.HostFailure(
                            kind: "ToolCallLimitExceeded",
                            message: "Execution exceeded its tool-call limit of \(limit)."
                        )
                    }
                    s.calls.append((name: name, key: key))
                    syncMetadataLocked(s)
                }
            }

            @Sendable func decodeArgs(name: String, tool: Tool.Definition, args: [CodemodeLanguage.Value]) throws -> JSONValue {
                var jsonArgs: [JSONValue] = []
                for a in args {
                    jsonArgs.append(try CodemodeLanguage.toJsonValue(a, dropFunctions: true) ?? .null)
                }
                let normalized: [JSONValue] = jsonArgs.isEmpty ? [.object([:])] : jsonArgs
                guard normalized.count == 1 else {
                    throw CodemodeLanguage.HostFailure(
                        kind: "InvalidToolInput",
                        message: "Tool '\(name)' expects at most one input object."
                    )
                }
                let rawInput = normalized[0]
                let finalInput: JSONValue
                if case .string = rawInput, let strParam = ToolSchema.stringParameter(tool) {
                    finalInput = .object([strParam.name: rawInput])
                } else {
                    finalInput = rawInput
                }
                do {
                    return try ToolSchema.decodeInput(tool, finalInput)
                } catch {
                    let hint = name == "search"
                        ? #"Pass search a query string or an object, such as search("issues") or search({ namespace: "github" })."#
                        : "The signature may have changed. Use search to get the current signature."
                    throw CodemodeLanguage.HostFailure(
                        kind: "InvalidToolInput",
                        message: "Invalid input for tool '\(name)': \(error)",
                        suggestions: [hint]
                    )
                }
            }

            @Sendable func executeTool(
                name: String,
                tool: Tool.Definition,
                args: [CodemodeLanguage.Value],
                call: CodemodeLanguage.Host.Call,
                builtins: CodemodeLanguage.Builtins
            ) async throws -> CodemodeLanguage.Value {
                let input = try decodeArgs(name: name, tool: tool, args: args)
                let isIdempotent: Bool
                let runFn: Tool.ExecuteFn
                switch tool.execute {
                case .standard(let fn):
                    isIdempotent = false
                    runFn = fn
                case .idempotent(let idem):
                    isIdempotent = true
                    runFn = idem.execute
                case .durable(let dur):
                    try admit(name: name, key: call.key, again: false)
                    let inv = ToolInvocation(name: name, input: input, key: call.key)
                    let outJson = try await hooked(inv, before: hooks.toolBefore, after: hooks.toolAfter, toResult: { $0 }) {
                        do {
                            let startData = try await dur.start(input, Tool.ToolContext(key: call.key))
                            let rawOut = try await dur.wait(startData, Tool.ToolContext(key: call.key))
                            return try ToolSchema.decodeOutput(tool, rawOut)
                        } catch let te as ToolError {
                            throw CodemodeLanguage.HostFailure(kind: "ToolFailure", message: te.message)
                        }
                    }
                    return try CodemodeLanguage.fromJson(builtins, outJson)
                }
                try admit(name: name, key: call.key, again: isIdempotent)
                let inv = ToolInvocation(name: name, input: input, key: call.key)
                let outJson = try await hooked(inv, before: hooks.toolBefore, after: hooks.toolAfter, toResult: { $0 }) {
                    do {
                        let rawOut = try await runFn(input, Tool.ToolContext(key: call.key))
                        return try ToolSchema.decodeOutput(tool, rawOut)
                    } catch let te as ToolError {
                        throw CodemodeLanguage.HostFailure(kind: "ToolFailure", message: te.message)
                    } catch let hf as CodemodeLanguage.HostFailure {
                        throw hf
                    } catch {
                        throw CodemodeLanguage.HostFailure(kind: "ToolFailure", message: CodemodeLanguage.errorMessage(error))
                    }
                }
                return try CodemodeLanguage.fromJson(builtins, outJson)
            }

            let searchCall: @Sendable ([CodemodeLanguage.Value], CodemodeLanguage.Host.Call, CodemodeLanguage.Builtins) async throws -> CodemodeLanguage.Value = { args, call, builtins in
                var query = ""
                var ns: String? = nil
                var limit = 10
                var offset = 0
                if let first = args.first, !first.isUndefined {
                    if case .string(let q) = first {
                        query = q
                    } else if let j = try CodemodeLanguage.toJsonValue(first, dropFunctions: true), case .object(let dict) = j {
                        if case .string(let q) = dict["query"] { query = q }
                        if case .string(let n) = dict["namespace"] { ns = n }
                        if case .int(let l) = dict["limit"] { limit = Int(l) }
                        else if case .double(let l) = dict["limit"] { limit = Int(l) }
                        if case .int(let o) = dict["offset"] { offset = Int(o) }
                        else if case .double(let o) = dict["offset"] { offset = Int(o) }
                    } else {
                        throw CodemodeLanguage.HostFailure(
                            kind: "InvalidToolInput",
                            message: "Invalid input for tool 'search'.",
                            suggestions: [#"Pass search a query string or an object, such as search("issues") or search({ namespace: "github" })."#]
                        )
                    }
                }
                let inputJson: JSONValue = .object([
                    "query": .string(query),
                    "namespace": ns.map { .string($0) } ?? .null,
                    "limit": .int(Int64(limit)),
                    "offset": .int(Int64(offset)),
                ])
                try admit(name: "search", key: call.key, again: false)
                let inv = ToolInvocation(name: "search", input: inputJson, key: call.key)
                let result = try await hooked(inv, before: hooks.toolBefore, after: hooks.toolAfter, toResult: { $0 }) {
                    performSearch(prepared: prepared, query: query, namespace: ns, limit: limit, offset: offset)
                }
                return try CodemodeLanguage.fromJson(builtins, result)
            }

            let searchFn = CodemodeLanguage.Host.fn(searchCall, options: .init(type: .syncThenable))
            let searchAlias = CodemodeLanguage.Host.fn(searchCall, options: .init(type: .async))

            let toolsNamespace = CodemodeLanguage.Host.namespace(
                keys: { path in
                    let segments = path.flatMap { $0.split(separator: ".").map(String.init) }
                    guard let node = lookupNode(prepared.root, segments: segments) else {
                        throw CodemodeLanguage.HostFailure(
                            kind: "UnknownTool",
                            message: "Unknown tool namespace '\(segments.joined(separator: "."))'."
                        )
                    }
                    return node.children.keys.sorted()
                },
                resolve: { path in
                    let segments = path.flatMap { $0.split(separator: ".").map(String.init) }
                    if segments.count == 1 && segments[0] == "search" && lookupNode(prepared.root, segments: segments) == nil {
                        return .fn(searchAlias)
                    }
                    guard let node = lookupNode(prepared.root, segments: segments) else {
                        let name = segments.joined(separator: ".")
                        let ns = segments.count > 1 && prepared.root.children[segments[0]] != nil ? segments[0] : nil
                        let pool = ns.map { prefix in prepared.searchIndex.filter { $0.description.path.hasPrefix("\(prefix).") } } ?? prepared.searchIndex
                        let closest = rank(entries: pool, query: ns != nil ? segments.dropFirst().joined(separator: " ") : name, index: prepared.searchIndex).first
                        let msg = closest.map { "Unknown tool '\(name)'. Did you mean \(toolExpression($0.description.path))?" } ?? "Unknown tool '\(name)'."
                        return .failure(CodemodeLanguage.HostFailure(kind: "UnknownTool", message: msg, suggestions: ["Use search to find available tools."]))
                    }
                    guard let toolDef = node.tool else {
                        let name = segments.joined(separator: ".")
                        let under = prepared.searchIndex.filter { $0.description.path.hasPrefix("\(name).") }
                        let shown = under.prefix(3).map { toolExpression($0.description.path) }
                        let more = max(0, under.count - shown.count)
                        let msg = shown.isEmpty
                            ? "Tool '\(name)' is not callable."
                            : "Tool '\(name)' is not callable, it is a namespace. Did you mean \(shown.joined(separator: ", "))?"
                        let hint = more > 0
                            ? "\(more) more under '\(name)'. Use search({ namespace: \(CodemodeLanguage.jsonEscapeString(name)) }) to list them."
                            : "Use search to find available tools."
                        return .failure(CodemodeLanguage.HostFailure(kind: "UnknownTool", message: msg, suggestions: [hint]))
                    }
                    let fullName = segments.joined(separator: ".")
                    return .fn(CodemodeLanguage.Host.fn({ args, call, builtins in
                        try await executeTool(name: fullName, tool: toolDef, args: args, call: call, builtins: builtins)
                    }, options: .init(type: .async)))
                }
            )

            return [
                "tools": .namespace(toolsNamespace),
                "search": .fn(searchFn),
            ]
        }
    }

    // MARK: - Static Tool Call Scanner (src/codemode/scan.ts)

    // parity: codemode/src/codemode/scan.ts#scanTools [status=implemented hash=8fd600da75d3]
    public static func scanTools(_ code: String) -> Result<[String], CodemodeLanguage.Diagnostic> {
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .failure(CodemodeLanguage.Diagnostic(kind: "ParseError", message: "Code cannot be empty."))
        }
        let parsed = CodemodeLanguage.parseProgram(code)
        let program: CodemodeLanguage.ProgramAST
        switch parsed {
        case .error(let diag): return .failure(diag)
        case .ok(let p, _): program = p
        }

        var foundOrder: [String] = []
        var foundSet = Set<String>()
        var scopes: [Set<String>] = [collectStmtNames(program.body, includeVar: true)]

        func isShadowed() -> Bool { scopes.contains { $0.contains("tools") } }
        func fail(_ loc: CodemodeLanguage.SourceLocation?, _ msg: String) -> CodemodeLanguage.Diagnostic {
            CodemodeLanguage.Diagnostic(
                kind: "UnsupportedSyntax",
                message: "\(msg)\(CodemodeLanguage.formatLocation(loc))",
                location: loc
            )
        }

        func extractStaticToolChain(_ expr: CodemodeLanguage.Expression) -> (ok: Bool, path: String?, reason: String?, loc: CodemodeLanguage.SourceLocation?)? {
            // Check if `expr` is rooted at unshadowed identifier `tools`
            var segments: [String] = []
            var cur = expr
            while true {
                switch cur {
                case .chain(let inner, _):
                    cur = inner
                case .member(let obj, let prop, _, let loc):
                    switch prop {
                    case .identifier(let s, _), .string(let s, _):
                        segments.append(s)
                        cur = obj
                    case .computed(.literalString(let s, _), _):
                        segments.append(s)
                        cur = obj
                    default:
                        if isRootedAtTools(obj) {
                            return (false, nil, "Automation code must reference tools statically (e.g. tools.slack.read_thread), not with dynamic bracket expressions.", loc)
                        }
                        return nil
                    }
                case .identifier("tools", _):
                    guard !isShadowed() else { return nil }
                    if segments.isEmpty {
                        return (false, nil, "Automation code must call tools directly as tools.<name>(...), not alias or pass the tools object.", cur.location)
                    }
                    return (true, segments.reversed().joined(separator: "."), nil, cur.location)
                default:
                    return nil
                }
            }
        }

        func isRootedAtTools(_ expr: CodemodeLanguage.Expression) -> Bool {
            switch expr {
            case .identifier("tools", _): return !isShadowed()
            case .member(let obj, _, _, _): return isRootedAtTools(obj)
            case .chain(let inner, _): return isRootedAtTools(inner)
            default: return false
            }
        }

        func visitExpr(_ expr: CodemodeLanguage.Expression) -> CodemodeLanguage.Diagnostic? {
            switch expr {
            case .call(let callee, let args, _, let loc):
                if case .identifier("require", _) = callee {
                    if let first = args.first, case .expr(let srcExpr) = first {
                        if case .literalString(let s, _) = srcExpr {
                            if CodemodeLanguage.moduleName(s) == "tools" {
                                return fail(loc, "Automation code must call tools directly as tools.<name>(...), not import or require them.")
                            }
                        } else {
                            return fail(loc, "Automation code must call tools directly as tools.<name>(...), not import or require them.")
                        }
                    }
                }
                if let chain = extractStaticToolChain(callee) {
                    if !chain.ok { return fail(chain.loc, chain.reason ?? "Invalid tool call.") }
                    if let path = chain.path, foundSet.insert(path).inserted { foundOrder.append(path) }
                } else {
                    if let err = visitExpr(callee) { return err }
                }
                for a in args {
                    if case .expr(let e) = a, let err = visitExpr(e) { return err }
                    if case .spread(let e, _) = a, let err = visitExpr(e) { return err }
                }
                return nil
            case .identifier("tools", let loc):
                if !isShadowed() {
                    return fail(loc, "Automation code must call tools directly as tools.<name>(...), not alias or pass the tools object.")
                }
                return nil
            case .member(let obj, let prop, _, let loc):
                if isRootedAtTools(expr) {
                    if case .computed(let ce, _) = prop, !(ce.isStringLiteral) {
                        return fail(loc, "Automation code must reference tools statically (e.g. tools.slack.read_thread), not with dynamic bracket expressions.")
                    }
                    return fail(loc, "Automation code must call tools directly as tools.<name>(...), not alias or pass the tools object.")
                }
                if let err = visitExpr(obj) { return err }
                if case .computed(let ce, _) = prop, let err = visitExpr(ce) { return err }
                return nil
            case .importExpr(let src, let loc):
                if case .literalString(let s, _) = src {
                    if CodemodeLanguage.moduleName(s) == "tools" {
                        return fail(loc, "Automation code must call tools directly as tools.<name>(...), not import or require them.")
                    }
                } else {
                    return fail(loc, "Automation code must call tools directly as tools.<name>(...), not import or require them.")
                }
                return nil
            case .function(let fn):
                var fnScope = Set<String>()
                if let n = fn.name { fnScope.insert(n) }
                for p in fn.params { for n in CodemodeLanguage.collectPatternNames(p) { fnScope.insert(n) } }
                if case .block(let stmts) = fn.body { fnScope.formUnion(collectStmtNames(stmts, includeVar: true)) }
                scopes.append(fnScope)
                defer { scopes.removeLast() }
                switch fn.body {
                case .block(let stmts): return visitStmts(stmts)
                case .expression(let e): return visitExpr(e)
                }
            case .array(let els, _):
                for el in els {
                    if case .expr(let e) = el, let err = visitExpr(e) { return err }
                    if case .spread(let e, _) = el, let err = visitExpr(e) { return err }
                }
                return nil
            case .object(let props, _):
                for p in props {
                    switch p {
                    case .property(let k, let v, _, _):
                        if case .computed(let ce, _) = k, let err = visitExpr(ce) { return err }
                        if let err = visitExpr(v) { return err }
                    case .spread(let e, _): if let err = visitExpr(e) { return err }
                    }
                }
                return nil
            case .templateLiteral(_, let es, _):
                for e in es { if let err = visitExpr(e) { return err } }
                return nil
            case .taggedTemplate(let tag, _, let es, _):
                if let err = visitExpr(tag) { return err }
                for e in es { if let err = visitExpr(e) { return err } }
                return nil
            case .newExpr(let callee, let args, _):
                if let err = visitExpr(callee) { return err }
                for a in args {
                    if case .expr(let e) = a, let err = visitExpr(e) { return err }
                    if case .spread(let e, _) = a, let err = visitExpr(e) { return err }
                }
                return nil
            case .unary(_, let a, _), .update(_, let a, _, _), .awaitExpr(let a, _), .chain(let a, _):
                return visitExpr(a)
            case .yieldExpr(let a, _, _):
                return a.flatMap(visitExpr)
            case .binary(_, let l, let r, _), .logical(_, let l, let r, _):
                return visitExpr(l) ?? visitExpr(r)
            case .conditional(let t, let c, let a, _):
                return visitExpr(t) ?? visitExpr(c) ?? visitExpr(a)
            case .assignment(_, _, let r, _):
                return visitExpr(r)
            case .sequence(let es, _):
                for e in es { if let err = visitExpr(e) { return err } }
                return nil
            default:
                return nil
            }
        }

        func visitStmts(_ stmts: [CodemodeLanguage.Statement]) -> CodemodeLanguage.Diagnostic? {
            for stmt in stmts {
                if let err = visitStmt(stmt) { return err }
            }
            return nil
        }

        func visitStmt(_ stmt: CodemodeLanguage.Statement) -> CodemodeLanguage.Diagnostic? {
            switch stmt {
            case .importDecl(_, let source, let loc):
                if CodemodeLanguage.moduleName(source) == "tools" {
                    return fail(loc, "Automation code must call tools directly as tools.<name>(...), not import or require them.")
                }
                return nil
            case .expression(let e, _), .throwStmt(let e, _):
                return visitExpr(e)
            case .returnStmt(let e, _):
                return e.flatMap(visitExpr)
            case .variable(_, let decls, _):
                for d in decls { if let ie = d.initializer, let err = visitExpr(ie) { return err } }
                return nil
            case .block(let inner, _):
                scopes.append(collectStmtNames(inner, includeVar: false))
                defer { scopes.removeLast() }
                return visitStmts(inner)
            case .functionDecl(let fn):
                var fnScope = Set<String>()
                if let n = fn.name { fnScope.insert(n) }
                for p in fn.params { for n in CodemodeLanguage.collectPatternNames(p) { fnScope.insert(n) } }
                if case .block(let stmts) = fn.body { fnScope.formUnion(collectStmtNames(stmts, includeVar: true)) }
                scopes.append(fnScope)
                defer { scopes.removeLast() }
                if case .block(let stmts) = fn.body { return visitStmts(stmts) }
                return nil
            case .ifStmt(let t, let c, let a, _):
                return visitExpr(t) ?? visitStmt(c) ?? a.flatMap(visitStmt)
            case .whileStmt(let t, let b, _):
                return visitExpr(t) ?? visitStmt(b)
            case .doWhileStmt(let b, let t, _):
                return visitStmt(b) ?? visitExpr(t)
            case .forStmt(let ini, let t, let u, let b, _):
                var fs = Set<String>()
                if case .variable(let k, let ds, _) = ini, k != .var {
                    for d in ds { for n in CodemodeLanguage.collectPatternNames(d.id) { fs.insert(n) } }
                }
                scopes.append(fs)
                defer { scopes.removeLast() }
                if case .variable(_, let ds, _) = ini {
                    for d in ds { if let ie = d.initializer, let err = visitExpr(ie) { return err } }
                } else if case .expression(let e) = ini, let err = visitExpr(e) { return err }
                if let t, let err = visitExpr(t) { return err }
                if let u, let err = visitExpr(u) { return err }
                return visitStmt(b)
            case .forInStmt(let l, let r, let b, _), .forOfStmt(let l, let r, let b, _, _):
                var fs = Set<String>()
                if case .variable(let k, let p, _) = l, k != .var {
                    for n in CodemodeLanguage.collectPatternNames(p) { fs.insert(n) }
                }
                scopes.append(fs)
                defer { scopes.removeLast() }
                return visitExpr(r) ?? visitStmt(b)
            case .switchStmt(let d, let cases, _):
                if let err = visitExpr(d) { return err }
                for c in cases {
                    if let t = c.test, let err = visitExpr(t) { return err }
                    if let err = visitStmts(c.consequent) { return err }
                }
                return nil
            case .tryStmt(let blk, let handler, let fin, _):
                if let err = visitStmts(blk) { return err }
                if let handler {
                    var cs = Set<String>()
                    if let p = handler.param { for n in CodemodeLanguage.collectPatternNames(p) { cs.insert(n) } }
                    scopes.append(cs)
                    let err = visitStmts(handler.body)
                    scopes.removeLast()
                    if let err { return err }
                }
                return fin.flatMap(visitStmts)
            case .labeled(_, let b, _):
                return visitStmt(b)
            case .empty, .breakStmt, .continueStmt:
                return nil
            }
        }

        if let err = visitStmts(program.body) {
            return .failure(err)
        }
        return .success(foundOrder)
    }

    private static func collectStmtNames(_ stmts: [CodemodeLanguage.Statement], includeVar: Bool) -> Set<String> {
        var names = Set<String>()
        for stmt in stmts {
            switch stmt {
            case .functionDecl(let fn): if let n = fn.name { names.insert(n) }
            case .variable(let kind, let decls, _) where includeVar || kind != .var:
                for d in decls { for n in CodemodeLanguage.collectPatternNames(d.id) { names.insert(n) } }
            default: break
            }
        }
        return names
    }

    // MARK: - CodeMode Runtime & Formatting (src/codemode/codemode.ts)

    // parity: codemode/src/codemode/codemode.ts#ExecutionLimits [status=implemented hash=ad7de141f594]
    public struct ExecutionLimits: Equatable, Hashable, Sendable, Codable {
        public let timeoutMs: Int?
        public let maxToolCalls: Int?
        public let maxOutputBytes: Int?
        public let maxSteps: Int?

        public init(timeoutMs: Int? = nil, maxToolCalls: Int? = nil, maxOutputBytes: Int? = nil, maxSteps: Int? = nil) {
            self.timeoutMs = timeoutMs
            self.maxToolCalls = maxToolCalls
            self.maxOutputBytes = maxOutputBytes
            self.maxSteps = maxSteps
        }
    }

    // parity: codemode/src/codemode/codemode.ts#ResolvedExecutionLimits [status=implemented hash=cad5fd51b703]
    public struct ResolvedExecutionLimits: Equatable, Hashable, Sendable, Codable {
        public let timeoutMs: Int?
        public let maxToolCalls: Int?
        public let maxOutputBytes: Int?
        public let maxSteps: Int?

        public init(timeoutMs: Int? = nil, maxToolCalls: Int? = nil, maxOutputBytes: Int? = nil, maxSteps: Int? = nil) {
            self.timeoutMs = timeoutMs
            self.maxToolCalls = maxToolCalls
            self.maxOutputBytes = maxOutputBytes
            self.maxSteps = maxSteps
        }
    }

    // parity: codemode/src/codemode/codemode.ts#RunOptions [status=implemented hash=e17ea202c38d]
    public struct RunOptions: Sendable {
        public let extensions: [Extension.Definition]?

        public init(extensions: [Extension.Definition]? = nil) {
            self.extensions = extensions
        }
    }

    // parity: codemode/src/codemode/codemode.ts#ProgramOptions [status=implemented hash=7f4704673644]
    public struct ProgramOptions: Sendable {
        public let extensions: [Extension.Definition]?
        public let runId: String?

        public init(extensions: [Extension.Definition]? = nil, runId: String? = nil) {
            self.extensions = extensions
            self.runId = runId
        }
    }

    // parity: codemode/src/codemode/codemode.ts#SuspendOptions [status=implemented hash=4d826935ccbe]
    public typealias SuspendOptions = CodemodeLanguage.SuspendOptions

    // parity: codemode/src/codemode/codemode.ts#Environment [status=implemented hash=099e9e7fcd01]
    public struct Environment: Sendable {
        public init() {}
    }

    // parity: codemode/src/codemode/codemode.ts#DataValue [status=implemented hash=b15f1b0b3f89]
    public typealias DataValue = JSONValue

    // parity: codemode/src/codemode/codemode.ts#Input [status=implemented hash=92460d1eba6a]
    public struct Input: Equatable, Hashable, Sendable, Codable {
        public let code: String

        public init(code: String) {
            self.code = code
        }
    }

    // parity: codemode/src/codemode/codemode.ts#DiagnosticKind [status=implemented hash=6cf294f8c2bb]
    public enum DiagnosticKind: String, CaseIterable, Equatable, Hashable, Sendable, Codable {
        case parseError = "ParseError"
        case unsupportedSyntax = "UnsupportedSyntax"
        case unknownTool = "UnknownTool"
        case invalidToolInput = "InvalidToolInput"
        case invalidToolOutput = "InvalidToolOutput"
        case invalidDataValue = "InvalidDataValue"
        case toolCallLimitExceeded = "ToolCallLimitExceeded"
        case timeoutExceeded = "TimeoutExceeded"
        case toolFailure = "ToolFailure"
        case executionFailure = "ExecutionFailure"
        case truncated = "Truncated"
    }

    // parity: codemode/src/codemode/codemode.ts#Diagnostic [status=implemented hash=5a0a46ec2687]
    public typealias Diagnostic = CodemodeLanguage.Diagnostic

    // parity: codemode/src/codemode/codemode.ts#Success [status=implemented hash=aff44dde6573]
    public struct Success: Equatable, Sendable, Codable {
        public let ok: Bool
        public let value: DataValue
        public let warnings: [Diagnostic]?
        public let logs: [String]?
        public let truncated: Bool?
        public let toolCalls: [ToolRuntime.ToolCall]

        public init(
            value: DataValue,
            warnings: [Diagnostic]? = nil,
            logs: [String]? = nil,
            truncated: Bool? = nil,
            toolCalls: [ToolRuntime.ToolCall] = []
        ) {
            self.ok = true
            self.value = value
            self.warnings = warnings
            self.logs = logs
            self.truncated = truncated
            self.toolCalls = toolCalls
        }
    }

    // parity: codemode/src/codemode/codemode.ts#Failure [status=implemented hash=5b3f72fd957f]
    public struct Failure: Equatable, Sendable, Codable {
        public let ok: Bool
        public let error: Diagnostic
        public let logs: [String]?
        public let truncated: Bool?
        public let toolCalls: [ToolRuntime.ToolCall]

        public init(
            error: Diagnostic,
            logs: [String]? = nil,
            truncated: Bool? = nil,
            toolCalls: [ToolRuntime.ToolCall] = []
        ) {
            self.ok = false
            self.error = error
            self.logs = logs
            self.truncated = truncated
            self.toolCalls = toolCalls
        }
    }

    // parity: codemode/src/codemode/codemode.ts#Result [status=implemented hash=1fa54eb4c67c]
    public enum ExecutionResult: Equatable, Sendable {
        case success(Success)
        case failure(Failure)

        public var ok: Bool {
            if case .success = self { return true }
            return false
        }

        public var toolCalls: [ToolRuntime.ToolCall] {
            switch self {
            case .success(let s): return s.toolCalls
            case .failure(let f): return f.toolCalls
            }
        }

        public var logs: [String]? {
            switch self {
            case .success(let s): return s.logs
            case .failure(let f): return f.logs
            }
        }

        public var warnings: [Diagnostic]? {
            switch self {
            case .success(let s): return s.warnings
            case .failure: return nil
            }
        }

        /// Formats this execution result using exact upstream `formatResult` rules
        /// so `OpenCodeUtil.formatExecuteOutput(...)` parses the leading JSON + `Warnings:` + `Logs:` sections seamlessly.
        public func formattedOutput() -> String {
            let output: String
            switch self {
            case .success(let s):
                if case .string(let str) = s.value { output = str }
                else { output = CodemodeLanguage.serializeJsonCompact(s.value) }
            case .failure(let f):
                var lines = [f.error.message]
                for hint in f.error.suggestions ?? [] where !f.error.message.contains(hint) {
                    lines.append(hint)
                }
                output = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let warningsSection: String?
            if case .success(let s) = self, let warns = s.warnings, !warns.isEmpty {
                warningsSection = "Warnings:\n" + warns.map { "- [\($0.kind)] \($0.message)" }.joined(separator: "\n")
            } else {
                warningsSection = nil
            }
            let logsSection: String? = logs.flatMap { list in
                list.isEmpty ? nil : "Logs:\n" + list.joined(separator: "\n")
            }
            let valuePart: String?
            if case .success(let s) = self, s.value == .null, (warningsSection != nil || logsSection != nil) {
                valuePart = nil
            } else {
                valuePart = output
            }
            return [valuePart, warningsSection, logsSection]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n\n")
        }
    }

    // parity: codemode/src/codemode/codemode.ts#Suspended [status=implemented hash=98694f609185]
    public typealias Suspended = CodemodeLanguage.Suspended

    // parity: codemode/src/codemode/codemode.ts#Outcome [status=implemented hash=20f0e50188c9]
    public enum Outcome: Equatable, Sendable {
        case result(ExecutionResult)
        case suspended(Suspended)
    }

    // parity: codemode/src/codemode/codemode.ts#Options [status=implemented hash=43a070637965]
    public struct Options: Sendable {
        public let tools: Tools
        public let hooks: ToolRuntime.Hooks
        public let extensions: [Extension.Definition]
        public let limits: ExecutionLimits

        public init(
            tools: Tools = [:],
            hooks: ToolRuntime.Hooks = ToolRuntime.Hooks(),
            extensions: [Extension.Definition] = [],
            limits: ExecutionLimits = ExecutionLimits()
        ) {
            self.tools = tools
            self.hooks = hooks
            self.extensions = extensions
            self.limits = limits
        }
    }

    // parity: codemode/src/codemode/codemode.ts#ExecuteOptions [status=implemented hash=e22a9f8e71d2]
    public struct ExecuteOptions: Sendable {
        public let code: String
        public let bindings: [String: DataValue]?
        public let tools: Tools
        public let hooks: ToolRuntime.Hooks
        public let extensions: [Extension.Definition]
        public let limits: ExecutionLimits

        public init(
            code: String,
            bindings: [String: DataValue]? = nil,
            tools: Tools = [:],
            hooks: ToolRuntime.Hooks = ToolRuntime.Hooks(),
            extensions: [Extension.Definition] = [],
            limits: ExecutionLimits = ExecutionLimits()
        ) {
            self.code = code
            self.bindings = bindings
            self.tools = tools
            self.hooks = hooks
            self.extensions = extensions
            self.limits = limits
        }
    }

    // parity: codemode/src/codemode/codemode.ts#Program [status=implemented hash=1312448d1b45]
    public struct Program: Sendable {
        public let run: @Sendable () async throws -> Outcome
        public let suspend: @Sendable (SuspendOptions?) throws -> Outcome

        public init(
            run: @escaping @Sendable () async throws -> Outcome,
            suspend: @escaping @Sendable (SuspendOptions?) throws -> Outcome
        ) {
            self.run = run
            self.suspend = suspend
        }
    }

    // parity: codemode/src/codemode/codemode.ts#Runtime [status=implemented hash=06dca549638b]
    public struct Runtime: Sendable {
        public let catalog: [ToolRuntime.ToolDescription]
        public let execute: @Sendable (String, [String: DataValue]?, RunOptions?) async -> ExecutionResult
        public let program: @Sendable (String, [String: DataValue]?, ProgramOptions?) -> Program
        public let resume: @Sendable (CodemodeLanguage.Snapshot, RunOptions?) -> Program

        public init(
            catalog: [ToolRuntime.ToolDescription],
            execute: @escaping @Sendable (String, [String: DataValue]?, RunOptions?) async -> ExecutionResult,
            program: @escaping @Sendable (String, [String: DataValue]?, ProgramOptions?) -> Program,
            resume: @escaping @Sendable (CodemodeLanguage.Snapshot, RunOptions?) -> Program
        ) {
            self.catalog = catalog
            self.execute = execute
            self.program = program
            self.resume = resume
        }
    }

    // parity: codemode/src/codemode/codemode.ts#execute [status=implemented hash=b3dc03fa7ccd]
    public static func execute(_ options: ExecuteOptions) async throws -> ExecutionResult {
        let rt = try make(Options(
            tools: options.tools,
            hooks: options.hooks,
            extensions: options.extensions,
            limits: options.limits
        ))
        return await rt.execute(options.code, options.bindings, nil)
    }

    // parity: codemode/src/codemode/codemode.ts#make [status=implemented hash=2717f96c2efd]
    public static func make(_ options: Options = Options()) throws -> Runtime {
        let prepared = ToolRuntime.prepare(options.tools)
        let resolved = ResolvedExecutionLimits(
            timeoutMs: try CodemodeLanguage.validateLimit("timeoutMs", options.limits.timeoutMs, minimum: 1),
            maxToolCalls: try CodemodeLanguage.validateLimit("maxToolCalls", options.limits.maxToolCalls, minimum: 0),
            maxOutputBytes: try CodemodeLanguage.validateLimit("maxOutputBytes", options.limits.maxOutputBytes, minimum: 0),
            maxSteps: try CodemodeLanguage.validateLimit("maxSteps", options.limits.maxSteps, minimum: 1)
        )
        var bound = CodemodeLanguage.globalNames.union(["tools", "search"])
        for ext in options.extensions {
            for name in ext.globals.keys {
                if bound.contains(name) {
                    throw CodemodeLanguage.typeError("Extension \"\(ext.name)\" global \"\(name)\" is already defined.")
                }
                bound.insert(name)
            }
        }

        @Sendable func convertExtensionItem(
            ext: Extension.Definition,
            label: String,
            item: Extension.GlobalItem
        ) -> CodemodeLanguage.HostGlobalValue {
            switch item {
            case .constant(let val):
                return .value(val)
            case .object(let dict):
                var out: [String: CodemodeLanguage.HostGlobalValue] = [:]
                for (k, v) in dict {
                    out[k] = convertExtensionItem(ext: ext, label: "\(label).\(k)", item: v)
                }
                return .object(out)
            case .function(let marked):
                let hooks = options.hooks
                let callType: CodemodeLanguage.Host.CallType = marked.isAsync ? .async : .sync
                return .fn(CodemodeLanguage.Host.fn({ args, _, builtins in
                    let inv = ToolRuntime.ExtensionInvocation(extension: ext.name, name: label, args: args)
                    return try await ToolRuntime.hooked(inv, before: hooks.extensionBefore, after: hooks.extensionAfter, toResult: { _ in .null }) {
                        try await marked.fn(args, builtins)
                    }
                }, options: .init(type: callType, snapshot: ext.snapshot, constructible: marked.isConstructible, takesFunctions: true)))
            }
        }

        @Sendable func makeLanguageRuntime(selected: [Extension.Definition]) throws -> CodemodeLanguage.Runtime {
            var modules: [String: String] = [:]
            for ext in selected {
                for (k, v) in ext.modules ?? [:] { modules[k] = v }
            }
            return try CodemodeLanguage.makeRuntime(CodemodeLanguage.RuntimeOptions(
                globals: { run in
                    var map = ToolRuntime.globals(
                        prepared: prepared,
                        hooks: options.hooks,
                        run: run,
                        maxToolCalls: resolved.maxToolCalls
                    )
                    for ext in selected {
                        for (name, item) in ext.globals {
                            map[name] = convertExtensionItem(ext: ext, label: name, item: item)
                        }
                    }
                    return map
                },
                modules: modules,
                limits: CodemodeLanguage.Limits(
                    timeoutMs: resolved.timeoutMs,
                    maxOutputBytes: resolved.maxOutputBytes,
                    maxSteps: resolved.maxSteps
                ),
                translate: CodemodeLanguage.Translate(functions: .drop, promises: .await)
            ))
        }

        @Sendable func mapOutcome(_ ended: CodemodeLanguage.Outcome) -> Outcome {
            switch ended {
            case .suspended(let s): return .suspended(s)
            case .result(let r):
                switch r {
                case .success(let value, let warnings, let logs, let truncated, let metadata):
                    return .result(.success(Success(
                        value: value,
                        warnings: warnings,
                        logs: logs,
                        truncated: truncated,
                        toolCalls: ToolRuntime.toolCalls(metadata)
                    )))
                case .failure(let error, let logs, let truncated, let metadata):
                    return .result(.failure(Failure(
                        error: error,
                        logs: logs,
                        truncated: truncated,
                        toolCalls: ToolRuntime.toolCalls(metadata)
                    )))
                }
            }
        }

        let makeProgram: @Sendable (String, [String: DataValue]?, ProgramOptions?) -> Program = { code, bindings, progOpts in
            let picked = progOpts?.extensions ?? options.extensions
            return Program(
                run: {
                    let langRt = try makeLanguageRuntime(selected: picked)
                    let langProg = langRt.program(code, CodemodeLanguage.ProgramOptions(bindings: bindings, runId: progOpts?.runId))
                    return mapOutcome(try await langProg.run())
                },
                suspend: { _ in
                    throw CodemodeLanguage.SuspendError(message: "Program not running.")
                }
            )
        }

        return Runtime(
            catalog: prepared.catalog,
            execute: { code, bindings, runOpts in
                let prog = makeProgram(code, bindings, ProgramOptions(extensions: runOpts?.extensions))
                do {
                    let outcome = try await prog.run()
                    switch outcome {
                    case .result(let r): return r
                    case .suspended(let s):
                        return .failure(Failure(
                            error: Diagnostic(kind: "ExecutionFailure", message: "The program suspended, which isn't supported here."),
                            toolCalls: ToolRuntime.toolCalls(s.state.header.metadata)
                        ))
                    }
                } catch {
                    return .failure(Failure(error: CodemodeLanguage.normalizeError(error)))
                }
            },
            program: makeProgram,
            resume: { snap, runOpts in
                let picked = runOpts?.extensions ?? options.extensions
                return Program(
                    run: {
                        let langRt = try makeLanguageRuntime(selected: picked)
                        return mapOutcome(try await langRt.resume(snap).run())
                    },
                    suspend: { _ in
                        throw CodemodeLanguage.SuspendError(message: "Program not running.")
                    }
                )
            }
        )
    }
    // MARK: - OpenAPI Spec-to-Tools Engine (src/codemode/openapi/*)

    public enum OpenAPI {
        // parity: codemode/src/codemode/openapi/types.ts#Document [status=implemented hash=985034628644]
        public typealias Document = [String: JSONValue]

        // parity: codemode/src/codemode/openapi/types.ts#Operation [status=implemented hash=6e562dce29c4]
        public struct Operation: Equatable, Hashable, Sendable, Codable {
            public let operationId: String?
            public let method: String
            public let path: String
            public let summary: String?
            public let description: String?

            public init(operationId: String?, method: String, path: String, summary: String?, description: String?) {
                self.operationId = operationId
                self.method = method
                self.path = path
                self.summary = summary
                self.description = description
            }
        }

        // parity: codemode/src/codemode/openapi/types.ts#SecurityScheme [status=implemented hash=18044dd55cbc]
        public enum SecurityScheme: Equatable, Hashable, Sendable, Codable {
            case apiKey(name: String, location: String)
            case http(scheme: String)
            case oauth2
            case openIdConnect
        }

        // parity: codemode/src/codemode/openapi/types.ts#Credential [status=implemented hash=e5e2f821c522]
        public enum Credential: Equatable, Hashable, Sendable, Codable {
            case bearer(token: String)
            case basic(username: String, password: String)
            case apiKey(value: String)
            case header(name: String, value: String)
        }

        public struct AuthContext: Sendable {
            public let name: String
            public let definition: SecurityScheme
            public let scopes: [String]
            public let operation: Operation

            public init(name: String, definition: SecurityScheme, scopes: [String], operation: Operation) {
                self.name = name
                self.definition = definition
                self.scopes = scopes
                self.operation = operation
            }
        }

        // parity: codemode/src/codemode/openapi/types.ts#AuthResolver [status=implemented hash=e5b925324430]
        public typealias AuthResolver = @Sendable (AuthContext) async throws -> Credential?

        // parity: codemode/src/codemode/openapi/types.ts#Options [status=implemented hash=c3165e6616d7]
        public struct Options: Sendable {
            public let spec: Document
            public let baseUrl: String?
            public let authResolve: AuthResolver?
            public let headers: [String: String]
            public let transport: (any HTTPTransport)?

            public init(
                spec: Document,
                baseUrl: String? = nil,
                authResolve: AuthResolver? = nil,
                headers: [String: String] = [:],
                transport: (any HTTPTransport)? = nil
            ) {
                self.spec = spec
                self.baseUrl = baseUrl
                self.authResolve = authResolve
                self.headers = headers
                self.transport = transport
            }
        }

        // parity: codemode/src/codemode/openapi/types.ts#Skipped [status=implemented hash=bbe7de22ec79]
        public struct Skipped: Equatable, Hashable, Sendable, Codable {
            public let method: String
            public let path: String
            public let reason: String

            public init(method: String, path: String, reason: String) {
                self.method = method
                self.path = path
                self.reason = reason
            }
        }

        // parity: codemode/src/codemode/openapi/types.ts#Tools [status=implemented hash=92c8bf003b3c]
        public typealias OpenAPITools = CodemodeEngine.Tools

        // parity: codemode/src/codemode/openapi/types.ts#Result [status=implemented hash=1e2a38ebca57]
        public struct SpecResult: Sendable {
            public let tools: OpenAPITools
            public let skipped: [Skipped]

            public init(tools: OpenAPITools, skipped: [Skipped]) {
                self.tools = tools
                self.skipped = skipped
            }
        }

        // parity: codemode/src/codemode/openapi/types.ts#Parsed [status=implemented hash=14735d91d099]
        public enum Parsed<T: Sendable>: Sendable {
            case ok(T)
            case err(String)
        }

        // parity: codemode/src/codemode/openapi/types.ts#InputLocation [status=implemented hash=c36ecaaed2d5]
        public enum InputLocation: String, Equatable, Hashable, Sendable, Codable {
            case path
            case query
            case header
            case body
        }

        // parity: codemode/src/codemode/openapi/types.ts#InputField [status=implemented hash=edfecb6681c5]
        public struct InputField: Equatable, Sendable {
            public let inputName: String
            public let name: String
            public let location: InputLocation
            public let required: Bool
            public let schema: Tool.JsonSchema
            public let style: String?
            public let explode: Bool?

            public init(
                inputName: String,
                name: String,
                location: InputLocation,
                required: Bool,
                schema: Tool.JsonSchema,
                style: String? = nil,
                explode: Bool? = nil
            ) {
                self.inputName = inputName
                self.name = name
                self.location = location
                self.required = required
                self.schema = schema
                self.style = style
                self.explode = explode
            }
        }

        // parity: codemode/src/codemode/openapi/types.ts#Body [status=implemented hash=6c538635ff24]
        public struct Body: Equatable, Hashable, Sendable, Codable {
            public let required: Bool
            public let mode: String
            public let mediaType: String

            public init(required: Bool, mode: String, mediaType: String) {
                self.required = required
                self.mode = mode
                self.mediaType = mediaType
            }
        }

        // parity: codemode/src/codemode/openapi/types.ts#OperationInput [status=implemented hash=ff165761f3cc]
        public struct OperationInput: Equatable, Sendable {
            public let fields: [InputField]
            public let body: Body?

            public init(fields: [InputField], body: Body?) {
                self.fields = fields
                self.body = body
            }
        }

        // parity: codemode/src/codemode/openapi/types.ts#SecurityRequirement [status=implemented hash=e2413867cead]
        public typealias SecurityRequirement = [String: [String]]

        // parity: codemode/src/codemode/openapi/types.ts#Plan [status=implemented hash=b96e2c8450a8]
        public struct Plan: Sendable {
            public let operation: Operation
            public let url: String
            public let fields: [InputField]
            public let body: Body?
            public let security: [SecurityRequirement]
            public let schemes: [String: SecurityScheme]
            public let authResolve: AuthResolver?
            public let headers: [String: String]

            public init(
                operation: Operation,
                url: String,
                fields: [InputField],
                body: Body?,
                security: [SecurityRequirement],
                schemes: [String: SecurityScheme],
                authResolve: AuthResolver?,
                headers: [String: String]
            ) {
                self.operation = operation
                self.url = url
                self.fields = fields
                self.body = body
                self.security = security
                self.schemes = schemes
                self.authResolve = authResolve
                self.headers = headers
            }
        }

        // parity: codemode/src/codemode/openapi/types.ts#AppliedAuth [status=implemented hash=176aff474e6c]
        public struct AppliedAuth: Equatable, Sendable {
            public let headers: [String: String]
            public let query: [String: String]

            public init(headers: [String: String] = [:], query: [String: String] = [:]) {
                self.headers = headers
                self.query = query
            }
        }

        // MARK: OpenAPI Spec Helpers (src/codemode/openapi/spec.ts)

        // parity: codemode/src/codemode/openapi/spec.ts#methods [status=implemented hash=a6fd6d467373]
        public static let methods: Set<String> = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]

        // parity: codemode/src/codemode/openapi/spec.ts#isRecord [status=implemented hash=edbb9bd43aff]
        public static func isRecord(_ value: JSONValue?) -> [String: JSONValue]? {
            if case .object(let d) = value { return d }
            return nil
        }

        // parity: codemode/src/codemode/openapi/spec.ts#nonEmptyString [status=implemented hash=95699f76476d]
        public static func nonEmptyString(_ value: JSONValue?) -> String? {
            if case .string(let s) = value, !s.isEmpty { return s }
            return nil
        }

        // parity: codemode/src/codemode/openapi/spec.ts#own [status=implemented hash=a17ed2b39d26]
        public static func own<T>(_ record: [String: T], _ key: String) -> T? {
            record[key]
        }

        // parity: codemode/src/codemode/openapi/spec.ts#resolve [status=implemented hash=5c0ddba7866c]
        public static func resolve(_ document: Document, _ value: JSONValue?) -> JSONValue? {
            func next(_ current: JSONValue?, seen: Set<String>) -> JSONValue? {
                guard let dict = isRecord(current),
                      let ref = nonEmptyString(dict["$ref"]),
                      ref.hasPrefix("#/"),
                      !seen.contains(ref)
                else { return current }
                let parts = ref.dropFirst(2).split(separator: "/").map {
                    String($0).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                }
                var cursor: JSONValue? = .object(document)
                for p in parts {
                    cursor = isRecord(cursor)?[p]
                }
                guard let target = cursor else { return current }
                return next(target, seen: seen.union([ref]))
            }
            return next(value, seen: [])
        }

        // parity: codemode/src/codemode/openapi/spec.ts#hasDirectionalSchemas [status=implemented hash=a4a14959675f]
        public static func hasDirectionalSchemas(_ document: Document) -> Bool {
            func contains(_ val: JSONValue) -> Bool {
                switch val {
                case .array(let arr): return arr.contains(where: contains)
                case .object(let dict):
                    if dict["readOnly"] == .bool(true) || dict["writeOnly"] == .bool(true) { return true }
                    return dict.values.contains(where: contains)
                default: return false
                }
            }
            return contains(.object(document))
        }

        // parity: codemode/src/codemode/openapi/spec.ts#componentDefinitions [status=implemented hash=44c19252d12e]
        public static func componentDefinitions(_ document: Document, direction: String = "request") -> [String: Tool.JsonSchema] {
            guard let comps = isRecord(document["components"]),
                  let schemas = isRecord(comps["schemas"])
            else { return [:] }
            var out: [String: Tool.JsonSchema] = [:]
            let hiddenKey = direction == "response" ? "writeOnly" : "readOnly"
            for (name, val) in schemas {
                if let dict = isRecord(val) {
                    out[name] = projectDirectional(dict, hiddenKey: hiddenKey)
                }
            }
            return out
        }

        private static func projectDirectional(_ schema: Tool.JsonSchema, hiddenKey: String) -> Tool.JsonSchema {
            var copy = schema
            if let props = isRecord(schema["properties"]) {
                var filtered: [String: JSONValue] = [:]
                var removed = Set<String>()
                for (k, v) in props {
                    if let pDict = isRecord(v), pDict[hiddenKey] == .bool(true) {
                        removed.insert(k)
                    } else if let pDict = isRecord(v) {
                        filtered[k] = .object(projectDirectional(pDict, hiddenKey: hiddenKey))
                    } else {
                        filtered[k] = v
                    }
                }
                copy["properties"] = .object(filtered)
                if case .array(let req) = schema["required"] {
                    copy["required"] = .array(req.filter {
                        if case .string(let s) = $0 { return !removed.contains(s) }
                        return true
                    })
                }
            }
            return copy
        }

        // parity: codemode/src/codemode/openapi/spec.ts#operationInput [status=implemented hash=a41acebe0a0a]
        public static func operationInput(
            _ document: Document,
            pathItem: [String: JSONValue],
            operation: [String: JSONValue]
        ) -> Parsed<OperationInput> {
            let ignoredHeaders: Set<String> = ["accept", "content-type", "authorization"]
            var declared: [String: (name: String, loc: String, param: [String: JSONValue])] = [:]
            var paramOrder: [String] = []
            let rawParams = (arrayOf(pathItem["parameters"]) + arrayOf(operation["parameters"]))
            for raw in rawParams {
                guard let resolved = isRecord(resolve(document, raw)) else {
                    return .err("parameter declaration is invalid or unresolved")
                }
                guard let name = nonEmptyString(resolved["name"]),
                      let loc = nonEmptyString(resolved["in"])
                else { return .err("parameter declaration is missing name or location") }
                let key = "\(loc):\(name)"
                if declared[key] == nil { paramOrder.append(key) }
                declared[key] = (name, loc, resolved)
            }
            var fields: [InputField] = []
            for key in paramOrder {
                guard let item = declared[key] else { continue }
                if item.loc == "cookie" { return .err("cookie parameter '\(item.name)' is not supported") }
                guard let location = InputLocation(rawValue: item.loc), location != .body else {
                    return .err("parameter '\(item.name)' uses unsupported location '\(item.loc)'")
                }
                if location == .header && ignoredHeaders.contains(item.name.lowercased()) { continue }
                let schema = isRecord(resolve(document, item.param["schema"])) ?? [:]
                let style = nonEmptyString(item.param["style"]) ?? (location == .query ? "form" : "simple")
                let explode: Bool
                if case .bool(let b) = item.param["explode"] { explode = b }
                else { explode = style == "form" }
                let required = item.param["required"] == .bool(true) || location == .path
                fields.append(InputField(
                    inputName: item.name,
                    name: item.name,
                    location: location,
                    required: required,
                    schema: schema,
                    style: style,
                    explode: explode
                ))
            }

            var bodyInfo: Body? = nil
            if let reqBody = isRecord(resolve(document, operation["requestBody"])) {
                let content = isRecord(reqBody["content"]) ?? [:]
                if let jsonEntry = content.first(where: { isJsonMediaType($0.key) }),
                   let mediaObj = isRecord(jsonEntry.value)
                {
                    let bodyReq = reqBody["required"] == .bool(true)
                    let bodySchema = isRecord(resolve(document, mediaObj["schema"])) ?? [:]
                    bodyInfo = Body(required: bodyReq, mode: "value", mediaType: jsonEntry.key)
                    fields.append(InputField(
                        inputName: "body",
                        name: "body",
                        location: .body,
                        required: bodyReq,
                        schema: bodySchema
                    ))
                } else {
                    let keys = content.keys.sorted().joined(separator: ", ")
                    return .err("request body has no JSON content (declared: \(keys.isEmpty ? "none" : keys))")
                }
            }

            // Disambiguate colliding names across locations
            var counts: [String: Int] = [:]
            for f in fields { counts[f.name, default: 0] += 1 }
            var usedNames = Set<String>()
            let resolvedFields: [InputField] = fields.map { f in
                let base = (counts[f.name] ?? 0) > 1 ? "\(f.location.rawValue)_\(f.name)" : f.name
                var candidate = base
                var idx = 2
                while usedNames.contains(candidate) {
                    candidate = "\(base)_\(idx)"
                    idx += 1
                }
                usedNames.insert(candidate)
                return InputField(
                    inputName: candidate,
                    name: f.name,
                    location: f.location,
                    required: f.required,
                    schema: f.schema,
                    style: f.style,
                    explode: f.explode
                )
            }
            return .ok(OperationInput(fields: resolvedFields, body: bodyInfo))
        }

        // parity: codemode/src/codemode/openapi/spec.ts#inputSchema [status=implemented hash=3f5f03400872]
        public static func inputSchema(
            _ fields: [InputField],
            definitions: [String: Tool.JsonSchema] = [:]
        ) -> Tool.JsonSchema {
            var props: [String: JSONValue] = [:]
            var required: [JSONValue] = []
            for f in fields {
                props[f.inputName] = .object(f.schema)
                if f.required { required.append(.string(f.inputName)) }
            }
            var schema: Tool.JsonSchema = ["type": .string("object"), "properties": .object(props)]
            if !required.isEmpty { schema["required"] = .array(required) }
            if !definitions.isEmpty {
                schema["$defs"] = .object(definitions.mapValues { .object($0) })
            }
            return schema
        }

        // parity: codemode/src/codemode/openapi/spec.ts#operationOutput [status=implemented hash=7cbc815fb956]
        public static func operationOutput(
            _ document: Document,
            operation: [String: JSONValue],
            definitions: [String: Tool.JsonSchema] = [:]
        ) -> Parsed<Tool.JsonSchema?> {
            if operation["x-websocket"] == .bool(true) {
                return .err("WebSocket operations are not supported")
            }
            guard let responses = isRecord(operation["responses"]) else { return .ok(nil) }
            var outcomes: [Tool.JsonSchema] = []
            for status in responses.keys.sorted() where status.hasPrefix("2") {
                guard let resolved = isRecord(resolve(document, responses[status])) else {
                    return .err("successful response declaration is invalid or unresolved")
                }
                let content = isRecord(resolved["content"]) ?? [:]
                if content.isEmpty {
                    outcomes.append(["type": .string("null")])
                    continue
                }
                for (mediaType, val) in content {
                    let norm = mediaType.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
                    if norm == "text/event-stream" { return .err("SSE operations are not supported") }
                    if !isJsonMediaType(norm) && !norm.hasPrefix("text/") { return .err("binary responses are not supported") }
                    if isJsonMediaType(norm) {
                        if let mObj = isRecord(val), let sc = isRecord(resolve(document, mObj["schema"])) {
                            if sc["format"] == .string("binary") { return .err("binary responses are not supported") }
                            outcomes.append(sc)
                        } else {
                            return .ok(nil)
                        }
                    } else {
                        outcomes.append(["type": .string("string")])
                    }
                }
            }
            if outcomes.isEmpty { return .ok(nil) }
            var final: Tool.JsonSchema = outcomes.count == 1 ? outcomes[0] : ["anyOf": .array(outcomes.map { .object($0) })]
            if !definitions.isEmpty { final["$defs"] = .object(definitions.mapValues { .object($0) }) }
            return .ok(final)
        }

        // parity: codemode/src/codemode/openapi/spec.ts#operationPath [status=implemented hash=b4156a1ae562]
        public static func operationPath(
            method: String,
            path: String,
            operation: [String: JSONValue],
            used: Set<String>,
            namespaces: Set<String>
        ) -> [String] {
            func sanitize(_ raw: String) -> String {
                let replaced = raw.replacingOccurrences(of: "[^A-Za-z0-9_$]+", with: "_", options: .regularExpression)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
                if replaced.isEmpty { return "operation" }
                if let f = replaced.first, f.isNumber { return "_\(replaced)" }
                return replaced
            }
            let segments: [String]
            if let opId = nonEmptyString(operation["operationId"]) {
                segments = opId.split(separator: ".").map { sanitize(String($0)) }
            } else {
                let parts = [method.lowercased()] + path.split(separator: "/").flatMap { seg -> [String] in
                    let s = String(seg)
                    if s.hasPrefix("{") && s.hasSuffix("}") {
                        return ["by", String(s.dropFirst().dropLast())]
                    }
                    return [s]
                }
                let camel = parts.enumerated().map { i, w in
                    let low = w.lowercased()
                    return i == 0 ? low : low.prefix(1).uppercased() + low.dropFirst()
                }.joined()
                segments = [sanitize(camel)]
            }
            let key = segments.joined(separator: ".")
            if !used.contains(key) && !namespaces.contains(key) { return segments }
            let fallback = segments.joined(separator: "_")
            var idx = 2
            while used.contains("\(fallback)_\(idx)") || namespaces.contains("\(fallback)_\(idx)") {
                idx += 1
            }
            return ["\(fallback)_\(idx)"]
        }

        // parity: codemode/src/codemode/openapi/spec.ts#validateBaseUrl [status=implemented hash=373ad6ee308f]
        public static func validateBaseUrl(_ value: String) -> Parsed<String> {
            let low = value.lowercased()
            guard low.hasPrefix("http://") || low.hasPrefix("https://"),
                  let url = URL(string: value),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else {
                return .err("server URL '\(value)' is not an absolute HTTP(S) URL")
            }
            if url.query != nil || url.fragment != nil {
                return .err("server URL '\(value)' contains an unsupported query string or fragment")
            }
            return .ok(value)
        }

        // parity: codemode/src/codemode/openapi/spec.ts#specServerUrl [status=implemented hash=e184a9c7ae24]
        public static func specServerUrl(_ source: [String: JSONValue]) -> Parsed<String> {
            let servers = arrayOf(source["servers"])
            guard let first = servers.compactMap({ isRecord($0) }).first,
                  let url = nonEmptyString(first["url"])
            else { return .err("spec declares no servers; pass baseUrl") }
            if url.contains("{") && url.contains("}") {
                return .err("server URL '\(url)' is not an absolute URL; pass baseUrl")
            }
            return validateBaseUrl(url)
        }

        // parity: codemode/src/codemode/openapi/spec.ts#securityRequirements [status=implemented hash=144964ab1a56]
        public static func securityRequirements(_ value: JSONValue?) -> Parsed<[SecurityRequirement]> {
            guard let value else { return .ok([]) }
            guard case .array(let list) = value else { return .err("security declaration is not an array") }
            var reqs: [SecurityRequirement] = []
            for item in list {
                guard let dict = isRecord(item) else { return .err("security requirement is not an object") }
                var req: SecurityRequirement = [:]
                for (name, rawScopes) in dict {
                    guard case .array(let sArr) = rawScopes else { return .err("security requirement scopes are not string arrays") }
                    var scopes: [String] = []
                    for s in sArr {
                        guard case .string(let str) = s else { return .err("security requirement scopes are not string arrays") }
                        scopes.append(str)
                    }
                    req[name] = scopes
                }
                reqs.append(req)
            }
            return .ok(reqs)
        }

        // parity: codemode/src/codemode/openapi/spec.ts#operationSecurityRequirements [status=implemented hash=d9e598abb8e8]
        public static func operationSecurityRequirements(
            _ value: JSONValue?,
            defaults: Parsed<[SecurityRequirement]>,
            schemes: [String: SecurityScheme]
        ) -> Parsed<[SecurityRequirement]> {
            let parsed = value == nil ? defaults : securityRequirements(value)
            guard case .ok(let reqs) = parsed else { return parsed }
            let supported = reqs.filter { req in
                req.keys.allSatisfy { name in
                    guard let s = schemes[name] else { return false }
                    if case .apiKey(_, let loc) = s, loc == "cookie" { return false }
                    return true
                }
            }
            if reqs.isEmpty || !supported.isEmpty { return .ok(supported) }
            let names = Array(Set(reqs.flatMap(\.keys))).sorted()
            if let cookie = names.first(where: {
                if case .apiKey(_, let loc) = schemes[$0] { return loc == "cookie" }
                return false
            }) {
                return .err("cookie authentication '\(cookie)' is not supported")
            }
            return .err("security requirement references missing or malformed scheme: \(names.joined(separator: ", "))")
        }

        // parity: codemode/src/codemode/openapi/spec.ts#securitySchemes [status=implemented hash=e82a89d57fe7]
        public static func securitySchemes(_ document: Document) -> [String: SecurityScheme] {
            guard let comps = isRecord(document["components"]),
                  let declared = isRecord(comps["securitySchemes"])
            else { return [:] }
            var out: [String: SecurityScheme] = [:]
            for (name, val) in declared {
                guard let resolved = isRecord(resolve(document, val)),
                      let type = nonEmptyString(resolved["type"])
                else { continue }
                switch type {
                case "apiKey":
                    if let param = nonEmptyString(resolved["name"]),
                       let loc = nonEmptyString(resolved["in"]),
                       loc == "header" || loc == "query" || loc == "cookie"
                    {
                        out[name] = .apiKey(name: param, location: loc)
                    }
                case "http":
                    if let scheme = nonEmptyString(resolved["scheme"])?.lowercased() {
                        out[name] = .http(scheme: scheme)
                    }
                case "oauth2": out[name] = .oauth2
                case "openIdConnect": out[name] = .openIdConnect
                default: break
                }
            }
            return out
        }

        private static func isJsonMediaType(_ mediaType: String) -> Bool {
            let norm = mediaType.split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            return norm == "application/json" || norm.hasSuffix("+json")
        }

        private static func arrayOf(_ val: JSONValue?) -> [JSONValue] {
            if case .array(let a) = val { return a }
            return []
        }

        // MARK: OpenAPI Runtime Invoke via HTTPTransport (src/codemode/openapi/runtime.ts)

        // parity: codemode/src/codemode/openapi/runtime.ts#invoke [status=implemented hash=f8af8b690976]
        public static func invoke(
            plan: Plan,
            input: JSONValue,
            transport: any HTTPTransport
        ) async throws -> JSONValue {
            let dict = isRecord(input) ?? [:]
            var urlStr = plan.url
            for field in plan.fields where field.location == .path {
                guard let val = dict[field.inputName] else {
                    throw toolError("Missing required path parameter '\(field.inputName)'.")
                }
                let encoded = CodemodeLanguage.percentEncode(scalarString(val), preserveURIReserved: false)
                if encoded.isEmpty || encoded == "." || encoded == ".." {
                    throw toolError("Invalid path parameter '\(field.inputName)'.")
                }
                urlStr = urlStr.replacingOccurrences(of: "{\(field.name)}", with: encoded)
            }
            var queryItems: [(String, String)] = []
            var headers = plan.headers
            var bodyBytes: [UInt8]? = nil

            for field in plan.fields {
                if field.required && field.location != .path && dict[field.inputName] == nil {
                    let label = field.location == .body ? "body field" : "\(field.location.rawValue) parameter"
                    throw toolError("Missing required \(label) '\(field.inputName)'.")
                }
                guard let val = dict[field.inputName] else { continue }
                switch field.location {
                case .query:
                    queryItems.append((field.name, scalarString(val)))
                case .header:
                    headers[field.name] = scalarString(val)
                case .body:
                    let text = CodemodeLanguage.serializeJsonCompact(val)
                    bodyBytes = Array(text.utf8)
                    headers["content-type"] = plan.body?.mediaType ?? "application/json"
                case .path:
                    break
                }
            }

            // Apply auth if configured
            if !plan.security.isEmpty {
                let auth = try await resolveAuth(plan: plan)
                for (k, v) in auth.headers { headers[k] = v }
                for (k, v) in auth.query { queryItems.append((k, v)) }
            }

            if !queryItems.isEmpty {
                let qs = CodemodeLanguage.buildPairs(queryItems)
                urlStr += urlStr.contains("?") ? "&\(qs)" : "?\(qs)"
            }

            let req = HTTPRequest(method: plan.operation.method, url: urlStr, headers: headers, body: bodyBytes)
            let resp: HTTPResponse
            do {
                resp = try await transport.send(req)
            } catch {
                throw toolError("\(plan.operation.method) \(plan.operation.path) failed: transport error", cause: error)
            }
            let text = String(decoding: resp.body, as: UTF8.self)
            let ct = resp.head.headers.first { $0.key.lowercased() == "content-type" }?.value ?? ""
            let isJson = isJsonMediaType(ct)
            let parsed: JSONValue?
            if text.isEmpty {
                parsed = .null
            } else if isJson {
                parsed = PureJSON.parse(text).map(pureToJsonValue)
            } else {
                parsed = .string(text)
            }
            if resp.head.statusCode < 200 || resp.head.statusCode >= 300 {
                let summary = text.isEmpty ? "no response body" : (text.count > 1024 ? "\(text.prefix(1024))..." : text)
                throw toolError("\(plan.operation.method) \(plan.operation.path) failed with HTTP \(resp.head.statusCode): \(summary)")
            }
            if isJson && parsed == nil {
                throw toolError("\(plan.operation.method) \(plan.operation.path) returned malformed JSON.")
            }
            return parsed ?? .null
        }

        private static func resolveAuth(plan: Plan) async throws -> AppliedAuth {
            var unavailable: [String] = []
            for requirement in plan.security {
                if requirement.isEmpty { return AppliedAuth() }
                var headers: [String: String] = [:]
                var query: [String: String] = [:]
                var ok = true
                for (name, scopes) in requirement {
                    guard let scheme = plan.schemes[name], let resolveFn = plan.authResolve else {
                        unavailable.append(name)
                        ok = false
                        break
                    }
                    guard let cred = try await resolveFn(AuthContext(name: name, definition: scheme, scopes: scopes, operation: plan.operation)) else {
                        unavailable.append(name)
                        ok = false
                        break
                    }
                    switch cred {
                    case .bearer(let tok): headers["authorization"] = "Bearer \(tok)"
                    case .basic(let u, let p): headers["authorization"] = "Basic \(bytesToBase64(Array("\(u):\(p)".utf8)))"
                    case .header(let hn, let hv): headers[hn.lowercased()] = hv
                    case .apiKey(let v):
                        if case .apiKey(let param, let loc) = scheme {
                            if loc == "header" { headers[param.lowercased()] = v }
                            else if loc == "query" { query[param] = v }
                        }
                    }
                }
                if ok { return AppliedAuth(headers: headers, query: query) }
            }
            throw toolError("\(plan.operation.method) \(plan.operation.path) requires authentication; no credential available for: \(Array(Set(unavailable)).sorted().joined(separator: ", ")).")
        }

        private static func scalarString(_ val: JSONValue) -> String {
            switch val {
            case .string(let s): return s
            case .int(let i): return String(i)
            case .double(let d): return CodemodeLanguage.formatJSNumber(d)
            case .bool(let b): return b ? "true" : "false"
            case .null: return "null"
            default: return CodemodeLanguage.serializeJsonCompact(val)
            }
        }

        private static func pureToJsonValue(_ pure: PureJSONValue) -> JSONValue {
            switch pure {
            case .null: return .null
            case .bool(let b): return .bool(b)
            case .number(let n):
                if n == n.rounded(.towardZero) && abs(n) <= 9_007_199_254_740_991 { return .int(Int64(n)) }
                return .double(n)
            case .string(let s): return .string(s)
            case .array(let a): return .array(a.map(pureToJsonValue))
            case .object(let pairs):
                var d: [String: JSONValue] = [:]
                for (k, v) in pairs { d[k] = pureToJsonValue(v) }
                return .object(d)
            }
        }

        // MARK: OpenAPI Spec Compiler (src/codemode/openapi/index.ts)

        // parity: codemode/src/codemode/openapi/index.ts#fromSpec [status=implemented hash=0359945af564]
        public static func fromSpec(_ options: Options) -> SpecResult {
            let document = options.spec
            let schemes = securitySchemes(document)
            let defaultSec = securityRequirements(document["security"])
            let reqDefs = componentDefinitions(document, direction: "request")
            let respDefs = hasDirectionalSchemas(document) ? componentDefinitions(document, direction: "response") : reqDefs
            let paths = isRecord(document["paths"]) ?? [:]
            var used = Set<String>()
            var namespaces = Set<String>()
            var skipped: [Skipped] = []
            var tools: OpenAPITools = [:]

            for path in paths.keys.sorted() {
                guard let pathVal = isRecord(paths[path]) else { continue }
                for method in pathVal.keys.sorted() {
                    guard methods.contains(method), let opVal = isRecord(pathVal[method]) else { continue }
                    let operation = Operation(
                        operationId: nonEmptyString(opVal["operationId"]),
                        method: method.uppercased(),
                        path: path,
                        summary: nonEmptyString(opVal["summary"]),
                        description: nonEmptyString(opVal["description"])
                    )
                    let outParsed = operationOutput(document, operation: opVal, definitions: respDefs)
                    guard case .ok(let outSchema) = outParsed else {
                        if case .err(let r) = outParsed { skipped.append(Skipped(method: operation.method, path: path, reason: r)) }
                        continue
                    }
                    let baseParsed: Parsed<String>
                    if let explicit = options.baseUrl { baseParsed = validateBaseUrl(explicit) }
                    else if opVal["servers"] != nil { baseParsed = specServerUrl(opVal) }
                    else if pathVal["servers"] != nil { baseParsed = specServerUrl(pathVal) }
                    else { baseParsed = specServerUrl(document) }
                    guard case .ok(let baseUrl) = baseParsed else {
                        if case .err(let r) = baseParsed { skipped.append(Skipped(method: operation.method, path: path, reason: r)) }
                        continue
                    }
                    let inParsed = operationInput(document, pathItem: pathVal, operation: opVal)
                    guard case .ok(let input) = inParsed else {
                        if case .err(let r) = inParsed { skipped.append(Skipped(method: operation.method, path: path, reason: r)) }
                        continue
                    }
                    let secParsed = operationSecurityRequirements(opVal["security"], defaults: defaultSec, schemes: schemes)
                    guard case .ok(let sec) = secParsed else {
                        if case .err(let r) = secParsed { skipped.append(Skipped(method: operation.method, path: path, reason: r)) }
                        continue
                    }
                    let cleanBase = baseUrl.hasSuffix("/") ? String(baseUrl.dropLast()) : baseUrl
                    let plan = Plan(
                        operation: operation,
                        url: "\(cleanBase)\(path)",
                        fields: input.fields,
                        body: input.body,
                        security: sec,
                        schemes: schemes,
                        authResolve: options.authResolve,
                        headers: options.headers
                    )
                    let segments = operationPath(method: method, path: path, operation: opVal, used: used, namespaces: namespaces)
                    used.insert(segments.joined(separator: "."))
                    if segments.count > 1 {
                        for i in 0..<(segments.count - 1) {
                            namespaces.insert(segments[0...i].joined(separator: "."))
                        }
                    }
                    let transport = options.transport
                    let def = Tool.make(Tool.Options(
                        description: operation.description ?? operation.summary ?? "\(operation.method) \(path)",
                        input: inputSchema(input.fields, definitions: reqDefs),
                        output: outSchema,
                        execute: { inputVal, _ in
                            guard let transport else {
                                throw toolError("No HTTPTransport configured for OpenAPI tool \(operation.method) \(path).")
                            }
                            return try await invoke(plan: plan, input: inputVal, transport: transport)
                        }
                    ))
                    insertTool(&tools, segments: segments, tool: def)
                }
            }
            return SpecResult(tools: tools, skipped: skipped)
        }

        private static func insertTool(_ tools: inout OpenAPITools, segments: [String], tool: Tool.Definition) {
            guard let head = segments.first else { return }
            if segments.count == 1 {
                tools[head] = .tool(tool)
                return
            }
            var sub: OpenAPITools
            if case .group(let existing) = tools[head] {
                sub = existing
            } else {
                sub = [:]
            }
            insertTool(&sub, segments: Array(segments.dropFirst()), tool: tool)
            tools[head] = .group(sub)
        }
    }
}

private extension CodemodeLanguage.Expression {
    var isStringLiteral: Bool {
        if case .literalString = self { return true }
        return false
    }
}
