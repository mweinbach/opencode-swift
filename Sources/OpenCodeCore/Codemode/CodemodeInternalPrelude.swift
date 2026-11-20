import OpenCodeSchema

/// The VM's internal prelude (psychoscript `prelude/internal.ts`, formerly `internal-prelude.ts`): the internal helpers'
/// source and the `$` intrinsics internal code may call.
extension CodemodeLanguage {
    /// Lightweight internal callable for VM-only `$` intrinsics: not an `Obj` or `Native`, so it never touches
    /// `builtins.Function` or static intrinsic numbering.
    // parity: psychoscript/src/prelude/internal.ts#VmIntrinsic [status=implemented hash=dc73ea7afa48]
    public final class VmIntrinsic: Sendable {
        public let name: String
        public let invoke: @Sendable ([Value]) throws -> Value

        public init(name: String, invoke: @escaping @Sendable ([Value]) throws -> Value) {
            self.name = name
            self.invoke = invoke
        }
    }

    /// The internal helpers' source, as upstream ships it. The evaluator runs the same steps natively where the VM
    /// pushes these helpers (setters and getters met by ops, thenable `then` getters, host calls whose arguments hold
    /// getters, and so on); the source is compiled for its code table, so each helper's code can be found by name.
    // parity: psychoscript/src/prelude/internal.ts#INTERNAL_SOURCE [status=adapted hash=edc105ee2ecf]
    public static let INTERNAL_SOURCE: String = #"""
function $vmToPrimitive(v, hint) {
  if (!$IsDataObj(v)) return v
  const first = hint === "string" || (hint === "default" && $IsDate(v)) ? "toString" : "valueOf"
  const second = first === "toString" ? "valueOf" : "toString"
  const m1 = v[first]
  if ($IsCallableAny(m1)) {
    const r1 = $Call(m1, v)
    if (!$IsObj(r1)) return r1
  }
  const m2 = v[second]
  if ($IsCallableAny(m2)) {
    const r2 = $Call(m2, v)
    if (!$IsObj(r2)) return r2
  }
  $Throw("TypeError", "Cannot convert object to primitive value.")
}

function $vmToKey(v) {
  return $PropKey($vmToPrimitive(v, "string"))
}

function $vmToString(v) {
  return $CoerceToString($vmToPrimitive(v, "string"))
}

function $vmToNumeric(incFlag, v) {
  return $ApplyToNumeric(incFlag, $vmToPrimitive(v, "number"))
}

function $vmInc(incFlag, v) {
  const n = $ApplyToNumeric(incFlag, $vmToPrimitive(v, "number"))
  return incFlag === 0 ? n + 1 : n - 1
}

function $vmUnary(sub, v) {
  return $ApplyUnary(sub, $vmToPrimitive(v, "number"))
}

function $vmBinary(op, lhs, rhs) {
  const kind = $OpConvKind(op, lhs, rhs)
  if (kind === 0) return $ApplyBinary(op, lhs, rhs)
  if (kind === 1) {
    const key = $vmToPrimitive(lhs, "string")
    return $ApplyBinary(op, key, rhs)
  }
  const hint = kind === 2 ? "default" : "number"
  const l = $vmToPrimitive(lhs, hint)
  const r = $vmToPrimitive(rhs, hint)
  return $ApplyBinary(op, l, r)
}

// A write that reached a program setter: the assignment's value is what was assigned, not what the setter returns.
function $vmSet(setter, receiver, value) {
  $Call(setter, receiver, value)
  return value
}

function $vmInstanceof(lhs, rhs) {
  return $HasInstance(lhs, rhs.prototype)
}

// A getter an iterator op met; the op runs again with its value (see Mode.REDO).
function $vmRedo(getter, receiver) {
  return $Call(getter, receiver)
}

// A promise resolved with an object whose then is a program getter: the getter runs in this job.
function $vmThenableGet(thenable, resolve, reject) {
  const then = thenable.then
  if ($IsFunction(then)) $Call(then, thenable, resolve, reject)
  else $FulfillWith(thenable)
}

// Spread and rest from a source with program getters: each getter runs once, in key order, and the copy is data.
function $vmCopyDataProps(target, source, excluded) {
  const keys = $OwnKeys(source, false, excluded)
  let index = 0
  while (index < keys.length) {
    const key = keys[index]
    if ($IsEnumerableOwn(source, key)) $Define(target, key, source[key], true)
    index++
  }
  return target
}

function $vmGetElem(o, k) {
  return o[$vmToKey(k)]
}

function $vmDeleteElem(o, k) {
  return delete o[$vmToKey(k)]
}

// A built-in that asked for conversions (a Convert) or program getters (a Prefetch) before it can go on: runs them in
// program code, then the built-in again with what they gave (replay by ordinal, read as receiver, key, value), until
// it asks for nothing more. With no request, it runs again straight away.
function $vmReplay(callable, target, args, constructing, replay, read, req) {
  while (true) {
    if ($IsPrefetch(req)) {
      const pairs = $PrefetchReads(req)
      let at = 0
      while (at < pairs.length) {
        const receiver = pairs[at]
        const key = pairs[at + 1]
        $ArraySet(read, read.length, receiver)
        $ArraySet(read, read.length, key)
        $ArraySet(read, read.length, receiver[key])
        at += 2
      }
    } else if (req !== undefined) {
      const values = $ConvValues(req)
      const coerce = $ConvFlag(req, 0)
      const ordinal = $ConvFlag(req, 1)
      const len = values.length
      const converted = []
      let i = 0
      while (i < len) {
        const val = values[i]
        const hint = $ConvHint(req, i)
        const prim = $IsObj(val) ? $vmToPrimitive(val, hint) : val
        $ArraySet(converted, i, coerce ? $ConvCoerce(hint, prim) : prim)
        i++
      }
      $ArraySet(replay, ordinal, converted)
    }
    const res = $Replay(callable, target, args, constructing, replay, read)
    if (!$IsConvert(res) && !$IsPrefetch(res)) return res
    req = res
  }
}

// A JSON walk's step for one value, holder[key]: its JSON as program data, or undefined when it is left out. A promise
// is yielded at the host boundary, which resumes the walk with its value.
function $vmJsonVisitor(boundary, replacer, properties) {
  const ancestors = []
  function* visit(holder, key, depth) {
    if (depth > 100) $Throw("RangeError", "Value exceeds the maximum depth of 100.")
    let val = holder[key]
    if ($IsPromise(val)) {
      if (!boundary) {
        $Throw("InvalidData", "JSON.stringify received an un-awaited Promise; await it first - e.g. \x60const result = await load(...)\x60.")
      }
      val = yield val
    }
    if ($IsObj(val)) {
      const toJSON = val.toJSON
      if ($IsCallableAny(toJSON)) val = $Call(toJSON, val, key)
    }
    if (replacer !== undefined) val = $Call(replacer, holder, key, val)
    const kind = $JsonClassify(val, boundary, ancestors)
    if (kind === 0) return undefined
    if (kind === 1) return val
    if (kind === 2) return null
    if (kind === 3) return $JsonSpecial(val, boundary)
    const target = kind === 4 ? $SetToArray(val) : val
    $ArraySet(ancestors, ancestors.length, target)
    let out
    if ($IsArray(target)) {
      out = []
      const len = target.length
      let i = 0
      while (i < len) {
        const elem = yield* visit(target, String(i), depth + 1)
        $ArraySet(out, i, elem === undefined ? null : elem)
        i++
      }
    } else {
      out = $NewNullProtoObj()
      const names = $JsonNames(target, boundary, properties)
      let i = 0
      while (i < names.length) {
        const k = names[i]
        const propVal = yield* visit(target, k, depth + 1)
        if (propVal !== undefined) $Define(out, k, propVal, true)
        i++
      }
    }
    $ArrayPop(ancestors)
    return out
  }
  return visit
}

function $vmJsonWalk(replacer, value, properties, indent) {
  const json = $vmJsonVisitor(false, replacer, properties)({ "": value }, "", 0).next().value
  return $JsonFinish(false, json, properties, indent)
}

function $vmSettleCall(callable, thisVal, args) {
  return $Apply(callable, thisVal, args)
}

function $vmCombine(name, items) {
  const c = $CombineStart(name, items)
  for (const item of items) {
    $CombineAdd(c, item)
  }
  $CombineEnd(c)
}

function $vmOpenSyncForAsync(v, method) {
  const it = $AfsRequireObj($Call(method, v))
  return $WrapAsyncFromSync(it, it.next)
}

function $vmAsyncFromSync(adapter, kind, hasArg, val) {
  const iter = $AfsGetIter(adapter)
  const method = kind === "next" ? $AfsGetNext(adapter) : $AfsMethod(adapter, iter[kind], kind)
  if (method === undefined || method === null) {
    if (kind === "return") {
      $AfsResolveDone(val)
      return
    }
    const ret = $AfsMethod(adapter, iter.return, "return")
    if (ret !== undefined && ret !== null) {
      $AfsCheckObj(adapter, $Call(ret, iter), "return")
    }
    $AfsRejectNoThrow(adapter)
    return
  }
  const res = hasArg ? $Call(method, iter, val) : $Call(method, iter)
  $AfsCheckObj(adapter, res, kind)
  const done = !!res.done
  const value = res.value
  $AfsSettle(adapter, value, done, kind !== "return")
}

function $vmAsyncFromSyncClose(iter) {
  const ret = iter.return
  if (ret !== undefined && ret !== null) $Call(ret, iter)
}

// A host call whose arguments hold promises that haven't fulfilled: waits for each, then calls again with the getter
// values read so far (read, as $vmReplay keeps them), so no getter runs twice; getters inside the values are read then.
async function $vmHostWait(promises, callee, args, read) {
  let i = 0
  while (i < promises.length) {
    await promises[i]
    i++
  }
  return $vmReplay(callee, undefined, args, false, [], read, undefined)
}

async function $vmResult(value) {
  const root = $IsThenable(value) ? await value : value
  const walk = $vmJsonVisitor(true, undefined, null)({ "": root }, "", 0)
  let step = walk.next()
  while (!step.done) step = walk.next(await step.value)
  return $JsonFinish(true, step.value, null, undefined)
}
"""#

    private static let compiledInternal: [Code] = builtinCodes(id: "@vm-internal", sourceCode: INTERNAL_SOURCE)

    /// The VM's internal helpers' code.
    // parity: psychoscript/src/prelude/internal.ts#getInternalPrelude [status=implemented hash=305e479371fd]
    public static func getInternalPrelude() -> [Code] {
        compiledInternal
    }

    /// The code of the internal helper `name`.
    // parity: psychoscript/src/prelude/internal.ts#internalCode [status=implemented hash=192f49efa4ad]
    public static func internalCode(_ name: String) -> Code? {
        getInternalPrelude().first { $0.name == name }
    }

    private static func arg(_ args: [Value], _ index: Int) -> Value {
        index < args.count ? args[index] : .undefined
    }

    /// Adds the intrinsics available to internal functions to `registry`: the `$` natives the internal helpers call.
    // parity: psychoscript/src/prelude/internal.ts#registerVmIntrinsics [status=adapted hash=fdd6a6b13941]
    public static func registerVmIntrinsics(_ registry: inout [String: VmIntrinsic], builtins: Builtins? = nil) {
        func add(_ name: String, _ invoke: @escaping @Sendable ([Value]) throws -> Value) {
            registry[name] = VmIntrinsic(name: name, invoke: invoke)
        }
        add("isArray") { args in
            if case .object(let obj) = arg(args, 0) { return .bool(obj is Arr) }
            return .bool(false)
        }
        add("typeof") { args in .string(JSString(typeofValue(arg(args, 0)))) }
        add("$IsObj") { args in
            if case .object = arg(args, 0) { return .bool(true) }
            return .bool(false)
        }
        add("$IsDataObj") { args in
            let value = arg(args, 0)
            if case .object = value { return .bool(!isOpaque(value)) }
            return .bool(false)
        }
        add("$IsDate") { args in
            if case .object(let obj) = arg(args, 0) { return .bool(obj is DateObj) }
            return .bool(false)
        }
        add("$IsPromise") { args in
            if case .object(let obj) = arg(args, 0) { return .bool(obj is PromiseObj) }
            return .bool(false)
        }
        add("$IsArray") { args in
            if case .object(let obj) = arg(args, 0) { return .bool(obj is Arr) }
            return .bool(false)
        }
        add("$IsCallableAny") { args in
            if case .object(let obj) = arg(args, 0) { return .bool(obj is Callable) }
            if case .hostNamespace = arg(args, 0) { return .bool(true) }
            return .bool(false)
        }
        add("$IsFunction") { args in .bool(typeofValue(arg(args, 0)) == "function") }
        add("$PropKey") { args in keyValue(propertyKey(arg(args, 0))) }
        add("$HasInstance") { args in .bool(try hasInstance(arg(args, 0), arg(args, 1), node: nil)) }
        add("$CoerceToString") { args in .string(coerceToString(arg(args, 0))) }
        add("$IsPrefetch") { _ in .bool(false) }
        add("$SetToArray") { args in
            guard case .object(let set as SetObj) = arg(args, 0) else { return .undefined }
            return .object(Arr(proto: builtins?.Array, items: set.table.liveKeys()))
        }
        add("$NewNullProtoObj") { _ in .object(Obj(proto: nil)) }
        add("$ArrayPop") { args in
            guard case .object(let arr as Arr) = arg(args, 0) else { return .undefined }
            var items = arr.items
            let last = items.popLast() ?? .undefined
            arr.items = items
            return last
        }
        // Writes an element of a prelude-made array without going through the prototype chain.
        add("$ArraySet") { args in
            guard case .object(let arr as Arr) = arg(args, 0) else { return .undefined }
            let value = arg(args, 2)
            try arr.setItem(at: Int(coerceToNumber(arg(args, 1))), value: value)
            return value
        }
    }

    // parity: psychoscript/src/prelude/internal.ts#tryFastBoundaryOrJson [status=implemented hash=d2fa72dbac15]
    public static func tryFastBoundaryOrJson(_ value: Value) -> JSONValue? {
        switch value {
        case .null: return .null
        case .bool(let b): return .bool(b)
        case .string(let s): return .string(s.toHostString())
        case .number(let n):
            guard n.isFinite else { return .null }
            if n == Double(Int64(n)) && n >= -9_007_199_254_740_991 && n <= 9_007_199_254_740_991 && !(n == 0 && n.sign == .minus) {
                return .int(Int64(n))
            }
            return .double(n)
        default:
            return nil
        }
    }
}
