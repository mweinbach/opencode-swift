import OpenCodeSchema
import OpenCodeUtil
import Synchronization

/// Confined JavaScript-subset language layer: tokens, lexer, recursive-descent/Pratt parser,
/// AST, diagnostics, scope analyzer, bytecode opcodes, and runtime primitives.
/// Ports `packages/codemode/src/language/*` (Part 1: AST, parser, diagnostics, scope, compiler, prelude, primitives).
public enum CodemodeLanguage {
    // MARK: - Source Locations & Diagnostics (src/language/runtime/model.ts)

    public struct SourceLocation: Equatable, Hashable, Sendable, Codable {
        public let line: Int
        public let column: Int

        public init(line: Int, column: Int) {
            self.line = line
            self.column = column
        }
    }

    // parity: psychoscript/src/runtime/model.ts#DiagnosticKind [status=implemented hash=8d4b9f3a4764]
    public typealias DiagnosticKind = String

    // parity: psychoscript/src/runtime/model.ts#Diagnostic [status=implemented hash=ce9d5f62e0d8]
    public struct Diagnostic: Error, Equatable, Hashable, Sendable, Codable {
        public let kind: DiagnosticKind
        public let message: String
        public let location: SourceLocation?
        public let suggestions: [String]?

        public init(
            kind: DiagnosticKind,
            message: String,
            location: SourceLocation? = nil,
            suggestions: [String]? = nil
        ) {
            self.kind = kind
            self.message = message
            self.location = location
            self.suggestions = suggestions
        }
    }

    // parity: psychoscript/src/runtime/model.ts#Binding [status=implemented hash=14e5129a1cc1]
    public struct Binding: Sendable {
        public let value: Value

        public init(value: Value) {
            self.value = value
        }
    }

    // parity: psychoscript/src/runtime/model.ts#GeneratorRequestKind [status=implemented hash=c7547eb98348]
    public enum GeneratorRequestKind: String, Equatable, Hashable, Sendable, Codable {
        case next
        case `return`
        case `throw`
    }

    public struct RuntimeSymbol: Equatable, Hashable, Sendable {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    // parity: psychoscript/src/runtime/model.ts#AsyncIteratorSymbol [status=implemented hash=d7914b39a121]
    public static let AsyncIteratorSymbol = RuntimeSymbol("Symbol.asyncIterator")

    // parity: psychoscript/src/runtime/model.ts#IteratorSymbol [status=implemented hash=2d12c1440ccc]
    public static let IteratorSymbol = RuntimeSymbol("Symbol.iterator")

    // parity: psychoscript/src/runtime/model.ts#Throw [status=implemented hash=13d2a2781ff8]
    public final class Throw: Error, Sendable {
        public let value: Value

        public init(_ value: Value) {
            self.value = value
        }
    }

    // parity: psychoscript/src/runtime/model.ts#PendingThrow [status=implemented hash=b3f9b298c43c]
    public final class PendingThrow: Error, Sendable {
        private struct Mutable: Sendable {
            var node: AstNode?
            var value: ErrorObj?
        }

        public let type: ErrorType
        public let message: String
        public let kind: DiagnosticKind
        public let suggestions: [String]?
        private let state: Mutex<Mutable>

        public var node: AstNode? {
            get { state.withLock { $0.node } }
            set { state.withLock { $0.node = newValue } }
        }

        public var value: ErrorObj? {
            get { state.withLock { $0.value } }
            set { state.withLock { $0.value = newValue } }
        }

        public init(
            type: ErrorType,
            message: String,
            node: AstNode? = nil,
            kind: DiagnosticKind = "ExecutionFailure",
            suggestions: [String]? = nil
        ) {
            self.type = type
            self.message = message
            self.kind = kind
            self.suggestions = suggestions
            self.state = Mutex(Mutable(node: node, value: nil))
        }
    }

    // parity: psychoscript/src/runtime/model.ts#HostFailure [status=implemented hash=73eee3dc8620]
    public final class HostFailure: Error, Sendable, CustomStringConvertible {
        public let kind: DiagnosticKind
        public let message: String
        public let suggestions: [String]

        public init(kind: DiagnosticKind, message: String, suggestions: [String] = []) {
            self.kind = kind
            self.message = message
            self.suggestions = suggestions
        }

        public var description: String { message }
    }

    // parity: psychoscript/src/runtime/model.ts#Lost [status=implemented hash=4dc2e63f5c6f]
    public final class Lost: Sendable {
        public let description: String

        public init(_ description: String) {
            self.description = description
        }
    }

    // parity: psychoscript/src/runtime/model.ts#lostError [status=implemented hash=b339b422c6d2]
    @inline(never) public static func lostError(_ description: String, node: AstNode? = nil) -> PendingThrow {
        PendingThrow(
            type: .typeError,
            message: "\(description) came from the host and was lost when the run was suspended; get it again after resuming.",
            node: node
        )
    }

    // parity: psychoscript/src/runtime/model.ts#typeError [status=implemented hash=d2e201e3d02b]
    @inline(never) public static func typeError(_ message: String, node: AstNode? = nil) -> PendingThrow {
        PendingThrow(type: .typeError, message: message, node: node)
    }

    // parity: psychoscript/src/runtime/model.ts#invalidData [status=implemented hash=f2a0ed07a30c]
    @inline(never) public static func invalidData(_ message: String, node: AstNode? = nil) -> PendingThrow {
        PendingThrow(type: .typeError, message: message, node: node, kind: "InvalidDataValue")
    }

    // parity: psychoscript/src/runtime/model.ts#rangeError [status=implemented hash=557f53331587]
    @inline(never) public static func rangeError(_ message: String, node: AstNode? = nil) -> PendingThrow {
        PendingThrow(type: .rangeError, message: message, node: node)
    }

    // parity: psychoscript/src/runtime/model.ts#referenceError [status=implemented hash=c336ed0b8e72]
    @inline(never) public static func referenceError(_ message: String, node: AstNode? = nil) -> PendingThrow {
        PendingThrow(type: .referenceError, message: message, node: node)
    }

    // parity: psychoscript/src/runtime/model.ts#syntaxError [status=implemented hash=b78d25883bc2]
    @inline(never) public static func syntaxError(_ message: String, node: AstNode? = nil) -> PendingThrow {
        PendingThrow(type: .syntaxError, message: message, node: node)
    }

    // parity: psychoscript/src/runtime/model.ts#uriError [status=implemented hash=151671bdf6db]
    @inline(never) public static func uriError(_ message: String, node: AstNode? = nil) -> PendingThrow {
        PendingThrow(type: .uriError, message: message, node: node)
    }

    // parity: psychoscript/src/runtime/model.ts#supportedSyntaxMessage [status=implemented hash=a1c2de2e65cb]
    public static let supportedSyntaxMessage: String =
        "This is a restricted JavaScript-like language. Supported: plain and async functions, data literals, destructuring, standard control flow, await and Promise, and built-ins such as Array, Object, Math, JSON, Date, RegExp, Map, Set, and URL. Unsupported: private class members, BigInt, and custom Symbols."

    // parity: psychoscript/src/runtime/model.ts#sourceLocation [status=implemented hash=f075447b8fab]
    public static func sourceLocation(_ node: AstNode) -> SourceLocation {
        node.location ?? SourceLocation(line: 1, column: 1)
    }

    // parity: psychoscript/src/runtime/model.ts#formatLocation [status=implemented hash=f753edfea735]
    public static func formatLocation(_ location: SourceLocation?) -> String {
        guard let location else { return "" }
        return " (line \(location.line), col \(location.column))"
    }

    // MARK: - Limits (src/language/runtime/limits.ts)

    // parity: psychoscript/src/runtime/limits.ts#MAX_STRING_LENGTH [status=implemented hash=75e2a193370c]
    public static let MAX_STRING_LENGTH: Int = 1 << 24

    // parity: psychoscript/src/runtime/limits.ts#MAX_ARRAY_LENGTH [status=implemented hash=2ef30070e0cf]
    public static let MAX_ARRAY_LENGTH: Int = 10_000_000

    // parity: psychoscript/src/runtime/limits.ts#MAX_PENDING_PROMISES [status=implemented hash=8dbd45e9f119]
    public static let MAX_PENDING_PROMISES: Int = 10_000

    // parity: psychoscript/src/runtime/limits.ts#MAX_VALUE_DEPTH [status=implemented hash=42e72293b65d]
    public static let MAX_VALUE_DEPTH: Int = 32

    // parity: psychoscript/src/runtime/limits.ts#checkStringLength [status=implemented hash=1f97f0f68e95]
    public static func checkStringLength(_ length: Int) throws {
        if length > MAX_STRING_LENGTH {
            throw rangeError("Invalid string length")
        }
    }

    // parity: psychoscript/src/runtime/limits.ts#checkArrayLength [status=implemented hash=6e3b76ef0c40]
    public static func checkArrayLength(_ length: Int) throws {
        if length > MAX_ARRAY_LENGTH {
            throw rangeError("Invalid array length")
        }
    }

    // MARK: - AST Definition

    public enum VariableKind: String, Equatable, Hashable, Sendable, Codable {
        case `var`
        case `let`
        case `const`
    }

    public enum BinaryOperator: String, Equatable, Hashable, Sendable, Codable {
        case add = "+"
        case sub = "-"
        case mul = "*"
        case div = "/"
        case mod = "%"
        case exp = "**"
        case eq = "=="
        case ne = "!="
        case seq = "==="
        case sne = "!=="
        case lt = "<"
        case le = "<="
        case gt = ">"
        case ge = ">="
        case bitAnd = "&"
        case bitOr = "|"
        case bitXor = "^"
        case shl = "<<"
        case sar = ">>"
        case shr = ">>>"
        case `in` = "in"
        case instanceof = "instanceof"
    }

    public enum LogicalOperator: String, Equatable, Hashable, Sendable, Codable {
        case and = "&&"
        case or = "||"
        case nullish = "??"
    }

    public enum AssignmentOperator: String, Equatable, Hashable, Sendable, Codable {
        case assign = "="
        case addAssign = "+="
        case subAssign = "-="
        case mulAssign = "*="
        case divAssign = "/="
        case modAssign = "%="
        case expAssign = "**="
        case bitAndAssign = "&="
        case bitOrAssign = "|="
        case bitXorAssign = "^="
        case shlAssign = "<<="
        case sarAssign = ">>="
        case shrAssign = ">>>="
        case andAssign = "&&="
        case orAssign = "||="
        case nullishAssign = "??="
    }

    public enum UnaryOperator: String, Equatable, Hashable, Sendable, Codable {
        case neg = "-"
        case plus = "+"
        case not = "!"
        case bitNot = "~"
        case typeof = "typeof"
        case void = "void"
        case delete = "delete"
    }

    public enum UpdateOperator: String, Equatable, Hashable, Sendable, Codable {
        case increment = "++"
        case decrement = "--"
    }

    public indirect enum Pattern: Equatable, Sendable {
        case identifier(name: String, loc: SourceLocation?)
        case array(elements: [Pattern?], rest: Pattern?, loc: SourceLocation?)
        case object(properties: [ObjectPatternProperty], rest: Pattern?, loc: SourceLocation?)
        case assignment(left: Pattern, right: Expression, loc: SourceLocation?)
        case member(object: Expression, property: PropertyKeyExpr, loc: SourceLocation?)
        /// `super.x = v` (and compound or update assignment) inside a method.
        case superMember(property: PropertyKeyExpr, loc: SourceLocation?)

        public var location: SourceLocation? {
            switch self {
            case .identifier(_, let loc),
                 .array(_, _, let loc),
                 .object(_, _, let loc),
                 .assignment(_, _, let loc),
                 .member(_, _, let loc),
                 .superMember(_, let loc):
                return loc
            }
        }
    }

    public struct ObjectPatternProperty: Equatable, Sendable {
        public let key: PropertyKeyExpr
        public let value: Pattern
        public let shorthand: Bool

        public init(key: PropertyKeyExpr, value: Pattern, shorthand: Bool) {
            self.key = key
            self.value = value
            self.shorthand = shorthand
        }
    }

    public indirect enum PropertyKeyExpr: Equatable, Sendable {
        case identifier(String, SourceLocation?)
        case string(String, SourceLocation?)
        case number(Double, SourceLocation?)
        case computed(Expression, SourceLocation?)

        public var location: SourceLocation? {
            switch self {
            case .identifier(_, let loc),
                 .string(_, let loc),
                 .number(_, let loc),
                 .computed(_, let loc):
                return loc
            }
        }
    }

    public enum ArrayElement: Equatable, Sendable {
        case expr(Expression)
        case spread(Expression, SourceLocation?)
        case hole
    }

    public enum ObjectProperty: Equatable, Sendable {
        case property(key: PropertyKeyExpr, value: Expression, shorthand: Bool, loc: SourceLocation?)
        case spread(Expression, SourceLocation?)
        /// An object literal's `get key() {}` or `set key(v) {}`.
        case accessor(kind: AccessorKind, key: PropertyKeyExpr, function: FunctionPayload, loc: SourceLocation?)
    }

    /// Which half of an accessor a `get` or `set` member defines.
    public enum AccessorKind: String, Equatable, Hashable, Sendable {
        case get
        case set
    }

    /// What a function is for: a plain function, a method (object literal or class, with a home object for `super`),
    /// a class constructor (`new` only; a derived one starts without `this`), or a class's field initializer.
    public enum FunctionKind: Equatable, Hashable, Sendable {
        case normal
        case method
        case classConstructor(derived: Bool)
        case fieldInit
    }

    /// One element of a class body: a method, accessor or field, static or on instances.
    public struct ClassMember: Equatable, Sendable {
        public enum Kind: Equatable, Hashable, Sendable {
            case method
            case getter
            case setter
            case field
        }

        public let kind: Kind
        public let isStatic: Bool
        public let key: PropertyKeyExpr
        /// A method's or accessor's function.
        public let function: FunctionPayload?
        /// A field's initializer, when it has one.
        public let value: Expression?
        public let loc: SourceLocation?

        public init(kind: Kind, isStatic: Bool, key: PropertyKeyExpr, function: FunctionPayload?, value: Expression?, loc: SourceLocation?) {
            self.kind = kind
            self.isStatic = isStatic
            self.key = key
            self.function = function
            self.value = value
            self.loc = loc
        }

        public var computed: Bool {
            if case .computed = key { return true }
            return false
        }
    }

    /// A class declaration or expression. `constructor` is the class's own, or a synthetic one when it has none:
    /// `constructor() {}`, or `constructor(...args) { super(...args) }` with `extends`.
    public struct ClassPayload: Equatable, Sendable {
        public let name: String?
        public let superClass: Expression?
        public let constructor: FunctionPayload
        public let members: [ClassMember]
        public let loc: SourceLocation?

        public init(name: String?, superClass: Expression?, constructor: FunctionPayload, members: [ClassMember], loc: SourceLocation?) {
            self.name = name
            self.superClass = superClass
            self.constructor = constructor
            self.members = members
            self.loc = loc
        }
    }

    public enum CallArgument: Equatable, Sendable {
        case expr(Expression)
        case spread(Expression, SourceLocation?)
    }

    public struct TemplateQuasi: Equatable, Sendable {
        public let cooked: String
        public let raw: String

        public init(cooked: String, raw: String) {
            self.cooked = cooked
            self.raw = raw
        }
    }

    public struct FunctionPayload: Equatable, Sendable {
        public let name: String?
        public let params: [Pattern]
        public let body: FunctionBody
        public let isAsync: Bool
        public let isGenerator: Bool
        public let isArrow: Bool
        public let loc: SourceLocation?
        public let kind: FunctionKind

        public init(
            name: String?,
            params: [Pattern],
            body: FunctionBody,
            isAsync: Bool,
            isGenerator: Bool,
            isArrow: Bool,
            loc: SourceLocation?,
            kind: FunctionKind = .normal
        ) {
            self.name = name
            self.params = params
            self.body = body
            self.isAsync = isAsync
            self.isGenerator = isGenerator
            self.isArrow = isArrow
            self.loc = loc
            self.kind = kind
        }

        /// The same function, made a method, class constructor or field initializer.
        public func with(kind: FunctionKind, name: String? = nil) -> FunctionPayload {
            FunctionPayload(
                name: name ?? self.name,
                params: params,
                body: body,
                isAsync: isAsync,
                isGenerator: isGenerator,
                isArrow: isArrow,
                loc: loc,
                kind: kind
            )
        }

        /// The number of parameters before the first default or rest one (a function's `length`).
        public var expectedArgumentCount: Int {
            var count = 0
            for param in params {
                if case .identifier = param { count += 1; continue }
                if case .array(let elements, .some, _) = param, elements.isEmpty { break }
                if case .assignment = param { break }
                count += 1
            }
            return count
        }
    }

    public enum FunctionBody: Equatable, Sendable {
        case block([Statement])
        case expression(Expression)
    }

    public indirect enum Expression: Equatable, Sendable {
        case literalNull(SourceLocation?)
        case literalBool(Bool, SourceLocation?)
        case literalNumber(Double, SourceLocation?)
        case literalString(String, SourceLocation?)
        case literalRegExp(pattern: String, flags: String, loc: SourceLocation?)
        case identifier(name: String, loc: SourceLocation?)
        case thisExpr(SourceLocation?)
        case array(elements: [ArrayElement], loc: SourceLocation?)
        case object(properties: [ObjectProperty], loc: SourceLocation?)
        case function(FunctionPayload)
        case templateLiteral(quasis: [TemplateQuasi], expressions: [Expression], loc: SourceLocation?)
        case taggedTemplate(tag: Expression, quasis: [TemplateQuasi], expressions: [Expression], loc: SourceLocation?)
        case member(object: Expression, property: PropertyKeyExpr, optional: Bool, loc: SourceLocation?)
        case call(callee: Expression, arguments: [CallArgument], optional: Bool, loc: SourceLocation?)
        case newExpr(callee: Expression, arguments: [CallArgument], loc: SourceLocation?)
        case unary(op: UnaryOperator, argument: Expression, loc: SourceLocation?)
        case update(op: UpdateOperator, argument: Expression, prefix: Bool, loc: SourceLocation?)
        case binary(op: BinaryOperator, left: Expression, right: Expression, loc: SourceLocation?)
        case logical(op: LogicalOperator, left: Expression, right: Expression, loc: SourceLocation?)
        case conditional(test: Expression, consequent: Expression, alternate: Expression, loc: SourceLocation?)
        case assignment(op: AssignmentOperator, left: Pattern, right: Expression, loc: SourceLocation?)
        case sequence(expressions: [Expression], loc: SourceLocation?)
        case awaitExpr(argument: Expression, loc: SourceLocation?)
        case yieldExpr(argument: Expression?, delegate: Bool, loc: SourceLocation?)
        case importExpr(source: Expression, loc: SourceLocation?)
        case chain(expression: Expression, loc: SourceLocation?)
        case classExpr(ClassPayload)
        /// `super.x` or `super[key]` inside a method: reads from the home object's prototype with `this` as receiver.
        case superMember(property: PropertyKeyExpr, loc: SourceLocation?)
        /// `super(...)` in a derived constructor. `passThrough` marks the synthetic default constructor's
        /// `super(...args)`, which hands its arguments on without iterating them.
        case superCall(arguments: [CallArgument], passThrough: Bool, loc: SourceLocation?)

        public var location: SourceLocation? {
            switch self {
            case .literalNull(let loc),
                 .literalBool(_, let loc),
                 .literalNumber(_, let loc),
                 .literalString(_, let loc),
                 .literalRegExp(_, _, let loc),
                 .identifier(_, let loc),
                 .thisExpr(let loc),
                 .array(_, let loc),
                 .object(_, let loc),
                 .templateLiteral(_, _, let loc),
                 .taggedTemplate(_, _, _, let loc),
                 .member(_, _, _, let loc),
                 .call(_, _, _, let loc),
                 .newExpr(_, _, let loc),
                 .unary(_, _, let loc),
                 .update(_, _, _, let loc),
                 .binary(_, _, _, let loc),
                 .logical(_, _, _, let loc),
                 .conditional(_, _, _, let loc),
                 .assignment(_, _, _, let loc),
                 .sequence(_, let loc),
                 .awaitExpr(_, let loc),
                 .yieldExpr(_, _, let loc),
                 .importExpr(_, let loc),
                 .chain(_, let loc),
                 .superMember(_, let loc),
                 .superCall(_, _, let loc):
                return loc
            case .function(let fn):
                return fn.loc
            case .classExpr(let cls):
                return cls.loc
            }
        }
    }

    public struct VariableDeclarator: Equatable, Sendable {
        public let id: Pattern
        public let initializer: Expression?
        public let loc: SourceLocation?

        public init(id: Pattern, initializer: Expression?, loc: SourceLocation?) {
            self.id = id
            self.initializer = initializer
            self.loc = loc
        }
    }

    public struct SwitchCase: Equatable, Sendable {
        public let test: Expression?
        public let consequent: [Statement]
        public let loc: SourceLocation?

        public init(test: Expression?, consequent: [Statement], loc: SourceLocation?) {
            self.test = test
            self.consequent = consequent
            self.loc = loc
        }
    }

    public struct CatchClause: Equatable, Sendable {
        public let param: Pattern?
        public let body: [Statement]
        public let loc: SourceLocation?

        public init(param: Pattern?, body: [Statement], loc: SourceLocation?) {
            self.param = param
            self.body = body
            self.loc = loc
        }
    }

    public enum ForInit: Equatable, Sendable {
        case variable(kind: VariableKind, declarations: [VariableDeclarator], loc: SourceLocation?)
        case expression(Expression)
    }

    public enum ForEachLeft: Equatable, Sendable {
        case variable(kind: VariableKind, pattern: Pattern, loc: SourceLocation?)
        case pattern(Pattern)
    }

    public enum ImportSpecifier: Equatable, Sendable {
        case defaultImport(local: String)
        case namespaceImport(local: String)
        case namedImport(imported: String, local: String)
    }

    public indirect enum Statement: Equatable, Sendable {
        case empty(SourceLocation?)
        case expression(Expression, SourceLocation?)
        case block([Statement], SourceLocation?)
        case variable(kind: VariableKind, declarations: [VariableDeclarator], loc: SourceLocation?)
        case functionDecl(FunctionPayload)
        case returnStmt(Expression?, SourceLocation?)
        case throwStmt(Expression, SourceLocation?)
        case breakStmt(label: String?, loc: SourceLocation?)
        case continueStmt(label: String?, loc: SourceLocation?)
        case ifStmt(test: Expression, consequent: Statement, alternate: Statement?, loc: SourceLocation?)
        case whileStmt(test: Expression, body: Statement, loc: SourceLocation?)
        case doWhileStmt(body: Statement, test: Expression, loc: SourceLocation?)
        case forStmt(initClause: ForInit?, test: Expression?, update: Expression?, body: Statement, loc: SourceLocation?)
        case forInStmt(left: ForEachLeft, right: Expression, body: Statement, loc: SourceLocation?)
        case forOfStmt(left: ForEachLeft, right: Expression, body: Statement, isAwait: Bool, loc: SourceLocation?)
        case switchStmt(discriminant: Expression, cases: [SwitchCase], loc: SourceLocation?)
        case tryStmt(block: [Statement], handler: CatchClause?, finalizer: [Statement]?, loc: SourceLocation?)
        case labeled(label: String, body: Statement, loc: SourceLocation?)
        case importDecl(specifiers: [ImportSpecifier], source: String, loc: SourceLocation?)
        case classDecl(ClassPayload)

        public var location: SourceLocation? {
            switch self {
            case .empty(let loc),
                 .expression(_, let loc),
                 .block(_, let loc),
                 .variable(_, _, let loc),
                 .returnStmt(_, let loc),
                 .throwStmt(_, let loc),
                 .breakStmt(_, let loc),
                 .continueStmt(_, let loc),
                 .ifStmt(_, _, _, let loc),
                 .whileStmt(_, _, let loc),
                 .doWhileStmt(_, _, let loc),
                 .forStmt(_, _, _, _, let loc),
                 .forInStmt(_, _, _, let loc),
                 .forOfStmt(_, _, _, _, let loc),
                 .switchStmt(_, _, let loc),
                 .tryStmt(_, _, _, let loc),
                 .labeled(_, _, let loc),
                 .importDecl(_, _, let loc):
                return loc
            case .functionDecl(let fn):
                return fn.loc
            case .classDecl(let cls):
                return cls.loc
            }
        }
    }

    public struct ProgramAST: Equatable, Sendable {
        public let body: [Statement]
        public let loc: SourceLocation?

        public init(body: [Statement], loc: SourceLocation? = SourceLocation(line: 1, column: 1)) {
            self.body = body
            self.loc = loc
        }
    }

    // parity: psychoscript/src/runtime/model.ts#AstNode [status=implemented hash=f6125e68a75d]
    public struct AstNode: Equatable, Sendable {
        public let type: String
        public let location: SourceLocation?
        public let nodeIndex: Int
        public let sourceId: String?

        public init(
            type: String,
            location: SourceLocation? = nil,
            nodeIndex: Int = -1,
            sourceId: String? = nil
        ) {
            self.type = type
            self.location = location
            self.nodeIndex = nodeIndex
            self.sourceId = sourceId
        }
    }

    // MARK: - Source Tracking (src/language/runtime/source.ts)

    // parity: psychoscript/src/runtime/source.ts#NodeId [status=implemented hash=23d4eba051b8]
    public struct NodeId: Equatable, Hashable, Sendable, Codable {
        public let source: String
        public let index: Int

        public init(source: String, index: Int) {
            self.source = source
            self.index = index
        }
    }

    // parity: psychoscript/src/runtime/source.ts#Source [status=implemented hash=f4d6418edda2]
    public final class Source: Sendable {
        public let id: String
        public let code: String
        private let storedProgram: ProgramAST
        private let storedNodes: [AstNode]

        // parity: psychoscript/src/runtime/source.ts#Source.program [status=implemented hash=f8e23bf26c60]
        public var program: ProgramAST { storedProgram }

        // parity: psychoscript/src/runtime/source.ts#Source.nodes [status=implemented hash=6b00ceea4e28]
        public var nodes: [AstNode] { storedNodes }

        public init(id: String, code: String, program: ProgramAST) {
            self.id = id
            self.code = code
            self.storedProgram = program
            self.storedNodes = Self.collectNodes(program: program, sourceId: id)
        }

        // parity: psychoscript/src/runtime/source.ts#Source.node [status=implemented hash=0ddf33fcbec0]
        public func node(_ id: NodeId) -> AstNode? {
            guard id.source == self.id, id.index >= 0, id.index < storedNodes.count else { return nil }
            return storedNodes[id.index]
        }

        private static func collectNodes(program: ProgramAST, sourceId: String) -> [AstNode] {
            var list: [AstNode] = []
            func append(_ type: String, _ loc: SourceLocation?) {
                list.append(AstNode(type: type, location: loc, nodeIndex: list.count, sourceId: sourceId))
            }
            func walkExpr(_ expr: Expression) {
                switch expr {
                case .literalNull(let l): append("Literal", l)
                case .literalBool(_, let l): append("Literal", l)
                case .literalNumber(_, let l): append("Literal", l)
                case .literalString(_, let l): append("Literal", l)
                case .literalRegExp(_, _, let l): append("Literal", l)
                case .identifier(_, let l): append("Identifier", l)
                case .thisExpr(let l): append("ThisExpression", l)
                case .array(let elements, let l):
                    append("ArrayExpression", l)
                    for el in elements {
                        switch el {
                        case .expr(let e): walkExpr(e)
                        case .spread(let e, let sl): append("SpreadElement", sl); walkExpr(e)
                        case .hole: break
                        }
                    }
                case .object(let props, let l):
                    append("ObjectExpression", l)
                    for prop in props {
                        switch prop {
                        case .property(let k, let v, _, let pl):
                            append("Property", pl)
                            if case .computed(let ce, _) = k { walkExpr(ce) }
                            walkExpr(v)
                        case .spread(let e, let sl):
                            append("SpreadElement", sl)
                            walkExpr(e)
                        case .accessor(_, let k, let fn, let pl):
                            append("Property", pl)
                            if case .computed(let ce, _) = k { walkExpr(ce) }
                            walkFunction(fn)
                        }
                    }
                case .classExpr(let cls):
                    append("ClassExpression", cls.loc)
                    walkClass(cls)
                case .superMember(let prop, let l):
                    append("MemberExpression", l)
                    if case .computed(let ce, _) = prop { walkExpr(ce) }
                case .superCall(let args, _, let l):
                    append("CallExpression", l)
                    for a in args {
                        switch a {
                        case .expr(let e), .spread(let e, _): walkExpr(e)
                        }
                    }
                case .function(let fn):
                    append(fn.isArrow ? "ArrowFunctionExpression" : "FunctionExpression", fn.loc)
                    switch fn.body {
                    case .block(let stmts): for s in stmts { walkStmt(s) }
                    case .expression(let e): walkExpr(e)
                    }
                case .templateLiteral(_, let exprs, let l):
                    append("TemplateLiteral", l)
                    for e in exprs { walkExpr(e) }
                case .taggedTemplate(let tag, _, let exprs, let l):
                    append("TaggedTemplateExpression", l)
                    walkExpr(tag)
                    for e in exprs { walkExpr(e) }
                case .member(let obj, let prop, _, let l):
                    append("MemberExpression", l)
                    walkExpr(obj)
                    if case .computed(let ce, _) = prop { walkExpr(ce) }
                case .call(let callee, let args, _, let l):
                    append("CallExpression", l)
                    walkExpr(callee)
                    for arg in args {
                        switch arg {
                        case .expr(let e): walkExpr(e)
                        case .spread(let e, let sl): append("SpreadElement", sl); walkExpr(e)
                        }
                    }
                case .newExpr(let callee, let args, let l):
                    append("NewExpression", l)
                    walkExpr(callee)
                    for arg in args {
                        switch arg {
                        case .expr(let e): walkExpr(e)
                        case .spread(let e, let sl): append("SpreadElement", sl); walkExpr(e)
                        }
                    }
                case .unary(_, let arg, let l): append("UnaryExpression", l); walkExpr(arg)
                case .update(_, let arg, _, let l): append("UpdateExpression", l); walkExpr(arg)
                case .binary(_, let lhs, let rhs, let l): append("BinaryExpression", l); walkExpr(lhs); walkExpr(rhs)
                case .logical(_, let lhs, let rhs, let l): append("LogicalExpression", l); walkExpr(lhs); walkExpr(rhs)
                case .conditional(let t, let c, let a, let l): append("ConditionalExpression", l); walkExpr(t); walkExpr(c); walkExpr(a)
                case .assignment(_, _, let rhs, let l): append("AssignmentExpression", l); walkExpr(rhs)
                case .sequence(let exprs, let l): append("SequenceExpression", l); for e in exprs { walkExpr(e) }
                case .awaitExpr(let arg, let l): append("AwaitExpression", l); walkExpr(arg)
                case .yieldExpr(let arg, _, let l): append("YieldExpression", l); if let arg { walkExpr(arg) }
                case .importExpr(let src, let l): append("ImportExpression", l); walkExpr(src)
                case .chain(let inner, let l): append("ChainExpression", l); walkExpr(inner)
                }
            }
            func walkFunction(_ fn: FunctionPayload) {
                append("FunctionExpression", fn.loc)
                switch fn.body {
                case .block(let stmts): for s in stmts { walkStmt(s) }
                case .expression(let e): walkExpr(e)
                }
            }
            func walkClass(_ cls: ClassPayload) {
                if let superClass = cls.superClass { walkExpr(superClass) }
                walkFunction(cls.constructor)
                for member in cls.members {
                    append(member.kind == .field ? "PropertyDefinition" : "MethodDefinition", member.loc)
                    if case .computed(let ce, _) = member.key { walkExpr(ce) }
                    if let fn = member.function { walkFunction(fn) }
                    if let value = member.value { walkExpr(value) }
                }
            }
            func walkStmt(_ stmt: Statement) {
                switch stmt {
                case .empty(let l): append("EmptyStatement", l)
                case .classDecl(let cls):
                    append("ClassDeclaration", cls.loc)
                    walkClass(cls)
                case .expression(let e, let l): append("ExpressionStatement", l); walkExpr(e)
                case .block(let stmts, let l): append("BlockStatement", l); for s in stmts { walkStmt(s) }
                case .variable(_, let decls, let l):
                    append("VariableDeclaration", l)
                    for d in decls {
                        append("VariableDeclarator", d.loc)
                        if let initExpr = d.initializer { walkExpr(initExpr) }
                    }
                case .functionDecl(let fn):
                    append("FunctionDeclaration", fn.loc)
                    if case .block(let stmts) = fn.body { for s in stmts { walkStmt(s) } }
                case .returnStmt(let e, let l): append("ReturnStatement", l); if let e { walkExpr(e) }
                case .throwStmt(let e, let l): append("ThrowStatement", l); walkExpr(e)
                case .breakStmt(_, let l): append("BreakStatement", l)
                case .continueStmt(_, let l): append("ContinueStatement", l)
                case .ifStmt(let t, let c, let a, let l):
                    append("IfStatement", l); walkExpr(t); walkStmt(c); if let a { walkStmt(a) }
                case .whileStmt(let t, let b, let l): append("WhileStatement", l); walkExpr(t); walkStmt(b)
                case .doWhileStmt(let b, let t, let l): append("DoWhileStatement", l); walkStmt(b); walkExpr(t)
                case .forStmt(let ini, let t, let u, let b, let l):
                    append("ForStatement", l)
                    if case .expression(let e) = ini { walkExpr(e) }
                    if case .variable(_, let ds, _) = ini { for d in ds { if let ie = d.initializer { walkExpr(ie) } } }
                    if let t { walkExpr(t) }
                    if let u { walkExpr(u) }
                    walkStmt(b)
                case .forInStmt(_, let r, let b, let l): append("ForInStatement", l); walkExpr(r); walkStmt(b)
                case .forOfStmt(_, let r, let b, _, let l): append("ForOfStatement", l); walkExpr(r); walkStmt(b)
                case .switchStmt(let d, let cases, let l):
                    append("SwitchStatement", l); walkExpr(d)
                    for c in cases {
                        append("SwitchCase", c.loc)
                        if let ct = c.test { walkExpr(ct) }
                        for s in c.consequent { walkStmt(s) }
                    }
                case .tryStmt(let blk, let handler, let fin, let l):
                    append("TryStatement", l)
                    for s in blk { walkStmt(s) }
                    if let handler {
                        append("CatchClause", handler.loc)
                        for s in handler.body { walkStmt(s) }
                    }
                    if let fin { for s in fin { walkStmt(s) } }
                case .labeled(_, let b, let l): append("LabeledStatement", l); walkStmt(b)
                case .importDecl(_, _, let l): append("ImportDeclaration", l)
                }
            }
            append("Program", program.loc)
            for s in program.body { walkStmt(s) }
            return list
        }
    }

    // parity: psychoscript/src/runtime/source.ts#nodeId [status=implemented hash=5918d8900c6a]
    public static func nodeId(_ node: AstNode) -> NodeId? {
        guard let sourceId = node.sourceId, node.nodeIndex >= 0 else { return nil }
        return NodeId(source: sourceId, index: node.nodeIndex)
    }

    // parity: psychoscript/src/runtime/source.ts#sourceOf [status=adapted hash=2763eaf838d2]
    public static func sourceOf(_ node: AstNode, in sources: [String: Source] = [:]) -> Source? {
        guard let sourceId = node.sourceId else { return nil }
        return sources[sourceId]
    }

    // parity: psychoscript/src/runtime/source.ts#inPrelude [status=implemented hash=899255e9cba7]
    public static func inPrelude(_ node: AstNode) -> Bool {
        node.location == nil
    }

    // MARK: - Lexer & Recursive-Descent Parser

    public enum TokenKind: Equatable, Sendable {
        case eof
        case identifier(String)
        case number(Double)
        case string(String)
        case regExp(pattern: String, flags: String)
        case templateNoSub(cooked: String, raw: String)
        case templateHead(cooked: String, raw: String)
        case templateMiddle(cooked: String, raw: String)
        case templateTail(cooked: String, raw: String)
        case keyword(String)
        case punct(String)
    }

    public struct Token: Equatable, Sendable {
        public let kind: TokenKind
        public let location: SourceLocation
        public let precededByNewline: Bool

        public init(kind: TokenKind, location: SourceLocation, precededByNewline: Bool) {
            self.kind = kind
            self.location = location
            self.precededByNewline = precededByNewline
        }
    }

    public struct ParseFailure: Error, Sendable {
        public let diagnostic: Diagnostic

        public init(diagnostic: Diagnostic) {
            self.diagnostic = diagnostic
        }
    }

    private static let jsKeywords: Set<String> = [
        "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default",
        "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function",
        "if", "import", "in", "instanceof", "let", "new", "null", "return", "super", "switch",
        "this", "throw", "true", "try", "typeof", "var", "void", "while", "with", "yield",
    ]

    /// Stateful JavaScript lexer supporting regex/division context disambiguation and nested templates.
    public struct Lexer: Sendable {
        private let scalars: [Unicode.Scalar]
        private var index: Int = 0
        private var line: Int = 1
        private var column: Int = 1
        private var braceDepthStack: [Int] = []

        public init(_ source: String) {
            self.scalars = Array(source.unicodeScalars)
        }

        private var isAtEnd: Bool { index >= scalars.count }
        private func peek(_ offset: Int = 0) -> Unicode.Scalar? {
            let i = index + offset
            return i < scalars.count ? scalars[i] : nil
        }

        @discardableResult
        private mutating func advance() -> Unicode.Scalar {
            let sc = scalars[index]
            index += 1
            if sc == "\n" {
                line += 1
                column = 1
            } else {
                column += 1
            }
            return sc
        }

        private mutating func skipWhitespaceAndComments() throws -> Bool {
            var sawNewline = false
            while !isAtEnd {
                let sc = scalars[index]
                if sc == "\n" || sc == "\r" || sc == "\u{2028}" || sc == "\u{2029}" {
                    sawNewline = true
                    if sc == "\r" && peek(1) == "\n" {
                        index += 1
                    }
                    _ = advance()
                } else if sc == " " || sc == "\t" || sc == "\u{000B}" || sc == "\u{000C}" || sc == "\u{00A0}" || sc == "\u{FEFF}" {
                    _ = advance()
                } else if sc == "/" && peek(1) == "/" {
                    while !isAtEnd && scalars[index] != "\n" && scalars[index] != "\r" {
                        _ = advance()
                    }
                } else if sc == "/" && peek(1) == "*" {
                    let startLoc = SourceLocation(line: line, column: column)
                    _ = advance(); _ = advance()
                    var closed = false
                    while !isAtEnd {
                        if scalars[index] == "\n" || scalars[index] == "\r" { sawNewline = true }
                        if scalars[index] == "*" && peek(1) == "/" {
                            _ = advance(); _ = advance()
                            closed = true
                            break
                        }
                        _ = advance()
                    }
                    if !closed {
                        throw makeSyntaxFailure("Unterminated block comment", at: startLoc)
                    }
                } else {
                    break
                }
            }
            return sawNewline
        }

        public mutating func nextToken(allowRegex: Bool) throws -> Token {
            let sawNewline = try skipWhitespaceAndComments()
            let startLoc = SourceLocation(line: line, column: column)
            guard !isAtEnd else {
                return Token(kind: .eof, location: startLoc, precededByNewline: sawNewline)
            }
            let ch = scalars[index]

            // Handle closing `}` of a template expression `${...}`
            if ch == "}" && !braceDepthStack.isEmpty {
                let top = braceDepthStack[braceDepthStack.count - 1]
                if top == 0 {
                    braceDepthStack.removeLast()
                    _ = advance() // consume '}'
                    return try readTemplatePart(isHead: false, startLoc: startLoc, precededByNewline: sawNewline)
                } else {
                    braceDepthStack[braceDepthStack.count - 1] = top - 1
                    _ = advance()
                    return Token(kind: .punct("}"), location: startLoc, precededByNewline: sawNewline)
                }
            }

            if ch == "{" && !braceDepthStack.isEmpty {
                braceDepthStack[braceDepthStack.count - 1] += 1
                _ = advance()
                return Token(kind: .punct("{"), location: startLoc, precededByNewline: sawNewline)
            }

            // Template literal
            if ch == "`" {
                _ = advance()
                return try readTemplatePart(isHead: true, startLoc: startLoc, precededByNewline: sawNewline)
            }

            // String literal
            if ch == "\"" || ch == "'" {
                let str = try readString(quote: ch, startLoc: startLoc)
                return Token(kind: .string(str), location: startLoc, precededByNewline: sawNewline)
            }

            // Number literal
            if isDigit(ch) || (ch == "." && peek(1).map(isDigit) == true) {
                let num = try readNumber(startLoc: startLoc)
                return Token(kind: .number(num), location: startLoc, precededByNewline: sawNewline)
            }

            // Identifier / keyword
            if isIdentStart(ch) {
                var ident = ""
                while !isAtEnd && isIdentContinue(scalars[index]) {
                    ident.unicodeScalars.append(advance())
                }
                if Self.isKeyword(ident) {
                    return Token(kind: .keyword(ident), location: startLoc, precededByNewline: sawNewline)
                }
                return Token(kind: .identifier(ident), location: startLoc, precededByNewline: sawNewline)
            }

            // RegExp literal when allowed by parser context
            if ch == "/" && allowRegex && peek(1) != "/" && peek(1) != "*" {
                let (pattern, flags) = try readRegExp(startLoc: startLoc)
                return Token(kind: .regExp(pattern: pattern, flags: flags), location: startLoc, precededByNewline: sawNewline)
            }

            // Punctuators (longest match)
            let punct = try readPunctuator(startLoc: startLoc)
            return Token(kind: .punct(punct), location: startLoc, precededByNewline: sawNewline)
        }

        private static func isKeyword(_ word: String) -> Bool {
            CodemodeLanguage.jsKeywords.contains(word)
        }

        private func isDigit(_ sc: Unicode.Scalar) -> Bool {
            sc.value >= 0x30 && sc.value <= 0x39
        }

        private func isHexDigit(_ sc: Unicode.Scalar) -> Bool {
            (sc.value >= 0x30 && sc.value <= 0x39)
                || (sc.value >= 0x41 && sc.value <= 0x46)
                || (sc.value >= 0x61 && sc.value <= 0x66)
        }

        private func isIdentStart(_ sc: Unicode.Scalar) -> Bool {
            (sc.value >= 0x41 && sc.value <= 0x5A)
                || (sc.value >= 0x61 && sc.value <= 0x7A)
                || sc == "_" || sc == "$" || sc.value >= 0x80 && sc.properties.isXIDStart
        }

        private func isIdentContinue(_ sc: Unicode.Scalar) -> Bool {
            isIdentStart(sc) || isDigit(sc) || (sc.value >= 0x80 && sc.properties.isXIDContinue)
        }

        private mutating func readEscapeSequence(startLoc: SourceLocation) throws -> String {
            guard !isAtEnd else { throw makeSyntaxFailure("Unterminated escape sequence", at: startLoc) }
            let esc = advance()
            switch esc {
            case "n": return "\n"
            case "r": return "\r"
            case "t": return "\t"
            case "b": return "\u{08}"
            case "f": return "\u{0C}"
            case "v": return "\u{0B}"
            case "0": return "\0"
            case "\\": return "\\"
            case "'": return "'"
            case "\"": return "\""
            case "`": return "`"
            case "$": return "$"
            case "\n": return ""
            case "\r":
                if peek() == "\n" { _ = advance() }
                return ""
            case "x":
                let hex = try readFixedHex(2, startLoc: startLoc)
                guard let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) else {
                    throw makeSyntaxFailure("Invalid hex escape sequence", at: startLoc)
                }
                return String(sc)
            case "u":
                if peek() == "{" {
                    _ = advance()
                    var hex = ""
                    while !isAtEnd && scalars[index] != "}" {
                        hex.unicodeScalars.append(advance())
                    }
                    guard !isAtEnd else { throw makeSyntaxFailure("Unterminated unicode escape", at: startLoc) }
                    _ = advance()
                    guard !hex.isEmpty, let v = UInt32(hex, radix: 16), let sc = Unicode.Scalar(v) else {
                        throw makeSyntaxFailure("Invalid unicode code point escape", at: startLoc)
                    }
                    return String(sc)
                }
                let hex = try readFixedHex(4, startLoc: startLoc)
                guard let u1 = UInt16(hex, radix: 16) else {
                    throw makeSyntaxFailure("Invalid unicode escape", at: startLoc)
                }
                if u1 >= 0xD800 && u1 <= 0xDBFF, peek() == "\\", peek(1) == "u" {
                    let savedIdx = index
                    let savedLine = line
                    let savedCol = column
                    _ = advance(); _ = advance()
                    if let hex2 = try? readFixedHex(4, startLoc: startLoc),
                       let u2 = UInt16(hex2, radix: 16),
                       u2 >= 0xDC00 && u2 <= 0xDFFF
                    {
                        let combined = 0x10000 + ((UInt32(u1 - 0xD800) << 10) | UInt32(u2 - 0xDC00))
                        if let sc = Unicode.Scalar(combined) { return String(sc) }
                    }
                    index = savedIdx; line = savedLine; column = savedCol
                }
                guard let sc = Unicode.Scalar(u1) else {
                    throw makeSyntaxFailure("Invalid unicode surrogate escape", at: startLoc)
                }
                return String(sc)
            default:
                return String(esc)
            }
        }

        private mutating func readFixedHex(_ count: Int, startLoc: SourceLocation) throws -> String {
            var hex = ""
            for _ in 0..<count {
                guard let sc = peek(), isHexDigit(sc) else {
                    throw makeSyntaxFailure("Invalid hexadecimal escape sequence", at: startLoc)
                }
                hex.unicodeScalars.append(advance())
            }
            return hex
        }

        private mutating func readString(quote: Unicode.Scalar, startLoc: SourceLocation) throws -> String {
            _ = advance() // opening quote
            var out = ""
            while !isAtEnd {
                let sc = scalars[index]
                if sc == quote {
                    _ = advance()
                    return out
                }
                if sc == "\n" || sc == "\r" {
                    throw makeSyntaxFailure("Unterminated string constant", at: startLoc)
                }
                if sc == "\\" {
                    _ = advance()
                    out.append(try readEscapeSequence(startLoc: startLoc))
                } else {
                    out.unicodeScalars.append(advance())
                }
            }
            throw makeSyntaxFailure("Unterminated string constant", at: startLoc)
        }

        private mutating func readTemplatePart(
            isHead: Bool,
            startLoc: SourceLocation,
            precededByNewline: Bool
        ) throws -> Token {
            var cooked = ""
            var raw = ""
            while !isAtEnd {
                let sc = scalars[index]
                if sc == "`" {
                    _ = advance()
                    return Token(
                        kind: isHead ? .templateNoSub(cooked: cooked, raw: raw) : .templateTail(cooked: cooked, raw: raw),
                        location: startLoc,
                        precededByNewline: precededByNewline
                    )
                }
                if sc == "$" && peek(1) == "{" {
                    _ = advance(); _ = advance()
                    braceDepthStack.append(0)
                    return Token(
                        kind: isHead ? .templateHead(cooked: cooked, raw: raw) : .templateMiddle(cooked: cooked, raw: raw),
                        location: startLoc,
                        precededByNewline: precededByNewline
                    )
                }
                if sc == "\\" {
                    let beforeIdx = index
                    _ = advance()
                    cooked.append(try readEscapeSequence(startLoc: startLoc))
                    for k in beforeIdx..<index {
                        raw.unicodeScalars.append(scalars[k])
                    }
                } else if sc == "\r" {
                    _ = advance()
                    if peek() == "\n" { _ = advance() }
                    cooked.append("\n")
                    raw.append("\n")
                } else {
                    let c = advance()
                    cooked.unicodeScalars.append(c)
                    raw.unicodeScalars.append(c)
                }
            }
            throw makeSyntaxFailure("Unterminated template literal", at: startLoc)
        }

        private mutating func readNumber(startLoc: SourceLocation) throws -> Double {
            if scalars[index] == "0", let next = peek(1) {
                if next == "x" || next == "X" {
                    _ = advance(); _ = advance()
                    var hex = ""
                    while !isAtEnd && (isHexDigit(scalars[index]) || scalars[index] == "_") {
                        let c = advance()
                        if c != "_" { hex.unicodeScalars.append(c) }
                    }
                    if peek() == "n" {
                        throw ParseFailure(diagnostic: Diagnostic(
                            kind: "UnsupportedSyntax",
                            message: "BigInt literals are not supported.\(CodemodeLanguage.formatLocation(startLoc))",
                            location: startLoc,
                            suggestions: [CodemodeLanguage.supportedSyntaxMessage]
                        ))
                    }
                    guard !hex.isEmpty, let v = UInt64(hex, radix: 16) else {
                        throw makeSyntaxFailure("Invalid hexadecimal number literal", at: startLoc)
                    }
                    return Double(v)
                } else if next == "b" || next == "B" {
                    _ = advance(); _ = advance()
                    var bin = ""
                    while !isAtEnd && (scalars[index] == "0" || scalars[index] == "1" || scalars[index] == "_") {
                        let c = advance()
                        if c != "_" { bin.unicodeScalars.append(c) }
                    }
                    if peek() == "n" {
                        throw ParseFailure(diagnostic: Diagnostic(
                            kind: "UnsupportedSyntax",
                            message: "BigInt literals are not supported.\(CodemodeLanguage.formatLocation(startLoc))",
                            location: startLoc,
                            suggestions: [CodemodeLanguage.supportedSyntaxMessage]
                        ))
                    }
                    guard !bin.isEmpty, let v = UInt64(bin, radix: 2) else {
                        throw makeSyntaxFailure("Invalid binary number literal", at: startLoc)
                    }
                    return Double(v)
                } else if next == "o" || next == "O" {
                    _ = advance(); _ = advance()
                    var oct = ""
                    while !isAtEnd && ((scalars[index].value >= 0x30 && scalars[index].value <= 0x37) || scalars[index] == "_") {
                        let c = advance()
                        if c != "_" { oct.unicodeScalars.append(c) }
                    }
                    if peek() == "n" {
                        throw ParseFailure(diagnostic: Diagnostic(
                            kind: "UnsupportedSyntax",
                            message: "BigInt literals are not supported.\(CodemodeLanguage.formatLocation(startLoc))",
                            location: startLoc,
                            suggestions: [CodemodeLanguage.supportedSyntaxMessage]
                        ))
                    }
                    guard !oct.isEmpty, let v = UInt64(oct, radix: 8) else {
                        throw makeSyntaxFailure("Invalid octal number literal", at: startLoc)
                    }
                    return Double(v)
                }
            }

            var raw = ""
            while !isAtEnd && (isDigit(scalars[index]) || scalars[index] == "_") {
                let c = advance()
                if c != "_" { raw.unicodeScalars.append(c) }
            }
            if peek() == "." {
                raw.append(".")
                _ = advance()
                while !isAtEnd && (isDigit(scalars[index]) || scalars[index] == "_") {
                    let c = advance()
                    if c != "_" { raw.unicodeScalars.append(c) }
                }
            }
            if peek() == "e" || peek() == "E" {
                raw.unicodeScalars.append(advance())
                if peek() == "+" || peek() == "-" {
                    raw.unicodeScalars.append(advance())
                }
                var hasExpDigit = false
                while !isAtEnd && (isDigit(scalars[index]) || scalars[index] == "_") {
                    let c = advance()
                    if c != "_" {
                        hasExpDigit = true
                        raw.unicodeScalars.append(c)
                    }
                }
                if !hasExpDigit {
                    throw makeSyntaxFailure("Invalid number exponent", at: startLoc)
                }
            }
            if peek() == "n" {
                throw ParseFailure(diagnostic: Diagnostic(
                    kind: "UnsupportedSyntax",
                    message: "BigInt literals are not supported.\(CodemodeLanguage.formatLocation(startLoc))",
                    location: startLoc,
                    suggestions: [CodemodeLanguage.supportedSyntaxMessage]
                ))
            }
            guard let value = Double(raw) else {
                throw makeSyntaxFailure("Invalid number literal '\(raw)'", at: startLoc)
            }
            return value
        }

        private mutating func readRegExp(startLoc: SourceLocation) throws -> (String, String) {
            _ = advance() // consume '/'
            var pattern = ""
            var inClass = false
            while !isAtEnd {
                let sc = scalars[index]
                if sc == "\n" || sc == "\r" {
                    throw makeSyntaxFailure("Unterminated regular expression", at: startLoc)
                }
                if sc == "\\" {
                    pattern.unicodeScalars.append(advance())
                    guard !isAtEnd else { throw makeSyntaxFailure("Unterminated regular expression", at: startLoc) }
                    pattern.unicodeScalars.append(advance())
                } else if sc == "[" {
                    inClass = true
                    pattern.unicodeScalars.append(advance())
                } else if sc == "]" {
                    inClass = false
                    pattern.unicodeScalars.append(advance())
                } else if sc == "/" && !inClass {
                    _ = advance()
                    var flags = ""
                    while !isAtEnd && isIdentContinue(scalars[index]) {
                        flags.unicodeScalars.append(advance())
                    }
                    return (pattern, flags)
                } else {
                    pattern.unicodeScalars.append(advance())
                }
            }
            throw makeSyntaxFailure("Unterminated regular expression", at: startLoc)
        }

        private mutating func readPunctuator(startLoc: SourceLocation) throws -> String {
            let candidates4 = [">>>="]
            let candidates3 = ["===", "!==", ">>>", "<<=", ">>=", "**=", "&&=", "||=", "??=", "..."]
            let candidates2 = ["==", "!=", "<=", ">=", "&&", "||", "??", "=>", "++", "--", "**", "<<", ">>", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "?."]
            let remaining = scalars.count - index

            if remaining >= 4 {
                let s4 = String(scalars[index..<(index + 4)].map(Character.init))
                if candidates4.contains(s4) {
                    for _ in 0..<4 { _ = advance() }
                    return s4
                }
            }
            if remaining >= 3 {
                let s3 = String(scalars[index..<(index + 3)].map(Character.init))
                if candidates3.contains(s3) {
                    for _ in 0..<3 { _ = advance() }
                    return s3
                }
            }
            if remaining >= 2 {
                let s2 = String(scalars[index..<(index + 2)].map(Character.init))
                if s2 == "?." && remaining >= 3 && isDigit(scalars[index + 2]) {
                    // `a ? .5 : 1` is ternary `?` followed by `.5`, not optional chaining
                } else if candidates2.contains(s2) {
                    for _ in 0..<2 { _ = advance() }
                    return s2
                }
            }
            let c = advance()
            let s1 = String(c)
            // `#` only starts a private class member name, which the parser refuses with its own message.
            let valid1 = "(){}[];,.:?+-*/%&|^~!<=>#"
            if valid1.contains(s1) {
                return s1
            }
            throw makeSyntaxFailure("Unexpected character '\(s1)'", at: startLoc)
        }

        private func makeSyntaxFailure(_ reason: String, at loc: SourceLocation) -> ParseFailure {
            let text = "\(reason.hasSuffix(".") ? reason : "\(reason).") Code must be plain JavaScript written as a program body."
            return ParseFailure(diagnostic: Diagnostic(
                kind: "ParseError",
                message: "SyntaxError: \(text)\(CodemodeLanguage.formatLocation(loc))",
                location: loc
            ))
        }
    }

    /// Recursive-descent + Pratt expression parser for the Code Mode JavaScript subset.
    public struct Parser: Sendable {
        private var lexer: Lexer
        private var current: Token
        private var allowRegexForNext: Bool = true
        /// The functions being parsed, innermost last: whether `super.x` and `super()` may appear in them.
        private var functionContexts: [FunctionContext] = []

        private struct FunctionContext {
            let isArrow: Bool
            let isMethod: Bool
            let isDerivedConstructor: Bool

            static let plain = FunctionContext(isArrow: false, isMethod: false, isDerivedConstructor: false)
            static let arrow = FunctionContext(isArrow: true, isMethod: false, isDerivedConstructor: false)
            static let method = FunctionContext(isArrow: false, isMethod: true, isDerivedConstructor: false)
        }

        public init(_ source: String) throws {
            self.lexer = Lexer(source)
            self.current = try self.lexer.nextToken(allowRegex: true)
        }

        private mutating func advance(allowRegex: Bool = true) throws -> Token {
            let prev = current
            current = try lexer.nextToken(allowRegex: allowRegex)
            allowRegexForNext = allowRegex
            return prev
        }

        private func isPunct(_ s: String) -> Bool {
            current.kind == .punct(s)
        }

        private func isKeyword(_ s: String) -> Bool {
            current.kind == .keyword(s)
        }

        private func isIdent(_ s: String) -> Bool {
            current.kind == .identifier(s)
        }

        private mutating func matchPunct(_ s: String, allowRegex: Bool = true) throws -> Bool {
            if isPunct(s) {
                _ = try advance(allowRegex: allowRegex)
                return true
            }
            return false
        }

        private mutating func expectPunct(_ s: String, allowRegex: Bool = true) throws {
            guard isPunct(s) else {
                throw syntaxError("Expected '\(s)'", at: current.location)
            }
            _ = try advance(allowRegex: allowRegex)
        }

        private mutating func consumeSemicolon() throws {
            if isPunct(";") {
                _ = try advance(allowRegex: true)
                return
            }
            if current.kind == .eof || isPunct("}") || current.precededByNewline {
                return
            }
            throw syntaxError("Unexpected token", at: current.location)
        }

        private func syntaxError(_ reason: String, at loc: SourceLocation) -> ParseFailure {
            let text = "\(reason.hasSuffix(".") ? reason : "\(reason).") Code must be plain JavaScript written as a program body."
            return ParseFailure(diagnostic: Diagnostic(
                kind: "ParseError",
                message: "SyntaxError: \(text)\(CodemodeLanguage.formatLocation(loc))",
                location: loc
            ))
        }

        private func unsupported(_ message: String, at loc: SourceLocation) -> ParseFailure {
            ParseFailure(diagnostic: Diagnostic(
                kind: "UnsupportedSyntax",
                message: "\(message)\(CodemodeLanguage.formatLocation(loc))",
                location: loc,
                suggestions: [CodemodeLanguage.supportedSyntaxMessage]
            ))
        }

        public mutating func parseProgram() throws -> ProgramAST {
            let loc = current.location
            var body: [Statement] = []
            while current.kind != .eof {
                body.append(try parseStatement())
            }
            return ProgramAST(body: body, loc: loc)
        }

        private mutating func parseStatement() throws -> Statement {
            let loc = current.location
            switch current.kind {
            case .punct(";"):
                _ = try advance(allowRegex: true)
                return .empty(loc)
            case .punct("{"):
                return try parseBlockStatement()
            case .keyword("export"):
                throw ParseFailure(diagnostic: Diagnostic(
                    kind: "ParseError",
                    message: "SyntaxError: Exports aren't available. Return the result instead.\(CodemodeLanguage.formatLocation(loc))",
                    location: loc
                ))
            case .keyword("class"):
                return .classDecl(try parseClass(requireName: true, loc: loc))
            case .keyword("import"):
                // Check for dynamic import(...) expression vs static import declaration
                let savedLexer = lexer
                let savedCurrent = current
                _ = try advance(allowRegex: true)
                if isPunct("(") {
                    lexer = savedLexer
                    current = savedCurrent
                    let expr = try parseExpression()
                    try consumeSemicolon()
                    return .expression(expr, loc)
                }
                return try parseImportDeclaration(loc: loc)
            case .keyword("var"):
                return try parseVariableStatement(kind: .var, loc: loc)
            case .keyword("let"):
                return try parseVariableStatement(kind: .let, loc: loc)
            case .keyword("const"):
                return try parseVariableStatement(kind: .const, loc: loc)
            case .keyword("function"):
                let fn = try parseFunction(isAsync: false, requireName: true, loc: loc)
                return .functionDecl(fn)
            case .identifier("async"):
                let savedLexer = lexer
                let savedCurrent = current
                _ = try advance(allowRegex: true)
                if isKeyword("function") && !current.precededByNewline {
                    let fn = try parseFunction(isAsync: true, requireName: true, loc: loc)
                    return .functionDecl(fn)
                }
                lexer = savedLexer
                current = savedCurrent
                return try parseExpressionOrLabelStatement()
            case .keyword("return"):
                _ = try advance(allowRegex: true)
                if isPunct(";") || isPunct("}") || current.kind == .eof || current.precededByNewline {
                    if isPunct(";") { _ = try advance(allowRegex: true) }
                    return .returnStmt(nil, loc)
                }
                let expr = try parseExpression()
                try consumeSemicolon()
                return .returnStmt(expr, loc)
            case .keyword("throw"):
                _ = try advance(allowRegex: true)
                if current.precededByNewline {
                    throw syntaxError("Illegal newline after throw", at: loc)
                }
                let expr = try parseExpression()
                try consumeSemicolon()
                return .throwStmt(expr, loc)
            case .keyword("break"):
                _ = try advance(allowRegex: true)
                var label: String? = nil
                if !current.precededByNewline, case .identifier(let name) = current.kind {
                    label = name
                    _ = try advance(allowRegex: true)
                }
                try consumeSemicolon()
                return .breakStmt(label: label, loc: loc)
            case .keyword("continue"):
                _ = try advance(allowRegex: true)
                var label: String? = nil
                if !current.precededByNewline, case .identifier(let name) = current.kind {
                    label = name
                    _ = try advance(allowRegex: true)
                }
                try consumeSemicolon()
                return .continueStmt(label: label, loc: loc)
            case .keyword("if"):
                _ = try advance(allowRegex: true)
                try expectPunct("(")
                let test = try parseExpression()
                try expectPunct(")")
                let cons = try parseStatement()
                var alt: Statement? = nil
                if isKeyword("else") {
                    _ = try advance(allowRegex: true)
                    alt = try parseStatement()
                }
                return .ifStmt(test: test, consequent: cons, alternate: alt, loc: loc)
            case .keyword("while"):
                _ = try advance(allowRegex: true)
                try expectPunct("(")
                let test = try parseExpression()
                try expectPunct(")")
                let body = try parseStatement()
                return .whileStmt(test: test, body: body, loc: loc)
            case .keyword("do"):
                _ = try advance(allowRegex: true)
                let body = try parseStatement()
                guard isKeyword("while") else {
                    throw syntaxError("Expected 'while' after 'do' body", at: current.location)
                }
                _ = try advance(allowRegex: true)
                try expectPunct("(")
                let test = try parseExpression()
                try expectPunct(")")
                if isPunct(";") { _ = try advance(allowRegex: true) }
                return .doWhileStmt(body: body, test: test, loc: loc)
            case .keyword("for"):
                return try parseForStatement(loc: loc)
            case .keyword("switch"):
                return try parseSwitchStatement(loc: loc)
            case .keyword("try"):
                return try parseTryStatement(loc: loc)
            case .keyword("with"):
                throw unsupported("'with' statements are not supported.", at: loc)
            case .keyword("debugger"):
                _ = try advance(allowRegex: true)
                try consumeSemicolon()
                return .empty(loc)
            default:
                return try parseExpressionOrLabelStatement()
            }
        }

        private mutating func parseExpressionOrLabelStatement() throws -> Statement {
            let loc = current.location
            if case .identifier(let name) = current.kind {
                let savedLexer = lexer
                let savedCurrent = current
                _ = try advance(allowRegex: false)
                if isPunct(":") {
                    _ = try advance(allowRegex: true)
                    let body = try parseStatement()
                    return .labeled(label: name, body: body, loc: loc)
                }
                lexer = savedLexer
                current = savedCurrent
            }
            let expr = try parseExpression()
            try consumeSemicolon()
            return .expression(expr, loc)
        }

        private mutating func parseBlockStatement() throws -> Statement {
            let loc = current.location
            let stmts = try parseBlockStatements()
            return .block(stmts, loc)
        }

        private mutating func parseBlockStatements() throws -> [Statement] {
            try expectPunct("{")
            var stmts: [Statement] = []
            while !isPunct("}") && current.kind != .eof {
                stmts.append(try parseStatement())
            }
            try expectPunct("}")
            return stmts
        }

        private mutating func parseImportDeclaration(loc: SourceLocation) throws -> Statement {
            // `import` already consumed
            if case .string(let src) = current.kind {
                _ = try advance(allowRegex: true)
                try consumeSemicolon()
                return .importDecl(specifiers: [], source: src, loc: loc)
            }
            var specifiers: [ImportSpecifier] = []
            if case .identifier(let defName) = current.kind {
                specifiers.append(.defaultImport(local: defName))
                _ = try advance(allowRegex: true)
                if isPunct(",") {
                    _ = try advance(allowRegex: true)
                }
            }
            if isPunct("*") {
                _ = try advance(allowRegex: true)
                guard isIdent("as") else { throw syntaxError("Expected 'as' after '*'", at: current.location) }
                _ = try advance(allowRegex: true)
                guard case .identifier(let nsName) = current.kind else {
                    throw syntaxError("Expected namespace identifier", at: current.location)
                }
                specifiers.append(.namespaceImport(local: nsName))
                _ = try advance(allowRegex: true)
            } else if isPunct("{") {
                _ = try advance(allowRegex: true)
                while !isPunct("}") && current.kind != .eof {
                    let imported = try parsePropertyOrIdentName()
                    var local = imported
                    if isIdent("as") {
                        _ = try advance(allowRegex: true)
                        guard case .identifier(let alias) = current.kind else {
                            throw syntaxError("Expected alias identifier", at: current.location)
                        }
                        local = alias
                        _ = try advance(allowRegex: true)
                    }
                    specifiers.append(.namedImport(imported: imported, local: local))
                    if !isPunct(",") { break }
                    _ = try advance(allowRegex: true)
                }
                try expectPunct("}")
            }
            guard isIdent("from") else {
                throw syntaxError("Expected 'from' in import declaration", at: current.location)
            }
            _ = try advance(allowRegex: true)
            guard case .string(let source) = current.kind else {
                throw syntaxError("Expected module specifier string", at: current.location)
            }
            _ = try advance(allowRegex: true)
            try consumeSemicolon()
            return .importDecl(specifiers: specifiers, source: source, loc: loc)
        }

        private mutating func parseVariableStatement(kind: VariableKind, loc: SourceLocation) throws -> Statement {
            _ = try advance(allowRegex: true) // var / let / const
            let decls = try parseVariableDeclarators(allowIn: true)
            try consumeSemicolon()
            return .variable(kind: kind, declarations: decls, loc: loc)
        }

        private mutating func parseVariableDeclarators(allowIn: Bool) throws -> [VariableDeclarator] {
            var decls: [VariableDeclarator] = []
            repeat {
                let dLoc = current.location
                let pattern = try parseBindingPattern()
                var initExpr: Expression? = nil
                if try matchPunct("=") {
                    initExpr = try parseAssignmentExpression(allowIn: allowIn)
                }
                decls.append(VariableDeclarator(id: pattern, initializer: initExpr, loc: dLoc))
            } while try matchPunct(",")
            return decls
        }

        private mutating func parseForStatement(loc: SourceLocation) throws -> Statement {
            _ = try advance(allowRegex: true) // for
            var isAwait = false
            if isKeyword("await") {
                isAwait = true
                _ = try advance(allowRegex: true)
            }
            try expectPunct("(")

            if isPunct(";") {
                _ = try advance(allowRegex: true)
                let test = isPunct(";") ? nil : try parseExpression()
                try expectPunct(";")
                let update = isPunct(")") ? nil : try parseExpression()
                try expectPunct(")")
                let body = try parseStatement()
                return .forStmt(initClause: nil, test: test, update: update, body: body, loc: loc)
            }

            if isKeyword("var") || isKeyword("let") || isKeyword("const") {
                let kindLoc = current.location
                let kind: VariableKind = isKeyword("var") ? .var : (isKeyword("let") ? .let : .const)
                _ = try advance(allowRegex: true)
                let firstLoc = current.location
                let firstPat = try parseBindingPattern()
                if isKeyword("in") || isIdent("of") {
                    let isOf = isIdent("of")
                    _ = try advance(allowRegex: true)
                    let right = isOf ? try parseAssignmentExpression(allowIn: true) : try parseExpression()
                    try expectPunct(")")
                    let body = try parseStatement()
                    let left = ForEachLeft.variable(kind: kind, pattern: firstPat, loc: kindLoc)
                    return isOf
                        ? .forOfStmt(left: left, right: right, body: body, isAwait: isAwait, loc: loc)
                        : .forInStmt(left: left, right: right, body: body, loc: loc)
                }
                var initExpr: Expression? = nil
                if try matchPunct("=") {
                    initExpr = try parseAssignmentExpression(allowIn: false)
                }
                var decls = [VariableDeclarator(id: firstPat, initializer: initExpr, loc: firstLoc)]
                while try matchPunct(",") {
                    let dl = current.location
                    let p = try parseBindingPattern()
                    var ie: Expression? = nil
                    if try matchPunct("=") { ie = try parseAssignmentExpression(allowIn: false) }
                    decls.append(VariableDeclarator(id: p, initializer: ie, loc: dl))
                }
                try expectPunct(";")
                let test = isPunct(";") ? nil : try parseExpression()
                try expectPunct(";")
                let update = isPunct(")") ? nil : try parseExpression()
                try expectPunct(")")
                let body = try parseStatement()
                return .forStmt(
                    initClause: .variable(kind: kind, declarations: decls, loc: kindLoc),
                    test: test,
                    update: update,
                    body: body,
                    loc: loc
                )
            }

            // Expression or destructuring pattern before in/of
            let initExpr = try parseExpression(allowIn: false)
            if isKeyword("in") || isIdent("of") {
                let isOf = isIdent("of")
                let pat = try expressionToPattern(initExpr)
                _ = try advance(allowRegex: true)
                let right = isOf ? try parseAssignmentExpression(allowIn: true) : try parseExpression()
                try expectPunct(")")
                let body = try parseStatement()
                return isOf
                    ? .forOfStmt(left: .pattern(pat), right: right, body: body, isAwait: isAwait, loc: loc)
                    : .forInStmt(left: .pattern(pat), right: right, body: body, loc: loc)
            }
            try expectPunct(";")
            let test = isPunct(";") ? nil : try parseExpression()
            try expectPunct(";")
            let update = isPunct(")") ? nil : try parseExpression()
            try expectPunct(")")
            let body = try parseStatement()
            return .forStmt(initClause: .expression(initExpr), test: test, update: update, body: body, loc: loc)
        }

        private mutating func parseSwitchStatement(loc: SourceLocation) throws -> Statement {
            _ = try advance(allowRegex: true) // switch
            try expectPunct("(")
            let disc = try parseExpression()
            try expectPunct(")")
            try expectPunct("{")
            var cases: [SwitchCase] = []
            while !isPunct("}") && current.kind != .eof {
                let cLoc = current.location
                let test: Expression?
                if isKeyword("case") {
                    _ = try advance(allowRegex: true)
                    test = try parseExpression()
                    try expectPunct(":")
                } else if isKeyword("default") {
                    _ = try advance(allowRegex: true)
                    test = nil
                    try expectPunct(":")
                } else {
                    throw syntaxError("Expected 'case' or 'default' in switch", at: cLoc)
                }
                var cons: [Statement] = []
                while !isKeyword("case") && !isKeyword("default") && !isPunct("}") && current.kind != .eof {
                    cons.append(try parseStatement())
                }
                cases.append(SwitchCase(test: test, consequent: cons, loc: cLoc))
            }
            try expectPunct("}")
            return .switchStmt(discriminant: disc, cases: cases, loc: loc)
        }

        private mutating func parseTryStatement(loc: SourceLocation) throws -> Statement {
            _ = try advance(allowRegex: true) // try
            let block = try parseBlockStatements()
            var handler: CatchClause? = nil
            var finalizer: [Statement]? = nil
            if isKeyword("catch") {
                let cLoc = current.location
                _ = try advance(allowRegex: true)
                var param: Pattern? = nil
                if try matchPunct("(") {
                    param = try parseBindingPattern()
                    try expectPunct(")")
                }
                let body = try parseBlockStatements()
                handler = CatchClause(param: param, body: body, loc: cLoc)
            }
            if isKeyword("finally") {
                _ = try advance(allowRegex: true)
                finalizer = try parseBlockStatements()
            }
            if handler == nil && finalizer == nil {
                throw syntaxError("Missing catch or finally after try", at: loc)
            }
            return .tryStmt(block: block, handler: handler, finalizer: finalizer, loc: loc)
        }

        private mutating func parseFunction(
            isAsync: Bool,
            requireName: Bool,
            loc: SourceLocation
        ) throws -> FunctionPayload {
            guard isKeyword("function") else {
                throw syntaxError("Expected 'function'", at: current.location)
            }
            _ = try advance(allowRegex: true)
            var isGen = false
            if isPunct("*") {
                isGen = true
                _ = try advance(allowRegex: true)
            }
            var name: String? = nil
            if case .identifier(let id) = current.kind {
                name = id
                _ = try advance(allowRegex: true)
            } else if requireName {
                throw syntaxError("Function statement requires a name", at: current.location)
            }
            functionContexts.append(.plain)
            defer { functionContexts.removeLast() }
            let params = try parseParameterList()
            let stmts = try parseBlockStatements()
            return FunctionPayload(
                name: name,
                params: params,
                body: .block(stmts),
                isAsync: isAsync,
                isGenerator: isGen,
                isArrow: false,
                loc: loc
            )
        }

        /// A method's parameters and body, parsed as a method (so `super` may appear in it).
        private mutating func parseMethodFunction(
            name: String?,
            isAsync: Bool,
            isGenerator: Bool,
            kind: FunctionKind,
            loc: SourceLocation
        ) throws -> FunctionPayload {
            let derived = if case .classConstructor(true) = kind { true } else { false }
            functionContexts.append(FunctionContext(isArrow: false, isMethod: true, isDerivedConstructor: derived))
            defer { functionContexts.removeLast() }
            let params = try parseParameterList()
            let stmts = try parseBlockStatements()
            return FunctionPayload(
                name: name,
                params: params,
                body: .block(stmts),
                isAsync: isAsync,
                isGenerator: isGenerator,
                isArrow: false,
                loc: loc,
                kind: kind
            )
        }

        private static func staticKeyName(_ key: PropertyKeyExpr) -> String? {
            switch key {
            case .identifier(let s, _), .string(let s, _): return s
            case .number(let n, _): return CodemodeLanguage.formatJSNumber(n)
            case .computed: return nil
            }
        }

        // The class elements: methods, accessors and fields with plain or computed names, static or not. Private
        // members and static blocks are refused, as upstream's `supportedClassMember` does.
        private mutating func parseClass(requireName: Bool, loc: SourceLocation) throws -> ClassPayload {
            _ = try advance(allowRegex: false) // class
            var name: String? = nil
            if case .identifier(let id) = current.kind {
                name = id
                _ = try advance(allowRegex: false)
            } else if requireName {
                throw syntaxError("Class statement requires a name", at: current.location)
            }
            var superClass: Expression? = nil
            if isKeyword("extends") {
                _ = try advance(allowRegex: true)
                superClass = try parseLeftHandSideExpression()
            }
            try expectPunct("{")
            var members: [ClassMember] = []
            var constructor: FunctionPayload? = nil
            while !isPunct("}") && current.kind != .eof {
                if try matchPunct(";") { continue }
                let mLoc = current.location
                var isStatic = false
                if isIdent("static") {
                    let savedLexer = lexer
                    let savedCurrent = current
                    _ = try advance(allowRegex: true)
                    if isPunct("(") || isPunct("=") || isPunct(";") || isPunct("}") {
                        lexer = savedLexer
                        current = savedCurrent
                    } else {
                        isStatic = true
                        if isPunct("{") {
                            throw unsupported("Class static blocks are not supported. Assign static fields instead.", at: mLoc)
                        }
                    }
                }
                if isPunct("#") {
                    throw unsupported("Private class members (#name) are not supported. Use a regular property instead.", at: mLoc)
                }
                var isAsync = false
                var isGenerator = false
                var accessor: AccessorKind? = nil
                if isIdent("async") {
                    let savedLexer = lexer
                    let savedCurrent = current
                    _ = try advance(allowRegex: true)
                    if isPunct("(") || isPunct("=") || isPunct(";") || isPunct("}") || current.precededByNewline {
                        lexer = savedLexer
                        current = savedCurrent
                    } else {
                        isAsync = true
                    }
                }
                if isPunct("*") {
                    isGenerator = true
                    _ = try advance(allowRegex: true)
                }
                if !isAsync && !isGenerator && (isIdent("get") || isIdent("set")) {
                    let half: AccessorKind = isIdent("get") ? .get : .set
                    let savedLexer = lexer
                    let savedCurrent = current
                    _ = try advance(allowRegex: true)
                    if isPunct("(") || isPunct("=") || isPunct(";") || isPunct("}") {
                        lexer = savedLexer
                        current = savedCurrent
                    } else {
                        accessor = half
                    }
                }
                if isPunct("#") {
                    throw unsupported("Private class members (#name) are not supported. Use a regular property instead.", at: mLoc)
                }
                let key = try parsePropertyKey()
                let keyName = Self.staticKeyName(key)
                if isPunct("(") {
                    let isConstructor = !isStatic && accessor == nil && keyName == "constructor"
                    if !isStatic && keyName == "constructor" {
                        if accessor != nil { throw syntaxError("Class constructor may not be an accessor", at: mLoc) }
                        if isAsync { throw syntaxError("Class constructor may not be an async method", at: mLoc) }
                        if isGenerator { throw syntaxError("Class constructor may not be a generator", at: mLoc) }
                    }
                    if isConstructor {
                        if constructor != nil { throw syntaxError("A class may only have one constructor", at: mLoc) }
                        constructor = try parseMethodFunction(
                            name: name,
                            isAsync: false,
                            isGenerator: false,
                            kind: .classConstructor(derived: superClass != nil),
                            loc: mLoc
                        )
                        continue
                    }
                    let fn = try parseMethodFunction(name: keyName, isAsync: isAsync, isGenerator: isGenerator, kind: .method, loc: mLoc)
                    let kind: ClassMember.Kind = switch accessor {
                    case .get: .getter
                    case .set: .setter
                    case nil: .method
                    }
                    members.append(ClassMember(kind: kind, isStatic: isStatic, key: key, function: fn, value: nil, loc: mLoc))
                    continue
                }
                if isAsync || isGenerator || accessor != nil {
                    throw syntaxError("Expected '(' after class method name", at: current.location)
                }
                if keyName == "constructor" {
                    throw syntaxError("Classes may not have a field named 'constructor'", at: mLoc)
                }
                if isStatic && keyName == "prototype" {
                    throw syntaxError("Classes may not have a static property named 'prototype'", at: mLoc)
                }
                var value: Expression? = nil
                if try matchPunct("=") {
                    functionContexts.append(.method)
                    defer { functionContexts.removeLast() }
                    value = try parseAssignmentExpression(allowIn: true)
                }
                members.append(ClassMember(kind: .field, isStatic: isStatic, key: key, function: nil, value: value, loc: mLoc))
                if try matchPunct(";") { continue }
                if !isPunct("}") && !current.precededByNewline {
                    throw syntaxError("Unexpected token", at: current.location)
                }
            }
            try expectPunct("}", allowRegex: false)
            let ctor = constructor ?? Self.defaultConstructor(name: name, derived: superClass != nil, loc: loc)
            return ClassPayload(name: name, superClass: superClass, constructor: ctor, members: members, loc: loc)
        }

        // `constructor() {}`, or `constructor(...args) { super(...args) }` for a derived class.
        private static func defaultConstructor(name: String?, derived: Bool, loc: SourceLocation) -> FunctionPayload {
            let args = Expression.identifier(name: "args", loc: loc)
            return FunctionPayload(
                name: name,
                params: derived ? [.array(elements: [], rest: .identifier(name: "args", loc: loc), loc: loc)] : [],
                body: .block(derived ? [.expression(.superCall(arguments: [.spread(args, loc)], passThrough: true, loc: loc), loc)] : []),
                isAsync: false,
                isGenerator: false,
                isArrow: false,
                loc: loc,
                kind: .classConstructor(derived: derived)
            )
        }

        // `super.x`, `super[key]` or `super(...)`: only inside the methods (and derived constructors) that may use it.
        private mutating func parseSuper(loc: SourceLocation) throws -> Expression {
            _ = try advance(allowRegex: false) // super
            let owner = functionContexts.last(where: { !$0.isArrow })
            if isPunct("(") {
                if functionContexts.last?.isArrow == true {
                    throw unsupported("super() inside an arrow function is not supported. Call super() directly in the constructor.", at: loc)
                }
                guard owner?.isDerivedConstructor == true else {
                    throw unsupported("'super' is only supported in class methods.", at: loc)
                }
                let args = try parseCallArguments()
                return .superCall(arguments: args, passThrough: false, loc: loc)
            }
            guard isPunct(".") || isPunct("[") else {
                throw syntaxError("'super' keyword unexpected here", at: loc)
            }
            guard owner?.isMethod == true else {
                throw unsupported("'super' is only supported in class methods.", at: loc)
            }
            if try matchPunct(".", allowRegex: false) {
                let propLoc = current.location
                let propName = try parsePropertyOrIdentName()
                return .superMember(property: .identifier(propName, propLoc), loc: loc)
            }
            let propLoc = current.location
            _ = try advance(allowRegex: true) // [
            let keyExpr = try parseExpression()
            try expectPunct("]", allowRegex: false)
            return .superMember(property: .computed(keyExpr, propLoc), loc: loc)
        }

        private mutating func parseParameterList() throws -> [Pattern] {
            try expectPunct("(")
            var params: [Pattern] = []
            while !isPunct(")") && current.kind != .eof {
                let pLoc = current.location
                if try matchPunct("...") {
                    let arg = try parseBindingPattern()
                    params.append(.array(elements: [], rest: arg, loc: pLoc))
                    if isPunct(",") {
                        throw syntaxError("Rest parameter must be last formal parameter", at: current.location)
                    }
                    break
                }
                var pat = try parseBindingPattern()
                if try matchPunct("=") {
                    let def = try parseAssignmentExpression(allowIn: true)
                    pat = .assignment(left: pat, right: def, loc: pLoc)
                }
                params.append(pat)
                if !isPunct(",") { break }
                _ = try advance(allowRegex: true)
            }
            try expectPunct(")")
            return params
        }

        private mutating func parseBindingPattern() throws -> Pattern {
            let loc = current.location
            switch current.kind {
            case .identifier(let name):
                _ = try advance(allowRegex: false)
                return .identifier(name: name, loc: loc)
            case .punct("["):
                _ = try advance(allowRegex: true)
                var elements: [Pattern?] = []
                var rest: Pattern? = nil
                while !isPunct("]") && current.kind != .eof {
                    if isPunct(",") {
                        elements.append(nil)
                        _ = try advance(allowRegex: true)
                        continue
                    }
                    if try matchPunct("...") {
                        rest = try parseBindingPattern()
                        break
                    }
                    let elemLoc = current.location
                    var elem = try parseBindingPattern()
                    if try matchPunct("=") {
                        let def = try parseAssignmentExpression(allowIn: true)
                        elem = .assignment(left: elem, right: def, loc: elemLoc)
                    }
                    elements.append(elem)
                    if !isPunct(",") { break }
                    _ = try advance(allowRegex: true)
                }
                try expectPunct("]", allowRegex: false)
                return .array(elements: elements, rest: rest, loc: loc)
            case .punct("{"):
                _ = try advance(allowRegex: true)
                var props: [ObjectPatternProperty] = []
                var rest: Pattern? = nil
                while !isPunct("}") && current.kind != .eof {
                    if try matchPunct("...") {
                        rest = try parseBindingPattern()
                        break
                    }
                    let propLoc = current.location
                    let key = try parsePropertyKey()
                    if try matchPunct(":") {
                        var value = try parseBindingPattern()
                        if try matchPunct("=") {
                            let def = try parseAssignmentExpression(allowIn: true)
                            value = .assignment(left: value, right: def, loc: propLoc)
                        }
                        props.append(ObjectPatternProperty(key: key, value: value, shorthand: false))
                    } else if case .identifier(let name, let kl) = key {
                        var value: Pattern = .identifier(name: name, loc: kl)
                        if try matchPunct("=") {
                            let def = try parseAssignmentExpression(allowIn: true)
                            value = .assignment(left: value, right: def, loc: propLoc)
                        }
                        props.append(ObjectPatternProperty(key: key, value: value, shorthand: true))
                    } else {
                        throw syntaxError("Expected ':' in object destructuring pattern", at: current.location)
                    }
                    if !isPunct(",") { break }
                    _ = try advance(allowRegex: true)
                }
                try expectPunct("}", allowRegex: false)
                return .object(properties: props, rest: rest, loc: loc)
            default:
                throw syntaxError("Expected binding identifier or destructuring pattern", at: loc)
            }
        }

        private mutating func parsePropertyOrIdentName() throws -> String {
            switch current.kind {
            case .identifier(let s), .keyword(let s):
                _ = try advance(allowRegex: false)
                return s
            default:
                throw syntaxError("Expected property name", at: current.location)
            }
        }

        private mutating func parsePropertyKey() throws -> PropertyKeyExpr {
            let loc = current.location
            switch current.kind {
            case .identifier(let s), .keyword(let s):
                _ = try advance(allowRegex: false)
                return .identifier(s, loc)
            case .string(let s):
                _ = try advance(allowRegex: false)
                return .string(s, loc)
            case .number(let n):
                _ = try advance(allowRegex: false)
                return .number(n, loc)
            case .punct("["):
                _ = try advance(allowRegex: true)
                let expr = try parseAssignmentExpression(allowIn: true)
                try expectPunct("]", allowRegex: false)
                return .computed(expr, loc)
            default:
                throw syntaxError("Expected property key", at: loc)
            }
        }

        // MARK: Expressions

        private mutating func parseExpression(allowIn: Bool = true) throws -> Expression {
            let loc = current.location
            let first = try parseAssignmentExpression(allowIn: allowIn)
            if !isPunct(",") { return first }
            var exprs = [first]
            while try matchPunct(",") {
                exprs.append(try parseAssignmentExpression(allowIn: allowIn))
            }
            return .sequence(expressions: exprs, loc: loc)
        }

        private mutating func parseAssignmentExpression(allowIn: Bool) throws -> Expression {
            let loc = current.location
            // Check for yield expression
            if isKeyword("yield") {
                _ = try advance(allowRegex: true)
                var delegate = false
                if !current.precededByNewline && isPunct("*") {
                    delegate = true
                    _ = try advance(allowRegex: true)
                }
                if !delegate && (current.precededByNewline || isPunct(";") || isPunct("}") || isPunct(")") || isPunct("]") || isPunct(",") || isPunct(":") || current.kind == .eof) {
                    return .yieldExpr(argument: nil, delegate: false, loc: loc)
                }
                let arg = try parseAssignmentExpression(allowIn: allowIn)
                return .yieldExpr(argument: arg, delegate: delegate, loc: loc)
            }

            // Try arrow function lookahead
            if let arrow = try tryParseArrowFunction(allowIn: allowIn) {
                return arrow
            }

            let left = try parseConditionalExpression(allowIn: allowIn)

            if case .punct(let p) = current.kind, let op = AssignmentOperator(rawValue: p) {
                let pat = try expressionToPattern(left)
                _ = try advance(allowRegex: true)
                let right = try parseAssignmentExpression(allowIn: allowIn)
                return .assignment(op: op, left: pat, right: right, loc: loc)
            }
            return left
        }

        private mutating func tryParseArrowFunction(allowIn: Bool) throws -> Expression? {
            let savedLexer = lexer
            let savedCurrent = current
            let loc = current.location
            var isAsync = false

            if isIdent("async") {
                _ = try advance(allowRegex: true)
                if current.precededByNewline {
                    lexer = savedLexer
                    current = savedCurrent
                    return nil
                }
                isAsync = true
            }

            if case .identifier(let singleParam) = current.kind {
                _ = try advance(allowRegex: false)
                if !current.precededByNewline && isPunct("=>") {
                    _ = try advance(allowRegex: true)
                    let body = try parseArrowBody(allowIn: allowIn)
                    return .function(FunctionPayload(
                        name: nil,
                        params: [.identifier(name: singleParam, loc: loc)],
                        body: body,
                        isAsync: isAsync,
                        isGenerator: false,
                        isArrow: true,
                        loc: loc
                    ))
                }
                lexer = savedLexer
                current = savedCurrent
                return nil
            }

            if isPunct("(") {
                if let params = try? parseParameterList(), !current.precededByNewline && isPunct("=>") {
                    _ = try advance(allowRegex: true)
                    let body = try parseArrowBody(allowIn: allowIn)
                    return .function(FunctionPayload(
                        name: nil,
                        params: params,
                        body: body,
                        isAsync: isAsync,
                        isGenerator: false,
                        isArrow: true,
                        loc: loc
                    ))
                }
                lexer = savedLexer
                current = savedCurrent
                return nil
            }

            lexer = savedLexer
            current = savedCurrent
            return nil
        }

        private mutating func parseArrowBody(allowIn: Bool) throws -> FunctionBody {
            functionContexts.append(.arrow)
            defer { functionContexts.removeLast() }
            if isPunct("{") {
                return .block(try parseBlockStatements())
            }
            return .expression(try parseAssignmentExpression(allowIn: allowIn))
        }

        private func expressionToPattern(_ expr: Expression, nested: Bool = false) throws -> Pattern {
            switch expr {
            case .identifier(let name, let loc):
                return .identifier(name: name, loc: loc)
            case .superMember(let prop, let loc):
                if nested {
                    throw unsupported("Destructuring into super.x is not supported.", at: loc ?? SourceLocation(line: 1, column: 1))
                }
                return .superMember(property: prop, loc: loc)
            case .member(let obj, let prop, false, let loc):
                return .member(object: obj, property: prop, loc: loc)
            case .array(let elements, let loc):
                var patElements: [Pattern?] = []
                var rest: Pattern? = nil
                for (idx, el) in elements.enumerated() {
                    switch el {
                    case .hole:
                        patElements.append(nil)
                    case .spread(let inner, _):
                        guard idx == elements.count - 1 else {
                            throw syntaxError("Rest element must be last element", at: inner.location ?? loc ?? SourceLocation(line: 1, column: 1))
                        }
                        rest = try expressionToPattern(inner, nested: true)
                    case .expr(let inner):
                        if case .assignment(.assign, let l, let r, let al) = inner {
                            patElements.append(.assignment(left: l, right: r, loc: al))
                        } else {
                            patElements.append(try expressionToPattern(inner, nested: true))
                        }
                    }
                }
                return .array(elements: patElements, rest: rest, loc: loc)
            case .object(let props, let loc):
                var patProps: [ObjectPatternProperty] = []
                var rest: Pattern? = nil
                for (idx, prop) in props.enumerated() {
                    switch prop {
                    case .spread(let inner, _):
                        guard idx == props.count - 1 else {
                            throw syntaxError("Rest element must be last element", at: inner.location ?? loc ?? SourceLocation(line: 1, column: 1))
                        }
                        rest = try expressionToPattern(inner, nested: true)
                    case .property(let k, let v, let sh, _):
                        let patVal: Pattern
                        if case .assignment(.assign, let l, let r, let al) = v {
                            patVal = .assignment(left: l, right: r, loc: al)
                        } else {
                            patVal = try expressionToPattern(v, nested: true)
                        }
                        patProps.append(ObjectPatternProperty(key: k, value: patVal, shorthand: sh))
                    case .accessor(_, _, _, let al):
                        throw syntaxError("Invalid destructuring assignment target", at: al ?? loc ?? SourceLocation(line: 1, column: 1))
                    }
                }
                return .object(properties: patProps, rest: rest, loc: loc)
            default:
                throw syntaxError("Invalid left-hand side in assignment", at: expr.location ?? SourceLocation(line: 1, column: 1))
            }
        }

        private mutating func parseConditionalExpression(allowIn: Bool) throws -> Expression {
            let loc = current.location
            let test = try parseBinaryExpression(minPrec: 1, allowIn: allowIn)
            if try matchPunct("?") {
                let consequent = try parseAssignmentExpression(allowIn: true)
                try expectPunct(":")
                let alternate = try parseAssignmentExpression(allowIn: allowIn)
                return .conditional(test: test, consequent: consequent, alternate: alternate, loc: loc)
            }
            return test
        }

        private func binaryPrecedence(allowIn: Bool) -> (prec: Int, rightAssoc: Bool, logical: LogicalOperator?, binary: BinaryOperator?)? {
            switch current.kind {
            case .punct("??"): return (1, false, .nullish, nil)
            case .punct("||"): return (2, false, .or, nil)
            case .punct("&&"): return (3, false, .and, nil)
            case .punct("|"): return (4, false, nil, .bitOr)
            case .punct("^"): return (5, false, nil, .bitXor)
            case .punct("&"): return (6, false, nil, .bitAnd)
            case .punct("=="): return (7, false, nil, .eq)
            case .punct("!="): return (7, false, nil, .ne)
            case .punct("==="): return (7, false, nil, .seq)
            case .punct("!=="): return (7, false, nil, .sne)
            case .punct("<"): return (8, false, nil, .lt)
            case .punct("<="): return (8, false, nil, .le)
            case .punct(">"): return (8, false, nil, .gt)
            case .punct(">="): return (8, false, nil, .ge)
            case .keyword("in"): return allowIn ? (8, false, nil, .in) : nil
            case .keyword("instanceof"): return (8, false, nil, .instanceof)
            case .punct("<<"): return (9, false, nil, .shl)
            case .punct(">>"): return (9, false, nil, .sar)
            case .punct(">>>"): return (9, false, nil, .shr)
            case .punct("+"): return (10, false, nil, .add)
            case .punct("-"): return (10, false, nil, .sub)
            case .punct("*"): return (11, false, nil, .mul)
            case .punct("/"): return (11, false, nil, .div)
            case .punct("%"): return (11, false, nil, .mod)
            case .punct("**"): return (12, true, nil, .exp)
            default: return nil
            }
        }

        private mutating func parseBinaryExpression(minPrec: Int, allowIn: Bool) throws -> Expression {
            var left = try parseUnaryExpression()
            while let info = binaryPrecedence(allowIn: allowIn), info.prec >= minPrec {
                let loc = current.location
                _ = try advance(allowRegex: true)
                let nextMin = info.rightAssoc ? info.prec : info.prec + 1
                let right = try parseBinaryExpression(minPrec: nextMin, allowIn: allowIn)
                if let logOp = info.logical {
                    left = .logical(op: logOp, left: left, right: right, loc: loc)
                } else if let binOp = info.binary {
                    left = .binary(op: binOp, left: left, right: right, loc: loc)
                }
            }
            return left
        }

        private mutating func parseUnaryExpression() throws -> Expression {
            let loc = current.location
            switch current.kind {
            case .keyword("await"):
                _ = try advance(allowRegex: true)
                return .awaitExpr(argument: try parseUnaryExpression(), loc: loc)
            case .punct("!"):
                _ = try advance(allowRegex: true)
                return .unary(op: .not, argument: try parseUnaryExpression(), loc: loc)
            case .punct("-"):
                _ = try advance(allowRegex: true)
                return .unary(op: .neg, argument: try parseUnaryExpression(), loc: loc)
            case .punct("+"):
                _ = try advance(allowRegex: true)
                return .unary(op: .plus, argument: try parseUnaryExpression(), loc: loc)
            case .punct("~"):
                _ = try advance(allowRegex: true)
                return .unary(op: .bitNot, argument: try parseUnaryExpression(), loc: loc)
            case .keyword("typeof"):
                _ = try advance(allowRegex: true)
                return .unary(op: .typeof, argument: try parseUnaryExpression(), loc: loc)
            case .keyword("void"):
                _ = try advance(allowRegex: true)
                return .unary(op: .void, argument: try parseUnaryExpression(), loc: loc)
            case .keyword("delete"):
                _ = try advance(allowRegex: true)
                return .unary(op: .delete, argument: try parseUnaryExpression(), loc: loc)
            case .punct("++"):
                _ = try advance(allowRegex: true)
                return .update(op: .increment, argument: try parseUnaryExpression(), prefix: true, loc: loc)
            case .punct("--"):
                _ = try advance(allowRegex: true)
                return .update(op: .decrement, argument: try parseUnaryExpression(), prefix: true, loc: loc)
            default:
                return try parsePostfixExpression()
            }
        }

        private mutating func parsePostfixExpression() throws -> Expression {
            var expr = try parseLeftHandSideExpression()
            if !current.precededByNewline {
                if isPunct("++") {
                    let loc = current.location
                    _ = try advance(allowRegex: false)
                    expr = .update(op: .increment, argument: expr, prefix: false, loc: loc)
                } else if isPunct("--") {
                    let loc = current.location
                    _ = try advance(allowRegex: false)
                    expr = .update(op: .decrement, argument: expr, prefix: false, loc: loc)
                }
            }
            return expr
        }

        private mutating func parseLeftHandSideExpression() throws -> Expression {
            if isKeyword("new") {
                return try parseNewExpression()
            }
            let base = try parsePrimaryExpression()
            return try parseMemberAndCallSuffixes(base: base, allowCall: true)
        }

        private mutating func parseNewExpression() throws -> Expression {
            let loc = current.location
            _ = try advance(allowRegex: true) // new
            if isPunct(".") {
                throw unsupported("new.target is not supported.", at: loc)
            }
            let callee: Expression
            if isKeyword("new") {
                callee = try parseNewExpression()
            } else {
                let primary = try parsePrimaryExpression()
                callee = try parseMemberAndCallSuffixes(base: primary, allowCall: false)
            }
            let args: [CallArgument]
            if isPunct("(") {
                args = try parseCallArguments()
            } else {
                args = []
            }
            let newExpr = Expression.newExpr(callee: callee, arguments: args, loc: loc)
            return try parseMemberAndCallSuffixes(base: newExpr, allowCall: true)
        }

        private mutating func parseMemberAndCallSuffixes(base: Expression, allowCall: Bool) throws -> Expression {
            var expr = base
            var hasOptional = false
            while true {
                let loc = current.location
                if isPunct(".") {
                    _ = try advance(allowRegex: false)
                    let propName = try parsePropertyOrIdentName()
                    expr = .member(object: expr, property: .identifier(propName, loc), optional: false, loc: loc)
                } else if isPunct("[") {
                    _ = try advance(allowRegex: true)
                    let keyExpr = try parseExpression()
                    try expectPunct("]", allowRegex: false)
                    expr = .member(object: expr, property: .computed(keyExpr, loc), optional: false, loc: loc)
                } else if isPunct("?.") {
                    hasOptional = true
                    _ = try advance(allowRegex: true)
                    if isPunct("[") {
                        _ = try advance(allowRegex: true)
                        let keyExpr = try parseExpression()
                        try expectPunct("]", allowRegex: false)
                        expr = .member(object: expr, property: .computed(keyExpr, loc), optional: true, loc: loc)
                    } else if isPunct("(") {
                        guard allowCall else { throw syntaxError("Optional call not allowed in new expression", at: loc) }
                        let args = try parseCallArguments()
                        expr = .call(callee: expr, arguments: args, optional: true, loc: loc)
                    } else {
                        let propName = try parsePropertyOrIdentName()
                        expr = .member(object: expr, property: .identifier(propName, loc), optional: true, loc: loc)
                    }
                } else if allowCall && isPunct("(") {
                    let args = try parseCallArguments()
                    expr = .call(callee: expr, arguments: args, optional: false, loc: loc)
                } else if case .templateNoSub(let cooked, let raw) = current.kind {
                    _ = try advance(allowRegex: false)
                    expr = .taggedTemplate(tag: expr, quasis: [TemplateQuasi(cooked: cooked, raw: raw)], expressions: [], loc: loc)
                } else if case .templateHead = current.kind {
                    let (quasis, exprs) = try parseTemplateParts()
                    expr = .taggedTemplate(tag: expr, quasis: quasis, expressions: exprs, loc: loc)
                } else {
                    break
                }
            }
            return hasOptional ? .chain(expression: expr, loc: base.location) : expr
        }

        private mutating func parseCallArguments() throws -> [CallArgument] {
            try expectPunct("(")
            var args: [CallArgument] = []
            while !isPunct(")") && current.kind != .eof {
                let loc = current.location
                if try matchPunct("...") {
                    args.append(.spread(try parseAssignmentExpression(allowIn: true), loc))
                } else {
                    args.append(.expr(try parseAssignmentExpression(allowIn: true)))
                }
                if !isPunct(",") { break }
                _ = try advance(allowRegex: true)
            }
            try expectPunct(")", allowRegex: false)
            return args
        }

        private mutating func parsePrimaryExpression() throws -> Expression {
            let loc = current.location
            switch current.kind {
            case .keyword("null"):
                _ = try advance(allowRegex: false)
                return .literalNull(loc)
            case .keyword("true"):
                _ = try advance(allowRegex: false)
                return .literalBool(true, loc)
            case .keyword("false"):
                _ = try advance(allowRegex: false)
                return .literalBool(false, loc)
            case .keyword("this"):
                _ = try advance(allowRegex: false)
                return .thisExpr(loc)
            case .number(let n):
                _ = try advance(allowRegex: false)
                return .literalNumber(n, loc)
            case .string(let s):
                _ = try advance(allowRegex: false)
                return .literalString(s, loc)
            case .regExp(let p, let f):
                _ = try advance(allowRegex: false)
                return .literalRegExp(pattern: p, flags: f, loc: loc)
            case .templateNoSub(let cooked, let raw):
                _ = try advance(allowRegex: false)
                return .templateLiteral(quasis: [TemplateQuasi(cooked: cooked, raw: raw)], expressions: [], loc: loc)
            case .templateHead:
                let (quasis, exprs) = try parseTemplateParts()
                return .templateLiteral(quasis: quasis, expressions: exprs, loc: loc)
            case .identifier("async"):
                let savedLexer = lexer
                let savedCurrent = current
                _ = try advance(allowRegex: true)
                if isKeyword("function") && !current.precededByNewline {
                    let fn = try parseFunction(isAsync: true, requireName: false, loc: loc)
                    return .function(fn)
                }
                lexer = savedLexer
                current = savedCurrent
                _ = try advance(allowRegex: false)
                return .identifier(name: "async", loc: loc)
            case .identifier(let name):
                _ = try advance(allowRegex: false)
                return .identifier(name: name, loc: loc)
            case .keyword("function"):
                return .function(try parseFunction(isAsync: false, requireName: false, loc: loc))
            case .keyword("class"):
                return .classExpr(try parseClass(requireName: false, loc: loc))
            case .keyword("super"):
                return try parseSuper(loc: loc)
            case .keyword("import"):
                _ = try advance(allowRegex: true)
                try expectPunct("(")
                let src = try parseAssignmentExpression(allowIn: true)
                try expectPunct(")", allowRegex: false)
                return .importExpr(source: src, loc: loc)
            case .punct("("):
                _ = try advance(allowRegex: true)
                let inner = try parseExpression()
                try expectPunct(")", allowRegex: false)
                return inner
            case .punct("["):
                return try parseArrayLiteral(loc: loc)
            case .punct("{"):
                return try parseObjectLiteral(loc: loc)
            default:
                throw syntaxError("Unexpected token", at: loc)
            }
        }

        private mutating func parseTemplateParts() throws -> ([TemplateQuasi], [Expression]) {
            var quasis: [TemplateQuasi] = []
            var exprs: [Expression] = []
            guard case .templateHead(let cooked, let raw) = current.kind else {
                throw syntaxError("Expected template head", at: current.location)
            }
            quasis.append(TemplateQuasi(cooked: cooked, raw: raw))
            _ = try advance(allowRegex: true)
            while true {
                exprs.append(try parseExpression())
                switch current.kind {
                case .templateMiddle(let mc, let mr):
                    quasis.append(TemplateQuasi(cooked: mc, raw: mr))
                    _ = try advance(allowRegex: true)
                case .templateTail(let tc, let tr):
                    quasis.append(TemplateQuasi(cooked: tc, raw: tr))
                    _ = try advance(allowRegex: false)
                    return (quasis, exprs)
                default:
                    throw syntaxError("Unterminated template expression", at: current.location)
                }
            }
        }

        private mutating func parseArrayLiteral(loc: SourceLocation) throws -> Expression {
            _ = try advance(allowRegex: true) // '['
            var elements: [ArrayElement] = []
            while !isPunct("]") && current.kind != .eof {
                let eLoc = current.location
                if isPunct(",") {
                    elements.append(.hole)
                    _ = try advance(allowRegex: true)
                    continue
                }
                if try matchPunct("...") {
                    elements.append(.spread(try parseAssignmentExpression(allowIn: true), eLoc))
                } else {
                    elements.append(.expr(try parseAssignmentExpression(allowIn: true)))
                }
                if !isPunct(",") { break }
                _ = try advance(allowRegex: true)
            }
            try expectPunct("]", allowRegex: false)
            return .array(elements: elements, loc: loc)
        }

        private mutating func parseObjectLiteral(loc: SourceLocation) throws -> Expression {
            _ = try advance(allowRegex: true) // '{'
            var props: [ObjectProperty] = []
            while !isPunct("}") && current.kind != .eof {
                let pLoc = current.location
                if try matchPunct("...") {
                    props.append(.spread(try parseAssignmentExpression(allowIn: true), pLoc))
                } else {
                    // Getters and setters: `get foo() {}` / `set foo(v) {}`, with plain or computed keys.
                    if isIdent("get") || isIdent("set") {
                        let half: AccessorKind = isIdent("get") ? .get : .set
                        let savedLexer = lexer
                        let savedCurrent = current
                        _ = try advance(allowRegex: true)
                        if !isPunct(":") && !isPunct(",") && !isPunct("}") && !isPunct("(") && !isPunct("=") {
                            let key = try parsePropertyKey()
                            let fn = try parseMethodFunction(name: nil, isAsync: false, isGenerator: false, kind: .method, loc: pLoc)
                            props.append(.accessor(kind: half, key: key, function: fn, loc: pLoc))
                            if !isPunct(",") { break }
                            _ = try advance(allowRegex: true)
                            continue
                        }
                        lexer = savedLexer
                        current = savedCurrent
                    }

                    // Check async / generator method shorthand
                    var isAsyncMethod = false
                    var isGenMethod = false
                    if isIdent("async") {
                        let savedLexer = lexer
                        let savedCurrent = current
                        _ = try advance(allowRegex: true)
                        if !isPunct(":") && !isPunct(",") && !isPunct("}") && !isPunct("(") && !isPunct("=") && !current.precededByNewline {
                            isAsyncMethod = true
                        } else {
                            lexer = savedLexer
                            current = savedCurrent
                        }
                    }
                    if isPunct("*") {
                        isGenMethod = true
                        _ = try advance(allowRegex: true)
                    }

                    let key = try parsePropertyKey()
                    if isPunct("(") {
                        let fnName: String? = if case .identifier(let n, _) = key { n } else { nil }
                        let fnExpr = Expression.function(try parseMethodFunction(
                            name: fnName,
                            isAsync: isAsyncMethod,
                            isGenerator: isGenMethod,
                            kind: .method,
                            loc: pLoc
                        ))
                        props.append(.property(key: key, value: fnExpr, shorthand: false, loc: pLoc))
                    } else if try matchPunct(":") {
                        let val = try parseAssignmentExpression(allowIn: true)
                        props.append(.property(key: key, value: val, shorthand: false, loc: pLoc))
                    } else if case .identifier(let name, let kl) = key {
                        if try matchPunct("=") {
                            // Cover initialized name for destructuring assignment `({ a = 1 } = obj)`
                            let def = try parseAssignmentExpression(allowIn: true)
                            let assignExpr = Expression.assignment(
                                op: .assign,
                                left: .identifier(name: name, loc: kl),
                                right: def,
                                loc: pLoc
                            )
                            props.append(.property(key: key, value: assignExpr, shorthand: true, loc: pLoc))
                        } else {
                            props.append(.property(key: key, value: .identifier(name: name, loc: kl), shorthand: true, loc: pLoc))
                        }
                    } else {
                        throw syntaxError("Expected ':' after property key", at: current.location)
                    }
                }
                if !isPunct(",") { break }
                _ = try advance(allowRegex: true)
            }
            try expectPunct("}", allowRegex: false)
            return .object(properties: props, loc: loc)
        }
    }

    // MARK: - Opcodes & Bytecode Builder (src/language/opcodes.ts, src/language/code.ts)

    public struct HoleSentinel: Equatable, Hashable, Sendable, CustomStringConvertible {
        public init() {}

        public var description: String { "Symbol(psychoscript.hole)" }
    }

    // parity: psychoscript/src/opcodes.ts#HOLE [status=implemented hash=4c3d6fbe3007]
    public static let HOLE = HoleSentinel()

    // parity: psychoscript/src/opcodes.ts#Cell [status=implemented hash=1485a4ccf5f0]
    public final class Cell: Sendable {
        private let storage: Mutex<Value>

        public var v: Value {
            get { storage.withLock { $0 } }
            set { storage.withLock { $0 = newValue } }
        }

        public init(_ value: Value = .undefined) {
            self.storage = Mutex(value)
        }
    }

    // parity: psychoscript/src/opcodes.ts#EMPTY_CELLS [status=implemented hash=198ce9174ac9]
    public static let EMPTY_CELLS: [Cell] = []

    // parity: psychoscript/src/opcodes.ts#NotYetImplemented [status=implemented hash=36b067cb5b7f]
    public final class NotYetImplemented: Error, Sendable, CustomStringConvertible {
        public let feature: String

        public init(_ feature: String) {
            self.feature = feature
        }

        public var description: String { "Not yet implemented in VM: \(feature)" }
    }

    // parity: psychoscript/src/opcodes.ts#OpCode [status=implemented hash=5c1abc58d768]
    public typealias OpCode = Int32

    // parity: psychoscript/src/opcodes.ts#Op [status=implemented hash=d04be9d8e1b8]
    public enum Op {
        public static let PUSH_UNDEF: OpCode = 0
        public static let PUSH_NULL: OpCode = 1
        public static let PUSH_BOOL: OpCode = 2
        public static let PUSH_INT: OpCode = 3
        public static let PUSH_CONST: OpCode = 4
        public static let POP: OpCode = 5
        public static let POPN: OpCode = 6
        public static let DUP: OpCode = 7
        public static let PICK: OpCode = 8
        public static let ROT: OpCode = 9
        public static let GET_LOCAL: OpCode = 10
        public static let PUT_LOCAL: OpCode = 11
        public static let HOLE_LOCAL: OpCode = 12
        public static let NEW_CELL: OpCode = 13
        public static let COPY_CELL: OpCode = 14
        public static let GET_CELL: OpCode = 15
        public static let PUT_CELL: OpCode = 16
        public static let GET_UPVAL: OpCode = 17
        public static let PUT_UPVAL: OpCode = 18
        public static let GET_GLOBAL: OpCode = 19
        public static let GET_INTRINSIC: OpCode = 20
        public static let ARGS: OpCode = 21
        public static let CLOSURE: OpCode = 22
        public static let SET_NAME: OpCode = 23
        public static let IMPORT: OpCode = 24
        public static let GET_PROP: OpCode = 25
        public static let GET_ELEM: OpCode = 26
        public static let PUT_PROP: OpCode = 27
        public static let PUT_ELEM: OpCode = 28
        public static let DELETE_PROP: OpCode = 29
        public static let DELETE_ELEM: OpCode = 30
        public static let CHECK_BASE: OpCode = 31
        public static let TO_KEY: OpCode = 32
        public static let IN: OpCode = 33
        public static let INSTANCEOF: OpCode = 34
        public static let NEW_OBJECT: OpCode = 35
        public static let NEW_ARRAY: OpCode = 36
        public static let ARRAY_APPEND: OpCode = 37
        /// `a` bit 0: computed key on the stack; bit 1: a class field, which throws when it cannot be defined.
        public static let DEFINE_FIELD: OpCode = 38
        public static let COPY_DATA_PROPS: OpCode = 39
        public static let COPY_REST: OpCode = 40
        public static let TEMPLATE: OpCode = 41
        public static let REGEXP: OpCode = 42
        public static let ADD: OpCode = 43
        public static let SUB: OpCode = 44
        public static let MUL: OpCode = 45
        public static let LT: OpCode = 46
        public static let LE: OpCode = 47
        public static let GT: OpCode = 48
        public static let GE: OpCode = 49
        public static let SEQ: OpCode = 50
        public static let SNE: OpCode = 51
        public static let BINOP: OpCode = 52
        public static let UNARY: OpCode = 53
        public static let NOT: OpCode = 54
        public static let TO_NUMERIC: OpCode = 55
        public static let INC: OpCode = 56
        public static let TO_STRING: OpCode = 57
        public static let CONCAT: OpCode = 58
        public static let JUMP: OpCode = 59
        public static let LOOP: OpCode = 60
        public static let JUMP_IF_FALSE: OpCode = 61
        public static let JUMP_IF_TRUE: OpCode = 62
        public static let JUMP_COND: OpCode = 63
        public static let THROW: OpCode = 64
        public static let THROW_ERROR: OpCode = 65
        public static let END_FINALLY: OpCode = 66
        public static let RETURN: OpCode = 67
        public static let NOP: OpCode = 68
        public static let EXTRA: OpCode = 69
        public static let CALL: OpCode = 70
        public static let CALL_SPREAD: OpCode = 71
        public static let NEW: OpCode = 72
        public static let NEW_SPREAD: OpCode = 73
        public static let ITER_OPEN: OpCode = 74
        public static let ITER_INIT: OpCode = 75
        public static let ITER_STEP: OpCode = 76
        public static let ITER_RESULT: OpCode = 77
        public static let ITER_CLOSE: OpCode = 78
        public static let ITER_APPEND_ALL: OpCode = 79
        public static let FOR_IN: OpCode = 80
        public static let GENERATOR_START: OpCode = 81
        public static let YIELD: OpCode = 82
        public static let RESUME: OpCode = 83
        public static let AWAIT: OpCode = 84
        public static let YSTAR: OpCode = 85
        public static let YSTAR_RESULT: OpCode = 86
        public static let END_PROGRAM: OpCode = 87
        /// Literals, added later: `get x() {}` / `set x(v) {}` (`a` bit 0: computed key; bit 1: setter).
        public static let DEFINE_ACCESSOR: OpCode = 88
        /// Classes: `CLASS` turns the constructor on top into a class, `[ctor] -> [ctor, proto]`.
        public static let CLASS: OpCode = 89
        /// Defines the method on top on the prototype, or on the constructor when `a` bit 0 is set. `a`: 1 static,
        /// 2 computed (`[.., key, fn]`), 4 getter, 8 setter (non-enumerable accessors).
        public static let DEFINE_METHOD: OpCode = 90
        /// Makes the field-initializer function on top the class's: `[ctor, proto, fn] -> [ctor, proto]`.
        public static let SET_FIELDS: OpCode = 91
        /// Runs field initializers: `a` 0 calls the running constructor's on its `this`; `a` 1 a static initializer.
        public static let INIT_FIELDS: OpCode = 92
        /// Constructs the parent of the running constructor for its new target (local `bx`).
        public static let SUPER_CALL: OpCode = 93
        /// Makes the instance on top the derived constructor's `this` (local `bx`, a cell when `a` is 1). Once only.
        public static let SUPER_BIND: OpCode = 94
        /// `super.x`: `[home, this] -> [value]`, keyed by constant `bx` or by a key on top when bit 1 is set.
        public static let GET_SUPER: OpCode = 96
        /// `super.x = v`: `[home, this, v] -> [v]`, or `[home, this, key, v] -> [v]` when bit 1 is set.
        public static let PUT_SUPER: OpCode = 97
        /// An object literal method that uses `super` gets the object at depth `a` as its home.
        public static let SET_HOME: OpCode = 98
    }

    // parity: psychoscript/src/opcodes.ts#OpNames [status=implemented hash=9cf37ccf2611]
    public static let OpNames: [String] = [
        "PUSH_UNDEF", "PUSH_NULL", "PUSH_BOOL", "PUSH_INT", "PUSH_CONST",
        "POP", "POPN", "DUP", "PICK", "ROT",
        "GET_LOCAL", "PUT_LOCAL", "HOLE_LOCAL", "NEW_CELL", "COPY_CELL",
        "GET_CELL", "PUT_CELL", "GET_UPVAL", "PUT_UPVAL", "GET_GLOBAL",
        "GET_INTRINSIC", "ARGS", "CLOSURE", "SET_NAME", "IMPORT",
        "GET_PROP", "GET_ELEM", "PUT_PROP", "PUT_ELEM", "DELETE_PROP",
        "DELETE_ELEM", "CHECK_BASE", "TO_KEY", "IN", "INSTANCEOF",
        "NEW_OBJECT", "NEW_ARRAY", "ARRAY_APPEND", "DEFINE_FIELD", "COPY_DATA_PROPS",
        "COPY_REST", "TEMPLATE", "REGEXP", "ADD", "SUB",
        "MUL", "LT", "LE", "GT", "GE",
        "SEQ", "SNE", "BINOP", "UNARY", "NOT",
        "TO_NUMERIC", "INC", "TO_STRING", "CONCAT", "JUMP",
        "LOOP", "JUMP_IF_FALSE", "JUMP_IF_TRUE", "JUMP_COND", "THROW",
        "THROW_ERROR", "END_FINALLY", "RETURN", "NOP", "EXTRA",
        "CALL", "CALL_SPREAD", "NEW", "NEW_SPREAD", "ITER_OPEN",
        "ITER_INIT", "ITER_STEP", "ITER_RESULT", "ITER_CLOSE", "ITER_APPEND_ALL",
        "FOR_IN", "GENERATOR_START", "YIELD", "RESUME", "AWAIT",
        "YSTAR", "YSTAR_RESULT", "END_PROGRAM", "DEFINE_ACCESSOR", "CLASS",
        "DEFINE_METHOD", "SET_FIELDS", "INIT_FIELDS", "SUPER_CALL", "SUPER_BIND",
        "", "GET_SUPER", "PUT_SUPER", "SET_HOME",
    ]

    // parity: psychoscript/src/opcodes.ts#BinOp [status=implemented hash=658848825af8]
    public enum BinOp {
        public static let DIV: Int32 = 0
        public static let MOD: Int32 = 1
        public static let EXP: Int32 = 2
        public static let BAND: Int32 = 3
        public static let BOR: Int32 = 4
        public static let BXOR: Int32 = 5
        public static let SHL: Int32 = 6
        public static let SAR: Int32 = 7
        public static let SHR: Int32 = 8
        public static let EQ: Int32 = 9
        public static let NE: Int32 = 10
    }

    // parity: psychoscript/src/opcodes.ts#BinOpSymbols [status=implemented hash=14f46cb71c1f]
    public static let BinOpSymbols: [String] = ["/", "%", "**", "&", "|", "^", "<<", ">>", ">>>", "==", "!="]

    // parity: psychoscript/src/opcodes.ts#UnaryOp [status=implemented hash=1d24a4cb2539]
    public enum UnaryOp {
        public static let NEG: Int32 = 0
        public static let PLUS: Int32 = 1
        public static let BNOT: Int32 = 2
        public static let TYPEOF: Int32 = 3
        public static let VOID: Int32 = 4
    }

    // parity: psychoscript/src/opcodes.ts#UnaryOpSymbols [status=implemented hash=de626f06a1aa]
    public static let UnaryOpSymbols: [String] = ["-", "+", "~", "typeof", "void"]

    // parity: psychoscript/src/opcodes.ts#CondKind [status=implemented hash=9c2fe7b1f7c7]
    public enum CondKind {
        public static let TRUTHY_KEEP: Int32 = 0
        public static let FALSY_KEEP: Int32 = 1
        public static let NOT_NULLISH_KEEP: Int32 = 2
        public static let DEFINED: Int32 = 3
        public static let NULLISH: Int32 = 4
        public static let NULLISH_METHOD: Int32 = 5
    }

    // parity: psychoscript/src/opcodes.ts#PutKind [status=implemented hash=2f4d2dcc427b]
    public enum PutKind {
        public static let ASSIGN: Int32 = 0
        public static let INIT: Int32 = 1
        public static let CONST: Int32 = 2
    }

    // parity: psychoscript/src/opcodes.ts#CheckBaseKind [status=implemented hash=9b2d4503c30c]
    public enum CheckBaseKind {
        public static let READ: Int32 = 0
        public static let WRITE_PROP: Int32 = 1
        public static let WRITE_ELEM: Int32 = 2
        public static let DESTRUCTURE: Int32 = 3
    }

    // parity: psychoscript/src/opcodes.ts#IterContext [status=implemented hash=14c7967d510f]
    public enum IterContext {
        public static let FOR_OF: Int32 = 0
        public static let DESTRUCTURE: Int32 = 1
        public static let SPREAD: Int32 = 2
        public static let DELEGATE: Int32 = 3
        public static let FOR_AWAIT: Int32 = 4
        public static let ASYNC_DELEGATE: Int32 = 5
        public static let CHECK_OBJECT: Int32 = 6
    }

    // parity: psychoscript/src/opcodes.ts#ImportKind [status=implemented hash=2567db403bce]
    public enum ImportKind {
        public static let DEFAULT: Int32 = 0
        public static let NAMESPACE: Int32 = 1
        public static let NAMED: Int32 = 2
        public static let SIDE_EFFECT: Int32 = 3
        public static let DYNAMIC: Int32 = 4
    }

    // parity: psychoscript/src/opcodes.ts#CodeFlags [status=implemented hash=79bd197d305d]
    public enum CodeFlags {
        public static let ARROW: Int = 1 << 0
        public static let ASYNC: Int = 1 << 1
        public static let GENERATOR: Int = 1 << 2
        public static let SIMPLE_PARAMS: Int = 1 << 3
        public static let USES_THIS: Int = 1 << 4
        public static let USES_ARGUMENTS: Int = 1 << 5
        public static let INTERNAL: Int = 1 << 6
        public static let PROGRAM: Int = 1 << 7
        /// A class constructor: `new` only, calling it throws.
        public static let CLASS_CONSTRUCTOR: Int = 1 << 8
        public static let NEEDS_ARGS: Int = 1 << 9
        /// The constructor of a class with `extends`.
        public static let DERIVED: Int = 1 << 10
        /// A class or object literal method, with a home object.
        public static let METHOD: Int = 1 << 11
        /// A class's hidden field-initializer function.
        public static let FIELD_INIT: Int = 1 << 12
    }

    // parity: psychoscript/src/opcodes.ts#TemplateSite [status=implemented hash=e7f1125778b0]
    public struct TemplateSite: Equatable, Hashable, Sendable, Codable {
        public let cooked: [String?]
        public let raw: [String]
        public let nodeIndex: Int

        public init(cooked: [String?], raw: [String], nodeIndex: Int) {
            self.cooked = cooked
            self.raw = raw
            self.nodeIndex = nodeIndex
        }
    }

    // parity: psychoscript/src/opcodes.ts#RegExpSite [status=implemented hash=564ba90034b3]
    public struct RegExpSite: Equatable, Hashable, Sendable, Codable {
        public let pattern: String
        public let flags: String

        public init(pattern: String, flags: String) {
            self.pattern = pattern
            self.flags = flags
        }
    }

    // parity: psychoscript/src/opcodes.ts#ErrorSite [status=implemented hash=d8e9677f5447]
    public struct ErrorSite: Equatable, Hashable, Sendable, Codable {
        public let type: ErrorType
        public let message: String
        public let kind: DiagnosticKind?
        public let suggestions: [String]?

        public init(type: ErrorType, message: String, kind: DiagnosticKind? = nil, suggestions: [String]? = nil) {
            self.type = type
            self.message = message
            self.kind = kind
            self.suggestions = suggestions
        }
    }

    // parity: psychoscript/src/opcodes.ts#ImportSite [status=implemented hash=9355255f1ef3]
    public struct ImportSite: Equatable, Hashable, Sendable, Codable {
        public let specifier: String
        public let imported: String?

        public init(specifier: String, imported: String? = nil) {
            self.specifier = specifier
            self.imported = imported
        }
    }

    // parity: psychoscript/src/opcodes.ts#ConstValue [status=implemented hash=7004b01e3cd7]
    public enum ConstValue: Equatable, Hashable, Sendable, Codable {
        case string(String)
        case number(Double)
        case template(TemplateSite)
        case regexp(RegExpSite)
        case error(ErrorSite)
        case importSite(ImportSite)
    }

    // parity: psychoscript/src/opcodes.ts#packWord [status=implemented hash=b98b53cd31f9]
    public static func packWord(_ op: OpCode, _ a: Int32 = 0, _ bx: Int32 = 0) throws -> Int32 {
        guard (op & 0xFF) == op, (a & 0xFF) == a, (bx & 0xFFFF) == bx else {
            throw rangeError("Instruction operand out of single-word range: op=\(op) a=\(a) bx=\(bx)")
        }
        let packed = UInt32(bitPattern: op) | (UInt32(bitPattern: a) << 8) | (UInt32(bitPattern: bx) << 16)
        return Int32(bitPattern: packed)
    }

    // MARK: - Code Units & Builder (src/language/code.ts)

    public struct SourceRef: Equatable, Hashable, Sendable, Codable {
        public let id: String
        public let hash: String

        public init(id: String, hash: String) {
            self.id = id
            self.hash = hash
        }
    }

    // parity: psychoscript/src/code.ts#Label [status=implemented hash=33b46a97a34c]
    public struct Label: Equatable, Sendable {
        public var pc: Int
        public var patches: [Int]
        public var depth: Int?

        public init(pc: Int = -1, patches: [Int] = [], depth: Int? = nil) {
            self.pc = pc
            self.patches = patches
            self.depth = depth
        }
    }

    // parity: psychoscript/src/code.ts#Code [status=implemented hash=6e5476af5885]
    public final class Code: Sendable {
        public let source: SourceRef
        public let index: Int
        public let name: String
        public let flags: Int
        public let length: Int
        public let params: Int
        public let locals: Int
        public let maxStack: Int
        public let code: [Int32]
        public let consts: [ConstValue]
        public let captures: [Int32]
        public let handlers: [Int32]
        public let finallies: [Int32]
        public let finallyOffsets: [Int32]
        public let sites: [Int32]
        public let localNames: [String]
        public let upvalNames: [String]
        public let sourceObj: Source?

        public init(
            source: SourceRef,
            index: Int,
            name: String,
            flags: Int,
            length: Int,
            params: Int,
            locals: Int,
            maxStack: Int,
            code: [Int32],
            consts: [ConstValue],
            captures: [Int32] = [],
            handlers: [Int32] = [],
            finallies: [Int32] = [],
            finallyOffsets: [Int32] = [],
            sites: [Int32] = [],
            localNames: [String] = [],
            upvalNames: [String] = [],
            sourceObj: Source? = nil
        ) {
            self.source = source
            self.index = index
            self.name = name
            self.flags = flags
            self.length = length
            self.params = params
            self.locals = locals
            self.maxStack = maxStack
            self.code = code
            self.consts = consts
            self.captures = captures
            self.handlers = handlers
            self.finallies = finallies
            self.finallyOffsets = finallyOffsets
            self.sites = sites
            self.localNames = localNames
            self.upvalNames = upvalNames
            self.sourceObj = sourceObj
        }

        // parity: psychoscript/src/code.ts#Code.nodeIndexAt [status=implemented hash=344825e16d88]
        public func nodeIndexAt(_ pc: Int) -> Int {
            let count = sites.count >> 1
            if count == 0 { return -1 }
            var low = 0
            var high = count - 1
            var best = -1
            while low <= high {
                let mid = (low + high) >> 1
                let entryPc = Int(sites[mid << 1])
                if entryPc <= pc {
                    best = Int(sites[(mid << 1) + 1])
                    low = mid + 1
                } else {
                    high = mid - 1
                }
            }
            return best
        }

        // parity: psychoscript/src/code.ts#Code.siteAt [status=implemented hash=e284696db5cf]
        public func siteAt(_ pc: Int) -> AstNode? {
            let idx = nodeIndexAt(pc)
            guard idx >= 0, let nodes = sourceObj?.nodes, idx < nodes.count else { return nil }
            return nodes[idx]
        }

        // parity: psychoscript/src/code.ts#Code.withSource [status=implemented hash=57a886457613]
        public func withSource(_ sourceObj: Source) -> Code {
            Code(
                source: source,
                index: index,
                name: name,
                flags: flags,
                length: length,
                params: params,
                locals: locals,
                maxStack: maxStack,
                code: code,
                consts: consts,
                captures: captures,
                handlers: handlers,
                finallies: finallies,
                finallyOffsets: finallyOffsets,
                sites: sites,
                localNames: localNames,
                upvalNames: upvalNames,
                sourceObj: sourceObj
            )
        }
    }

    // parity: psychoscript/src/code.ts#CodeJson [status=implemented hash=512244bb74f7]
    public struct CodeJson: Equatable, Sendable, Codable {
        public let source: SourceRef
        public let index: Int
        public let name: String
        public let flags: Int
        public let length: Int
        public let params: Int
        public let locals: Int
        public let maxStack: Int
        public let code: [Int32]
        public let consts: [ConstValue]
        public let captures: [Int32]
        public let handlers: [Int32]
        public let finallies: [Int32]
        public let finallyOffsets: [Int32]
        public let sites: [Int32]
        public let localNames: [String]
        public let upvalNames: [String]
    }

    // parity: psychoscript/src/code.ts#codeToJson [status=implemented hash=bb346a73fb0c]
    public static func codeToJson(_ code: Code) -> CodeJson {
        CodeJson(
            source: code.source,
            index: code.index,
            name: code.name,
            flags: code.flags,
            length: code.length,
            params: code.params,
            locals: code.locals,
            maxStack: code.maxStack,
            code: code.code,
            consts: code.consts,
            captures: code.captures,
            handlers: code.handlers,
            finallies: code.finallies,
            finallyOffsets: code.finallyOffsets,
            sites: code.sites,
            localNames: code.localNames,
            upvalNames: code.upvalNames
        )
    }

    // parity: psychoscript/src/code.ts#codeFromJson [status=implemented hash=efe0a72be173]
    public static func codeFromJson(_ data: CodeJson, sourceObj: Source) -> Code {
        Code(
            source: data.source,
            index: data.index,
            name: data.name,
            flags: data.flags,
            length: data.length,
            params: data.params,
            locals: data.locals,
            maxStack: data.maxStack,
            code: data.code,
            consts: data.consts,
            captures: data.captures,
            handlers: data.handlers,
            finallies: data.finallies,
            finallyOffsets: data.finallyOffsets,
            sites: data.sites,
            localNames: data.localNames,
            upvalNames: data.upvalNames,
            sourceObj: sourceObj
        )
    }

    // parity: psychoscript/src/code.ts#CodeSizeOverflow [status=implemented hash=9e1e5528fd13]
    public final class CodeSizeOverflow: Error, Sendable, CustomStringConvertible {
        public let message: String

        public init(_ message: String = "Function bytecode exceeds 16-bit jump range") {
            self.message = message
        }

        public var description: String { message }
    }

    // parity: psychoscript/src/code.ts#CodeBuilder [status=implemented hash=02b61e5d8310]
    public final class CodeBuilder: Sendable {
        private struct State: Sendable {
            var words: [Int32] = []
            var sitePairs: [Int32] = []
            var lastNodeIndex: Int = -2
            var constList: [ConstValue] = []
            var pooledStrings: [String: Int] = [:]
            var pooledNumbers: [UInt64: Int] = [:]
            var handlerWords: [Int32] = []
            var finallyWords: [Int32] = []
            var finallyLevelOffsets: [Int32] = []
            var depth: Int = 0
            var maxStack: Int = 0
            var flags: Int
            var locals: Int
            var wideJumps: Bool = false
            var forceExtra: Bool = false
        }

        public let source: SourceRef
        public let sourceObj: Source?
        public let index: Int
        public let name: String
        public let length: Int
        public let params: Int
        public let localNames: [String]
        public let captures: [Int32]
        public let upvalNames: [String]
        private let state: Mutex<State>

        public init(
            source: SourceRef,
            sourceObj: Source?,
            index: Int,
            name: String,
            flags: Int,
            length: Int,
            params: Int,
            locals: Int,
            localNames: [String],
            captures: [Int32] = [],
            upvalNames: [String] = []
        ) {
            self.source = source
            self.sourceObj = sourceObj
            self.index = index
            self.name = name
            self.length = length
            self.params = params
            self.localNames = localNames
            self.captures = captures
            self.upvalNames = upvalNames
            self.state = Mutex(State(flags: flags, locals: locals))
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.pc [status=implemented hash=e0470568ca97]
        public var pc: Int {
            state.withLock { $0.words.count }
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.adjustDepth [status=implemented hash=7fa0637432fe]
        public func adjustDepth(_ delta: Int) {
            state.withLock { s in
                if s.depth < 0 { return }
                s.depth += delta
                if s.depth > s.maxStack { s.maxStack = s.depth }
            }
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.setDepth [status=implemented hash=79e9c28719e9]
        public func setDepth(_ depth: Int) {
            state.withLock { s in
                s.depth = depth
                if s.depth > s.maxStack { s.maxStack = s.depth }
            }
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.unreachable [status=implemented hash=2395e07d6869]
        public func unreachable() {
            state.withLock { $0.depth = -1 }
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.constant [status=implemented hash=554a260e76fd]
        public func constant(_ value: ConstValue) -> Int {
            state.withLock { s in
                switch value {
                case .string(let str):
                    if let existing = s.pooledStrings[str] { return existing }
                    let idx = s.constList.count
                    s.constList.append(value)
                    s.pooledStrings[str] = idx
                    return idx
                case .number(let num) where !(num == 0 && num.sign == .minus):
                    let bits = num.bitPattern
                    if let existing = s.pooledNumbers[bits] { return existing }
                    let idx = s.constList.count
                    s.constList.append(value)
                    s.pooledNumbers[bits] = idx
                    return idx
                default:
                    let idx = s.constList.count
                    s.constList.append(value)
                    return idx
                }
            }
        }

        public func addConst(_ value: ConstValue) -> Int {
            constant(value)
        }

        private static func recordSiteLocked(_ s: inout State, pc: Int, nodeIndex: Int) {
            if nodeIndex < 0 || nodeIndex == s.lastNodeIndex { return }
            s.sitePairs.append(Int32(pc))
            s.sitePairs.append(Int32(nodeIndex))
            s.lastNodeIndex = nodeIndex
        }

        private static func pushOpLocked(
            _ s: inout State,
            op: OpCode,
            a: Int,
            bx: Int,
            nodeIndex: Int,
            forceWide: Bool
        ) throws -> Int {
            if op == Op.EXTRA {
                throw CodemodeLanguage.rangeError("Invalid opcode: \(op)")
            }
            if op == Op.NEW && a > 0xff {
                throw CodemodeLanguage.rangeError("Op.NEW operand a out of range: \(a)")
            }
            if a > 0xffff {
                recordSiteLocked(&s, pc: s.words.count, nodeIndex: nodeIndex)
                s.words.append(try packWord(Op.EXTRA, 0, Int32((a >> 16) & 0xffff)))
                s.words.append(try packWord(Op.EXTRA, Int32((a >> 8) & 0xff), Int32((bx >> 16) & 0xffff)))
            } else if forceWide || a > 0xff || (op != Op.PUSH_INT && bx > 0xffff) {
                recordSiteLocked(&s, pc: s.words.count, nodeIndex: nodeIndex)
                s.words.append(try packWord(Op.EXTRA, Int32((a >> 8) & 0xff), Int32((bx >> 16) & 0xffff)))
            }
            let emittedPc = s.words.count
            recordSiteLocked(&s, pc: emittedPc, nodeIndex: nodeIndex)
            s.words.append(try packWord(op, Int32(a & 0xff), Int32(bx & 0xffff)))
            if !s.wideJumps && !s.forceExtra && s.words.count > 0xffff {
                throw CodeSizeOverflow()
            }
            return emittedPc
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.emit [status=implemented hash=5c6bfb2bd79d]
        @discardableResult
        public func emit(_ op: OpCode, a: Int32 = 0, bx: Int32 = 0, nodeIndex: Int = -1, stackDelta: Int = 0) throws -> Int {
            try state.withLock { s in
                if s.depth < 0 { return s.words.count }
                let emitted = try Self.pushOpLocked(&s, op: op, a: Int(a), bx: Int(bx), nodeIndex: nodeIndex, forceWide: s.forceExtra)
                s.depth += stackDelta
                if s.depth > s.maxStack { s.maxStack = s.depth }
                return emitted
            }
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.emitNumber [status=implemented hash=e748b2ea3481]
        public func emitNumber(_ value: Double, nodeIndex: Int = -1) throws {
            let isNegZero = value == 0 && value.sign == .minus
            let forceExtra = state.withLock { $0.forceExtra }
            if value.isFinite && value.rounded(.towardZero) == value && !isNegZero && value >= -32768 && value <= 32767 && !forceExtra {
                let raw = Int32(Int(value)) & 0xffff
                try emit(Op.PUSH_INT, a: 0, bx: raw, nodeIndex: nodeIndex, stackDelta: 1)
                return
            }
            let k = constant(.number(value))
            try emit(Op.PUSH_CONST, a: 0, bx: Int32(k), nodeIndex: nodeIndex, stackDelta: 1)
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.emitString [status=implemented hash=60cf4472f289]
        public func emitString(_ value: String, nodeIndex: Int = -1) throws {
            let k = constant(.string(value))
            try emit(Op.PUSH_CONST, a: 0, bx: Int32(k), nodeIndex: nodeIndex, stackDelta: 1)
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.newLabel [status=implemented hash=a91cbd8fdc92]
        public func newLabel(depth: Int? = nil) -> Label {
            Label(pc: -1, patches: [], depth: depth)
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.mark [status=implemented hash=e53bac945b16]
        public func mark(_ label: inout Label) throws {
            try state.withLock { s in
                let target = s.words.count
                label.pc = target
                if let labelDepth = label.depth {
                    s.depth = labelDepth
                    if s.depth > s.maxStack { s.maxStack = s.depth }
                } else if s.depth >= 0 {
                    label.depth = s.depth
                }
                for patchPc in label.patches {
                    let hasExtra = patchPc > 0 && UInt8(truncatingIfNeeded: s.words[patchPc - 1]) == Op.EXTRA
                    if !hasExtra {
                        if target > 0xffff { throw CodeSizeOverflow() }
                        s.words[patchPc] = (s.words[patchPc] & 0xffff) | Int32(truncatingIfNeeded: (target & 0xffff) << 16)
                    } else {
                        let hi = (target >> 16) & 0xffff
                        let lo = target & 0xffff
                        s.words[patchPc - 1] = (s.words[patchPc - 1] & 0xffff) | Int32(truncatingIfNeeded: hi << 16)
                        s.words[patchPc] = (s.words[patchPc] & 0xffff) | Int32(truncatingIfNeeded: lo << 16)
                    }
                }
                label.patches.removeAll()
            }
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.emitJump [status=implemented hash=6a47273cb977]
        public func emitJump(
            _ op: OpCode,
            a: Int = 0,
            label: inout Label,
            nodeIndex: Int = -1,
            jumpDelta: Int = 0,
            fallDelta: Int? = 0
        ) throws {
            try state.withLock { s in
                if s.depth < 0 { return }
                let targetDepth = s.depth + jumpDelta
                if label.depth == nil { label.depth = targetDepth }
                let known = label.pc >= 0
                if known && !s.wideJumps && !s.forceExtra && label.pc > 0xffff {
                    throw CodeSizeOverflow()
                }
                let emittedPc = try Self.pushOpLocked(
                    &s,
                    op: op,
                    a: a,
                    bx: known ? label.pc : 0,
                    nodeIndex: nodeIndex,
                    forceWide: s.wideJumps || s.forceExtra
                )
                if !known { label.patches.append(emittedPc) }
                if let fallDelta {
                    s.depth += fallDelta
                    if s.depth > s.maxStack { s.maxStack = s.depth }
                } else {
                    s.depth = -1
                }
            }
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.addHandler [status=implemented hash=d6c8c036040e]
        public func addHandler(start: Int, end: Int, target: Int, depth: Int) {
            guard start < end, target >= 0 else { return }
            state.withLock { s in
                s.handlerWords.append(contentsOf: [Int32(start), Int32(end), Int32(target), Int32(depth)])
            }
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.reserveFinally [status=implemented hash=1a29d03d9c34]
        public func reserveFinally() -> Int {
            state.withLock { s in
                let level = s.finallyLevelOffsets.count
                s.finallyLevelOffsets.append(-1)
                return level
            }
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.setFinally [status=implemented hash=f4e15a96829c]
        public func setFinally(level: Int, tagSlot: Int, valSlot: Int, entryDepth: Int, targets: [Int]) throws {
            try state.withLock { s in
                guard level >= 0, level < s.finallyLevelOffsets.count else {
                    throw CodemodeLanguage.rangeError("Finally level out of range: \(level)")
                }
                s.finallyLevelOffsets[level] = Int32(s.finallyWords.count)
                s.finallyWords.append(contentsOf: [Int32(tagSlot), Int32(valSlot), Int32(entryDepth), Int32(targets.count)])
                for t in targets {
                    guard t >= -1 && t <= 0x7fffffff else {
                        throw CodemodeLanguage.rangeError("Finally target out of range: \(t)")
                    }
                    s.finallyWords.append(Int32(t))
                }
            }
        }

        // parity: psychoscript/src/code.ts#CodeBuilder.finish [status=implemented hash=875080499824]
        public func finish() -> Code {
            state.withLock { s in
                Code(
                    source: source,
                    index: index,
                    name: name,
                    flags: s.flags,
                    length: length,
                    params: params,
                    locals: s.locals,
                    maxStack: s.maxStack,
                    code: s.words,
                    consts: s.constList,
                    captures: captures,
                    handlers: s.handlerWords,
                    finallies: s.finallyWords,
                    finallyOffsets: s.finallyLevelOffsets,
                    sites: s.sitePairs,
                    localNames: localNames,
                    upvalNames: upvalNames,
                    sourceObj: sourceObj
                )
            }
        }

        public func build() -> Code {
            finish()
        }
    }

    // parity: psychoscript/src/code.ts#hashOf [status=implemented hash=b718dc281f87]
    public static func hashOf(_ codes: [Code]) -> String {
        var acc = ""
        for c in codes {
            acc += "\(c.index):\(c.name):\(c.flags):\(c.params):\(c.locals):\(c.code.count);"
        }
        return snapshotHash(acc)
    }

    // MARK: - Scope Analysis & Compiler (src/language/compiler/scope.ts, compile.ts)

    public enum DeclKind: String, Equatable, Hashable, Sendable, Codable {
        case `var`, `let`, `const`, function, param, `catch`, `import`, `self`, this, arguments, home, newTarget
    }

    // parity: psychoscript/src/compiler/scope.ts#Decl [status=implemented hash=e572b054f662]
    public struct Decl: Equatable, Hashable, Sendable {
        public let name: String
        public let kind: DeclKind
        public let fnIndex: Int
        public var mutable: Bool
        public var captured: Bool
        public var used: Bool
        public var slot: Int

        public init(
            name: String,
            kind: DeclKind,
            fnIndex: Int,
            mutable: Bool,
            captured: Bool = false,
            used: Bool = false,
            slot: Int = -1
        ) {
            self.name = name
            self.kind = kind
            self.fnIndex = fnIndex
            self.mutable = mutable
            self.captured = captured
            self.used = used
            self.slot = slot
        }
    }

    // parity: psychoscript/src/compiler/scope.ts#Scope [status=implemented hash=93e9e7ddf08d]
    public final class Scope: Sendable {
        private struct State: Sendable {
            var decls: [String: Decl] = [:]
        }

        public let parent: Scope?
        private let state = Mutex(State())

        public init(parent: Scope? = nil) {
            self.parent = parent
        }

        public var decls: [String: Decl] {
            state.withLock { $0.decls }
        }

        public func insert(_ decl: Decl) {
            state.withLock { $0.decls[decl.name] = decl }
        }

        public func lookup(_ name: String) -> Decl? {
            if let local = state.withLock({ $0.decls[name] }) { return local }
            return parent?.lookup(name)
        }
    }

    // parity: psychoscript/src/compiler/scope.ts#FunctionInfo [status=implemented hash=46d02d55ecf4]
    public struct FunctionInfo: Sendable {
        public let index: Int
        public let parentIndex: Int
        public let name: String
        public let flags: Int
        public let length: Int
        public let params: [Pattern]
        public let bodyScope: Scope
        public let allDecls: [Decl]
        public let localNames: [String]
        /// A method's home object (`super`), when it or an arrow in it uses `super`.
        public let homeDecl: Decl?
        /// A derived constructor's new target, which `super()` passes on.
        public let newTargetDecl: Decl?

        public init(
            index: Int,
            parentIndex: Int,
            name: String,
            flags: Int,
            length: Int,
            params: [Pattern],
            bodyScope: Scope,
            allDecls: [Decl],
            localNames: [String],
            homeDecl: Decl? = nil,
            newTargetDecl: Decl? = nil
        ) {
            self.index = index
            self.parentIndex = parentIndex
            self.name = name
            self.flags = flags
            self.length = length
            self.params = params
            self.bodyScope = bodyScope
            self.allDecls = allDecls
            self.localNames = localNames
            self.homeDecl = homeDecl
            self.newTargetDecl = newTargetDecl
        }
    }

    // parity: psychoscript/src/compiler/scope.ts#ResolvedRef [status=implemented hash=1d39cfd0c2ff]
    public enum ResolvedRef: Equatable, Sendable {
        case local(Decl)
        case upval(upvalIndex: Int, decl: Decl)
        case global(name: String)
    }

    /// One `super` of a `super.x`: the method whose home object it reads (through arrows) and where it is.
    public struct SuperRef: Equatable, Sendable {
        public let ownerIndex: Int
        public let location: SourceLocation?

        public init(ownerIndex: Int, location: SourceLocation?) {
            self.ownerIndex = ownerIndex
            self.location = location
        }
    }

    /// A class's synthetic field-initializer functions, when it has instance or static fields.
    public struct ClassFieldInits: Equatable, Sendable {
        public let instance: Int?
        public let `static`: Int?

        public init(instance: Int?, static: Int?) {
            self.instance = instance
            self.static = `static`
        }
    }

    // parity: psychoscript/src/compiler/scope.ts#ScopeAnalysis [status=implemented hash=eef17b721e89]
    public struct ScopeAnalysis: Sendable {
        public let functions: [FunctionInfo]
        public let globalsReferenced: [String]
        /// Each `super` of a `super.x` inside a method. Those outside methods are refused by the parser.
        public let superRefs: [SuperRef]
        /// Each class (in source order) and its constructor's function index: its own, or the synthetic one.
        public let classConstructors: [Int]
        /// Each class's field-initializer function indices, by class (in source order).
        public let classFieldInits: [Int: ClassFieldInits]
        /// The fields a synthetic field-initializer function (by function index) defines, in order.
        public let fieldInitMembers: [Int: [ClassMember]]
        /// A computed field's key, evaluated once at class definition into a hidden class-scope binding: by class and
        /// member index, the binding's name.
        public let fieldKeys: [String: String]

        public init(
            functions: [FunctionInfo],
            globalsReferenced: [String],
            superRefs: [SuperRef] = [],
            classConstructors: [Int] = [],
            classFieldInits: [Int: ClassFieldInits] = [:],
            fieldInitMembers: [Int: [ClassMember]] = [:],
            fieldKeys: [String: String] = [:]
        ) {
            self.functions = functions
            self.globalsReferenced = globalsReferenced
            self.superRefs = superRefs
            self.classConstructors = classConstructors
            self.classFieldInits = classFieldInits
            self.fieldInitMembers = fieldInitMembers
            self.fieldKeys = fieldKeys
        }
    }

    /// The `super(...args)` of each default derived constructor: it passes its arguments on as they are, without
    /// iterating them, so an overridden array iterator is not observable (ES2022). The parser marks it `passThrough`.
    // parity: psychoscript/src/compiler/scope.ts#defaultSuperCalls [status=adapted hash=42a4ea9b8649]
    public static func defaultSuperCalls(_ expression: Expression) -> Bool {
        if case .superCall(_, true, _) = expression { return true }
        return false
    }

    // parity: psychoscript/src/compiler/scope.ts#ClassNode [status=implemented hash=9ab9f9de1158]
    public typealias ClassNode = ClassPayload

    /// The class elements compiled so far: methods, accessors and fields with plain or computed names. Anything else
    /// (private members, static blocks) is refused by the parser before a `ClassMember` exists.
    // parity: psychoscript/src/compiler/scope.ts#supportedClassMember [status=implemented hash=2490b4025aca]
    public static func supportedClassMember(_ member: ClassMember) -> Bool {
        switch member.key {
        case .computed, .identifier, .string, .number: return true
        }
    }

    public static func collectPatternNames(_ pattern: Pattern) -> [String] {
        switch pattern {
        case .identifier(let name, _):
            return [name]
        case .assignment(let left, _, _):
            return collectPatternNames(left)
        case .array(let elements, let rest, _):
            var out: [String] = []
            for el in elements {
                if let el { out.append(contentsOf: collectPatternNames(el)) }
            }
            if let rest { out.append(contentsOf: collectPatternNames(rest)) }
            return out
        case .object(let props, let rest, _):
            var out: [String] = []
            for p in props { out.append(contentsOf: collectPatternNames(p.value)) }
            if let rest { out.append(contentsOf: collectPatternNames(rest)) }
            return out
        case .member, .superMember:
            return []
        }
    }

    // parity: psychoscript/src/compiler/scope.ts#analyzeScopes [status=implemented hash=addcc0d3b7ec]
    public static func analyzeScopes(_ source: Source, internal isInternal: Bool = false) -> ScopeAnalysis {
        var functions: [FunctionInfo] = []
        var globalsSet: Set<String> = []
        var superUses: [(fnIndex: Int, location: SourceLocation?)] = []
        var classConstructors: [Int] = []
        var classFieldInits: [Int: ClassFieldInits] = [:]
        var fieldInitMembers: [Int: [ClassMember]] = [:]
        var fieldKeys: [String: String] = [:]
        var classCount = 0

        @discardableResult
        func visitFunction(
            name: String,
            params: [Pattern],
            body: FunctionBody,
            isProgram: Bool,
            isArrow: Bool,
            isAsync: Bool,
            isGenerator: Bool,
            parentScope: Scope?,
            parentFnIndex: Int,
            extraFlags: Int = 0,
            fieldMembers: [ClassMember]? = nil
        ) -> Int {
            let fnIndex = functions.count
            var flags = extraFlags
            if isArrow { flags |= CodeFlags.ARROW }
            if isProgram || isAsync { flags |= CodeFlags.ASYNC }
            if isGenerator { flags |= CodeFlags.GENERATOR }
            if isInternal { flags |= CodeFlags.INTERNAL }
            if isProgram { flags |= CodeFlags.PROGRAM }

            let scope = Scope(parent: parentScope)
            var decls: [Decl] = []
            var names: [String] = []

            func addDecl(_ declName: String, kind: DeclKind, mutable: Bool) {
                if scope.decls[declName] != nil { return }
                let d = Decl(name: declName, kind: kind, fnIndex: fnIndex, mutable: mutable, slot: decls.count)
                scope.insert(d)
                decls.append(d)
                names.append(declName)
            }

            for param in params {
                for pName in collectPatternNames(param) {
                    addDecl(pName, kind: .param, mutable: true)
                }
            }
            // `this` starts uninitialized in a derived constructor: `super()` binds it, with its new target.
            if (flags & CodeFlags.DERIVED) != 0 {
                addDecl("this", kind: .this, mutable: true)
                addDecl("%newTarget", kind: .newTarget, mutable: false)
            }

            // The class body sees its own name as an immutable binding; the constructor and methods are functions in it.
            func visitClass(_ cls: ClassPayload, _ cur: Scope) {
                guard cls.members.allSatisfy(supportedClassMember) else { return }
                let classIndex = classCount
                classCount += 1
                let classScope = Scope(parent: cur)
                if let className = cls.name {
                    classScope.insert(Decl(name: className, kind: .const, fnIndex: fnIndex, mutable: false))
                }
                if let superClass = cls.superClass { walkExpr(superClass, classScope) }
                let derived = cls.superClass != nil
                let ctor = cls.constructor
                let ctorIndex = visitFunction(
                    name: cls.name ?? "",
                    params: ctor.params,
                    body: ctor.body,
                    isProgram: false,
                    isArrow: false,
                    isAsync: false,
                    isGenerator: false,
                    parentScope: classScope,
                    parentFnIndex: fnIndex,
                    extraFlags: CodeFlags.CLASS_CONSTRUCTOR | CodeFlags.METHOD | (derived ? CodeFlags.DERIVED : 0)
                )
                classConstructors.append(ctorIndex)
                for (memberIndex, member) in cls.members.enumerated() {
                    guard case .computed(let keyExpr, _) = member.key else { continue }
                    walkExpr(keyExpr, classScope)
                    guard member.kind == .field else { continue }
                    let keyName = "%key\(fieldKeys.count)"
                    classScope.insert(Decl(name: keyName, kind: .const, fnIndex: fnIndex, mutable: false))
                    fieldKeys["\(classIndex):\(memberIndex)"] = keyName
                }
                for member in cls.members where member.kind != .field {
                    guard let fn = member.function else { continue }
                    visitFunction(
                        name: fn.name ?? "",
                        params: fn.params,
                        body: fn.body,
                        isProgram: false,
                        isArrow: false,
                        isAsync: fn.isAsync,
                        isGenerator: fn.isGenerator,
                        parentScope: classScope,
                        parentFnIndex: fnIndex,
                        extraFlags: CodeFlags.METHOD
                    )
                }
                func fieldInit(_ fields: [ClassMember], _ initName: String) -> Int? {
                    if fields.isEmpty { return nil }
                    // A synthetic method whose body is `this` and the field initializers.
                    let stmts: [Statement] = [.expression(.thisExpr(cls.loc), cls.loc)] + fields.compactMap { field in
                        field.value.map { Statement.expression($0, field.loc) }
                    }
                    return visitFunction(
                        name: initName,
                        params: [],
                        body: .block(stmts),
                        isProgram: false,
                        isArrow: false,
                        isAsync: false,
                        isGenerator: false,
                        parentScope: classScope,
                        parentFnIndex: fnIndex,
                        extraFlags: CodeFlags.METHOD | CodeFlags.FIELD_INIT,
                        fieldMembers: fields
                    )
                }
                let fields = cls.members.filter { $0.kind == .field }
                let instance = fieldInit(fields.filter { !$0.isStatic }, "<instance_members_initializer>")
                let statics = fieldInit(fields.filter(\.isStatic), "<static_initializer>")
                if instance != nil || statics != nil {
                    classFieldInits[classIndex] = ClassFieldInits(instance: instance, static: statics)
                }
            }

            func walkExpr(_ expr: Expression, _ cur: Scope) {
                switch expr {
                case .identifier(let idName, _):
                    if cur.lookup(idName) == nil { globalsSet.insert(idName) }
                case .function(let fn):
                    visitFunction(
                        name: fn.name ?? "",
                        params: fn.params,
                        body: fn.body,
                        isProgram: false,
                        isArrow: fn.isArrow,
                        isAsync: fn.isAsync,
                        isGenerator: fn.isGenerator,
                        parentScope: cur,
                        parentFnIndex: fnIndex,
                        extraFlags: fn.kind == .method ? CodeFlags.METHOD : 0
                    )
                case .classExpr(let cls):
                    visitClass(cls, cur)
                case .superMember(let prop, let loc):
                    superUses.append((fnIndex, loc))
                    if case .computed(let ce, _) = prop { walkExpr(ce, cur) }
                case .superCall(let args, _, _):
                    for a in args {
                        if case .expr(let e) = a { walkExpr(e, cur) }
                        else if case .spread(let e, _) = a { walkExpr(e, cur) }
                    }
                case .array(let els, _):
                    for el in els {
                        if case .expr(let e) = el { walkExpr(e, cur) }
                        else if case .spread(let e, _) = el { walkExpr(e, cur) }
                    }
                case .object(let props, _):
                    for p in props {
                        switch p {
                        case .property(let k, let v, _, _):
                            if case .computed(let ce, _) = k { walkExpr(ce, cur) }
                            walkExpr(v, cur)
                        case .spread(let e, _): walkExpr(e, cur)
                        case .accessor(_, let k, let fn, _):
                            // Object literal methods and accessors have the object as their home, for `super`.
                            if case .computed(let ce, _) = k { walkExpr(ce, cur) }
                            visitFunction(
                                name: fn.name ?? "",
                                params: fn.params,
                                body: fn.body,
                                isProgram: false,
                                isArrow: false,
                                isAsync: false,
                                isGenerator: false,
                                parentScope: cur,
                                parentFnIndex: fnIndex,
                                extraFlags: CodeFlags.METHOD
                            )
                        }
                    }
                case .templateLiteral(_, let es, _): for e in es { walkExpr(e, cur) }
                case .taggedTemplate(let tag, _, let es, _): walkExpr(tag, cur); for e in es { walkExpr(e, cur) }
                case .member(let obj, let prop, _, _):
                    walkExpr(obj, cur)
                    if case .computed(let ce, _) = prop { walkExpr(ce, cur) }
                case .call(let callee, let args, _, _), .newExpr(let callee, let args, _):
                    walkExpr(callee, cur)
                    for a in args {
                        if case .expr(let e) = a { walkExpr(e, cur) }
                        else if case .spread(let e, _) = a { walkExpr(e, cur) }
                    }
                case .unary(_, let a, _), .update(_, let a, _, _), .awaitExpr(let a, _), .importExpr(let a, _), .chain(let a, _):
                    walkExpr(a, cur)
                case .yieldExpr(let a, _, _):
                    if let a { walkExpr(a, cur) }
                case .binary(_, let l, let r, _), .logical(_, let l, let r, _):
                    walkExpr(l, cur); walkExpr(r, cur)
                case .conditional(let t, let c, let a, _):
                    walkExpr(t, cur); walkExpr(c, cur); walkExpr(a, cur)
                case .assignment(_, let left, let r, _):
                    if case .superMember(let prop, let loc) = left {
                        superUses.append((fnIndex, loc))
                        if case .computed(let ce, _) = prop { walkExpr(ce, cur) }
                    }
                    walkExpr(r, cur)
                case .sequence(let es, _):
                    for e in es { walkExpr(e, cur) }
                default: break
                }
            }

            func walkStmts(_ stmts: [Statement], _ cur: Scope) {
                for stmt in stmts {
                    switch stmt {
                    case .variable(let kind, let list, _):
                        let dk: DeclKind = kind == .var ? .var : (kind == .let ? .let : .const)
                        for d in list {
                            for n in collectPatternNames(d.id) {
                                if cur === scope || kind == .var {
                                    addDecl(n, kind: dk, mutable: kind != .const)
                                } else {
                                    cur.insert(Decl(name: n, kind: dk, fnIndex: fnIndex, mutable: kind != .const))
                                }
                            }
                            if let initE = d.initializer { walkExpr(initE, cur) }
                        }
                    case .functionDecl(let fn):
                        if let fnName = fn.name {
                            addDecl(fnName, kind: .function, mutable: true)
                        }
                        visitFunction(
                            name: fn.name ?? "",
                            params: fn.params,
                            body: fn.body,
                            isProgram: false,
                            isArrow: false,
                            isAsync: fn.isAsync,
                            isGenerator: fn.isGenerator,
                            parentScope: cur,
                            parentFnIndex: fnIndex
                        )
                    case .classDecl(let cls):
                        if let className = cls.name {
                            if cur === scope {
                                addDecl(className, kind: .let, mutable: true)
                            } else {
                                cur.insert(Decl(name: className, kind: .let, fnIndex: fnIndex, mutable: true))
                            }
                        }
                        visitClass(cls, cur)
                    case .block(let inner, _):
                        walkStmts(inner, Scope(parent: cur))
                    case .expression(let e, _), .throwStmt(let e, _):
                        walkExpr(e, cur)
                    case .returnStmt(let e, _):
                        if let e { walkExpr(e, cur) }
                    case .ifStmt(let t, let c, let a, _):
                        walkExpr(t, cur); walkStmts([c], cur); if let a { walkStmts([a], cur) }
                    case .whileStmt(let t, let b, _):
                        walkExpr(t, cur); walkStmts([b], cur)
                    case .doWhileStmt(let b, let t, _):
                        walkStmts([b], cur); walkExpr(t, cur)
                    case .forStmt(let ini, let t, let u, let b, _):
                        let fs = Scope(parent: cur)
                        if case .variable(let k, let ds, _) = ini {
                            let dk: DeclKind = k == .var ? .var : (k == .let ? .let : .const)
                            for d in ds {
                                for n in collectPatternNames(d.id) {
                                    fs.insert(Decl(name: n, kind: dk, fnIndex: fnIndex, mutable: k != .const))
                                }
                                if let ie = d.initializer { walkExpr(ie, fs) }
                            }
                        } else if case .expression(let e) = ini {
                            walkExpr(e, fs)
                        }
                        if let t { walkExpr(t, fs) }
                        if let u { walkExpr(u, fs) }
                        walkStmts([b], fs)
                    case .forInStmt(let l, let r, let b, _), .forOfStmt(let l, let r, let b, _, _):
                        let fs = Scope(parent: cur)
                        if case .variable(let k, let p, _) = l {
                            let dk: DeclKind = k == .var ? .var : (k == .let ? .let : .const)
                            for n in collectPatternNames(p) {
                                fs.insert(Decl(name: n, kind: dk, fnIndex: fnIndex, mutable: k != .const))
                            }
                        }
                        walkExpr(r, cur)
                        walkStmts([b], fs)
                    case .switchStmt(let d, let cases, _):
                        walkExpr(d, cur)
                        let ss = Scope(parent: cur)
                        for c in cases {
                            if let t = c.test { walkExpr(t, ss) }
                            walkStmts(c.consequent, ss)
                        }
                    case .tryStmt(let blk, let handler, let fin, _):
                        walkStmts(blk, Scope(parent: cur))
                        if let handler {
                            let cs = Scope(parent: cur)
                            if let p = handler.param {
                                for n in collectPatternNames(p) {
                                    cs.insert(Decl(name: n, kind: .catch, fnIndex: fnIndex, mutable: true))
                                }
                            }
                            walkStmts(handler.body, cs)
                        }
                        if let fin { walkStmts(fin, Scope(parent: cur)) }
                    case .labeled(_, let b, _):
                        walkStmts([b], cur)
                    case .importDecl(let specs, _, _):
                        for spec in specs {
                            switch spec {
                            case .defaultImport(let local), .namespaceImport(let local), .namedImport(_, let local):
                                addDecl(local, kind: .import, mutable: false)
                            }
                        }
                    case .empty, .breakStmt, .continueStmt:
                        break
                    }
                }
            }

            let placeholderIndex = functions.count
            functions.append(FunctionInfo(
                index: fnIndex,
                parentIndex: parentFnIndex,
                name: name,
                flags: flags,
                length: params.count,
                params: params,
                bodyScope: scope,
                allDecls: [],
                localNames: []
            ))
            if let fieldMembers { fieldInitMembers[fnIndex] = fieldMembers }

            switch body {
            case .block(let stmts): walkStmts(stmts, scope)
            case .expression(let expr): walkExpr(expr, scope)
            }

            functions[placeholderIndex] = FunctionInfo(
                index: fnIndex,
                parentIndex: parentFnIndex,
                name: name,
                flags: flags,
                length: params.count,
                params: params,
                bodyScope: scope,
                allDecls: decls,
                localNames: names,
                newTargetDecl: decls.first { $0.kind == .newTarget }
            )
            return fnIndex
        }

        visitFunction(
            name: "<program>",
            params: [],
            body: .block(source.program.body),
            isProgram: true,
            isArrow: false,
            isAsync: true,
            isGenerator: false,
            parentScope: nil,
            parentFnIndex: -1
        )

        // `super` reads the home object of the method it is in, through arrows.
        var superRefs: [SuperRef] = []
        for use in superUses {
            var owner = functions[use.fnIndex]
            while (owner.flags & CodeFlags.ARROW) != 0, owner.parentIndex >= 0 { owner = functions[owner.parentIndex] }
            guard (owner.flags & CodeFlags.METHOD) != 0 else { continue }
            if owner.homeDecl == nil {
                let home = Decl(name: "%home", kind: .home, fnIndex: owner.index, mutable: false, slot: owner.localNames.count)
                owner.bodyScope.insert(home)
                functions[owner.index] = FunctionInfo(
                    index: owner.index,
                    parentIndex: owner.parentIndex,
                    name: owner.name,
                    flags: owner.flags,
                    length: owner.length,
                    params: owner.params,
                    bodyScope: owner.bodyScope,
                    allDecls: owner.allDecls + [home],
                    localNames: owner.localNames + [home.name],
                    homeDecl: home,
                    newTargetDecl: owner.newTargetDecl
                )
            }
            superRefs.append(SuperRef(ownerIndex: owner.index, location: use.location))
        }
        return ScopeAnalysis(
            functions: functions,
            globalsReferenced: globalsSet.sorted(),
            superRefs: superRefs,
            classConstructors: classConstructors,
            classFieldInits: classFieldInits,
            fieldInitMembers: fieldInitMembers,
            fieldKeys: fieldKeys
        )
    }

    // parity: psychoscript/src/compiler/compile.ts#COMPILER_VERSION [status=implemented hash=8ef83148df0d]
    public static let COMPILER_VERSION: Int = 3

    // parity: psychoscript/src/compiler/compile.ts#CompileOptions [status=implemented hash=77e0db95ca3e]
    public struct CompileOptions: Equatable, Sendable {
        public let isInternal: Bool

        public init(isInternal: Bool = false) {
            self.isInternal = isInternal
        }
    }

    // parity: psychoscript/src/compiler/compile.ts#compileSource [status=adapted hash=962946c12371]
    public static func compileSource(_ source: Source, options: CompileOptions = CompileOptions()) -> [Code] {
        let analysis = analyzeScopes(source, internal: options.isInternal)
        let ref = SourceRef(id: source.id, hash: snapshotHash(source.code))
        return analysis.functions.map { fn in
            let builder = CodeBuilder(
                source: ref,
                sourceObj: source,
                index: fn.index,
                name: fn.name,
                flags: fn.flags,
                length: fn.length,
                params: fn.params.count,
                locals: fn.localNames.count,
                localNames: fn.localNames
            )
            _ = try? builder.emit(fn.index == 0 ? Op.END_PROGRAM : Op.RETURN)
            return builder.build()
        }
    }

    // MARK: - Signals (src/language/runtime/signals.ts)

    // parity: psychoscript/src/runtime/signals.ts#Completion [status=implemented hash=d093dc453cd1]
    public enum Completion: Sendable {
        case ok(Value)
        case error(Error)

        public var isOk: Bool {
            if case .ok = self { return true }
            return false
        }
    }

    // parity: psychoscript/src/runtime/signals.ts#normal [status=implemented hash=24ad11f9c1ee]
    public static func normal(_ value: Value) -> Completion {
        .ok(value)
    }

    // parity: psychoscript/src/runtime/signals.ts#abrupt [status=implemented hash=daa652f750ea]
    public static func abrupt(_ error: Error) -> Completion {
        .error(error)
    }

    // parity: psychoscript/src/runtime/signals.ts#PushKind [status=implemented hash=44259b0a6f09]
    public enum PushKind: String, Equatable, Hashable, Sendable, Codable {
        case jsonStringify = "JSON.stringify"
        case asyncFromSyncIterator = "AsyncFromSyncIterator"
        case promiseExecutor = "Promise executor"
        case promiseTry = "Promise.try"
        case promiseCombinator = "Promise combinator"
    }

    // parity: psychoscript/src/runtime/signals.ts#Push [status=implemented hash=4b2612e25636]
    public final class Push: Sendable {
        public let kind: PushKind
        public let slots: [Value]

        public init(kind: PushKind, slots: [Value]) {
            self.kind = kind
            self.slots = slots
        }
    }

    // parity: psychoscript/src/runtime/signals.ts#GeneratorRequest [status=implemented hash=995119cae41e]
    public struct GeneratorRequest: Sendable {
        public let kind: GeneratorRequestKind
        public let value: Value

        public init(kind: GeneratorRequestKind, value: Value = .undefined) {
            self.kind = kind
            self.value = value
        }
    }

    // parity: psychoscript/src/runtime/signals.ts#Resume [status=implemented hash=71ba5324e151]
    public final class Resume: Sendable {
        public let generator: GeneratorObj
        public let request: GeneratorRequest

        public init(generator: GeneratorObj, request: GeneratorRequest) {
            self.generator = generator
            self.request = request
        }
    }

    // parity: psychoscript/src/runtime/signals.ts#Hint [status=implemented hash=6505557e259b]
    public enum Hint: String, Equatable, Hashable, Sendable, Codable {
        case number
        case string
        case `default`
    }

    // parity: psychoscript/src/runtime/signals.ts#Hints [status=implemented hash=3612382eede5]
    public enum Hints: Equatable, Sendable {
        case single(Hint)
        case list([Hint])
    }

    // parity: psychoscript/src/runtime/signals.ts#Convert [status=implemented hash=be597ea06f3a]
    public final class Convert: Sendable {
        public let hints: Hints
        public let values: [Value]
        public let ordinal: Int
        public let coerce: Bool

        public init(hints: Hints, values: [Value], ordinal: Int, coerce: Bool) {
            self.hints = hints
            self.values = values
            self.ordinal = ordinal
            self.coerce = coerce
        }
    }

    // parity: psychoscript/src/runtime/signals.ts#Interruption [status=implemented hash=5b7c98e8f2a2]
    public final class Interruption: Error, Sendable {
        public let reason: String

        public init(_ reason: String = "interrupted") {
            self.reason = reason
        }
    }

    // parity: psychoscript/src/runtime/signals.ts#Invoke [status=implemented hash=f574d101ab7b]
    public final class Invoke: Sendable {
        public let callable: Value
        public let thisValue: Value
        public let args: [Value]
        public let site: AstNode?

        public init(callable: Value, thisValue: Value, args: [Value], site: AstNode? = nil) {
            self.callable = callable
            self.thisValue = thisValue
            self.args = args
            self.site = site
        }
    }

    // parity: psychoscript/src/runtime/signals.ts#Prefetch [status=adapted hash=08c1d410b667]
    /// A built-in met program getters it cannot call (see `withReads`): `reads` (receiver, key, receiver, key, …) are
    /// read in program code, then the built-in runs again from the start, and its reads of them get those values.
    /// Upstream returns it to the VM; here `withReads` carries it out through the evaluator.
    public struct Prefetch: Sendable {
        public let reads: [Value]

        public init(reads: [Value]) {
            self.reads = reads
        }
    }

    // parity: psychoscript/src/runtime/signals.ts#MAX_CALL_DEPTH [status=implemented hash=101eadd2b440]
    public static let MAX_CALL_DEPTH: Int = 10_000

    // MARK: - Modules (src/language/runtime/modules.ts)

    private static let nodeCoreModules: Set<String> = Set(
        "assert async_hooks buffer child_process cluster console constants crypto dgram diagnostics_channel dns domain events fs http http2 https inspector module net os path perf_hooks process punycode querystring readline repl stream string_decoder sys timers tls trace_events tty url util v8 vm wasi worker_threads zlib"
            .split(separator: " ")
            .map(String.init)
    )

    // parity: psychoscript/src/runtime/modules.ts#moduleName [status=implemented hash=a7e83675977d]
    public static func moduleName(_ specifier: String) -> String {
        specifier.hasPrefix("node:") ? String(specifier.dropFirst(5)) : specifier
    }

    // parity: psychoscript/src/runtime/modules.ts#isRuntimeModule [status=implemented hash=1cd61c4c7edd]
    public static func isRuntimeModule(_ specifier: String) -> Bool {
        if specifier.hasPrefix("node:") || specifier == "bun" || specifier.hasPrefix("bun:") {
            return true
        }
        let head = String(specifier.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        return nodeCoreModules.contains(head)
    }

    // parity: psychoscript/src/runtime/modules.ts#resolveModule [status=implemented hash=bdfc6475869d]
    public static func resolveModule(
        _ specifier: String,
        global: (String) -> Value,
        hosted: [String: String] = [:]
    ) -> Value {
        let name = moduleName(specifier)
        let direct = global(name)
        if !direct.isUndefined { return direct }
        if let mapped = hosted[name] {
            let hostedVal = global(mapped)
            if !hostedVal.isUndefined { return hostedVal }
        }
        switch name {
        case "fs/promises":
            if case .object(let fsObj) = global("fs") {
                return get(fsObj, "promises")
            }
            return .undefined
        case "url":
            return pickModule(global: global, names: ["URL", "URLSearchParams"])
        case "util":
            return pickModule(global: global, names: ["TextEncoder", "TextDecoder"])
        case "buffer":
            return pickModule(global: global, names: ["Buffer", "atob", "btoa"])
        default:
            return .undefined
        }
    }

    private static func pickModule(global: (String) -> Value, names: [String]) -> Value {
        var found: [(String, Value)] = []
        for n in names {
            let v = global(n)
            if !v.isUndefined { found.append((n, v)) }
        }
        if found.isEmpty { return .undefined }
        let mod = Obj(proto: nil)
        for (k, v) in found { define(mod, k, v) }
        return .object(mod)
    }

    // MARK: - OrderedTable (src/language/runtime/table.ts)

    public struct DeletedSentinel: Equatable, Hashable, Sendable {
        public init() {}
    }

    // parity: psychoscript/src/runtime/table.ts#deleted [status=implemented hash=4fd98185703e]
    public static let deleted = DeletedSentinel()

    // parity: psychoscript/src/runtime/table.ts#TableCursor [status=implemented hash=3f26d3d2e8d8]
    public final class TableCursor: Sendable {
        private struct State: Sendable {
            var index: Int
            var done: Bool
        }
        private let state: Mutex<State>

        public var index: Int {
            get { state.withLock { $0.index } }
            set { state.withLock { $0.index = newValue } }
        }

        public var done: Bool {
            get { state.withLock { $0.done } }
            set { state.withLock { $0.done = newValue } }
        }

        public init(index: Int = 0, done: Bool = false) {
            self.state = Mutex(State(index: index, done: done))
        }
    }

    /// Insertion-ordered hash table with SameValueZero keys for JS `Map` and `Set`.
    // parity: psychoscript/src/runtime/table.ts#OrderedTable [status=implemented hash=4e1c810ef089]
    public final class OrderedTable: Sendable {
        private enum Entry: Sendable {
            case live(key: Value, value: Value)
            case tombstone
        }

        private struct State: Sendable {
            var entries: [Entry] = []
            var keyIndex: [SameValueZeroKey: Int] = [:]
            var cursors: [TableCursor] = []
            var tombstones: Int = 0
            var pruneAt: Int = 16
        }

        private let state = Mutex(State())

        public init() {}

        // parity: psychoscript/src/runtime/table.ts#OrderedTable.size [status=implemented hash=abef89851de1]
        public var size: Int {
            state.withLock { $0.keyIndex.count }
        }

        // parity: psychoscript/src/runtime/table.ts#OrderedTable.has [status=implemented hash=04808716ce43]
        public func has(_ key: Value) -> Bool {
            let k = SameValueZeroKey(key)
            return state.withLock { $0.keyIndex[k] != nil }
        }

        // parity: psychoscript/src/runtime/table.ts#OrderedTable.get [status=implemented hash=551651e498b4]
        public func get(_ key: Value) -> Value {
            let k = SameValueZeroKey(key)
            return state.withLock { s in
                guard let idx = s.keyIndex[k], case .live(_, let val) = s.entries[idx] else { return .undefined }
                return val
            }
        }

        // parity: psychoscript/src/runtime/table.ts#OrderedTable.set [status=implemented hash=aed8fd42d5dd]
        public func set(_ key: Value, _ value: Value) {
            let normalizedKey: Value = if case .number(let n) = key, n == 0 { .number(0) } else { key }
            let k = SameValueZeroKey(normalizedKey)
            state.withLock { s in
                if let idx = s.keyIndex[k] {
                    s.entries[idx] = .live(key: normalizedKey, value: value)
                    return
                }
                s.keyIndex[k] = s.entries.count
                s.entries.append(.live(key: normalizedKey, value: value))
            }
        }

        // parity: psychoscript/src/runtime/table.ts#OrderedTable.add [status=implemented hash=79e0fb8c9603]
        public func add(_ key: Value) {
            if !has(key) { set(key, .undefined) }
        }

        @discardableResult
        public func delete(_ key: Value) -> Bool {
            let k = SameValueZeroKey(key)
            return state.withLock { s in
                guard let idx = s.keyIndex.removeValue(forKey: k) else { return false }
                s.entries[idx] = .tombstone
                s.tombstones += 1
                if s.tombstones >= 16 && s.tombstones * 2 >= s.entries.count {
                    Self.compactLocked(&s)
                }
                return true
            }
        }

        // parity: psychoscript/src/runtime/table.ts#OrderedTable.clear [status=implemented hash=545c4123e6dd]
        public func clear() {
            state.withLock { s in
                s.entries.removeAll(keepingCapacity: false)
                s.keyIndex.removeAll(keepingCapacity: false)
                s.tombstones = 0
                for c in s.cursors where !c.done {
                    c.index = 0
                }
            }
        }

        // parity: psychoscript/src/runtime/table.ts#OrderedTable.cursor [status=implemented hash=0f5fc2e15b83]
        public func cursor() -> TableCursor {
            track(TableCursor(index: 0, done: false))
        }

        // parity: psychoscript/src/runtime/table.ts#OrderedTable.track [status=implemented hash=f013c2b6971b]
        @discardableResult
        public func track(_ cursor: TableCursor) -> TableCursor {
            state.withLock { s in
                if s.cursors.count >= s.pruneAt {
                    s.cursors = s.cursors.filter { !$0.done }
                    s.pruneAt = max(16, s.cursors.count * 2)
                }
                s.cursors.append(cursor)
            }
            return cursor
        }

        // parity: psychoscript/src/runtime/table.ts#OrderedTable.advance [status=implemented hash=4eaec371c00a]
        public func advance(_ cursor: TableCursor) -> Int {
            if cursor.done { return -1 }
            return state.withLock { s in
                var at = cursor.index
                while at < s.entries.count {
                    if case .live = s.entries[at] {
                        cursor.index = at + 1
                        return at
                    }
                    at += 1
                }
                cursor.done = true
                return -1
            }
        }

        public func entry(at index: Int) -> (Value, Value)? {
            state.withLock { s in
                guard index >= 0, index < s.entries.count, case .live(let k, let v) = s.entries[index] else { return nil }
                return (k, v)
            }
        }

        public func liveEntries() -> [(Value, Value)] {
            state.withLock { s in
                var out: [(Value, Value)] = []
                out.reserveCapacity(s.keyIndex.count)
                for e in s.entries {
                    if case .live(let k, let v) = e { out.append((k, v)) }
                }
                return out
            }
        }

        public func liveKeys() -> [Value] {
            liveEntries().map(\.0)
        }

        public func liveValues() -> [Value] {
            liveEntries().map(\.1)
        }

        private static func compactLocked(_ s: inout State) {
            var remap = [Int](repeating: 0, count: s.entries.count + 1)
            var compacted: [Entry] = []
            compacted.reserveCapacity(s.keyIndex.count)
            s.keyIndex.removeAll(keepingCapacity: true)
            for (oldIdx, e) in s.entries.enumerated() {
                remap[oldIdx] = compacted.count
                if case .live(let k, let v) = e {
                    s.keyIndex[SameValueZeroKey(k)] = compacted.count
                    compacted.append(.live(key: k, value: v))
                }
            }
            remap[s.entries.count] = compacted.count
            for c in s.cursors where !c.done {
                let idx = max(0, min(c.index, s.entries.count))
                c.index = remap[idx]
            }
            s.entries = compacted
            s.tombstones = 0
        }
    }

    public struct SameValueZeroKey: Hashable, Sendable {
        public let value: Value

        public init(_ value: Value) {
            self.value = value
        }

        public static func == (lhs: SameValueZeroKey, rhs: SameValueZeroKey) -> Bool {
            switch (lhs.value, rhs.value) {
            case (.undefined, .undefined), (.null, .null): return true
            case let (.bool(a), .bool(b)): return a == b
            case let (.string(a), .string(b)): return a == b
            case let (.symbol(a), .symbol(b)): return a == b
            case let (.number(a), .number(b)):
                if a.isNaN && b.isNaN { return true }
                return a == b // handles +0 == -0
            case let (.object(a), .object(b)): return a === b
            case let (.hostNamespace(a), .hostNamespace(b)): return a === b
            default: return false
            }
        }

        public func hash(into hasher: inout Hasher) {
            switch value {
            case .undefined: hasher.combine(0)
            case .null: hasher.combine(1)
            case .bool(let b): hasher.combine(2); hasher.combine(b)
            case .number(let n):
                hasher.combine(3)
                if n.isNaN { hasher.combine(UInt64.max) }
                else if n == 0 { hasher.combine(UInt64(0)) }
                else { hasher.combine(n.bitPattern) }
            case .string(let s): hasher.combine(4); hasher.combine(s)
            case .symbol(let sym): hasher.combine(5); hasher.combine(sym)
            case .object(let obj): hasher.combine(6); hasher.combine(ObjectIdentifier(obj))
            case .hostNamespace(let ns): hasher.combine(7); hasher.combine(ObjectIdentifier(ns))
            }
        }
    }

    // MARK: - References Inspection (src/language/runtime/references.ts)

    // parity: psychoscript/src/runtime/references.ts#isOpaque [status=implemented hash=9046153cd3da]
    public static func isOpaque(_ value: Value) -> Bool {
        switch value {
        case .hostNamespace: return true
        case .object(let obj): return obj is Opaque
        default: return false
        }
    }

    private static func findInValue(
        _ root: Value,
        match: (Value) -> Bool,
        skip: (Value) -> Bool
    ) -> Bool {
        var seen = Set<ObjectIdentifier>()
        var stack: [Value] = [root]
        while let current = stack.popLast() {
            if match(current) { return true }
            guard case .object(let obj) = current, !skip(current) else { continue }
            let id = ObjectIdentifier(obj)
            if !seen.insert(id).inserted { continue }
            // A structural check, so it never runs program code: program accessors are left out.
            let hasAccessors = obj.hasProgramAccessors
            for key in ownKeys(obj) {
                if hasAccessors, let slot = own(obj, .string(key)), isProgramAccessor(slot) { continue }
                stack.append(getOwn(obj, key))
            }
        }
        return false
    }

    // parity: psychoscript/src/runtime/references.ts#containsRuntimeReference [status=implemented hash=7528d98c2e22]
    public static func containsRuntimeReference(_ value: Value) -> Bool {
        findInValue(value, match: isRuntimeReference, skip: { _ in false })
    }

    // parity: psychoscript/src/runtime/references.ts#containsOpaqueReference [status=implemented hash=27677ea416e9]
    public static func containsOpaqueReference(_ value: Value) -> Bool {
        findInValue(value, match: isOpaque, skip: { isRuntimeReference($0) && !isOpaque($0) })
    }

    // parity: psychoscript/src/runtime/references.ts#rejectCircularInsertion [status=implemented hash=d7ccda8f43c8]
    public static func rejectCircularInsertion(_ container: Obj, _ value: Value, label: String) throws {
        if hasCircularReference(container, value) { throw circularValue(label) }
    }

    // parity: psychoscript/src/runtime/references.ts#hasCircularReference [status=implemented hash=807701fca078]
    public static func hasCircularReference(_ container: Obj, _ value: Value) -> Bool {
        findInValue(
            value,
            match: { if case .object(let o) = $0 { return o === container } else { return false } },
            skip: isRuntimeReference
        )
    }

    // parity: psychoscript/src/runtime/references.ts#circularValue [status=implemented hash=7ff49c7f4bd8]
    public static func circularValue(_ label: String) -> PendingThrow {
        invalidData("\(label) contains a circular value.")
    }

    // parity: psychoscript/src/runtime/references.ts#describeValue [status=implemented hash=63563bdb6e3a]
    public static func describeValue(_ value: Value) -> String {
        switch value {
        case .null: return "null"
        case .undefined: return "undefined"
        case .bool: return "a boolean"
        case .number: return "a number"
        case .string: return "a string"
        case .symbol: return "a symbol"
        case .hostNamespace: return "a namespace reference"
        case .object(let obj): return obj.describe
        }
    }

    // parity: psychoscript/src/runtime/references.ts#typeofValue [status=implemented hash=6c0e157abf69]
    public static func typeofValue(_ value: Value) -> String {
        switch value {
        case .undefined: return "undefined"
        case .null: return "object"
        case .bool: return "boolean"
        case .number: return "number"
        case .string: return "string"
        case .symbol: return "symbol"
        case .hostNamespace(let ns): return ns.path.isEmpty ? "object" : "function"
        case .object(let obj): return obj is Callable ? "function" : "object"
        }
    }

    // MARK: - Intrinsic Names (src/language/runtime/intrinsic-names.ts)

    // parity: psychoscript/src/runtime/intrinsic-names.ts#Roots [status=implemented hash=f676632bc1ea]
    public struct Roots: Sendable {
        public let globals: [(String, Value)]
        public let builtins: Builtins
        public let internals: [(String, Obj)]

        public init(globals: [(String, Value)], builtins: Builtins, internals: [(String, Obj)] = []) {
            self.globals = globals
            self.builtins = builtins
            self.internals = internals
        }
    }

    // parity: psychoscript/src/runtime/intrinsic-names.ts#member [status=implemented hash=4c2cf21afd22]
    public static func member(_ base: String, _ key: String) -> String {
        "\(base).\(key)"
    }

    // parity: psychoscript/src/runtime/intrinsic-names.ts#unchanged [status=implemented hash=b7be906fffc4]
    public static func unchanged(_ value: Obj) -> Bool {
        value.intrinsic > 0 && type(of: value) == Obj.self || value.intrinsic > 0 && (value is Arr || value is Native || value is Fn)
    }

    private static let cachedStaticNames = Mutex<[String]>([])

    // parity: psychoscript/src/runtime/intrinsic-names.ts#staticNames [status=implemented hash=e872cbf316d5]
    public static func staticNames() -> [String] {
        cachedStaticNames.withLock { $0 }
    }

    // parity: psychoscript/src/runtime/intrinsic-names.ts#IntrinsicNames [status=implemented hash=7c80d701b4a8]
    public final class IntrinsicNames: Sendable {
        private let byName: [String: Obj]
        private let byId: [ObjectIdentifier: String]
        private let hostNamesList: [String]
        private let orderedNames: [String]
        private let orderedValues: [Obj]

        public init(made: [Obj], roots: Roots, hosts: [(String, Value)] = []) {
            var nameMap: [String: Obj] = [:]
            var idMap: [ObjectIdentifier: String] = [:]
            var ordered: [String] = []
            var objs: [Obj] = []
            var hNames: [String] = []

            for (idx, obj) in made.enumerated() {
                obj.intrinsic = idx + 1
            }

            func visit(_ value: Value, _ name: String, isHost: Bool) {
                guard case .object(let obj) = value else { return }
                let oid = ObjectIdentifier(obj)
                if idMap[oid] != nil { return }
                idMap[oid] = name
                nameMap[name] = obj
                ordered.append(name)
                objs.append(obj)
                if isHost { hNames.append(name) }
            }

            for (name, val) in roots.globals { visit(val, name, isHost: false) }
            for (name, obj) in roots.internals { visit(.object(obj), name, isHost: false) }
            for (name, val) in hosts { visit(val, "@\(name)", isHost: true) }

            self.byName = nameMap
            self.byId = idMap
            self.hostNamesList = hNames
            self.orderedNames = ordered
            self.orderedValues = objs
            let staticOnly = ordered.filter { !$0.hasPrefix("@") }
            CodemodeLanguage.cachedStaticNames.withLock { current in
                if current.isEmpty { current = staticOnly }
            }
        }

        // parity: psychoscript/src/runtime/intrinsic-names.ts#IntrinsicNames.values [status=implemented hash=2cd16b96586f]
        public var values: [Obj] { orderedValues }

        // parity: psychoscript/src/runtime/intrinsic-names.ts#IntrinsicNames.nameOf [status=implemented hash=f493d7c263ea]
        public func nameOf(_ value: Obj) -> String? { byId[ObjectIdentifier(value)] }

        // parity: psychoscript/src/runtime/intrinsic-names.ts#IntrinsicNames.valueOf [status=implemented hash=ef3c97e74236]
        public func valueOf(_ name: String) -> Obj? { byName[name] }

        // parity: psychoscript/src/runtime/intrinsic-names.ts#IntrinsicNames.all [status=implemented hash=ee4528ee2d26]
        public func all() -> [String] { orderedNames }

        // parity: psychoscript/src/runtime/intrinsic-names.ts#IntrinsicNames.hosts [status=implemented hash=bb983fed8080]
        public func hosts() -> [String] { hostNamesList }

        // parity: psychoscript/src/runtime/intrinsic-names.ts#IntrinsicNames.changed [status=implemented hash=dbb048db447c]
        public func changed() -> [Obj] { orderedValues.filter { !CodemodeLanguage.unchanged($0) } }
    }

    // MARK: - Prelude (prelude/source.ts, bytecode.ts, helpers.ts, prelude.ts; the internal prelude is in CodemodeInternalPrelude.swift)

    /// The prelude's source as upstream ships it: psychoscript JavaScript, only top-level function declarations, with
    /// `$` names for the privileged helpers. The Swift stdlib implements these built-ins natively (writing elements of
    /// arrays it makes directly, as `$ArraySet` does, and visiting keys with their enumerability checked as they are
    /// read, as `objectEntries`/`objectAssign` do); the source is compiled for its code table.
    // parity: psychoscript/src/prelude/source.ts#code [status=adapted hash=f93c67ca9f39]
    public static let preludeSourceCode: String = #"""
function arrayFromIterable(items, mapper, thisArg) {
  const result = []
  let index = 0
  for (const item of items) {
    $ArraySet(result, index, mapper === undefined ? item : $Call(mapper, thisArg, item, index))
    index++
  }
  return result
}

// Array.from over an array-like with a mapper: every index is read, holes included.
function arrayFromLike(source, length, mapper, thisArg) {
  const result = new Array(length)
  let index = 0
  while (index < length) {
    $ArraySet(result, index, $Call(mapper, thisArg, source[index], index))
    index++
  }
  return result
}

// The callback methods Array and Uint8Array share. They fix the iteration length when they start and read elements
// live; they skip holes, but the find methods visit them as undefined. map and filter return the receiver's kind of
// collection.
function Array$prototype$map(callback, thisArg = undefined) {
  return mapItems($Receiver(this, "Array", "Array.prototype.map"), callback, thisArg, "Array.map")
}
function Uint8Array$prototype$map(callback, thisArg = undefined) {
  const bytes = $Receiver(this, "Uint8Array", "Uint8Array.prototype.map")
  return $DerivedBytes(mapItems(bytes, callback, thisArg, "Uint8Array.map"), bytes)
}
function mapItems(array, callback, thisArg, label) {
  $Callback(callback, label)
  const length = array.length
  const result = new Array(length)
  let index = 0
  while (index < length) {
    if (index in array) $ArraySet(result, index, $Call(callback, thisArg, array[index], index, array))
    index++
  }
  return result
}

function Array$prototype$filter(callback, thisArg = undefined) {
  return filterItems($Receiver(this, "Array", "Array.prototype.filter"), callback, thisArg, "Array.filter")
}
function Uint8Array$prototype$filter(callback, thisArg = undefined) {
  const bytes = $Receiver(this, "Uint8Array", "Uint8Array.prototype.filter")
  return $DerivedBytes(filterItems(bytes, callback, thisArg, "Uint8Array.filter"), bytes)
}
function filterItems(array, callback, thisArg, label) {
  $Callback(callback, label)
  const length = array.length
  const result = []
  let count = 0
  let index = 0
  let item
  while (index < length) {
    if (index in array) {
      item = array[index]
      if ($Call(callback, thisArg, item, index, array)) result[count++] = item
    }
    index++
  }
  return result
}

function Array$prototype$forEach(callback, thisArg = undefined) {
  forEachItem($Receiver(this, "Array", "Array.prototype.forEach"), callback, thisArg, "Array.forEach")
}
function Uint8Array$prototype$forEach(callback, thisArg = undefined) {
  forEachItem($Receiver(this, "Uint8Array", "Uint8Array.prototype.forEach"), callback, thisArg, "Uint8Array.forEach")
}
function forEachItem(array, callback, thisArg, label) {
  $Callback(callback, label)
  const length = array.length
  let index = 0
  while (index < length) {
    if (index in array) $Call(callback, thisArg, array[index], index, array)
    index++
  }
}

function Array$prototype$some(callback, thisArg = undefined) {
  return testItems($Receiver(this, "Array", "Array.prototype.some"), callback, thisArg, "Array.some", false)
}
function Uint8Array$prototype$some(callback, thisArg = undefined) {
  return testItems($Receiver(this, "Uint8Array", "Uint8Array.prototype.some"), callback, thisArg, "Uint8Array.some", false)
}
function Array$prototype$every(callback, thisArg = undefined) {
  return testItems($Receiver(this, "Array", "Array.prototype.every"), callback, thisArg, "Array.every", true)
}
function Uint8Array$prototype$every(callback, thisArg = undefined) {
  return testItems($Receiver(this, "Uint8Array", "Uint8Array.prototype.every"), callback, thisArg, "Uint8Array.every", true)
}
// some stops at the first truthy result, every at the first falsy one.
function testItems(array, callback, thisArg, label, every) {
  $Callback(callback, label)
  const length = array.length
  let index = 0
  while (index < length) {
    if (index in array && !$Call(callback, thisArg, array[index], index, array) === every) return !every
    index++
  }
  return every
}

function Array$prototype$find(callback, thisArg = undefined) {
  return findItem($Receiver(this, "Array", "Array.prototype.find"), callback, thisArg, "Array.find", false, false)
}
function Uint8Array$prototype$find(callback, thisArg = undefined) {
  return findItem($Receiver(this, "Uint8Array", "Uint8Array.prototype.find"), callback, thisArg, "Uint8Array.find", false, false)
}
function Array$prototype$findIndex(callback, thisArg = undefined) {
  return findItem($Receiver(this, "Array", "Array.prototype.findIndex"), callback, thisArg, "Array.findIndex", false, true)
}
function Uint8Array$prototype$findIndex(callback, thisArg = undefined) {
  return findItem($Receiver(this, "Uint8Array", "Uint8Array.prototype.findIndex"), callback, thisArg, "Uint8Array.findIndex", false, true)
}
function Array$prototype$findLast(callback, thisArg = undefined) {
  return findItem($Receiver(this, "Array", "Array.prototype.findLast"), callback, thisArg, "Array.findLast", true, false)
}
function Uint8Array$prototype$findLast(callback, thisArg = undefined) {
  return findItem($Receiver(this, "Uint8Array", "Uint8Array.prototype.findLast"), callback, thisArg, "Uint8Array.findLast", true, false)
}
function Array$prototype$findLastIndex(callback, thisArg = undefined) {
  return findItem($Receiver(this, "Array", "Array.prototype.findLastIndex"), callback, thisArg, "Array.findLastIndex", true, true)
}
function Uint8Array$prototype$findLastIndex(callback, thisArg = undefined) {
  return findItem($Receiver(this, "Uint8Array", "Uint8Array.prototype.findLastIndex"), callback, thisArg, "Uint8Array.findLastIndex", true, true)
}
function findItem(array, callback, thisArg, label, last, wantIndex) {
  $Callback(callback, label)
  const length = array.length
  const step = last ? -1 : 1
  let index = last ? length - 1 : 0
  let item
  while (index >= 0 && index < length) {
    item = array[index]
    if ($Call(callback, thisArg, item, index, array)) return wantIndex ? index : item
    index += step
  }
  return wantIndex ? -1 : undefined
}

// reduce and reduceRight take an initial value where the others take a thisArg.
function Array$prototype$reduce(callback, ...initial) {
  return reduceItems($Receiver(this, "Array", "Array.prototype.reduce"), callback, initial, "Array.reduce", false)
}
function Uint8Array$prototype$reduce(callback, ...initial) {
  return reduceItems($Receiver(this, "Uint8Array", "Uint8Array.prototype.reduce"), callback, initial, "Uint8Array.reduce", false)
}
function Array$prototype$reduceRight(callback, ...initial) {
  return reduceItems($Receiver(this, "Array", "Array.prototype.reduceRight"), callback, initial, "Array.reduceRight", true)
}
function Uint8Array$prototype$reduceRight(callback, ...initial) {
  return reduceItems($Receiver(this, "Uint8Array", "Uint8Array.prototype.reduceRight"), callback, initial, "Uint8Array.reduceRight", true)
}
function reduceItems(array, callback, initial, label, right) {
  $Callback(callback, label)
  const length = array.length
  const step = right ? -1 : 1
  let index = right ? length - 1 : 0
  let accumulator
  if (initial.length > 0) accumulator = initial[0]
  else {
    while (index >= 0 && index < length && !(index in array)) index += step
    if (index < 0 || index >= length) $Throw("TypeError", label + " of an empty array with no initial value.")
    accumulator = array[index]
    index += step
  }
  while (index >= 0 && index < length) {
    if (index in array) accumulator = $Call(callback, undefined, accumulator, array[index], index, array)
    index += step
  }
  return accumulator
}

// forEach semantics: a returned array's holes are skipped, as flattening does.
function Array$prototype$flatMap(callback, thisArg = undefined) {
  const array = $Receiver(this, "Array", "Array.prototype.flatMap")
  $Callback(callback, "Array.flatMap")
  const length = array.length
  const result = []
  let count = 0
  let index = 0
  let inner
  let at
  while (index < length) {
    if (index in array) {
      inner = $Call(callback, thisArg, array[index], index, array)
      if ($IsArray(inner)) {
        at = 0
        while (at < inner.length) {
          if (at in inner) result[count++] = inner[at]
          at++
        }
      } else result[count++] = inner
    }
    index++
  }
  return result
}

// A sort with a comparator (see sortArray): a stable top-down merge sort that compares in the same order as the
// recursive one, running the merges (low, middle, high) the native planned in post-order over one working copy.
// Holes and undefined values sort last without being compared.
function sortWith(target, into, holes, comparator, work, undefs, merges) {
  const merged = []
  let merge = 0
  let middle
  let high
  let left
  let right
  let count
  let order
  while (merge < merges.length) {
    left = merges[merge]
    middle = merges[merge + 1]
    high = merges[merge + 2]
    right = middle
    count = 0
    while (left < middle && right < high) {
      order = +$Call(comparator, undefined, work[left], work[right])
      // A NaN result counts as equal, which keeps the order stable.
      if (order <= 0 || order !== order) {
        $ArraySet(merged, count, work[left])
        left++
      } else {
        $ArraySet(merged, count, work[right])
        right++
      }
      count++
    }
    $MergeRest(work, merged, count, left, middle, right, high, merges[merge])
    merge += 3
  }
  return $Sorted(target, into, holes, work, undefs)
}

// The default sort over more values than one native sort may take at once: native steps of bounded size (see
// $SortStep), so the run can pause between them like any loop.
function sortDefault(target, into, holes, values, undefs) {
  const state = $SortState(values)
  while ($SortStep(state)) {}
  return $Sorted(target, into, holes, $SortResult(state, values), undefs)
}

function Array$prototype$toLocaleString() {
  const array = $Receiver(this, "Array", "Array.prototype.toLocaleString")
  let result = ""
  let index = 0
  let item
  while (index < array.length) {
    if (index > 0) result += ","
    item = array[index]
    if (item !== null && item !== undefined) result += String(item.toLocaleString())
    index++
  }
  return result
}
// new Map, Set, WeakMap, and WeakSet from an iterable.
function fillCollection(target, items, kind) {
  const pairs = kind === "Map" || kind === "WeakMap"
  for (const item of items) {
    if (!pairs) $Table("add", target, item)
    else if (!$IsObject(item)) $Throw("TypeError", "new " + kind + "(...) expects [key, value] pairs as entry objects.")
    else $Table("add", target, item[0], item[1])
  }
  return target
}

function Map$groupBy(items, callback) {
  return groupBy(items, callback, "Map")
}
function Object$groupBy(items, callback) {
  return groupBy(items, callback, "Object")
}
// Object.groupBy's groups have a null prototype, so group names never collide with inherited methods.
function groupBy(items, callback, kind) {
  if (items === null || items === undefined) $Throw("TypeError", kind + ".groupBy expects an iterable collection.")
  $Callback(callback, kind + ".groupBy")
  const groups = $Table("groups", kind)
  let index = 0
  let key
  for (const item of items) {
    key = callback(item, index++)
    if (kind === "Object") key = String($Table("groupKey", key))
    $Table("group", groups, key, item)
  }
  return groups
}

// getOrInsertComputed when the key is missing: the callback's result wins over anything it inserted itself.
function insertComputed(target, key, callback) {
  const value = callback(key)
  $Table("add", target, key, value)
  return value
}

function Map$prototype$forEach(callback, thisArg = undefined) {
  collectionForEach($Receiver(this, "Map", "Map.prototype.forEach"), callback, thisArg, "Map.forEach")
}
function Set$prototype$forEach(callback, thisArg = undefined) {
  collectionForEach($Receiver(this, "Set", "Set.prototype.forEach"), callback, thisArg, "Set.forEach")
}
// Visits entries live, as in JS.
function collectionForEach(target, callback, thisArg, label) {
  $Callback(callback, label)
  for (const entry of $Table("entries", target)) $Call(callback, thisArg, entry[1], entry[0], target)
}

function Set$prototype$union(other) {
  return setMethod($Receiver(this, "Set", "Set.prototype.union"), other, "union")
}
function Set$prototype$intersection(other) {
  return setMethod($Receiver(this, "Set", "Set.prototype.intersection"), other, "intersection")
}
function Set$prototype$difference(other) {
  return setMethod($Receiver(this, "Set", "Set.prototype.difference"), other, "difference")
}
function Set$prototype$symmetricDifference(other) {
  return setMethod($Receiver(this, "Set", "Set.prototype.symmetricDifference"), other, "symmetricDifference")
}
function Set$prototype$isSubsetOf(other) {
  return setMethod($Receiver(this, "Set", "Set.prototype.isSubsetOf"), other, "isSubsetOf")
}
function Set$prototype$isSupersetOf(other) {
  return setMethod($Receiver(this, "Set", "Set.prototype.isSupersetOf"), other, "isSupersetOf")
}
function Set$prototype$isDisjointFrom(other) {
  return setMethod($Receiver(this, "Set", "Set.prototype.isDisjointFrom"), other, "isDisjointFrom")
}
// A Set method over the other set's size, has, and keys (GetSetRecord): it either asks the other set whether it has
// each of this set's values, or takes all of the other set's values, whichever is smaller.
function setMethod(target, other, name) {
  if (!$IsObject(other)) $Throw("TypeError", "Set." + name + " expects a Set-like object.")
  const size = +other.size
  if (size !== size) $Throw("TypeError", "Set." + name + " received a Set-like object with an invalid size.")
  if (size < 0) $Throw("RangeError", "Set." + name + " received a Set-like object with a negative size.")
  const has = other.has
  const keys = other.keys
  if (!$IsCallable(has) || !$IsCallable(keys)) $Throw("TypeError", "Set." + name + " expects callable 'has' and 'keys' methods.")
  const own = $Table("size", target)
  if (name === "isSubsetOf" && own > size) return false
  if (name === "isSupersetOf" && own < size) return false
  const result = name === "intersection" ? new Set() : name === "union" || name === "difference" || name === "symmetricDifference" ? $Table("copy", target) : undefined
  const asks = name === "isSubsetOf" || ((name === "intersection" || name === "difference" || name === "isDisjointFrom") && own <= size)
  let found
  if (asks) {
    for (const item of $Table("values", name === "difference" ? result : target)) {
      found = !!$Call(has, other, item)
      if (name === "intersection") {
        if (found) $Table("add", result, item)
      } else if (name === "difference") {
        if (found) $Table("delete", result, item)
      } else if (found === (name === "isDisjointFrom")) return false
    }
    return result === undefined ? true : result
  }
  const iterator = $Call(keys, other)
  if (!$IsObject(iterator)) $Throw("TypeError", "Set." + name + " expects 'keys' to return an iterator object.")
  for (const item of $Direct(iterator, true)) {
    found = $Table("has", target, item)
    if (name === "union") $Table("add", result, item)
    else if (name === "intersection") {
      if (found) $Table("add", result, item)
    } else if (name === "difference") $Table("delete", result, item)
    else if (name === "symmetricDifference") $Table(found ? "delete" : "add", result, item)
    else if (found === (name === "isDisjointFrom")) return false
  }
  return result === undefined ? true : result
}
function Object$fromEntries(entries) {
  const result = {}
  for (const entry of entries) {
    if (!$IsObject(entry, true)) $Throw("TypeError", "Object.fromEntries expects [key, value] entry objects.")
    $Define(result, String(entry[0]), entry[1], true)
  }
  return result
}

function Math$sumPrecise(items) {
  const numbers = []
  for (const item of items) {
    if (typeof item !== "number") $Throw("TypeError", "Math.sumPrecise expects an iterable of numbers.")
    $ArraySet(numbers, numbers.length, item)
  }
  return $SumPrecise(numbers)
}

// new AggregateError: the error is made (message and cause) before its errors are read.
function aggregateError(error, errors) {
  const list = []
  for (const item of errors) $ArraySet(list, list.length, item)
  return $Define(error, "errors", list, false)
}

// A Uint8Array's bytes from an iterable: a new one with prototype into, or set into the Uint8Array into at
// offset. As in TypedArray.from, a mapper sees the original values, after the source is consumed in full.
function collectBytes(source, name, mapper, thisArg, into, offset) {
  if (!$IsIterable(source)) $Throw("TypeError", name + " expects a Uint8Array, an array, or an iterable of numbers, received " + $Describe(source) + ".")
  const values = []
  for (const item of source) $ArraySet(values, values.length, item)
  let index = 0
  if (mapper !== undefined) {
    while (index < values.length) {
      values[index] = $Call(mapper, thisArg, values[index], index)
      index++
    }
  }
  return $Bytes(values, into, offset)
}

// An arguments object's [Symbol.iterator], as Array.prototype.values reads it: the length and each index, live.
function* argumentsValues() {
  let index = 0
  while (index < this.length) {
    yield this[index]
    index++
  }
}

// Object.entries and Object.values over an object with program getters: each key's enumerability is checked as it is
// visited, so a getter that deletes or hides a later key is seen.
function objectEntries(source, values) {
  const keys = $OwnKeys(source, true, undefined)
  const result = []
  let index = 0
  while (index < keys.length) {
    const key = keys[index]
    if ($IsEnumerableOwn(source, key)) $ArraySet(result, result.length, values ? source[key] : [key, source[key]])
    index++
  }
  return result
}

// Object.assign when a source has program getters or the target's chain has program setters: Get from each source,
// then Set on the target, key by key.
function objectAssign(target, sources) {
  let at = 0
  while (at < sources.length) {
    const source = sources[at]
    const keys = $OwnKeys(source, false, undefined)
    let index = 0
    while (index < keys.length) {
      const key = keys[index]
      if ($IsEnumerableOwn(source, key)) target[key] = source[key]
      index++
    }
    at++
  }
  return target
}

// Headers and URLSearchParams from iterable [name, value] pairs, read in full as strings before any is checked; from a
// record of names to values when init is not iterable.
function readPairs(init, label, kind, proto) {
  if (!$IsIterable(init)) return $Pairs(kind, proto, init, label)
  const pairs = []
  let strings
  for (const pair of init) {
    if (!$IsIterable(pair)) $Throw("TypeError", label + " expects iterable [name, value] pairs.")
    strings = []
    for (const item of pair) $ArraySet(strings, strings.length, String(item))
    $ArraySet(pairs, pairs.length, strings)
  }
  return $Pairs(kind, proto, pairs, label)
}

// Headers and URLSearchParams forEach: the callback sees each pair as listed when it started.
function pairsForEach(target, pairs, callback, thisArg) {
  let index = 0
  while (index < pairs.length) {
    $Call(callback, thisArg, pairs[index][1], pairs[index][0], target)
    index++
  }
}
// Iterator helpers are prelude generators, made with %IteratorHelper% as their prototype. Each is primed to its first
// yield, so a return() before the first next() still closes the source, from its finally.
function Iterator$from(value) {
  if ($IsObject(value) && $Inherits(value, Iterator.prototype)) return value
  return prime(wrapHelper(value, flattenable(value, true, "Iterator.from")))
}
function* wrapHelper(source, iterator) {
  let started = false
  try {
    yield
    started = true
    for (const item of iterator) yield item
  } finally {
    if (!started) closeIterator(source)
  }
}

function Iterator$prototype$map(mapper) {
  const iterator = $Direct(this, false)
  $Callback(mapper, "Iterator.prototype.map")
  return prime(mapHelper(this, iterator, mapper))
}
function* mapHelper(source, iterator, mapper) {
  let started = false
  try {
    yield
    started = true
    let counter = 0
    for (const item of iterator) yield mapper(item, counter++)
  } finally {
    if (!started) closeIterator(source)
  }
}

function Iterator$prototype$filter(predicate) {
  const iterator = $Direct(this, false)
  $Callback(predicate, "Iterator.prototype.filter")
  return prime(filterHelper(this, iterator, predicate))
}
function* filterHelper(source, iterator, predicate) {
  let started = false
  try {
    yield
    started = true
    let counter = 0
    for (const item of iterator) if (predicate(item, counter++)) yield item
  } finally {
    if (!started) closeIterator(source)
  }
}

function Iterator$prototype$take(limit) {
  const iterator = $Direct(this, false)
  return prime(takeHelper(this, iterator, count(limit, "take")))
}
function* takeHelper(source, iterator, remaining) {
  let started = false
  try {
    yield
    started = true
    if (remaining === 0) return closeIterator(source)
    for (const item of iterator) {
      remaining--
      yield item
      if (remaining === 0) break
    }
  } finally {
    if (!started) closeIterator(source)
  }
}

function Iterator$prototype$drop(limit) {
  const iterator = $Direct(this, false)
  return prime(dropHelper(this, iterator, count(limit, "drop")))
}
function* dropHelper(source, iterator, remaining) {
  let started = false
  try {
    yield
    started = true
    for (const item of iterator) {
      if (remaining > 0) remaining--
      else yield item
    }
  } finally {
    if (!started) closeIterator(source)
  }
}

function Iterator$prototype$flatMap(mapper) {
  const iterator = $Direct(this, false)
  $Callback(mapper, "Iterator.prototype.flatMap")
  return prime(flatMapHelper(this, iterator, mapper))
}
function* flatMapHelper(source, iterator, mapper) {
  let started = false
  try {
    yield
    started = true
    let counter = 0
    for (const item of iterator) {
      for (const inner of flattenable(mapper(item, counter++), false, "Iterator.prototype.flatMap")) yield inner
    }
  } finally {
    if (!started) closeIterator(source)
  }
}

function prime(helper) {
  helper.next()
  return helper
}

// A take or drop count: a number that is not NaN or negative.
function count(limit, name) {
  const number = +limit
  const integer = number === Infinity || number === -Infinity ? number : number - (number % 1)
  if (number !== number || integer < 0) $Throw("RangeError", "Iterator.prototype." + name + " expects a non-negative count, received " + number + ".")
  return integer
}

// GetIteratorFlattenable: an iterable by its [Symbol.iterator], otherwise the object itself as an iterator.
function flattenable(value, strings, name) {
  if (typeof value === "string" ? !strings : !$IsObject(value)) $Throw("TypeError", name + " expects an iterable or iterator, received " + $Describe(value) + ".")
  const method = value[Symbol.iterator]
  return $Direct(method === undefined || method === null ? value : $Call(method, value), false)
}

function closeIterator(iterator) {
  const method = iterator.return
  if (method !== undefined && method !== null && !$IsObject($Call(method, iterator))) $Throw("TypeError", "Iterator return() must return an object.")
}

function Iterator$prototype$toArray() {
  const result = []
  for (const item of $Direct(this, false)) $ArraySet(result, result.length, item)
  return result
}

function Iterator$prototype$reduce(callback, ...initial) {
  const iterator = $Direct(this, false)
  $Callback(callback, "Iterator.prototype.reduce")
  let accumulator = initial[0]
  let started = initial.length > 0
  let index = 0
  for (const item of iterator) {
    if (started) accumulator = callback(accumulator, item, index)
    else accumulator = item
    started = true
    index++
  }
  if (!started) $Throw("TypeError", "Iterator.prototype.reduce of an empty iterator with no initial value.")
  return accumulator
}

function Iterator$prototype$forEach(callback) {
  iteratorTest(this, callback, "forEach")
}
function Iterator$prototype$some(callback) {
  return iteratorTest(this, callback, "some")
}
function Iterator$prototype$every(callback) {
  return iteratorTest(this, callback, "every")
}
function Iterator$prototype$find(callback) {
  return iteratorTest(this, callback, "find")
}
// Calls the callback with each value and its index until its result decides; leaving early closes the iterator.
function iteratorTest(self, callback, name) {
  const iterator = $Direct(self, false)
  $Callback(callback, "Iterator.prototype." + name)
  let index = 0
  let result
  for (const item of iterator) {
    result = callback(item, index++)
    if (name === "some" && result) return true
    if (name === "every" && !result) return false
    if (name === "find" && result) return item
  }
  return name === "every" ? true : name === "some" ? false : undefined
}

// JSON.parse's reviver: children are revived first, each replacing (or, when the reviver gives undefined, removing)
// its property; then the reviver sees the value itself.
function revive(holder, key, reviver) {
  const value = holder[key]
  if ($IsObject(value)) {
    const names = $Keys(value)
    let index = 0
    let revived
    while (index < names.length) {
      revived = revive(value, names[index], reviver)
      if (revived === undefined) delete value[names[index]]
      else value[names[index]] = revived
      index++
    }
  }
  return $Call(reviver, holder, key, value)
}

// String replace with a callback, once the matches are found: each is the text before it and the callback's
// arguments; the text after the last one follows.
function replaceWith(matches, rest, callback) {
  let result = ""
  let index = 0
  while (index < matches.length) {
    result += matches[index][0] + String(callback(...matches[index][1]))
    index++
  }
  return result + rest
}
"""#

    // parity: psychoscript/src/prelude/bytecode.ts#SavedCodes [status=implemented hash=35954d4a7ac3]
    public struct SavedCodes: Equatable, Sendable, Codable {
        public let version: Int
        public let sourceHash: String
        public let codes: [CodeJson]

        public init(version: Int, sourceHash: String, codes: [CodeJson]) {
            self.version = version
            self.sourceHash = sourceHash
            self.codes = codes
        }
    }

    // parity: psychoscript/src/prelude/bytecode.ts#saveCodes [status=implemented hash=795e32c362b7]
    public static func saveCodes(_ codes: [Code], sourceCode: String) -> SavedCodes {
        SavedCodes(
            version: COMPILER_VERSION,
            sourceHash: snapshotHash(sourceCode),
            codes: codes.map(codeToJson)
        )
    }

    // parity: psychoscript/src/prelude/bytecode.ts#builtinCodes [status=implemented hash=c52504770860]
    public static func builtinCodes(id: String, sourceCode: String) -> [Code] {
        let parsed = parseProgram(sourceCode)
        switch parsed {
        case .ok(let program, _):
            return compileSource(Source(id: id, code: sourceCode, program: program), options: CompileOptions(isInternal: true))
        case .error:
            return []
        }
    }

    /// The privileged `$` helpers the prelude calls, by name, each with the native that does its work (the stdlib's
    /// Swift implementation of the same step).
    // parity: psychoscript/src/prelude/helpers.ts#helpers [status=adapted hash=fdc7b249c0f2]
    public static func helpers() -> [String: String] {
        let names = [
            "$Throw", "$Callback", "$Call", "$Receiver", "$IsObject", "$IsIterable", "$Describe", "$Inherits", "$Keys",
            "$OwnKeys", "$IsEnumerableOwn", "$Define", "$ArraySet", "$SumPrecise", "$Bytes", "$DerivedBytes", "$Pairs",
            "$IsCallable", "$Direct", "$Sorted", "$MergeRest", "$SortState", "$SortStep", "$SortResult", "$Table",
        ]
        var map: [String: String] = [
            "toPrimitive": "internal:toPrimitive",
            "aggregateError": "internal:aggregateError",
        ]
        for name in names { map[name] = "internal:\(name)" }
        return map
    }

    // parity: psychoscript/src/prelude/prelude.ts#compiledPrelude [status=implemented hash=67de943408d8]
    public static func compiledPrelude() -> [Code] {
        compiledPreludeCodes
    }

    /// Parsed and compiled once per process.
    private static let compiledPreludeCodes: [Code] = builtinCodes(id: "<prelude>", sourceCode: preludeSourceCode)

    // parity: psychoscript/src/prelude/prelude.ts#Prelude [status=implemented hash=f03d030aedd9]
    public final class Prelude: Sendable {
        public let codes: [Code]
        private let functions: [String: Callable]

        public init(codes: [Code] = compiledPrelude(), functions: [String: Callable] = [:]) {
            self.codes = codes
            self.functions = functions
        }

        // parity: psychoscript/src/prelude/prelude.ts#Prelude.fn [status=implemented hash=3b62689aafb9]
        public func fn(_ name: String) -> Callable? {
            functions[name]
        }
    }

}
