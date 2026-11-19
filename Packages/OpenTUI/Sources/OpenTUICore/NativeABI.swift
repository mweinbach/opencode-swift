// Pure-Swift Native ABI constants, C-ABI struct layouts, Zig struct codecs, and portable FFI adapter.
// Ports core/src/native-abi.generated.ts (859 symbols), core/src/zig-structs.ts (34 symbols),
// and core/src/platform/ffi.ts (31 symbols).
// Zero OS / Foundation imports (Pure Tier).

import Synchronization

// MARK: - ABI Metadata Types

/// Field layout descriptor for a C-ABI struct in `NativeABI.nativeLayouts`.
public struct ABIFieldLayout: Equatable, Hashable, Sendable, Codable {
    public let offset: Int
    public let size: Int
    public let alignment: Int
    public let type: String

    public init(offset: Int, size: Int, alignment: Int, type: String) {
        self.offset = offset
        self.size = size
        self.alignment = alignment
        self.type = type
    }
}

/// Struct layout descriptor matching `opentui.h` C-ABI sizing and alignment.
public struct ABIStructLayout: Equatable, Hashable, Sendable, Codable {
    public let size: Int
    public let alignment: Int
    public let fields: [String: ABIFieldLayout]

    public init(size: Int, alignment: Int, fields: [String: ABIFieldLayout]) {
        self.size = size
        self.alignment = alignment
        self.fields = fields
    }
}

/// Signature descriptor for an exported C-ABI function or callback in `NativeABI`.
public struct ABISymbolSignature: Equatable, Hashable, Sendable, Codable {
    public let args: [String]
    public let returns: String

    public init(args: [String], returns: String) {
        self.args = args
        self.returns = returns
    }
}

// MARK: - NativeABI Constants, Symbols, Callbacks & Struct Layouts

/// Pure-Swift mirror of `core/src/native-abi.generated.ts` (generated from `opentui.h`).
public enum NativeABI {
    /// ABI audit SHA-256 recorded in upstream `native-abi.generated.ts`.
    public static let abiAuditSHA256: String = "18064486de0ef6f07485fe84137c19de73adf5cb04f907845033cc34b05a4981"

    // parity: core/src/native-abi.generated.ts#OT_CONTEXT_ABI_VERSION [status=implemented hash=1880aecc1494]
    public static let OT_CONTEXT_ABI_VERSION: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_OK [status=implemented hash=8fbd84215cd4]
    public static let OT_OK: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_INVALID_ARGUMENT [status=implemented hash=fe0f0934e71b]
    public static let OT_INVALID_ARGUMENT: Int64 = -1
    // parity: core/src/native-abi.generated.ts#OT_UNSUPPORTED_VERSION [status=implemented hash=8f8b8e14e47e]
    public static let OT_UNSUPPORTED_VERSION: Int64 = -2
    // parity: core/src/native-abi.generated.ts#OT_OUT_OF_MEMORY [status=implemented hash=0473f7cb0115]
    public static let OT_OUT_OF_MEMORY: Int64 = -3
    // parity: core/src/native-abi.generated.ts#OT_WRONG_THREAD [status=implemented hash=41d7e7bbd4ef]
    public static let OT_WRONG_THREAD: Int64 = -4
    // parity: core/src/native-abi.generated.ts#OT_INTERNAL_ERROR [status=implemented hash=552efc3eaf6f]
    public static let OT_INTERNAL_ERROR: Int64 = -5
    // parity: core/src/native-abi.generated.ts#OT_CONTEXT_BUSY [status=implemented hash=6eb18ab37b5a]
    public static let OT_CONTEXT_BUSY: Int64 = -6
    // parity: core/src/native-abi.generated.ts#OT_WRONG_CONTEXT [status=implemented hash=888d737c1cd0]
    public static let OT_WRONG_CONTEXT: Int64 = -7
    // parity: core/src/native-abi.generated.ts#OT_WRONG_KIND [status=implemented hash=75e3cb68d4cd]
    public static let OT_WRONG_KIND: Int64 = -8
    // parity: core/src/native-abi.generated.ts#OT_STALE_HANDLE [status=implemented hash=63af194815ff]
    public static let OT_STALE_HANDLE: Int64 = -9
    // parity: core/src/native-abi.generated.ts#OT_WRONG_SESSION [status=implemented hash=b21e7af77707]
    public static let OT_WRONG_SESSION: Int64 = -10
    // parity: core/src/native-abi.generated.ts#OT_OUTPUT_BACKPRESSURE [status=implemented hash=f8ff4c67efa5]
    public static let OT_OUTPUT_BACKPRESSURE: Int64 = -11
    // parity: core/src/native-abi.generated.ts#OT_SESSION_CLOSED [status=implemented hash=191d2c089a9e]
    public static let OT_SESSION_CLOSED: Int64 = -12
    // parity: core/src/native-abi.generated.ts#OT_OUTPUT_BUSY [status=implemented hash=f2856f71f24c]
    public static let OT_OUTPUT_BUSY: Int64 = -13
    // parity: core/src/native-abi.generated.ts#OT_STALE_OUTPUT [status=implemented hash=5b9a2096dff7]
    public static let OT_STALE_OUTPUT: Int64 = -14
    // parity: core/src/native-abi.generated.ts#OT_OUTPUT_FAILED [status=implemented hash=d37682299c89]
    public static let OT_OUTPUT_FAILED: Int64 = -15
    // parity: core/src/native-abi.generated.ts#OT_OBJECT_LIMIT [status=implemented hash=05df34ba6219]
    public static let OT_OBJECT_LIMIT: Int64 = -16
    // parity: core/src/native-abi.generated.ts#OT_RENDERER_ATTACHED [status=implemented hash=c2d1bc6e360f]
    public static let OT_RENDERER_ATTACHED: Int64 = -17
    // parity: core/src/native-abi.generated.ts#OT_RENDERER_NOT_ATTACHED [status=implemented hash=67a0cd5530b7]
    public static let OT_RENDERER_NOT_ATTACHED: Int64 = -18
    // parity: core/src/native-abi.generated.ts#OT_INVALID_PHASE [status=implemented hash=f277b11f7afd]
    public static let OT_INVALID_PHASE: Int64 = -19
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_PACKET_LIMIT [status=implemented hash=0b6536096b61]
    public static let OT_CONTROL_PACKET_LIMIT: Int64 = -20
    // parity: core/src/native-abi.generated.ts#OT_LEASE_LIMIT [status=implemented hash=4c9a0f986e82]
    public static let OT_LEASE_LIMIT: Int64 = -21
    // parity: core/src/native-abi.generated.ts#OT_LEASE_BYTES_LIMIT [status=implemented hash=56d4ce9690a7]
    public static let OT_LEASE_BYTES_LIMIT: Int64 = -22
    // parity: core/src/native-abi.generated.ts#OT_STALE_LEASE [status=implemented hash=b4d78d605639]
    public static let OT_STALE_LEASE: Int64 = -23
    // parity: core/src/native-abi.generated.ts#OT_UNSUPPORTED_RESOURCE [status=implemented hash=49b258fc4717]
    public static let OT_UNSUPPORTED_RESOURCE: Int64 = -24
    // parity: core/src/native-abi.generated.ts#OT_STALE_FRAME [status=implemented hash=7c8ffd3bfed1]
    public static let OT_STALE_FRAME: Int64 = -25
    // parity: core/src/native-abi.generated.ts#OT_LAYOUT_LIMIT [status=implemented hash=88d954f80cb2]
    public static let OT_LAYOUT_LIMIT: Int64 = -26
    // parity: core/src/native-abi.generated.ts#OT_FRAME_BUSY [status=implemented hash=705894862600]
    public static let OT_FRAME_BUSY: Int64 = -27
    // parity: core/src/native-abi.generated.ts#OT_FRAME_REQUEST_LIMIT [status=implemented hash=a2e9883b61af]
    public static let OT_FRAME_REQUEST_LIMIT: Int64 = -28
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_UNSUPPORTED_FORMAT [status=implemented hash=1332f7608c12]
    public static let OT_IMAGE_UNSUPPORTED_FORMAT: Int64 = -40
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_UNSUPPORTED_COLOR_SPACE [status=implemented hash=df8294ea4bb4]
    public static let OT_IMAGE_UNSUPPORTED_COLOR_SPACE: Int64 = -41
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_MALFORMED_DATA [status=implemented hash=3026cb7a4ad5]
    public static let OT_IMAGE_MALFORMED_DATA: Int64 = -42
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_DIMENSION_LIMIT [status=implemented hash=690462ef1f75]
    public static let OT_IMAGE_DIMENSION_LIMIT: Int64 = -43
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_MEMORY_LIMIT [status=implemented hash=21afe8f5e0a4]
    public static let OT_IMAGE_MEMORY_LIMIT: Int64 = -44
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_OUTPUT_TOO_SMALL [status=implemented hash=12d28f640513]
    public static let OT_IMAGE_OUTPUT_TOO_SMALL: Int64 = -45
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_UNSUPPORTED_FEATURE [status=implemented hash=ec646fa322de]
    public static let OT_IMAGE_UNSUPPORTED_FEATURE: Int64 = -46
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_BUSY [status=implemented hash=7526256d3ea8]
    public static let OT_IMAGE_BUSY: Int64 = -47
    // parity: core/src/native-abi.generated.ts#OT_VIDEO_FAILED [status=implemented hash=97d7b57dcd7b]
    public static let OT_VIDEO_FAILED: Int64 = -60
    // parity: core/src/native-abi.generated.ts#OT_AUDIO_DECODE_FAILED [status=implemented hash=81a8fd6c868f]
    public static let OT_AUDIO_DECODE_FAILED: Int64 = -61
    // parity: core/src/native-abi.generated.ts#OT_AUDIO_DEVICE_FAILED [status=implemented hash=a0e64c7c44db]
    public static let OT_AUDIO_DEVICE_FAILED: Int64 = -62
    // parity: core/src/native-abi.generated.ts#OT_SCENE_ROOT [status=implemented hash=4a9bde864c50]
    public static let OT_SCENE_ROOT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_BOX [status=implemented hash=917fdc4a2fc3]
    public static let OT_SCENE_BOX: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT [status=implemented hash=2d5670f969fe]
    public static let OT_SCENE_TEXT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SLIDER [status=implemented hash=784ae24b1a98]
    public static let OT_SCENE_SLIDER: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_SCENE_ARROW [status=implemented hash=12fc3080fbb8]
    public static let OT_SCENE_ARROW: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_EDITOR [status=implemented hash=39ccdf7ea4a4]
    public static let OT_SCENE_EDITOR: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_SCENE_CUSTOM [status=implemented hash=164fcbdbf813]
    public static let OT_SCENE_CUSTOM: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_VIEW [status=implemented hash=ae11c201939b]
    public static let OT_SCENE_TEXT_VIEW: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_SCENE_IMAGE [status=implemented hash=b1919fbf5277]
    public static let OT_SCENE_IMAGE: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_SCENE_VIDEO [status=implemented hash=e40352f248a1]
    public static let OT_SCENE_VIDEO: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_SCENE_WRAP_NONE [status=implemented hash=4b41cd6bf5d2]
    public static let OT_SCENE_WRAP_NONE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_WRAP_CHAR [status=implemented hash=683ffb3ae779]
    public static let OT_SCENE_WRAP_CHAR: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_WRAP_WORD [status=implemented hash=47aa72327393]
    public static let OT_SCENE_WRAP_WORD: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_ALIGN_LEFT [status=implemented hash=5b3506fc0a60]
    public static let OT_SCENE_ALIGN_LEFT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_ALIGN_CENTER [status=implemented hash=a5d63fb60011]
    public static let OT_SCENE_ALIGN_CENTER: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_ALIGN_RIGHT [status=implemented hash=a4cc95a599ff]
    public static let OT_SCENE_ALIGN_RIGHT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM [status=implemented hash=98b3de01dcc2]
    public static let OT_STYLE_ENUM: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_STYLE_FLOAT [status=implemented hash=04c2698871fa]
    public static let OT_STYLE_FLOAT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE [status=implemented hash=e26a6802eb29]
    public static let OT_STYLE_VALUE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_STYLE_BORDER [status=implemented hash=357ea7695b8c]
    public static let OT_STYLE_BORDER: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_STYLE_DIMENSION [status=implemented hash=d9af6f28aadc]
    public static let OT_STYLE_DIMENSION: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_STYLE_BORDER_WIDTH [status=implemented hash=cf0ffb373996]
    public static let OT_STYLE_BORDER_WIDTH: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_STYLE_FLAGS_NONE [status=implemented hash=558c542f54cf]
    public static let OT_STYLE_FLAGS_NONE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_STYLE_DISABLE_FLEX_SHRINK [status=implemented hash=2d8f8f7d2430]
    public static let OT_STYLE_DISABLE_FLEX_SHRINK: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_STYLE_CONTENT [status=implemented hash=a62b15e36b46]
    public static let OT_STYLE_CONTENT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_DIRECTION [status=implemented hash=6ce1d0d62120]
    public static let OT_STYLE_ENUM_DIRECTION: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_FLEX_DIRECTION [status=implemented hash=b9aa96a33127]
    public static let OT_STYLE_ENUM_FLEX_DIRECTION: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_JUSTIFY_CONTENT [status=implemented hash=216fb0e4fba4]
    public static let OT_STYLE_ENUM_JUSTIFY_CONTENT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_ALIGN_CONTENT [status=implemented hash=f8661b826a85]
    public static let OT_STYLE_ENUM_ALIGN_CONTENT: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_ALIGN_ITEMS [status=implemented hash=c7892b9ceb7d]
    public static let OT_STYLE_ENUM_ALIGN_ITEMS: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_ALIGN_SELF [status=implemented hash=a13d90486631]
    public static let OT_STYLE_ENUM_ALIGN_SELF: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_POSITION_TYPE [status=implemented hash=4e74387086a2]
    public static let OT_STYLE_ENUM_POSITION_TYPE: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_FLEX_WRAP [status=implemented hash=f95c1238e1c9]
    public static let OT_STYLE_ENUM_FLEX_WRAP: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_OVERFLOW [status=implemented hash=67f13c612f83]
    public static let OT_STYLE_ENUM_OVERFLOW: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_DISPLAY [status=implemented hash=91abfff4d3d5]
    public static let OT_STYLE_ENUM_DISPLAY: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_BOX_SIZING [status=implemented hash=fda828a6bc83]
    public static let OT_STYLE_ENUM_BOX_SIZING: Int64 = 10
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_LAYOUT_MODE [status=implemented hash=7b94dc57d555]
    public static let OT_STYLE_ENUM_LAYOUT_MODE: Int64 = 11
    // parity: core/src/native-abi.generated.ts#OT_STYLE_FLOAT_FLEX [status=implemented hash=9df04a13d071]
    public static let OT_STYLE_FLOAT_FLEX: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_STYLE_FLOAT_FLEX_GROW [status=implemented hash=6110b203f5dc]
    public static let OT_STYLE_FLOAT_FLEX_GROW: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_STYLE_FLOAT_FLEX_SHRINK [status=implemented hash=c2180ff9fc00]
    public static let OT_STYLE_FLOAT_FLEX_SHRINK: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_STYLE_FLOAT_ASPECT_RATIO [status=implemented hash=6e6253f0fee4]
    public static let OT_STYLE_FLOAT_ASPECT_RATIO: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_WIDTH [status=implemented hash=3ce144859566]
    public static let OT_STYLE_VALUE_WIDTH: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_HEIGHT [status=implemented hash=2046c6f6f86f]
    public static let OT_STYLE_VALUE_HEIGHT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_MIN_WIDTH [status=implemented hash=2be21766b6f6]
    public static let OT_STYLE_VALUE_MIN_WIDTH: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_MIN_HEIGHT [status=implemented hash=80bc940e4c8c]
    public static let OT_STYLE_VALUE_MIN_HEIGHT: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_MAX_WIDTH [status=implemented hash=7d57faae6671]
    public static let OT_STYLE_VALUE_MAX_WIDTH: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_MAX_HEIGHT [status=implemented hash=9edb20327280]
    public static let OT_STYLE_VALUE_MAX_HEIGHT: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_FLEX_BASIS [status=implemented hash=6c3ea3e39453]
    public static let OT_STYLE_VALUE_FLEX_BASIS: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_MARGIN [status=implemented hash=e1173e3bbe53]
    public static let OT_STYLE_VALUE_MARGIN: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_PADDING [status=implemented hash=4459dab2ebce]
    public static let OT_STYLE_VALUE_PADDING: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_POSITION [status=implemented hash=191d35f96fc4]
    public static let OT_STYLE_VALUE_POSITION: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_STYLE_VALUE_GAP [status=implemented hash=e52d65ced720]
    public static let OT_STYLE_VALUE_GAP: Int64 = 10
    // parity: core/src/native-abi.generated.ts#OT_DIMENSION_WIDTH [status=implemented hash=175ffcd97a19]
    public static let OT_DIMENSION_WIDTH: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_DIMENSION_HEIGHT [status=implemented hash=acf196653099]
    public static let OT_DIMENSION_HEIGHT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_UNIT_UNDEFINED [status=implemented hash=6f9c4894065d]
    public static let OT_UNIT_UNDEFINED: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_UNIT_POINT [status=implemented hash=df5622a6867b]
    public static let OT_UNIT_POINT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_UNIT_PERCENT [status=implemented hash=8dc6cefe9ce3]
    public static let OT_UNIT_PERCENT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_UNIT_AUTO [status=implemented hash=3e509e4bace1]
    public static let OT_UNIT_AUTO: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EDGE_NONE [status=implemented hash=765342a8344d]
    public static let OT_EDGE_NONE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EDGE_LEFT [status=implemented hash=f01b8237c922]
    public static let OT_EDGE_LEFT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EDGE_TOP [status=implemented hash=3cfb2fc7c28a]
    public static let OT_EDGE_TOP: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDGE_RIGHT [status=implemented hash=0963972320e9]
    public static let OT_EDGE_RIGHT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDGE_BOTTOM [status=implemented hash=15512583710b]
    public static let OT_EDGE_BOTTOM: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EDGE_START [status=implemented hash=179241d5b2a3]
    public static let OT_EDGE_START: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_EDGE_END [status=implemented hash=270dd523171f]
    public static let OT_EDGE_END: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_EDGE_HORIZONTAL [status=implemented hash=4870b2c884b6]
    public static let OT_EDGE_HORIZONTAL: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_EDGE_VERTICAL [status=implemented hash=db554b861c0b]
    public static let OT_EDGE_VERTICAL: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_EDGE_ALL [status=implemented hash=49fdd1957c55]
    public static let OT_EDGE_ALL: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_GUTTER_COLUMN [status=implemented hash=1bd92abb570b]
    public static let OT_GUTTER_COLUMN: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_GUTTER_ROW [status=implemented hash=8eb3ecadad13]
    public static let OT_GUTTER_ROW: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_GUTTER_ALL [status=implemented hash=a7ced05e740b]
    public static let OT_GUTTER_ALL: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_DIRECTION_INHERIT [status=implemented hash=e7936e3b6df2]
    public static let OT_DIRECTION_INHERIT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_DIRECTION_LTR [status=implemented hash=85faca05494f]
    public static let OT_DIRECTION_LTR: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_DIRECTION_RTL [status=implemented hash=c6e0711cc7a8]
    public static let OT_DIRECTION_RTL: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_FLEX_DIRECTION_COLUMN [status=implemented hash=7be61d896813]
    public static let OT_FLEX_DIRECTION_COLUMN: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_FLEX_DIRECTION_COLUMN_REVERSE [status=implemented hash=d382eaaee619]
    public static let OT_FLEX_DIRECTION_COLUMN_REVERSE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_FLEX_DIRECTION_ROW [status=implemented hash=b1fb1226a588]
    public static let OT_FLEX_DIRECTION_ROW: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_FLEX_DIRECTION_ROW_REVERSE [status=implemented hash=b1b613f9981e]
    public static let OT_FLEX_DIRECTION_ROW_REVERSE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_JUSTIFY_FLEX_START [status=implemented hash=9d7925ea47c5]
    public static let OT_JUSTIFY_FLEX_START: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_JUSTIFY_CENTER [status=implemented hash=75f17be81265]
    public static let OT_JUSTIFY_CENTER: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_JUSTIFY_FLEX_END [status=implemented hash=d8ff4bce9689]
    public static let OT_JUSTIFY_FLEX_END: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_JUSTIFY_SPACE_BETWEEN [status=implemented hash=75a45bf92cb2]
    public static let OT_JUSTIFY_SPACE_BETWEEN: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_JUSTIFY_SPACE_AROUND [status=implemented hash=4c7a7d33fda0]
    public static let OT_JUSTIFY_SPACE_AROUND: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_JUSTIFY_SPACE_EVENLY [status=implemented hash=322ef824119f]
    public static let OT_JUSTIFY_SPACE_EVENLY: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_ALIGN_AUTO [status=implemented hash=ff9fcca5ed94]
    public static let OT_ALIGN_AUTO: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_ALIGN_FLEX_START [status=implemented hash=40da8bf28fb0]
    public static let OT_ALIGN_FLEX_START: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_ALIGN_CENTER [status=implemented hash=25c0d55ce342]
    public static let OT_ALIGN_CENTER: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_ALIGN_FLEX_END [status=implemented hash=a45288bd23a2]
    public static let OT_ALIGN_FLEX_END: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_ALIGN_STRETCH [status=implemented hash=2527ce01dd3c]
    public static let OT_ALIGN_STRETCH: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_ALIGN_BASELINE [status=implemented hash=15c293d3501d]
    public static let OT_ALIGN_BASELINE: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_ALIGN_SPACE_BETWEEN [status=implemented hash=7fb1bdde2fdb]
    public static let OT_ALIGN_SPACE_BETWEEN: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_ALIGN_SPACE_AROUND [status=implemented hash=2cdfcea26dd4]
    public static let OT_ALIGN_SPACE_AROUND: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_ALIGN_SPACE_EVENLY [status=implemented hash=427daa40fb7b]
    public static let OT_ALIGN_SPACE_EVENLY: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_POSITION_STATIC [status=implemented hash=32ec5620371c]
    public static let OT_POSITION_STATIC: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_POSITION_RELATIVE [status=implemented hash=096f1295f6ab]
    public static let OT_POSITION_RELATIVE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_POSITION_ABSOLUTE [status=implemented hash=325549e4ea1f]
    public static let OT_POSITION_ABSOLUTE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_FLEX_WRAP_NONE [status=implemented hash=efa01e9ad1c3]
    public static let OT_FLEX_WRAP_NONE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_FLEX_WRAP_WRAP [status=implemented hash=dd403934a838]
    public static let OT_FLEX_WRAP_WRAP: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_FLEX_WRAP_REVERSE [status=implemented hash=0f1bc42527ec]
    public static let OT_FLEX_WRAP_REVERSE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_OVERFLOW_VISIBLE [status=implemented hash=82a5cc4d748f]
    public static let OT_OVERFLOW_VISIBLE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_OVERFLOW_HIDDEN [status=implemented hash=4dbfa8730978]
    public static let OT_OVERFLOW_HIDDEN: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_OVERFLOW_SCROLL [status=implemented hash=bbdacb2325b5]
    public static let OT_OVERFLOW_SCROLL: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_DISPLAY_FLEX [status=implemented hash=0c4561f77ff1]
    public static let OT_DISPLAY_FLEX: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_DISPLAY_NONE [status=implemented hash=e8408f6df0d4]
    public static let OT_DISPLAY_NONE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_BOX_SIZING_BORDER_BOX [status=implemented hash=d98748a67522]
    public static let OT_BOX_SIZING_BORDER_BOX: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_BOX_SIZING_CONTENT_BOX [status=implemented hash=b1f0986964e8]
    public static let OT_BOX_SIZING_CONTENT_BOX: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_LAYOUT_MODE_FLEX [status=implemented hash=49e0c655405d]
    public static let OT_LAYOUT_MODE_FLEX: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_LAYOUT_MODE_LIST [status=implemented hash=d0713d1e52c6]
    public static let OT_LAYOUT_MODE_LIST: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_DISPLAY_CONTENTS [status=implemented hash=acd9c1a8a157]
    public static let OT_DISPLAY_CONTENTS: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_YOGA_ERRATA_NONE [status=implemented hash=072a638bf387]
    public static let OT_YOGA_ERRATA_NONE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_YOGA_ERRATA_STRETCH_FLEX_BASIS [status=implemented hash=2e4279ac9c7a]
    public static let OT_YOGA_ERRATA_STRETCH_FLEX_BASIS: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_YOGA_ERRATA_ABSOLUTE_POSITION_WITHOUT_INSETS_EXCLUDES_PADDING [status=implemented hash=13bbaff908d4]
    public static let OT_YOGA_ERRATA_ABSOLUTE_POSITION_WITHOUT_INSETS_EXCLUDES_PADDING: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_YOGA_ERRATA_ABSOLUTE_PERCENT_AGAINST_INNER_SIZE [status=implemented hash=841731d1661c]
    public static let OT_YOGA_ERRATA_ABSOLUTE_PERCENT_AGAINST_INNER_SIZE: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_YOGA_ERRATA_ALL [status=implemented hash=a6c2a13820b9]
    public static let OT_YOGA_ERRATA_ALL: Int64 = 2147483647
    // parity: core/src/native-abi.generated.ts#OT_YOGA_ERRATA_CLASSIC [status=implemented hash=090f6ecb0107]
    public static let OT_YOGA_ERRATA_CLASSIC: Int64 = 2147483646
    // parity: core/src/native-abi.generated.ts#OT_YOGA_EXPERIMENTAL_FEATURE_WEB_FLEX_BASIS [status=implemented hash=9efb5089709d]
    public static let OT_YOGA_EXPERIMENTAL_FEATURE_WEB_FLEX_BASIS: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_YOGA_LOG_LEVEL_ERROR [status=implemented hash=45bf0f3f3677]
    public static let OT_YOGA_LOG_LEVEL_ERROR: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_YOGA_LOG_LEVEL_WARN [status=implemented hash=bb1f4cceb2b3]
    public static let OT_YOGA_LOG_LEVEL_WARN: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_YOGA_LOG_LEVEL_INFO [status=implemented hash=e8664a75110e]
    public static let OT_YOGA_LOG_LEVEL_INFO: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_YOGA_LOG_LEVEL_DEBUG [status=implemented hash=1ba2e2a831ff]
    public static let OT_YOGA_LOG_LEVEL_DEBUG: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_YOGA_LOG_LEVEL_VERBOSE [status=implemented hash=0a5d80bed0f0]
    public static let OT_YOGA_LOG_LEVEL_VERBOSE: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_YOGA_LOG_LEVEL_FATAL [status=implemented hash=5c59fad817c3]
    public static let OT_YOGA_LOG_LEVEL_FATAL: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_YOGA_NODE_TYPE_DEFAULT [status=implemented hash=253a9063c75f]
    public static let OT_YOGA_NODE_TYPE_DEFAULT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_YOGA_NODE_TYPE_TEXT [status=implemented hash=35488f8a3ad7]
    public static let OT_YOGA_NODE_TYPE_TEXT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_DIRECTION_MAX [status=implemented hash=ab97535beff1]
    public static let OT_STYLE_ENUM_DIRECTION_MAX: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_FLEX_DIRECTION_MAX [status=implemented hash=da4954fa63cb]
    public static let OT_STYLE_ENUM_FLEX_DIRECTION_MAX: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_JUSTIFY_CONTENT_MAX [status=implemented hash=fd3a7f6ad254]
    public static let OT_STYLE_ENUM_JUSTIFY_CONTENT_MAX: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_ALIGN_CONTENT_MAX [status=implemented hash=998951123f07]
    public static let OT_STYLE_ENUM_ALIGN_CONTENT_MAX: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_ALIGN_ITEMS_MAX [status=implemented hash=52cda7bd5a4d]
    public static let OT_STYLE_ENUM_ALIGN_ITEMS_MAX: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_ALIGN_SELF_MAX [status=implemented hash=b2af3efc0cda]
    public static let OT_STYLE_ENUM_ALIGN_SELF_MAX: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_POSITION_TYPE_MAX [status=implemented hash=6fa646d4e863]
    public static let OT_STYLE_ENUM_POSITION_TYPE_MAX: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_FLEX_WRAP_MAX [status=implemented hash=b5379697a945]
    public static let OT_STYLE_ENUM_FLEX_WRAP_MAX: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_OVERFLOW_MAX [status=implemented hash=300483463577]
    public static let OT_STYLE_ENUM_OVERFLOW_MAX: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_DISPLAY_MAX [status=implemented hash=4af444b771a5]
    public static let OT_STYLE_ENUM_DISPLAY_MAX: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_BOX_SIZING_MAX [status=implemented hash=0b73ace0c8df]
    public static let OT_STYLE_ENUM_BOX_SIZING_MAX: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_STYLE_ENUM_LAYOUT_MODE_MAX [status=implemented hash=89cefeed2bdf]
    public static let OT_STYLE_ENUM_LAYOUT_MODE_MAX: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_MEASURE_UNDEFINED [status=implemented hash=a3281514f2e0]
    public static let OT_MEASURE_UNDEFINED: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_MEASURE_EXACTLY [status=implemented hash=d3febcf6fa9d]
    public static let OT_MEASURE_EXACTLY: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_MEASURE_AT_MOST [status=implemented hash=6759c823b39a]
    public static let OT_MEASURE_AT_MOST: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_LAYOUT_PUBLIC [status=implemented hash=1f86abcbc573]
    public static let OT_LAYOUT_PUBLIC: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_LAYOUT_YOGA [status=implemented hash=6ecb3a49404b]
    public static let OT_LAYOUT_YOGA: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_LAYOUT_PAINT [status=implemented hash=a152cd8f9b1f]
    public static let OT_LAYOUT_PAINT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_LAYOUT_CONTENT [status=implemented hash=752955724453]
    public static let OT_LAYOUT_CONTENT: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_BORDER_NONE [status=implemented hash=ff1e81c93e08]
    public static let OT_BORDER_NONE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_BORDER_LEFT [status=implemented hash=35318c6c9250]
    public static let OT_BORDER_LEFT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_BORDER_BOTTOM [status=implemented hash=6f7aed3a032d]
    public static let OT_BORDER_BOTTOM: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_BORDER_RIGHT [status=implemented hash=a77c5e7a6ec0]
    public static let OT_BORDER_RIGHT: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_BORDER_TOP [status=implemented hash=3158f5acdb55]
    public static let OT_BORDER_TOP: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_BORDER_ALL [status=implemented hash=6a52224cd3b4]
    public static let OT_BORDER_ALL: Int64 = 15
    // parity: core/src/native-abi.generated.ts#OT_BORDER_SINGLE [status=implemented hash=22a1acf9b00d]
    public static let OT_BORDER_SINGLE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_BORDER_DOUBLE [status=implemented hash=87164a894b76]
    public static let OT_BORDER_DOUBLE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_BORDER_ROUNDED [status=implemented hash=b816391a08d0]
    public static let OT_BORDER_ROUNDED: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_BORDER_HEAVY [status=implemented hash=88397f56ad29]
    public static let OT_BORDER_HEAVY: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_COLOR_RGB [status=implemented hash=9a69f54aef00]
    public static let OT_COLOR_RGB: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_COLOR_INDEXED [status=implemented hash=042d85c9b1cd]
    public static let OT_COLOR_INDEXED: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_COLOR_DEFAULT [status=implemented hash=effd411ffdd6]
    public static let OT_COLOR_DEFAULT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_COLOR_CHANNEL_MASK [status=implemented hash=2c4d3a703c3e]
    public static let OT_COLOR_CHANNEL_MASK: Int64 = 255
    // parity: core/src/native-abi.generated.ts#OT_COLOR_META_SHIFT [status=implemented hash=79d89bb66fd1]
    public static let OT_COLOR_META_SHIFT: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_0 [status=implemented hash=8a049bed6928]
    public static let OT_COLOR_ANSI_0: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_1 [status=implemented hash=2793504f9905]
    public static let OT_COLOR_ANSI_1: Int64 = 8388608
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_2 [status=implemented hash=a4bfd0796ecb]
    public static let OT_COLOR_ANSI_2: Int64 = 32768
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_3 [status=implemented hash=c8576323eb11]
    public static let OT_COLOR_ANSI_3: Int64 = 8421376
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_4 [status=implemented hash=e6f2c832146e]
    public static let OT_COLOR_ANSI_4: Int64 = 128
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_5 [status=implemented hash=c5d5b65f5e9b]
    public static let OT_COLOR_ANSI_5: Int64 = 8388736
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_6 [status=implemented hash=f1ecafa4e81e]
    public static let OT_COLOR_ANSI_6: Int64 = 32896
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_7 [status=implemented hash=bf9d7a571909]
    public static let OT_COLOR_ANSI_7: Int64 = 12632256
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_8 [status=implemented hash=45052fe27609]
    public static let OT_COLOR_ANSI_8: Int64 = 8421504
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_9 [status=implemented hash=d773e7706fdf]
    public static let OT_COLOR_ANSI_9: Int64 = 16711680
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_10 [status=implemented hash=a2161d5341c5]
    public static let OT_COLOR_ANSI_10: Int64 = 65280
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_11 [status=implemented hash=2d53057bf5b9]
    public static let OT_COLOR_ANSI_11: Int64 = 16776960
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_12 [status=implemented hash=0ecb698bf8d8]
    public static let OT_COLOR_ANSI_12: Int64 = 255
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_13 [status=implemented hash=9f3d89790e2b]
    public static let OT_COLOR_ANSI_13: Int64 = 16711935
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_14 [status=implemented hash=01149da25c0a]
    public static let OT_COLOR_ANSI_14: Int64 = 65535
    // parity: core/src/native-abi.generated.ts#OT_COLOR_ANSI_15 [status=implemented hash=39faf87a8c84]
    public static let OT_COLOR_ANSI_15: Int64 = 16777215
    // parity: core/src/native-abi.generated.ts#OT_COLOR_CUBE_BASE [status=implemented hash=86d74b0fa29e]
    public static let OT_COLOR_CUBE_BASE: Int64 = 55
    // parity: core/src/native-abi.generated.ts#OT_COLOR_CUBE_STEP [status=implemented hash=e51f18439b25]
    public static let OT_COLOR_CUBE_STEP: Int64 = 40
    // parity: core/src/native-abi.generated.ts#OT_COLOR_GRAY_BASE [status=implemented hash=e4528b5d16cd]
    public static let OT_COLOR_GRAY_BASE: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_COLOR_GRAY_STEP [status=implemented hash=40936388e8bc]
    public static let OT_COLOR_GRAY_STEP: Int64 = 10
    // parity: core/src/native-abi.generated.ts#OT_ATTR_BOLD [status=implemented hash=5ba439e9a640]
    public static let OT_ATTR_BOLD: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_ATTR_DIM [status=implemented hash=096da25ae18d]
    public static let OT_ATTR_DIM: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_ATTR_ITALIC [status=implemented hash=fdddb8084699]
    public static let OT_ATTR_ITALIC: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_ATTR_UNDERLINE [status=implemented hash=709c5aabb360]
    public static let OT_ATTR_UNDERLINE: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_ATTR_BLINK [status=implemented hash=483bad9081fb]
    public static let OT_ATTR_BLINK: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_ATTR_INVERSE [status=implemented hash=c5dc7893d393]
    public static let OT_ATTR_INVERSE: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_ATTR_HIDDEN [status=implemented hash=cef8ca6d061b]
    public static let OT_ATTR_HIDDEN: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_ATTR_STRIKETHROUGH [status=implemented hash=25a3d49dabdc]
    public static let OT_ATTR_STRIKETHROUGH: Int64 = 128
    // parity: core/src/native-abi.generated.ts#OT_ATTR_BASE_MASK [status=implemented hash=06077c228eaf]
    public static let OT_ATTR_BASE_MASK: Int64 = 255
    // parity: core/src/native-abi.generated.ts#OT_ATTR_LINK_SHIFT [status=implemented hash=e1f41b4d0850]
    public static let OT_ATTR_LINK_SHIFT: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_ATTR_LINK_MASK [status=implemented hash=0b30a8cb6c71]
    public static let OT_ATTR_LINK_MASK: Int64 = 16777215
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_SELECTION_RESET [status=implemented hash=90e2208e529c]
    public static let OT_SCENE_TEXT_SELECTION_RESET: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_SELECTION_SET [status=implemented hash=38ed411e2eed]
    public static let OT_SCENE_TEXT_SELECTION_SET: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_SELECTION_UPDATE [status=implemented hash=84520233f040]
    public static let OT_SCENE_TEXT_SELECTION_UPDATE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_SELECTION_COLORS [status=implemented hash=40b237675a2e]
    public static let OT_SCENE_TEXT_SELECTION_COLORS: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_SELECTION_CELL [status=implemented hash=79dce62ac9f7]
    public static let OT_SCENE_TEXT_SELECTION_CELL: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_SELECTION_WORD [status=implemented hash=f5eebb49b564]
    public static let OT_SCENE_TEXT_SELECTION_WORD: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_SELECTION_LINE [status=implemented hash=b858a84f5981]
    public static let OT_SCENE_TEXT_SELECTION_LINE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_SELECTION_BACKGROUND [status=implemented hash=1c182b876a93]
    public static let OT_SCENE_TEXT_SELECTION_BACKGROUND: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_SELECTION_FOREGROUND [status=implemented hash=a784af3441ac]
    public static let OT_SCENE_TEXT_SELECTION_FOREGROUND: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_FOREGROUND [status=implemented hash=7fb85cf602e3]
    public static let OT_SCENE_TEXT_FOREGROUND: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_BACKGROUND [status=implemented hash=af304b67036f]
    public static let OT_SCENE_TEXT_BACKGROUND: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_TEXT_LINK [status=implemented hash=689710bef94a]
    public static let OT_SCENE_TEXT_LINK: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_MUTATIONS_MAX [status=implemented hash=ad50e828bcb4]
    public static let OT_SCENE_MUTATIONS_MAX: Int64 = 4096
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FULL_PATH_FORCED [status=implemented hash=d0a493a4b6f7]
    public static let OT_SCENE_FULL_PATH_FORCED: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FULL_PATH_SCREEN [status=implemented hash=5b0f983d7f39]
    public static let OT_SCENE_FULL_PATH_SCREEN: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FULL_PATH_IMAGES [status=implemented hash=d0e236a06429]
    public static let OT_SCENE_FULL_PATH_IMAGES: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FULL_PATH_TAINTED [status=implemented hash=604a5046a548]
    public static let OT_SCENE_FULL_PATH_TAINTED: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FULL_PATH_UNRETAINED [status=implemented hash=2d557d7bebec]
    public static let OT_SCENE_FULL_PATH_UNRETAINED: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FULL_PATH_OPTIONS [status=implemented hash=f111b90d63d0]
    public static let OT_SCENE_FULL_PATH_OPTIONS: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FULL_PATH_NON_LOCAL [status=implemented hash=a5bc1757c29d]
    public static let OT_SCENE_FULL_PATH_NON_LOCAL: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_CURSOR_STYLE_BLOCK [status=implemented hash=8b6a240fe7df]
    public static let OT_CURSOR_STYLE_BLOCK: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_CURSOR_STYLE_LINE [status=implemented hash=4141211ad5ed]
    public static let OT_CURSOR_STYLE_LINE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CURSOR_STYLE_UNDERLINE [status=implemented hash=108fb052d8f5]
    public static let OT_CURSOR_STYLE_UNDERLINE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_CURSOR_STYLE_DEFAULT [status=implemented hash=cc4f9dc5e26b]
    public static let OT_CURSOR_STYLE_DEFAULT: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_SCENE_HOOK_UPDATE [status=implemented hash=11b7cdf30134]
    public static let OT_SCENE_HOOK_UPDATE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_HOOK_RESIZE [status=implemented hash=402ac505e988]
    public static let OT_SCENE_HOOK_RESIZE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_HOOK_LAYOUT_CHANGED [status=implemented hash=0a2b4d0408be]
    public static let OT_SCENE_HOOK_LAYOUT_CHANGED: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_HOOK_RENDER_BEFORE [status=implemented hash=6acc780b3946]
    public static let OT_SCENE_HOOK_RENDER_BEFORE: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_SCENE_HOOK_RENDER_AFTER [status=implemented hash=f16db2b4b981]
    public static let OT_SCENE_HOOK_RENDER_AFTER: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_SCENE_HOOK_RENDER_SELF [status=implemented hash=2ecebc07d0bc]
    public static let OT_SCENE_HOOK_RENDER_SELF: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_SCENE_HOOK_IDLE_UPDATE [status=implemented hash=6f5db60bccb6]
    public static let OT_SCENE_HOOK_IDLE_UPDATE: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_SCENE_HOOK_SCROLL [status=implemented hash=5912e262c3db]
    public static let OT_SCENE_HOOK_SCROLL: Int64 = 128
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FRAME_DONE [status=implemented hash=3ce641c05950]
    public static let OT_SCENE_FRAME_DONE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FRAME_UPDATE [status=implemented hash=448c1f85ba49]
    public static let OT_SCENE_FRAME_UPDATE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FRAME_RESIZE [status=implemented hash=c4af3252f46d]
    public static let OT_SCENE_FRAME_RESIZE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FRAME_LAYOUT_CHANGED [status=implemented hash=f8ea29e4bc0f]
    public static let OT_SCENE_FRAME_LAYOUT_CHANGED: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FRAME_RECORD [status=implemented hash=33dc1fea8783]
    public static let OT_SCENE_FRAME_RECORD: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_FRAME_SCROLL [status=implemented hash=557e663c68e4]
    public static let OT_SCENE_FRAME_SCROLL: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_SCENE_GEOMETRY_PAINT [status=implemented hash=66cb73d76bfd]
    public static let OT_SCENE_GEOMETRY_PAINT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_GEOMETRY_PUBLIC [status=implemented hash=baf91a941315]
    public static let OT_SCENE_GEOMETRY_PUBLIC: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_Z_INDEX [status=implemented hash=2b06299cdc86]
    public static let OT_SCENE_PROPERTY_Z_INDEX: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_OPACITY [status=implemented hash=b3493d3cb4b0]
    public static let OT_SCENE_PROPERTY_OPACITY: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_TRANSLATE_X [status=implemented hash=33f7792640f2]
    public static let OT_SCENE_PROPERTY_TRANSLATE_X: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_TRANSLATE_Y [status=implemented hash=4d3c7bb7fea1]
    public static let OT_SCENE_PROPERTY_TRANSLATE_Y: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_BORDER [status=implemented hash=9357510ddb0b]
    public static let OT_SCENE_PROPERTY_BORDER: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_SHOULD_FILL [status=implemented hash=83e4ba9c6ae3]
    public static let OT_SCENE_PROPERTY_SHOULD_FILL: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_BACKGROUND [status=implemented hash=71066fb3118f]
    public static let OT_SCENE_PROPERTY_BACKGROUND: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_BORDER_COLOR [status=implemented hash=775693a454ef]
    public static let OT_SCENE_PROPERTY_BORDER_COLOR: Int64 = 128
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_BORDER_STYLE [status=implemented hash=6ce0b1f1b9cc]
    public static let OT_SCENE_PROPERTY_BORDER_STYLE: Int64 = 256
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_FOCUSABLE [status=implemented hash=18ef861178cd]
    public static let OT_SCENE_PROPERTY_FOCUSABLE: Int64 = 512
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_FOCUSED_BORDER_COLOR [status=implemented hash=af77aa00d9db]
    public static let OT_SCENE_PROPERTY_FOCUSED_BORDER_COLOR: Int64 = 1024
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_STYLE [status=implemented hash=772f1540d82f]
    public static let OT_SCENE_PROPERTY_STYLE: Int64 = 2048
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_RESET_BORDER_CHARACTERS [status=implemented hash=61a12aa9e030]
    public static let OT_SCENE_PROPERTY_RESET_BORDER_CHARACTERS: Int64 = 4096
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_RECORD_MAX [status=implemented hash=9463a9b3cd0b]
    public static let OT_SCENE_PROPERTY_RECORD_MAX: Int64 = 88
    // parity: core/src/native-abi.generated.ts#OT_SCENE_PROPERTY_BYTES_MAX [status=implemented hash=2878e909e870]
    public static let OT_SCENE_PROPERTY_BYTES_MAX: Int64 = 360448
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_X [status=implemented hash=236ae0d10d22]
    public static let OT_SCENE_SCROLL_X: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_Y [status=implemented hash=a97d2cd1055a]
    public static let OT_SCENE_SCROLL_Y: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_FOLLOW_NONE [status=implemented hash=6663a156eba2]
    public static let OT_SCENE_SCROLL_FOLLOW_NONE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_FOLLOW_TOP [status=implemented hash=a42fd754e8ed]
    public static let OT_SCENE_SCROLL_FOLLOW_TOP: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_FOLLOW_BOTTOM [status=implemented hash=17f4fcf72689]
    public static let OT_SCENE_SCROLL_FOLLOW_BOTTOM: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_FOLLOW_LEFT [status=implemented hash=38ea4ac983a7]
    public static let OT_SCENE_SCROLL_FOLLOW_LEFT: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_FOLLOW_RIGHT [status=implemented hash=38d0d3874edb]
    public static let OT_SCENE_SCROLL_FOLLOW_RIGHT: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_FILL_WRAPPER [status=implemented hash=44076d868f0d]
    public static let OT_SCENE_SCROLL_FILL_WRAPPER: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_FILL_VIEWPORT [status=implemented hash=02cf95f44ac2]
    public static let OT_SCENE_SCROLL_FILL_VIEWPORT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_FILL_CONTENT [status=implemented hash=3685d8b9e4fb]
    public static let OT_SCENE_SCROLL_FILL_CONTENT: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_BAR_AUTO [status=implemented hash=ba4f487d6b70]
    public static let OT_SCENE_SCROLL_BAR_AUTO: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_BAR_ALWAYS [status=implemented hash=946724b217f3]
    public static let OT_SCENE_SCROLL_BAR_ALWAYS: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_BAR_NEVER [status=implemented hash=17d3df18dbdc]
    public static let OT_SCENE_SCROLL_BAR_NEVER: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_BAR_INSET [status=implemented hash=2651704f2211]
    public static let OT_SCENE_SCROLL_BAR_INSET: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_BAR_OVERLAY [status=implemented hash=ec29ae8ae6ff]
    public static let OT_SCENE_SCROLL_BAR_OVERLAY: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_RELATIVE_X [status=implemented hash=20b32ee420f2]
    public static let OT_SCENE_SCROLL_RELATIVE_X: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_RELATIVE_Y [status=implemented hash=ecd4ab878afb]
    public static let OT_SCENE_SCROLL_RELATIVE_Y: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_REAPPLY [status=implemented hash=f1bf60bbde84]
    public static let OT_SCENE_SCROLL_REAPPLY: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_REQUEST_INTO_VIEW [status=implemented hash=7d54f6146d26]
    public static let OT_SCENE_SCROLL_REQUEST_INTO_VIEW: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_REQUEST_ANCHOR [status=implemented hash=ec2a8b49d839]
    public static let OT_SCENE_SCROLL_REQUEST_ANCHOR: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_REQUEST_LAYOUT [status=implemented hash=299ed1c0f6a8]
    public static let OT_SCENE_SCROLL_REQUEST_LAYOUT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_ALIGN_NEAREST [status=implemented hash=924f4631fc0a]
    public static let OT_SCENE_SCROLL_ALIGN_NEAREST: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_ALIGN_START [status=implemented hash=0736e8ec3509]
    public static let OT_SCENE_SCROLL_ALIGN_START: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_ALIGN_END [status=implemented hash=1f537c2bd591]
    public static let OT_SCENE_SCROLL_ALIGN_END: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_PADDING_MAX [status=implemented hash=58baf87186ec]
    public static let OT_SCENE_SCROLL_PADDING_MAX: Int64 = 65535
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_CHANGED_OFFSET_X [status=implemented hash=ac81a5436c35]
    public static let OT_SCENE_SCROLL_CHANGED_OFFSET_X: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_CHANGED_OFFSET_Y [status=implemented hash=806880a3ee97]
    public static let OT_SCENE_SCROLL_CHANGED_OFFSET_Y: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_CHANGED_CONTENT [status=implemented hash=ca5997f0dcab]
    public static let OT_SCENE_SCROLL_CHANGED_CONTENT: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_CHANGED_VIEWPORT [status=implemented hash=63e166fc5056]
    public static let OT_SCENE_SCROLL_CHANGED_VIEWPORT: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_SCENE_SCROLL_CHANGED_LAYOUT [status=implemented hash=d9ea8456fb3a]
    public static let OT_SCENE_SCROLL_CHANGED_LAYOUT: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_SCENE_DEBUG_FULL_FRAME [status=implemented hash=f38ee13d95a8]
    public static let OT_SCENE_DEBUG_FULL_FRAME: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_DEBUG_VERIFY [status=implemented hash=c83206e2d0f3]
    public static let OT_SCENE_DEBUG_VERIFY: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SESSION_OPEN [status=implemented hash=38a32eb09c30]
    public static let OT_SESSION_OPEN: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SESSION_CLOSING [status=implemented hash=f2f6f8e422a4]
    public static let OT_SESSION_CLOSING: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SESSION_CLOSED_STATE [status=implemented hash=787fb75aeec2]
    public static let OT_SESSION_CLOSED_STATE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SESSION_FAILED [status=implemented hash=a3e648d56d58]
    public static let OT_SESSION_FAILED: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_SESSION_CANCELLED_STATE [status=implemented hash=b5d7b1442669]
    public static let OT_SESSION_CANCELLED_STATE: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SESSION_REMOTE_AUTO [status=implemented hash=7ae5ed869562]
    public static let OT_SESSION_REMOTE_AUTO: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SESSION_REMOTE_LOCAL [status=implemented hash=ce603c46cccc]
    public static let OT_SESSION_REMOTE_LOCAL: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SESSION_REMOTE_REMOTE [status=implemented hash=997b75adf9ca]
    public static let OT_SESSION_REMOTE_REMOTE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SESSION_ENV_ENTRIES_MAX [status=implemented hash=cea97f4f71fe]
    public static let OT_SESSION_ENV_ENTRIES_MAX: Int64 = 256
    // parity: core/src/native-abi.generated.ts#OT_SESSION_ENV_BYTES_MAX [status=implemented hash=568571ca25ed]
    public static let OT_SESSION_ENV_BYTES_MAX: Int64 = 65536
    // parity: core/src/native-abi.generated.ts#OT_RENDER_PRESENTED [status=implemented hash=effc58f0f21c]
    public static let OT_RENDER_PRESENTED: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_RENDER_PENDING [status=implemented hash=c862cb0b016d]
    public static let OT_RENDER_PENDING: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_RENDER_SKIPPED [status=implemented hash=ba91555c2150]
    public static let OT_RENDER_SKIPPED: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_RENDER_FAILED [status=implemented hash=f691631bbc60]
    public static let OT_RENDER_FAILED: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_SPLIT_SNAPSHOTS_MAX [status=implemented hash=37da2bbc45f0]
    public static let OT_SPLIT_SNAPSHOTS_MAX: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_SESSION_BUFFER_CURRENT [status=implemented hash=a5dd9e134710]
    public static let OT_SESSION_BUFFER_CURRENT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SESSION_BUFFER_NEXT [status=implemented hash=86aff9049a91]
    public static let OT_SESSION_BUFFER_NEXT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_WIDTH_METHOD_WCWIDTH [status=implemented hash=7ce089012242]
    public static let OT_WIDTH_METHOD_WCWIDTH: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_WIDTH_METHOD_UNICODE [status=implemented hash=4adbec7951e3]
    public static let OT_WIDTH_METHOD_UNICODE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_WIDTH_METHOD_NO_ZWJ [status=implemented hash=907fb3b7cf39]
    public static let OT_WIDTH_METHOD_NO_ZWJ: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_WIDTH_METHOD_UNICODE_WIDE [status=implemented hash=176a51df1881]
    public static let OT_WIDTH_METHOD_UNICODE_WIDE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_RESPECT_ALPHA [status=implemented hash=b201f091ef95]
    public static let OT_BUFFER_RESPECT_ALPHA: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_CURSOR_BAR [status=implemented hash=adbf99113bbe]
    public static let OT_EMBEDDED_TERMINAL_CURSOR_BAR: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_CURSOR_BLOCK [status=implemented hash=3124576ebed5]
    public static let OT_EMBEDDED_TERMINAL_CURSOR_BLOCK: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_CURSOR_UNDERLINE [status=implemented hash=ef2291947376]
    public static let OT_EMBEDDED_TERMINAL_CURSOR_UNDERLINE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_CURSOR_BLOCK_HOLLOW [status=implemented hash=dde704405a35]
    public static let OT_EMBEDDED_TERMINAL_CURSOR_BLOCK_HOLLOW: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_MOD_SHIFT [status=implemented hash=7aa3209cc29e]
    public static let OT_EMBEDDED_TERMINAL_MOD_SHIFT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_MOD_CTRL [status=implemented hash=1afa8a08cdfe]
    public static let OT_EMBEDDED_TERMINAL_MOD_CTRL: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_MOD_ALT [status=implemented hash=6c80501a32e6]
    public static let OT_EMBEDDED_TERMINAL_MOD_ALT: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_MOD_SUPER [status=implemented hash=da3efdb4e4c7]
    public static let OT_EMBEDDED_TERMINAL_MOD_SUPER: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_MOD_CAPS_LOCK [status=implemented hash=b7885f9de446]
    public static let OT_EMBEDDED_TERMINAL_MOD_CAPS_LOCK: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_MOD_NUM_LOCK [status=implemented hash=6a0301072e44]
    public static let OT_EMBEDDED_TERMINAL_MOD_NUM_LOCK: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_KEY_RELEASE [status=implemented hash=b371f26ef391]
    public static let OT_EMBEDDED_TERMINAL_KEY_RELEASE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_KEY_PRESS [status=implemented hash=7d3ddfbe4629]
    public static let OT_EMBEDDED_TERMINAL_KEY_PRESS: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_KEY_REPEAT [status=implemented hash=c56dcf37aaab]
    public static let OT_EMBEDDED_TERMINAL_KEY_REPEAT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_MOUSE_PRESS [status=implemented hash=2a3f9d8a29f3]
    public static let OT_EMBEDDED_TERMINAL_MOUSE_PRESS: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_MOUSE_RELEASE [status=implemented hash=7c61a16b8b56]
    public static let OT_EMBEDDED_TERMINAL_MOUSE_RELEASE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_MOUSE_MOTION [status=implemented hash=df5ff4361dd1]
    public static let OT_EMBEDDED_TERMINAL_MOUSE_MOTION: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_BUTTON_NONE [status=implemented hash=908ecf843f50]
    public static let OT_EMBEDDED_TERMINAL_BUTTON_NONE: Int64 = -1
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_BUTTON_UNKNOWN [status=implemented hash=b7c8071e616e]
    public static let OT_EMBEDDED_TERMINAL_BUTTON_UNKNOWN: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_BUTTON_LEFT [status=implemented hash=4e7019225e80]
    public static let OT_EMBEDDED_TERMINAL_BUTTON_LEFT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_BUTTON_RIGHT [status=implemented hash=f25131b806d5]
    public static let OT_EMBEDDED_TERMINAL_BUTTON_RIGHT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_BUTTON_MIDDLE [status=implemented hash=e2885c1b9e3b]
    public static let OT_EMBEDDED_TERMINAL_BUTTON_MIDDLE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_BUTTON_FOUR [status=implemented hash=e069765cec4c]
    public static let OT_EMBEDDED_TERMINAL_BUTTON_FOUR: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_BUTTON_FIVE [status=implemented hash=6bd1af5e7e39]
    public static let OT_EMBEDDED_TERMINAL_BUTTON_FIVE: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_BUTTON_SIX [status=implemented hash=99fb23716a50]
    public static let OT_EMBEDDED_TERMINAL_BUTTON_SIX: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_BUTTON_SEVEN [status=implemented hash=209e5a820130]
    public static let OT_EMBEDDED_TERMINAL_BUTTON_SEVEN: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_INPUT_BYTES_MAX [status=implemented hash=a991c9c1e8c5]
    public static let OT_EMBEDDED_TERMINAL_INPUT_BYTES_MAX: Int64 = 1048576
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_INVALIDATE [status=implemented hash=b47ec0778639]
    public static let OT_EMBEDDED_TERMINAL_INVALIDATE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_SCROLL [status=implemented hash=91a2898e429d]
    public static let OT_EMBEDDED_TERMINAL_SCROLL: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_CLEAR_SELECTION [status=implemented hash=bb0c33e21ef1]
    public static let OT_EMBEDDED_TERMINAL_CLEAR_SELECTION: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_SET_TRANSPARENT_BACKGROUND [status=implemented hash=ec3441bab953]
    public static let OT_EMBEDDED_TERMINAL_SET_TRANSPARENT_BACKGROUND: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EMBEDDED_TERMINAL_RESPONSE_BYTES_MAX [status=implemented hash=a7ece1c66ea7]
    public static let OT_EMBEDDED_TERMINAL_RESPONSE_BYTES_MAX: Int64 = 1048576
    // parity: core/src/native-abi.generated.ts#OT_EDIT_BUFFER_FOLLOW_SESSION_WIDTH [status=implemented hash=0c54a2c0af7a]
    public static let OT_EDIT_BUFFER_FOLLOW_SESSION_WIDTH: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDIT_CURSOR_CHANGED [status=implemented hash=5883308d162a]
    public static let OT_EDIT_CURSOR_CHANGED: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDIT_CONTENT_CHANGED [status=implemented hash=0a6692c5b22e]
    public static let OT_EDIT_CONTENT_CHANGED: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDIT_HISTORY_CURSOR_CHANGED [status=implemented hash=737d3ccd82c8]
    public static let OT_EDIT_HISTORY_CURSOR_CHANGED: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_AUTO [status=implemented hash=f8f6e3e8899a]
    public static let OT_MOUSE_POINTER_AUTO: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_DEFAULT [status=implemented hash=0d8e1ac3ea0e]
    public static let OT_MOUSE_POINTER_DEFAULT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_NONE [status=implemented hash=18a1a5a40f56]
    public static let OT_MOUSE_POINTER_NONE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_CONTEXT_MENU [status=implemented hash=932a897ee249]
    public static let OT_MOUSE_POINTER_CONTEXT_MENU: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_HELP [status=implemented hash=15f27dd1351c]
    public static let OT_MOUSE_POINTER_HELP: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_POINTER [status=implemented hash=dd964632f690]
    public static let OT_MOUSE_POINTER_POINTER: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_PROGRESS [status=implemented hash=8e091a51896e]
    public static let OT_MOUSE_POINTER_PROGRESS: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_WAIT [status=implemented hash=091727e68864]
    public static let OT_MOUSE_POINTER_WAIT: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_CELL [status=implemented hash=18b78d1ab460]
    public static let OT_MOUSE_POINTER_CELL: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_CROSSHAIR [status=implemented hash=13c5bc3f8b2e]
    public static let OT_MOUSE_POINTER_CROSSHAIR: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_TEXT [status=implemented hash=ef9e4d23d47c]
    public static let OT_MOUSE_POINTER_TEXT: Int64 = 10
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_VERTICAL_TEXT [status=implemented hash=3768727a3d34]
    public static let OT_MOUSE_POINTER_VERTICAL_TEXT: Int64 = 11
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_ALIAS [status=implemented hash=62d0becdf747]
    public static let OT_MOUSE_POINTER_ALIAS: Int64 = 12
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_COPY [status=implemented hash=4877b27f69b7]
    public static let OT_MOUSE_POINTER_COPY: Int64 = 13
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_MOVE [status=implemented hash=4e8281543800]
    public static let OT_MOUSE_POINTER_MOVE: Int64 = 14
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_NO_DROP [status=implemented hash=c25e9a8a5eb4]
    public static let OT_MOUSE_POINTER_NO_DROP: Int64 = 15
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_NOT_ALLOWED [status=implemented hash=065227204aa5]
    public static let OT_MOUSE_POINTER_NOT_ALLOWED: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_GRAB [status=implemented hash=b90e92255031]
    public static let OT_MOUSE_POINTER_GRAB: Int64 = 17
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_GRABBING [status=implemented hash=0aca38c06c44]
    public static let OT_MOUSE_POINTER_GRABBING: Int64 = 18
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_ALL_SCROLL [status=implemented hash=bd385b03a74c]
    public static let OT_MOUSE_POINTER_ALL_SCROLL: Int64 = 19
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_COL_RESIZE [status=implemented hash=6926897d556b]
    public static let OT_MOUSE_POINTER_COL_RESIZE: Int64 = 20
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_ROW_RESIZE [status=implemented hash=f4fc2baa6dbf]
    public static let OT_MOUSE_POINTER_ROW_RESIZE: Int64 = 21
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_N_RESIZE [status=implemented hash=8888d2c72e5a]
    public static let OT_MOUSE_POINTER_N_RESIZE: Int64 = 22
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_E_RESIZE [status=implemented hash=eba6ce3c2cf6]
    public static let OT_MOUSE_POINTER_E_RESIZE: Int64 = 23
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_S_RESIZE [status=implemented hash=efacdf49b435]
    public static let OT_MOUSE_POINTER_S_RESIZE: Int64 = 24
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_W_RESIZE [status=implemented hash=60c3f41e8a6c]
    public static let OT_MOUSE_POINTER_W_RESIZE: Int64 = 25
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_NE_RESIZE [status=implemented hash=6b521a39a3eb]
    public static let OT_MOUSE_POINTER_NE_RESIZE: Int64 = 26
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_NW_RESIZE [status=implemented hash=a9eba358af97]
    public static let OT_MOUSE_POINTER_NW_RESIZE: Int64 = 27
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_SE_RESIZE [status=implemented hash=32c2306851b7]
    public static let OT_MOUSE_POINTER_SE_RESIZE: Int64 = 28
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_SW_RESIZE [status=implemented hash=484535e89073]
    public static let OT_MOUSE_POINTER_SW_RESIZE: Int64 = 29
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_EW_RESIZE [status=implemented hash=84e066498f9f]
    public static let OT_MOUSE_POINTER_EW_RESIZE: Int64 = 30
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_NS_RESIZE [status=implemented hash=4b0b4ed3342e]
    public static let OT_MOUSE_POINTER_NS_RESIZE: Int64 = 31
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_NESW_RESIZE [status=implemented hash=07a55db9c2a4]
    public static let OT_MOUSE_POINTER_NESW_RESIZE: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_NWSE_RESIZE [status=implemented hash=39d3d224cacc]
    public static let OT_MOUSE_POINTER_NWSE_RESIZE: Int64 = 33
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_ZOOM_IN [status=implemented hash=6895a40f0cab]
    public static let OT_MOUSE_POINTER_ZOOM_IN: Int64 = 34
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_ZOOM_OUT [status=implemented hash=82277c738fdf]
    public static let OT_MOUSE_POINTER_ZOOM_OUT: Int64 = 35
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_MAX [status=implemented hash=8e8f6f417cfa]
    public static let OT_MOUSE_POINTER_MAX: Int64 = 35
    // parity: core/src/native-abi.generated.ts#OT_MOUSE_POINTER_UNCHANGED [status=implemented hash=33da92a527ec]
    public static let OT_MOUSE_POINTER_UNCHANGED: Int64 = 4294967295
    // parity: core/src/native-abi.generated.ts#OT_EDIT_DELETE_FORWARD [status=implemented hash=38a82e669efd]
    public static let OT_EDIT_DELETE_FORWARD: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EDIT_BACKSPACE [status=implemented hash=284f7d4ba3cd]
    public static let OT_EDIT_BACKSPACE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDIT_NEW_LINE [status=implemented hash=5d8c1fe762b5]
    public static let OT_EDIT_NEW_LINE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDIT_DELETE_LINE [status=implemented hash=2ea51f1a1786]
    public static let OT_EDIT_DELETE_LINE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EDIT_MOVE_LEFT [status=implemented hash=7f274b0c3e93]
    public static let OT_EDIT_MOVE_LEFT: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_EDIT_MOVE_RIGHT [status=implemented hash=84d0da79d52f]
    public static let OT_EDIT_MOVE_RIGHT: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_EDIT_MOVE_UP [status=implemented hash=257e0e87a76c]
    public static let OT_EDIT_MOVE_UP: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_EDIT_MOVE_DOWN [status=implemented hash=b6a48b4f9ddb]
    public static let OT_EDIT_MOVE_DOWN: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_EDIT_GOTO_LINE [status=implemented hash=8924349370e8]
    public static let OT_EDIT_GOTO_LINE: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_EDIT_CURSOR_OFFSET [status=implemented hash=77395a879c17]
    public static let OT_EDIT_CURSOR_OFFSET: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_EDIT_CLEAR [status=implemented hash=2e319dc1fb1a]
    public static let OT_EDIT_CLEAR: Int64 = 10
    // parity: core/src/native-abi.generated.ts#OT_EDIT_CLEAR_HISTORY [status=implemented hash=36806782d836]
    public static let OT_EDIT_CLEAR_HISTORY: Int64 = 11
    // parity: core/src/native-abi.generated.ts#OT_EDIT_DEBUG_ROPE [status=implemented hash=bf49b042740b]
    public static let OT_EDIT_DEBUG_ROPE: Int64 = 12
    // parity: core/src/native-abi.generated.ts#OT_EDIT_CURSOR_OFFSET_ATOMIC [status=implemented hash=7550c9d64cf6]
    public static let OT_EDIT_CURSOR_OFFSET_ATOMIC: Int64 = 13
    // parity: core/src/native-abi.generated.ts#OT_EDIT_KEEP_OUTSIDE [status=implemented hash=34693b071cd1]
    public static let OT_EDIT_KEEP_OUTSIDE: Int64 = 14
    // parity: core/src/native-abi.generated.ts#OT_EDIT_ATOMIC [status=implemented hash=a2e76a13e573]
    public static let OT_EDIT_ATOMIC: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDIT_POSITION_CURSOR [status=implemented hash=3b913aa71e5a]
    public static let OT_EDIT_POSITION_CURSOR: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EDIT_POSITION_NEXT_WORD [status=implemented hash=ec1bb5c7f821]
    public static let OT_EDIT_POSITION_NEXT_WORD: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDIT_POSITION_PREV_WORD [status=implemented hash=b02477dec94f]
    public static let OT_EDIT_POSITION_PREV_WORD: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDIT_POSITION_EOL [status=implemented hash=ed1b4be5dd64]
    public static let OT_EDIT_POSITION_EOL: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EDIT_POSITION_OFFSET [status=implemented hash=bc326a2e78b2]
    public static let OT_EDIT_POSITION_OFFSET: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_EDIT_POSITION_COORDS [status=implemented hash=1b8c63ffa4cb]
    public static let OT_EDIT_POSITION_COORDS: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_EDIT_POSITION_LINE_START [status=implemented hash=82dcbb274168]
    public static let OT_EDIT_POSITION_LINE_START: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_EDIT_POSITION_END [status=implemented hash=4ff7aa2cabef]
    public static let OT_EDIT_POSITION_END: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_EDIT_POSITION_PREV_CHAR [status=implemented hash=243c3336f78a]
    public static let OT_EDIT_POSITION_PREV_CHAR: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_EDIT_BYTE_TO_CELL [status=implemented hash=94092acc2784]
    public static let OT_EDIT_BYTE_TO_CELL: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EDIT_CELL_TO_BYTE [status=implemented hash=9bcc8f2f2c55]
    public static let OT_EDIT_CELL_TO_BYTE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDIT_UTF16_TO_CELL [status=implemented hash=5450a1ff408e]
    public static let OT_EDIT_UTF16_TO_CELL: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDIT_CELL_TO_UTF16 [status=implemented hash=c7070dd9e472]
    public static let OT_EDIT_CELL_TO_UTF16: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_STYLE_FOREGROUND [status=implemented hash=28c08d63b77f]
    public static let OT_EDITOR_STYLE_FOREGROUND: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_STYLE_BACKGROUND [status=implemented hash=3d958062a5c7]
    public static let OT_EDITOR_STYLE_BACKGROUND: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_STYLE_ATTRIBUTES [status=implemented hash=676a6113e553]
    public static let OT_EDITOR_STYLE_ATTRIBUTES: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_STYLE_ATTRIBUTE_MASK [status=implemented hash=07618c10c78e]
    public static let OT_EDITOR_STYLE_ATTRIBUTE_MASK: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_EDIT_HIGHLIGHT_ADD_LINE [status=implemented hash=f1dff5425f34]
    public static let OT_EDIT_HIGHLIGHT_ADD_LINE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EDIT_HIGHLIGHT_ADD_RANGE [status=implemented hash=c95fc13ca59f]
    public static let OT_EDIT_HIGHLIGHT_ADD_RANGE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDIT_HIGHLIGHT_REMOVE_REF [status=implemented hash=2adb97ead54a]
    public static let OT_EDIT_HIGHLIGHT_REMOVE_REF: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDIT_HIGHLIGHT_CLEAR_LINE [status=implemented hash=c27e321a2405]
    public static let OT_EDIT_HIGHLIGHT_CLEAR_LINE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EDIT_HIGHLIGHT_CLEAR_ALL [status=implemented hash=cb817d338791]
    public static let OT_EDIT_HIGHLIGHT_CLEAR_ALL: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_STYLE_RUN_FLAG [status=implemented hash=c7650bc5af19]
    public static let OT_STYLE_RUN_FLAG: Int64 = 2147483648
    // parity: core/src/native-abi.generated.ts#OT_GROUP_SET_NAME_COUNT_MAX [status=implemented hash=8a0564d966c3]
    public static let OT_GROUP_SET_NAME_COUNT_MAX: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_GROUP_SET_NAME_BYTE_COUNT_MAX [status=implemented hash=9e860db61aa9]
    public static let OT_GROUP_SET_NAME_BYTE_COUNT_MAX: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_EDIT_MARK_ADD [status=implemented hash=fd2968a978d7]
    public static let OT_EDIT_MARK_ADD: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EDIT_MARK_REMOVE [status=implemented hash=bd01f183bfeb]
    public static let OT_EDIT_MARK_REMOVE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDIT_MARK_CLEAR [status=implemented hash=987be2dc9885]
    public static let OT_EDIT_MARK_CLEAR: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDIT_MARK_ATOMIC [status=implemented hash=df70f0df14c9]
    public static let OT_EDIT_MARK_ATOMIC: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDIT_MARK_STYLE_VALUE [status=implemented hash=d1dde5c7cb2c]
    public static let OT_EDIT_MARK_STYLE_VALUE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDIT_MARK_ANY_KIND [status=implemented hash=c00bf3ff97a1]
    public static let OT_EDIT_MARK_ANY_KIND: Int64 = 4294967295
    // parity: core/src/native-abi.generated.ts#OT_MD_CONCEAL [status=implemented hash=cce0323ca17c]
    public static let OT_MD_CONCEAL: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_MD_HYPERLINKS [status=implemented hash=e16f0b4e4246]
    public static let OT_MD_HYPERLINKS: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_MD_MATH [status=implemented hash=27b5415f6112]
    public static let OT_MD_MATH: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_MD_HOOK [status=implemented hash=672f11a3c90d]
    public static let OT_MD_HOOK: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_MD_HOOK_FILTER_BYTE_COUNT_MAX [status=implemented hash=2112b9e759b6]
    public static let OT_MD_HOOK_FILTER_BYTE_COUNT_MAX: Int64 = 256
    // parity: core/src/native-abi.generated.ts#OT_MD_PARAGRAPH [status=implemented hash=86d35e7616f7]
    public static let OT_MD_PARAGRAPH: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_MD_HEADING [status=implemented hash=c46c14d637aa]
    public static let OT_MD_HEADING: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_MD_CODE [status=implemented hash=f0a84b7d1c28]
    public static let OT_MD_CODE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_MD_HTML [status=implemented hash=1403b39ac37f]
    public static let OT_MD_HTML: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_MD_RULE [status=implemented hash=6533f1752fbc]
    public static let OT_MD_RULE: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_MD_TABLE [status=implemented hash=7a43b3df4c37]
    public static let OT_MD_TABLE: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_MD_TABLE_ROW [status=implemented hash=cf933cf6da5b]
    public static let OT_MD_TABLE_ROW: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_MD_TABLE_CELL [status=implemented hash=16ffa498770e]
    public static let OT_MD_TABLE_CELL: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_MD_QUOTE [status=implemented hash=9ccd5b713c96]
    public static let OT_MD_QUOTE: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_MD_LIST [status=implemented hash=7b1e0aa83e7e]
    public static let OT_MD_LIST: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_MD_ITEM [status=implemented hash=66246a533f76]
    public static let OT_MD_ITEM: Int64 = 10
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_CLOSED [status=implemented hash=886641da609c]
    public static let OT_MD_BLOCK_CLOSED: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_SETEXT [status=implemented hash=0339b2313bb6]
    public static let OT_MD_BLOCK_SETEXT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_ORDERED [status=implemented hash=da8923f08cc4]
    public static let OT_MD_BLOCK_ORDERED: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_TIGHT [status=implemented hash=f8b1b2f367d9]
    public static let OT_MD_BLOCK_TIGHT: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_TASK [status=implemented hash=f4bb4392702e]
    public static let OT_MD_BLOCK_TASK: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_CHECKED [status=implemented hash=3cdd44007ea7]
    public static let OT_MD_BLOCK_CHECKED: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_BLANK_AFTER [status=implemented hash=e10b479fd1f4]
    public static let OT_MD_BLOCK_BLANK_AFTER: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_FENCED [status=implemented hash=269f606c2a75]
    public static let OT_MD_BLOCK_FENCED: Int64 = 128
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_HOOKED [status=implemented hash=63e900d5ecf4]
    public static let OT_MD_BLOCK_HOOKED: Int64 = 256
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_MATH [status=implemented hash=2c1cd41a5c8b]
    public static let OT_MD_BLOCK_MATH: Int64 = 512
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_HEADER [status=implemented hash=0817676f3303]
    public static let OT_MD_BLOCK_HEADER: Int64 = 1024
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_OPEN [status=implemented hash=bb0922bf5cfe]
    public static let OT_MD_BLOCK_OPEN: Int64 = 2048
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_ALIGN_LEFT [status=implemented hash=f997f534a608]
    public static let OT_MD_BLOCK_ALIGN_LEFT: Int64 = 4096
    // parity: core/src/native-abi.generated.ts#OT_MD_BLOCK_ALIGN_RIGHT [status=implemented hash=9830723cc6ba]
    public static let OT_MD_BLOCK_ALIGN_RIGHT: Int64 = 8192
    // parity: core/src/native-abi.generated.ts#OT_MD_SPAN_CODE [status=implemented hash=d741a4bb75b6]
    public static let OT_MD_SPAN_CODE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_MD_SPAN_MATH [status=implemented hash=92332adce935]
    public static let OT_MD_SPAN_MATH: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_MOVE_UP [status=implemented hash=02f9b426c7b9]
    public static let OT_EDITOR_MOVE_UP: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_MOVE_DOWN [status=implemented hash=708cfc04a463]
    public static let OT_EDITOR_MOVE_DOWN: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_GOTO_LINE_END [status=implemented hash=bac1bfde9b37]
    public static let OT_EDITOR_GOTO_LINE_END: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_DELETE_SELECTION [status=implemented hash=4c60f087f1e6]
    public static let OT_EDITOR_DELETE_SELECTION: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_CURSOR_OFFSET [status=implemented hash=8f93c6f312e3]
    public static let OT_EDITOR_CURSOR_OFFSET: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_WRAP_MODE [status=implemented hash=f8a141167c83]
    public static let OT_EDITOR_WRAP_MODE: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_TAB_INDICATOR [status=implemented hash=9bbc63ae992f]
    public static let OT_EDITOR_TAB_INDICATOR: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_SELECT_SET [status=implemented hash=ad610e529df0]
    public static let OT_EDITOR_SELECT_SET: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_SELECT_UPDATE [status=implemented hash=21051646a8c5]
    public static let OT_EDITOR_SELECT_UPDATE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_SELECT_RESET [status=implemented hash=396486d39540]
    public static let OT_EDITOR_SELECT_RESET: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_SELECT_LOCAL [status=implemented hash=16ac13a1c2d6]
    public static let OT_EDITOR_SELECT_LOCAL: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_SELECT_LOCAL_UPDATE [status=implemented hash=50e3a9faba58]
    public static let OT_EDITOR_SELECT_LOCAL_UPDATE: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_SELECT_LOCAL_RESET [status=implemented hash=81699297e637]
    public static let OT_EDITOR_SELECT_LOCAL_RESET: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_SELECT_CELL [status=implemented hash=cd4ea98c9d1d]
    public static let OT_EDITOR_SELECT_CELL: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_SELECT_OCCUPANCY [status=implemented hash=d8d73d5e626c]
    public static let OT_EDITOR_SELECT_OCCUPANCY: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_SELECT_INCLUSIVE [status=implemented hash=97c777e65a7f]
    public static let OT_EDITOR_SELECT_INCLUSIVE: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_SELECT_COLORS [status=implemented hash=04c02963ec9d]
    public static let OT_EDITOR_SELECT_COLORS: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_SELECT_DOCUMENT_SET [status=implemented hash=7890e56a919f]
    public static let OT_SELECT_DOCUMENT_SET: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SELECT_DOCUMENT_UPDATE [status=implemented hash=8df9ef792433]
    public static let OT_SELECT_DOCUMENT_UPDATE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SELECT_DOCUMENT_RESET [status=implemented hash=e66b8fced0dc]
    public static let OT_SELECT_DOCUMENT_RESET: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SELECT_VIEWPORT_SET [status=implemented hash=9ecbb82ab7a9]
    public static let OT_SELECT_VIEWPORT_SET: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_SELECT_VIEWPORT_UPDATE [status=implemented hash=188b748a68d8]
    public static let OT_SELECT_VIEWPORT_UPDATE: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SELECT_VIEWPORT_RESET [status=implemented hash=341e1b3393bc]
    public static let OT_SELECT_VIEWPORT_RESET: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_SELECTION_CELL [status=implemented hash=a1eda26b74c5]
    public static let OT_SELECTION_CELL: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SELECTION_WORD [status=implemented hash=c11aeae7d698]
    public static let OT_SELECTION_WORD: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SELECTION_LINE [status=implemented hash=482b45a64a4f]
    public static let OT_SELECTION_LINE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SELECTION_OCCUPANCY_CELL [status=implemented hash=5e187fb688a0]
    public static let OT_SELECTION_OCCUPANCY_CELL: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SELECTION_OCCUPANCY_BOUNDARY [status=implemented hash=a3db4bad8908]
    public static let OT_SELECTION_OCCUPANCY_BOUNDARY: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_POSITION_CURSOR [status=implemented hash=55aa8fa0abb0]
    public static let OT_EDITOR_POSITION_CURSOR: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_POSITION_NEXT_WORD [status=implemented hash=f1839d76f2ea]
    public static let OT_EDITOR_POSITION_NEXT_WORD: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_POSITION_PREV_WORD [status=implemented hash=8855557bfe8e]
    public static let OT_EDITOR_POSITION_PREV_WORD: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_POSITION_EOL [status=implemented hash=0c0b3418f352]
    public static let OT_EDITOR_POSITION_EOL: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_POSITION_VISUAL_SOL [status=implemented hash=023e8d61556e]
    public static let OT_EDITOR_POSITION_VISUAL_SOL: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_EDITOR_POSITION_VISUAL_EOL [status=implemented hash=0fe9fadb9959]
    public static let OT_EDITOR_POSITION_VISUAL_EOL: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FIT [status=implemented hash=871d97065323]
    public static let OT_IMAGE_FIT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_COVER [status=implemented hash=6b257e95c828]
    public static let OT_IMAGE_COVER: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FILL [status=implemented hash=62f59577bf86]
    public static let OT_IMAGE_FILL: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_PROTOCOL_AUTO [status=implemented hash=a3bd6ca79fa0]
    public static let OT_IMAGE_PROTOCOL_AUTO: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_PROTOCOL_KITTY [status=implemented hash=5cbb58f601ff]
    public static let OT_IMAGE_PROTOCOL_KITTY: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_PROTOCOL_SIXEL [status=implemented hash=861437553193]
    public static let OT_IMAGE_PROTOCOL_SIXEL: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_PROTOCOL_BLOCKS [status=implemented hash=63f667b5c4b6]
    public static let OT_IMAGE_PROTOCOL_BLOCKS: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_DRAW_SOURCE_WIDTH [status=implemented hash=e3157b6f451a]
    public static let OT_IMAGE_DRAW_SOURCE_WIDTH: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_DRAW_SOURCE_HEIGHT [status=implemented hash=5447f8eb30dd]
    public static let OT_IMAGE_DRAW_SOURCE_HEIGHT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_ENCODED_BYTES_MAX [status=implemented hash=cb5791ecbeee]
    public static let OT_IMAGE_ENCODED_BYTES_MAX: Int64 = 67108864
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FORMAT_UNKNOWN [status=implemented hash=9e9dcfa06b35]
    public static let OT_IMAGE_FORMAT_UNKNOWN: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FORMAT_PNG [status=implemented hash=4e0c935833d6]
    public static let OT_IMAGE_FORMAT_PNG: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FORMAT_RGBA [status=implemented hash=6b0e6ab7c9b7]
    public static let OT_IMAGE_FORMAT_RGBA: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FORMAT_JPEG [status=implemented hash=4dfd505195d6]
    public static let OT_IMAGE_FORMAT_JPEG: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FORMAT_WEBP [status=implemented hash=2c6234aca189]
    public static let OT_IMAGE_FORMAT_WEBP: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FORMAT_GIF [status=implemented hash=04df60974bf2]
    public static let OT_IMAGE_FORMAT_GIF: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_ASSUMED_SRGB [status=implemented hash=3e628b32b7ab]
    public static let OT_IMAGE_ASSUMED_SRGB: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_EXPLICIT_SRGB [status=implemented hash=01852dc64f3e]
    public static let OT_IMAGE_EXPLICIT_SRGB: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_RGBA8 [status=implemented hash=9554c4da2e56]
    public static let OT_IMAGE_RGBA8: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_BGRA8 [status=implemented hash=78a68c5a41f4]
    public static let OT_IMAGE_BGRA8: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_ALPHA_STRAIGHT [status=implemented hash=6229780065d1]
    public static let OT_IMAGE_ALPHA_STRAIGHT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_ALPHA_OPAQUE [status=implemented hash=07887e9203ff]
    public static let OT_IMAGE_ALPHA_OPAQUE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FILTER_DEFAULT [status=implemented hash=20907e49331c]
    public static let OT_IMAGE_FILTER_DEFAULT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FILTER_AREA [status=implemented hash=70b574aef46b]
    public static let OT_IMAGE_FILTER_AREA: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FILTER_TRIANGLE [status=implemented hash=89b918194686]
    public static let OT_IMAGE_FILTER_TRIANGLE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FILTER_CUBIC_BSPLINE [status=implemented hash=e226c1a4891c]
    public static let OT_IMAGE_FILTER_CUBIC_BSPLINE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FILTER_CATMULL_ROM [status=implemented hash=629e4782b12c]
    public static let OT_IMAGE_FILTER_CATMULL_ROM: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FILTER_MITCHELL [status=implemented hash=ccb886da3185]
    public static let OT_IMAGE_FILTER_MITCHELL: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FILTER_NEAREST [status=implemented hash=8681529a80da]
    public static let OT_IMAGE_FILTER_NEAREST: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_ROTATE_90 [status=implemented hash=cedb31abffca]
    public static let OT_IMAGE_ROTATE_90: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_ROTATE_180 [status=implemented hash=771356e456b2]
    public static let OT_IMAGE_ROTATE_180: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_ROTATE_270 [status=implemented hash=2f33e589c9c5]
    public static let OT_IMAGE_ROTATE_270: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FLIP [status=implemented hash=6a258f70a40f]
    public static let OT_IMAGE_FLIP: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_FLOP [status=implemented hash=8d27c1574213]
    public static let OT_IMAGE_FLOP: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_BLEND_SOURCE_OVER [status=implemented hash=44f83b271ffd]
    public static let OT_IMAGE_BLEND_SOURCE_OVER: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_BLEND_SOURCE [status=implemented hash=8d402fcbfd88]
    public static let OT_IMAGE_BLEND_SOURCE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_IMAGE_BLEND_DESTINATION_OVER [status=implemented hash=e2af135a16e9]
    public static let OT_IMAGE_BLEND_DESTINATION_OVER: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_VIDEO_OPEN_NO_AUDIO [status=implemented hash=b9090bdb69cc]
    public static let OT_VIDEO_OPEN_NO_AUDIO: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_VIDEO_PLAYING [status=implemented hash=1d75d16b5bd3]
    public static let OT_VIDEO_PLAYING: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_VIDEO_ENDED [status=implemented hash=8b436d13314f]
    public static let OT_VIDEO_ENDED: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_VIDEO_BUFFERING [status=implemented hash=df92bf1eafeb]
    public static let OT_VIDEO_BUFFERING: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_VIDEO_AUDIO [status=implemented hash=32c67fede9b4]
    public static let OT_VIDEO_AUDIO: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_VIDEO_HAS_FRAME [status=implemented hash=a28dbd05369c]
    public static let OT_VIDEO_HAS_FRAME: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_VIDEO_ERROR [status=implemented hash=dec34ab1ac22]
    public static let OT_VIDEO_ERROR: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_AUDIO_START_NO_DEVICE [status=implemented hash=fadf1df84150]
    public static let OT_AUDIO_START_NO_DEVICE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_TEXT_VIEW_WRAP_WIDTH [status=implemented hash=20a0b704fe22]
    public static let OT_TEXT_VIEW_WRAP_WIDTH: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_TEXT_VIEW_WRAP_MODE [status=implemented hash=a161013d2031]
    public static let OT_TEXT_VIEW_WRAP_MODE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_TEXT_VIEW_FIRST_LINE_OFFSET [status=implemented hash=177879335027]
    public static let OT_TEXT_VIEW_FIRST_LINE_OFFSET: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_TEXT_VIEW_TAB_INDICATOR [status=implemented hash=830482f669c7]
    public static let OT_TEXT_VIEW_TAB_INDICATOR: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_TEXT_VIEW_TRUNCATE [status=implemented hash=bfc38caf86ea]
    public static let OT_TEXT_VIEW_TRUNCATE: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_TEXT_VIEW_TEXT_ALIGN [status=implemented hash=97a28eab9965]
    public static let OT_TEXT_VIEW_TEXT_ALIGN: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_TEXT_REPLACEMENT_COUNT_MAX [status=implemented hash=ce404aa9e442]
    public static let OT_TEXT_REPLACEMENT_COUNT_MAX: Int64 = 256
    // parity: core/src/native-abi.generated.ts#OT_TEXT_REPLACEMENT_CHUNKS_MAX [status=implemented hash=a0909ceac6d5]
    public static let OT_TEXT_REPLACEMENT_CHUNKS_MAX: Int64 = 4096
    // parity: core/src/native-abi.generated.ts#OT_TEXT_REPLACEMENT_BYTES_MAX [status=implemented hash=09af2d1a5b27]
    public static let OT_TEXT_REPLACEMENT_BYTES_MAX: Int64 = 4194304
    // parity: core/src/native-abi.generated.ts#OT_TEXT_REPLACEMENT_URL_BYTES_MAX [status=implemented hash=1d3713be725e]
    public static let OT_TEXT_REPLACEMENT_URL_BYTES_MAX: Int64 = 1048576
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_TEXT_BYTES_MAX [status=implemented hash=0428c16b843d]
    public static let OT_BUFFER_TEXT_BYTES_MAX: Int64 = 65536
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_CLEAR [status=implemented hash=a23d428d7dad]
    public static let OT_BUFFER_DRAW_CLEAR: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_FILL [status=implemented hash=4e86b9b7df20]
    public static let OT_BUFFER_DRAW_FILL: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_TEXT [status=implemented hash=78ac67804e0e]
    public static let OT_BUFFER_DRAW_TEXT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_CELL [status=implemented hash=1df966af2084]
    public static let OT_BUFFER_DRAW_CELL: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_CELL_BLEND [status=implemented hash=9629e84d9857]
    public static let OT_BUFFER_DRAW_CELL_BLEND: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_CHAR [status=implemented hash=2cbd52588086]
    public static let OT_BUFFER_DRAW_CHAR: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_BOX [status=implemented hash=9ad57cb2d072]
    public static let OT_BUFFER_DRAW_BOX: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_COMPOSE [status=implemented hash=ebe494e8cc8a]
    public static let OT_BUFFER_DRAW_COMPOSE: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_RESPECT_ALPHA [status=implemented hash=c64348ed9451]
    public static let OT_BUFFER_DRAW_RESPECT_ALPHA: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_HAS_BACKGROUND [status=implemented hash=745e038f5dcf]
    public static let OT_BUFFER_DRAW_HAS_BACKGROUND: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_HAS_SOURCE_WIDTH [status=implemented hash=52ae8f8b6319]
    public static let OT_BUFFER_DRAW_HAS_SOURCE_WIDTH: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_HAS_SOURCE_HEIGHT [status=implemented hash=cf58513b89b5]
    public static let OT_BUFFER_DRAW_HAS_SOURCE_HEIGHT: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_DRAW_FIT_ELLIPSIS [status=implemented hash=db985d2d5b2c]
    public static let OT_BUFFER_DRAW_FIT_ELLIPSIS: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_STACK_DEPTH_MAX [status=implemented hash=3a469dd8c3e3]
    public static let OT_BUFFER_STACK_DEPTH_MAX: Int64 = 256
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_STACK_GET_OPACITY [status=implemented hash=71bcf0901b40]
    public static let OT_BUFFER_STACK_GET_OPACITY: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_STACK_PUSH_SCISSOR [status=implemented hash=a5ff6b0f51e1]
    public static let OT_BUFFER_STACK_PUSH_SCISSOR: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_STACK_POP_SCISSOR [status=implemented hash=33e1e8155f04]
    public static let OT_BUFFER_STACK_POP_SCISSOR: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_STACK_CLEAR_SCISSORS [status=implemented hash=216308c98b14]
    public static let OT_BUFFER_STACK_CLEAR_SCISSORS: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_STACK_PUSH_OPACITY [status=implemented hash=6cbef6846674]
    public static let OT_BUFFER_STACK_PUSH_OPACITY: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_STACK_POP_OPACITY [status=implemented hash=a4d8edd33125]
    public static let OT_BUFFER_STACK_POP_OPACITY: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_STACK_CLEAR_OPACITY [status=implemented hash=104b8eb47f18]
    public static let OT_BUFFER_STACK_CLEAR_OPACITY: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_GRID_INNER [status=implemented hash=462f8ac70f24]
    public static let OT_BUFFER_GRID_INNER: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_BUFFER_GRID_OUTER [status=implemented hash=acd14eacb494]
    public static let OT_BUFFER_GRID_OUTER: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_CELL_CHAR_KIND_MASK [status=implemented hash=035c7f35247f]
    public static let OT_CELL_CHAR_KIND_MASK: Int64 = 3221225472
    // parity: core/src/native-abi.generated.ts#OT_CELL_CHAR_IMAGE [status=implemented hash=4ae742d4a057]
    public static let OT_CELL_CHAR_IMAGE: Int64 = 1073741824
    // parity: core/src/native-abi.generated.ts#OT_CELL_CHAR_GRAPHEME [status=implemented hash=c8dfa7f7bac3]
    public static let OT_CELL_CHAR_GRAPHEME: Int64 = 2147483648
    // parity: core/src/native-abi.generated.ts#OT_CELL_CHAR_CONTINUATION [status=implemented hash=4ec6ae21a7e8]
    public static let OT_CELL_CHAR_CONTINUATION: Int64 = 3221225472
    // parity: core/src/native-abi.generated.ts#OT_SESSION_CONTROL_PACKET_BYTES [status=implemented hash=d4b440ed0ca6]
    public static let OT_SESSION_CONTROL_PACKET_BYTES: Int64 = 4096
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_ALTERNATE_SCREEN [status=implemented hash=763406826a0f]
    public static let OT_TERMINAL_ALTERNATE_SCREEN: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_MOUSE [status=implemented hash=4a938d28dc10]
    public static let OT_TERMINAL_MOUSE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_MOUSE_MOVEMENT [status=implemented hash=d2803a569857]
    public static let OT_TERMINAL_MOUSE_MOVEMENT: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_CLEAR_ON_CLOSE [status=implemented hash=04d0353cb85d]
    public static let OT_TERMINAL_CLEAR_ON_CLOSE: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_REPLY_SENTINEL [status=implemented hash=169bab5037cd]
    public static let OT_TERMINAL_REPLY_SENTINEL: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_SYNC_ALWAYS [status=implemented hash=a2891ad19e9a]
    public static let OT_TERMINAL_SYNC_ALWAYS: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_SYNC_NEVER [status=implemented hash=a1e7353c4d5f]
    public static let OT_TERMINAL_SYNC_NEVER: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_HOST_MULTIPLEXER [status=implemented hash=07faa6e77b92]
    public static let OT_TERMINAL_HOST_MULTIPLEXER: Int64 = 128
    // parity: core/src/native-abi.generated.ts#OT_KITTY_KEYBOARD_DISAMBIGUATE [status=implemented hash=40887df4638b]
    public static let OT_KITTY_KEYBOARD_DISAMBIGUATE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_KITTY_KEYBOARD_EVENT_TYPES [status=implemented hash=3bdfda20d74e]
    public static let OT_KITTY_KEYBOARD_EVENT_TYPES: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_KITTY_KEYBOARD_ALTERNATE_KEYS [status=implemented hash=9334f8ee33cd]
    public static let OT_KITTY_KEYBOARD_ALTERNATE_KEYS: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_KITTY_KEYBOARD_ALL_KEYS_AS_ESCAPES [status=implemented hash=85cd712d71dd]
    public static let OT_KITTY_KEYBOARD_ALL_KEYS_AS_ESCAPES: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_KITTY_KEYBOARD_REPORT_TEXT [status=implemented hash=307e1a14ad6d]
    public static let OT_KITTY_KEYBOARD_REPORT_TEXT: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_KITTY_KEYBOARD_ALL [status=implemented hash=a012dfc6c449]
    public static let OT_KITTY_KEYBOARD_ALL: Int64 = 31
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_CAPABILITY_RESPONSE [status=implemented hash=397a70aca08a]
    public static let OT_CONTROL_CAPABILITY_RESPONSE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_TITLE [status=implemented hash=459d347985f1]
    public static let OT_CONTROL_TITLE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_MOUSE [status=implemented hash=4a2c4e0e8767]
    public static let OT_CONTROL_MOUSE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_KITTY_KEYBOARD_FLAGS [status=implemented hash=cb739be5a4ed]
    public static let OT_CONTROL_KITTY_KEYBOARD_FLAGS: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_RESTORE_MODES [status=implemented hash=4a4cbf5195c4]
    public static let OT_CONTROL_RESTORE_MODES: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_QUERY_PIXEL_RESOLUTION [status=implemented hash=1828206423f6]
    public static let OT_CONTROL_QUERY_PIXEL_RESOLUTION: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_QUERY_THEME_COLORS [status=implemented hash=f599d959ea20]
    public static let OT_CONTROL_QUERY_THEME_COLORS: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_CURSOR [status=implemented hash=cdb1637f5da1]
    public static let OT_CONTROL_CURSOR: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_RESET_BACKGROUND [status=implemented hash=e91cd20e43d1]
    public static let OT_CONTROL_RESET_BACKGROUND: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_PALETTE_QUERY [status=implemented hash=d5b4b0dc70a7]
    public static let OT_CONTROL_PALETTE_QUERY: Int64 = 10
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_PROGRAM_STATUS [status=implemented hash=d5807767c241]
    public static let OT_CONTROL_PROGRAM_STATUS: Int64 = 11
    // parity: core/src/native-abi.generated.ts#OT_CONTROL_END_REPLY_SENTINEL [status=implemented hash=ed365e330f8e]
    public static let OT_CONTROL_END_REPLY_SENTINEL: Int64 = 12
    // parity: core/src/native-abi.generated.ts#OT_CURSOR_POSITION [status=implemented hash=0698b9918869]
    public static let OT_CURSOR_POSITION: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CURSOR_STYLE [status=implemented hash=6a13a59dfe38]
    public static let OT_CURSOR_STYLE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_CURSOR_BLINKING [status=implemented hash=cdd647e8281f]
    public static let OT_CURSOR_BLINKING: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_CURSOR_COLOR [status=implemented hash=647e6f84d19e]
    public static let OT_CURSOR_COLOR: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_CURSOR_MOUSE_POINTER [status=implemented hash=9ffbae413811]
    public static let OT_CURSOR_MOUSE_POINTER: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_PROGRAM_STATE_IDLE [status=implemented hash=b9a32f5fe2ca]
    public static let OT_PROGRAM_STATE_IDLE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_PROGRAM_STATE_WORKING [status=implemented hash=596967a37f81]
    public static let OT_PROGRAM_STATE_WORKING: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_PROGRAM_STATE_DONE [status=implemented hash=f42e47e580e3]
    public static let OT_PROGRAM_STATE_DONE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_PROGRAM_STATE_BLOCKED [status=implemented hash=1709b7749a69]
    public static let OT_PROGRAM_STATE_BLOCKED: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_PROGRAM_STATE_ERROR [status=implemented hash=476e5e23f423]
    public static let OT_PROGRAM_STATE_ERROR: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_PROGRAM_STATE_CLEAR [status=implemented hash=06b617684f40]
    public static let OT_PROGRAM_STATE_CLEAR: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_PROGRAM_KIND_PERMISSION [status=implemented hash=3d1a9f22eefb]
    public static let OT_PROGRAM_KIND_PERMISSION: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_PROGRAM_KIND_QUESTION [status=implemented hash=fe1fda4fb62c]
    public static let OT_PROGRAM_KIND_QUESTION: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_PROGRAM_KIND_AUTH [status=implemented hash=4196d3260e5e]
    public static let OT_PROGRAM_KIND_AUTH: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_PROGRAM_STATUS_PROGRESS [status=implemented hash=711a38d6ea24]
    public static let OT_PROGRAM_STATUS_PROGRESS: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CAP_KITTY_KEYBOARD [status=implemented hash=e238b23dc593]
    public static let OT_CAP_KITTY_KEYBOARD: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CAP_KITTY_GRAPHICS [status=implemented hash=79f120d8be22]
    public static let OT_CAP_KITTY_GRAPHICS: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_CAP_RGB [status=implemented hash=ac847e6be3c0]
    public static let OT_CAP_RGB: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_CAP_ANSI256 [status=implemented hash=ee3f9551ffb7]
    public static let OT_CAP_ANSI256: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_CAP_SGR_PIXELS [status=implemented hash=bed861870731]
    public static let OT_CAP_SGR_PIXELS: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_CAP_COLOR_SCHEME_UPDATES [status=implemented hash=a9f1b245cfbc]
    public static let OT_CAP_COLOR_SCHEME_UPDATES: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_CAP_EXPLICIT_WIDTH [status=implemented hash=db6953f91e97]
    public static let OT_CAP_EXPLICIT_WIDTH: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_CAP_SCALED_TEXT [status=implemented hash=332c7ed34ae2]
    public static let OT_CAP_SCALED_TEXT: Int64 = 128
    // parity: core/src/native-abi.generated.ts#OT_CAP_SIXEL [status=implemented hash=cad2fed162a6]
    public static let OT_CAP_SIXEL: Int64 = 256
    // parity: core/src/native-abi.generated.ts#OT_CAP_FOCUS_TRACKING [status=implemented hash=8e1a286219ca]
    public static let OT_CAP_FOCUS_TRACKING: Int64 = 512
    // parity: core/src/native-abi.generated.ts#OT_CAP_SYNC [status=implemented hash=456ac9829200]
    public static let OT_CAP_SYNC: Int64 = 1024
    // parity: core/src/native-abi.generated.ts#OT_CAP_BRACKETED_PASTE [status=implemented hash=a0acb8608d4d]
    public static let OT_CAP_BRACKETED_PASTE: Int64 = 2048
    // parity: core/src/native-abi.generated.ts#OT_CAP_HYPERLINKS [status=implemented hash=9705f4e540c3]
    public static let OT_CAP_HYPERLINKS: Int64 = 4096
    // parity: core/src/native-abi.generated.ts#OT_CAP_OSC52 [status=implemented hash=5ea28514f7c9]
    public static let OT_CAP_OSC52: Int64 = 8192
    // parity: core/src/native-abi.generated.ts#OT_CAP_NOTIFICATIONS [status=implemented hash=8b3129462b04]
    public static let OT_CAP_NOTIFICATIONS: Int64 = 16384
    // parity: core/src/native-abi.generated.ts#OT_CAP_EXPLICIT_CURSOR_POSITIONING [status=implemented hash=af1bb7eb8cd3]
    public static let OT_CAP_EXPLICIT_CURSOR_POSITIONING: Int64 = 32768
    // parity: core/src/native-abi.generated.ts#OT_CAP_REMOTE [status=implemented hash=1bc7f5343d93]
    public static let OT_CAP_REMOTE: Int64 = 65536
    // parity: core/src/native-abi.generated.ts#OT_CAP_PROGRAM_STATUS [status=implemented hash=0feb5ed1a428]
    public static let OT_CAP_PROGRAM_STATUS: Int64 = 131072
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_UNINITIALIZED [status=implemented hash=7c3b8ef9edeb]
    public static let OT_TERMINAL_UNINITIALIZED: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_SETTING_UP [status=implemented hash=fb82c95a19e8]
    public static let OT_TERMINAL_SETTING_UP: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_ACTIVE [status=implemented hash=904faf59c5ba]
    public static let OT_TERMINAL_ACTIVE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_SUSPENDING [status=implemented hash=72106b5c3590]
    public static let OT_TERMINAL_SUSPENDING: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_SUSPENDED [status=implemented hash=4ab40cbaa01e]
    public static let OT_TERMINAL_SUSPENDED: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_RESUMING [status=implemented hash=88882236a50d]
    public static let OT_TERMINAL_RESUMING: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_CLOSING [status=implemented hash=82c73196cc5a]
    public static let OT_TERMINAL_CLOSING: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_RESTORED [status=implemented hash=d979d50b653a]
    public static let OT_TERMINAL_RESTORED: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_FAILED [status=implemented hash=0dd2f1d9b005]
    public static let OT_TERMINAL_FAILED: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_TERMINAL_CANCELLED [status=implemented hash=502aa9d34faa]
    public static let OT_TERMINAL_CANCELLED: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_PUMP_IDLE [status=implemented hash=bfaa00579ce4]
    public static let OT_PUMP_IDLE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_PUMP_AGAIN [status=implemented hash=ca1c4edb17d9]
    public static let OT_PUMP_AGAIN: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_PUMP_OUTPUT_PENDING [status=implemented hash=3a396ab18c72]
    public static let OT_PUMP_OUTPUT_PENDING: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_PUMP_WAIT_UNTIL [status=implemented hash=5926a75e744b]
    public static let OT_PUMP_WAIT_UNTIL: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_PUMP_CLOSED [status=implemented hash=73ac66a05b43]
    public static let OT_PUMP_CLOSED: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_STDOUT_IDLE [status=implemented hash=03d517bb4c85]
    public static let OT_STDOUT_IDLE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_STDOUT_IN_FLIGHT [status=implemented hash=b9e45d8385c5]
    public static let OT_STDOUT_IN_FLIGHT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY [status=implemented hash=f48d3223287f]
    public static let OT_INPUT_KEY: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOUSE [status=implemented hash=39fb2c7760e3]
    public static let OT_INPUT_MOUSE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_INPUT_PASTE [status=implemented hash=7fc42e5258b2]
    public static let OT_INPUT_PASTE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_INPUT_FOCUS [status=implemented hash=deb73ce42faf]
    public static let OT_INPUT_FOCUS: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_INPUT_REPLY [status=implemented hash=dc7346686e22]
    public static let OT_INPUT_REPLY: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_PRESS [status=implemented hash=23c98778c778]
    public static let OT_INPUT_KEY_PRESS: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_REPEAT [status=implemented hash=045503dc4f3f]
    public static let OT_INPUT_KEY_REPEAT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_RELEASE [status=implemented hash=cb60f9fe82fc]
    public static let OT_INPUT_KEY_RELEASE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOUSE_DOWN [status=implemented hash=13b954498037]
    public static let OT_INPUT_MOUSE_DOWN: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOUSE_UP [status=implemented hash=eb97067b2ee8]
    public static let OT_INPUT_MOUSE_UP: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOUSE_MOVE [status=implemented hash=c7cfe085ac66]
    public static let OT_INPUT_MOUSE_MOVE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOUSE_DRAG [status=implemented hash=cd872fbd1cd5]
    public static let OT_INPUT_MOUSE_DRAG: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOUSE_SCROLL [status=implemented hash=12fc00f3ad5f]
    public static let OT_INPUT_MOUSE_SCROLL: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOUSE_BUTTON_NONE [status=implemented hash=dba479e89c6f]
    public static let OT_INPUT_MOUSE_BUTTON_NONE: Int64 = 255
    // parity: core/src/native-abi.generated.ts#OT_INPUT_FOCUS_OUT [status=implemented hash=c4dbf9b646f8]
    public static let OT_INPUT_FOCUS_OUT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_INPUT_FOCUS_IN [status=implemented hash=b292d032d42e]
    public static let OT_INPUT_FOCUS_IN: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOD_SHIFT [status=implemented hash=1112a77d42dd]
    public static let OT_INPUT_MOD_SHIFT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOD_ALT [status=implemented hash=9a0e5f2b89f1]
    public static let OT_INPUT_MOD_ALT: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOD_CTRL [status=implemented hash=46ff05240f05]
    public static let OT_INPUT_MOD_CTRL: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOD_SUPER [status=implemented hash=82968e6e557b]
    public static let OT_INPUT_MOD_SUPER: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOD_HYPER [status=implemented hash=a3c8666e96a4]
    public static let OT_INPUT_MOD_HYPER: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOD_META [status=implemented hash=6974b1a185e7]
    public static let OT_INPUT_MOD_META: Int64 = 32
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOD_CAPS_LOCK [status=implemented hash=30431124a77e]
    public static let OT_INPUT_MOD_CAPS_LOCK: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_INPUT_MOD_NUM_LOCK [status=implemented hash=54bcd07a1660]
    public static let OT_INPUT_MOD_NUM_LOCK: Int64 = 128
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KITTY [status=implemented hash=b1eaeac53159]
    public static let OT_INPUT_KEY_KITTY: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_TEXT_TRUNCATED [status=implemented hash=77eef9386aee]
    public static let OT_INPUT_KEY_TEXT_TRUNCATED: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_TYPED [status=implemented hash=bd85716acaff]
    public static let OT_INPUT_KEY_TYPED: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_INPUT_PASTE_START [status=implemented hash=f1e07781a3eb]
    public static let OT_INPUT_PASTE_START: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_PASTE_END [status=implemented hash=4dbb1a7b82c8]
    public static let OT_INPUT_PASTE_END: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_INPUT_REPLY_FRAGMENT [status=implemented hash=96755c93690e]
    public static let OT_INPUT_REPLY_FRAGMENT: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_REPLY_CURSOR_POSITION [status=implemented hash=fe70e158f9c9]
    public static let OT_INPUT_REPLY_CURSOR_POSITION: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_INPUT_REPLY_CSI [status=implemented hash=142c33520061]
    public static let OT_INPUT_REPLY_CSI: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_REPLY_SS3 [status=implemented hash=696096333161]
    public static let OT_INPUT_REPLY_SS3: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_INPUT_REPLY_OSC [status=implemented hash=12da5d7a6f35]
    public static let OT_INPUT_REPLY_OSC: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_INPUT_REPLY_DCS [status=implemented hash=ff87d991946e]
    public static let OT_INPUT_REPLY_DCS: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_INPUT_REPLY_APC [status=implemented hash=80d3009e96e6]
    public static let OT_INPUT_REPLY_APC: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_ESCAPE [status=implemented hash=c5cd17ea6f60]
    public static let OT_INPUT_KEY_ESCAPE: Int64 = 27
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_ENTER [status=implemented hash=cae76a8cdf85]
    public static let OT_INPUT_KEY_ENTER: Int64 = 13
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_TAB [status=implemented hash=0e7c730be526]
    public static let OT_INPUT_KEY_TAB: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_BACKSPACE [status=implemented hash=8c465af39e4c]
    public static let OT_INPUT_KEY_BACKSPACE: Int64 = 127
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_INSERT [status=implemented hash=967ecbb6525b]
    public static let OT_INPUT_KEY_INSERT: Int64 = 57348
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_DELETE [status=implemented hash=0f20417a7d1e]
    public static let OT_INPUT_KEY_DELETE: Int64 = 57349
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_LEFT [status=implemented hash=9b074514f626]
    public static let OT_INPUT_KEY_LEFT: Int64 = 57350
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_RIGHT [status=implemented hash=3a9d287c9609]
    public static let OT_INPUT_KEY_RIGHT: Int64 = 57351
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_UP [status=implemented hash=f745cb882fba]
    public static let OT_INPUT_KEY_UP: Int64 = 57352
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_DOWN [status=implemented hash=23b9950d0b70]
    public static let OT_INPUT_KEY_DOWN: Int64 = 57353
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_PAGE_UP [status=implemented hash=059348f6c9d5]
    public static let OT_INPUT_KEY_PAGE_UP: Int64 = 57354
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_PAGE_DOWN [status=implemented hash=1382f3786a30]
    public static let OT_INPUT_KEY_PAGE_DOWN: Int64 = 57355
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_HOME [status=implemented hash=1aa5742a040b]
    public static let OT_INPUT_KEY_HOME: Int64 = 57356
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_END [status=implemented hash=2b12f2d4b145]
    public static let OT_INPUT_KEY_END: Int64 = 57357
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_CAPS_LOCK [status=implemented hash=e777390ea187]
    public static let OT_INPUT_KEY_CAPS_LOCK: Int64 = 57358
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_SCROLL_LOCK [status=implemented hash=834b854d346d]
    public static let OT_INPUT_KEY_SCROLL_LOCK: Int64 = 57359
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_NUM_LOCK [status=implemented hash=1caa8581e578]
    public static let OT_INPUT_KEY_NUM_LOCK: Int64 = 57360
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_PRINT_SCREEN [status=implemented hash=5c844a579f5a]
    public static let OT_INPUT_KEY_PRINT_SCREEN: Int64 = 57361
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_PAUSE [status=implemented hash=021c746f163b]
    public static let OT_INPUT_KEY_PAUSE: Int64 = 57362
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MENU [status=implemented hash=5b4638565db5]
    public static let OT_INPUT_KEY_MENU: Int64 = 57363
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_F1 [status=implemented hash=c652ab78070b]
    public static let OT_INPUT_KEY_F1: Int64 = 57364
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_F35 [status=implemented hash=3b810f8aa013]
    public static let OT_INPUT_KEY_F35: Int64 = 57398
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_0 [status=implemented hash=7db42c8dc69b]
    public static let OT_INPUT_KEY_KP_0: Int64 = 57399
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_9 [status=implemented hash=6ba43fc01eae]
    public static let OT_INPUT_KEY_KP_9: Int64 = 57408
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_DECIMAL [status=implemented hash=f8f29ed13fdb]
    public static let OT_INPUT_KEY_KP_DECIMAL: Int64 = 57409
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_DIVIDE [status=implemented hash=c5ef1c41c3f5]
    public static let OT_INPUT_KEY_KP_DIVIDE: Int64 = 57410
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_MULTIPLY [status=implemented hash=f784a44f9b47]
    public static let OT_INPUT_KEY_KP_MULTIPLY: Int64 = 57411
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_SUBTRACT [status=implemented hash=b60b947466eb]
    public static let OT_INPUT_KEY_KP_SUBTRACT: Int64 = 57412
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_ADD [status=implemented hash=778595c4cdb2]
    public static let OT_INPUT_KEY_KP_ADD: Int64 = 57413
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_ENTER [status=implemented hash=eb4f8ea9a4b7]
    public static let OT_INPUT_KEY_KP_ENTER: Int64 = 57414
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_EQUAL [status=implemented hash=af3bc0397725]
    public static let OT_INPUT_KEY_KP_EQUAL: Int64 = 57415
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_SEPARATOR [status=implemented hash=4fc82458980a]
    public static let OT_INPUT_KEY_KP_SEPARATOR: Int64 = 57416
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_LEFT [status=implemented hash=005577594abb]
    public static let OT_INPUT_KEY_KP_LEFT: Int64 = 57417
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_RIGHT [status=implemented hash=e46b65937c7e]
    public static let OT_INPUT_KEY_KP_RIGHT: Int64 = 57418
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_UP [status=implemented hash=5021bfcb549e]
    public static let OT_INPUT_KEY_KP_UP: Int64 = 57419
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_DOWN [status=implemented hash=813c4446ea35]
    public static let OT_INPUT_KEY_KP_DOWN: Int64 = 57420
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_PAGE_UP [status=implemented hash=7d4844b602e7]
    public static let OT_INPUT_KEY_KP_PAGE_UP: Int64 = 57421
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_PAGE_DOWN [status=implemented hash=5036903ff8af]
    public static let OT_INPUT_KEY_KP_PAGE_DOWN: Int64 = 57422
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_HOME [status=implemented hash=a909af182528]
    public static let OT_INPUT_KEY_KP_HOME: Int64 = 57423
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_END [status=implemented hash=91014d963223]
    public static let OT_INPUT_KEY_KP_END: Int64 = 57424
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_INSERT [status=implemented hash=dda4620b0359]
    public static let OT_INPUT_KEY_KP_INSERT: Int64 = 57425
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_DELETE [status=implemented hash=d64faaf80951]
    public static let OT_INPUT_KEY_KP_DELETE: Int64 = 57426
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_KP_BEGIN [status=implemented hash=cf1a2e9ca918]
    public static let OT_INPUT_KEY_KP_BEGIN: Int64 = 57427
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MEDIA_PLAY [status=implemented hash=f83b80e5b4ed]
    public static let OT_INPUT_KEY_MEDIA_PLAY: Int64 = 57428
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MEDIA_PAUSE [status=implemented hash=fee7292ca972]
    public static let OT_INPUT_KEY_MEDIA_PAUSE: Int64 = 57429
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MEDIA_PLAY_PAUSE [status=implemented hash=7947be7c994b]
    public static let OT_INPUT_KEY_MEDIA_PLAY_PAUSE: Int64 = 57430
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MEDIA_REVERSE [status=implemented hash=7ae8f63ebd8a]
    public static let OT_INPUT_KEY_MEDIA_REVERSE: Int64 = 57431
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MEDIA_STOP [status=implemented hash=c71b25b99a15]
    public static let OT_INPUT_KEY_MEDIA_STOP: Int64 = 57432
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MEDIA_FAST_FORWARD [status=implemented hash=0d5ba6285433]
    public static let OT_INPUT_KEY_MEDIA_FAST_FORWARD: Int64 = 57433
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MEDIA_REWIND [status=implemented hash=25c8224d22be]
    public static let OT_INPUT_KEY_MEDIA_REWIND: Int64 = 57434
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MEDIA_TRACK_NEXT [status=implemented hash=d7fa304a8bf7]
    public static let OT_INPUT_KEY_MEDIA_TRACK_NEXT: Int64 = 57435
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MEDIA_TRACK_PREVIOUS [status=implemented hash=6ae577b95521]
    public static let OT_INPUT_KEY_MEDIA_TRACK_PREVIOUS: Int64 = 57436
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MEDIA_RECORD [status=implemented hash=02605aad779a]
    public static let OT_INPUT_KEY_MEDIA_RECORD: Int64 = 57437
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_LOWER_VOLUME [status=implemented hash=5997a6ac1290]
    public static let OT_INPUT_KEY_LOWER_VOLUME: Int64 = 57438
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_RAISE_VOLUME [status=implemented hash=f658800cadfe]
    public static let OT_INPUT_KEY_RAISE_VOLUME: Int64 = 57439
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_MUTE_VOLUME [status=implemented hash=692fa2a4c4be]
    public static let OT_INPUT_KEY_MUTE_VOLUME: Int64 = 57440
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_LEFT_SHIFT [status=implemented hash=170e607ab91f]
    public static let OT_INPUT_KEY_LEFT_SHIFT: Int64 = 57441
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_LEFT_CONTROL [status=implemented hash=3845daca9bee]
    public static let OT_INPUT_KEY_LEFT_CONTROL: Int64 = 57442
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_LEFT_ALT [status=implemented hash=e63ddb828e0f]
    public static let OT_INPUT_KEY_LEFT_ALT: Int64 = 57443
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_LEFT_SUPER [status=implemented hash=072db50543dd]
    public static let OT_INPUT_KEY_LEFT_SUPER: Int64 = 57444
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_LEFT_HYPER [status=implemented hash=f1a745bade3e]
    public static let OT_INPUT_KEY_LEFT_HYPER: Int64 = 57445
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_LEFT_META [status=implemented hash=65c6922b77b7]
    public static let OT_INPUT_KEY_LEFT_META: Int64 = 57446
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_RIGHT_SHIFT [status=implemented hash=0de4ecbfaf8a]
    public static let OT_INPUT_KEY_RIGHT_SHIFT: Int64 = 57447
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_RIGHT_CONTROL [status=implemented hash=c3cf43b61d04]
    public static let OT_INPUT_KEY_RIGHT_CONTROL: Int64 = 57448
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_RIGHT_ALT [status=implemented hash=d7c64af6f807]
    public static let OT_INPUT_KEY_RIGHT_ALT: Int64 = 57449
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_RIGHT_SUPER [status=implemented hash=21e0b1b40819]
    public static let OT_INPUT_KEY_RIGHT_SUPER: Int64 = 57450
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_RIGHT_HYPER [status=implemented hash=2dcd8024fdcb]
    public static let OT_INPUT_KEY_RIGHT_HYPER: Int64 = 57451
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_RIGHT_META [status=implemented hash=6a70c12dd544]
    public static let OT_INPUT_KEY_RIGHT_META: Int64 = 57452
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_ISO_LEVEL3_SHIFT [status=implemented hash=e9d2897aa6c0]
    public static let OT_INPUT_KEY_ISO_LEVEL3_SHIFT: Int64 = 57453
    // parity: core/src/native-abi.generated.ts#OT_INPUT_KEY_ISO_LEVEL5_SHIFT [status=implemented hash=14922a3f934b]
    public static let OT_INPUT_KEY_ISO_LEVEL5_SHIFT: Int64 = 57454
    // parity: core/src/native-abi.generated.ts#OT_INPUT_EXPECT_REPLIES [status=implemented hash=e33ac2e21ffd]
    public static let OT_INPUT_EXPECT_REPLIES: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_INPUT_EXPECT_KITTY_KEYBOARD [status=implemented hash=3ecead4b7f38]
    public static let OT_INPUT_EXPECT_KITTY_KEYBOARD: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_INPUT_EXPECT_CURSOR_POSITION [status=implemented hash=1e2f171eaf6a]
    public static let OT_INPUT_EXPECT_CURSOR_POSITION: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_INPUT_EXPECT_SENTINEL [status=implemented hash=1ff82cc40acf]
    public static let OT_INPUT_EXPECT_SENTINEL: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_INPUT_EXPECT_ESCAPE_PREFIX [status=implemented hash=333c0fc987c0]
    public static let OT_INPUT_EXPECT_ESCAPE_PREFIX: Int64 = 16
    // parity: core/src/native-abi.generated.ts#OT_INPUT_EVENTS_MIN [status=implemented hash=8c5305b8b540]
    public static let OT_INPUT_EVENTS_MIN: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_INPUT_PAYLOAD_BYTES_MIN [status=implemented hash=60624d998313]
    public static let OT_INPUT_PAYLOAD_BYTES_MIN: Int64 = 4384
    // parity: core/src/native-abi.generated.ts#OT_INPUT_TIMEOUT_NS [status=implemented hash=3245230e4d6e]
    public static let OT_INPUT_TIMEOUT_NS: Int64 = 20000000
    // parity: core/src/native-abi.generated.ts#OT_DIAGNOSTIC_MESSAGE_BYTES [status=implemented hash=76bfd47bc1ab]
    public static let OT_DIAGNOSTIC_MESSAGE_BYTES: Int64 = 4096
    // parity: core/src/native-abi.generated.ts#OT_DIAGNOSTIC_TRUNCATED [status=implemented hash=1cf6ca759ad1]
    public static let OT_DIAGNOSTIC_TRUNCATED: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_DIAGNOSTIC_QUEUE_MAX [status=implemented hash=3dfce6711494]
    public static let OT_DIAGNOSTIC_QUEUE_MAX: Int64 = 64
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_BYTES_MAX [status=implemented hash=9f75c95d25c2]
    public static let OT_SCENE_RECORD_BYTES_MAX: Int64 = 67108864
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_PHASE_BEFORE [status=implemented hash=0e51912d5a61]
    public static let OT_SCENE_RECORD_PHASE_BEFORE: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_PHASE_SELF [status=implemented hash=b74bde118798]
    public static let OT_SCENE_RECORD_PHASE_SELF: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_PHASE_AFTER [status=implemented hash=ea722e709f62]
    public static let OT_SCENE_RECORD_PHASE_AFTER: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_SLOT [status=implemented hash=ae40409cfbdc]
    public static let OT_SCENE_RECORD_SLOT: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_DRAW [status=implemented hash=befe7e8c79db]
    public static let OT_SCENE_RECORD_DRAW: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_STACK [status=implemented hash=2c851402868a]
    public static let OT_SCENE_RECORD_STACK: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_GRID [status=implemented hash=7af280e466a8]
    public static let OT_SCENE_RECORD_GRID: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_PACKED [status=implemented hash=215cba86ad2c]
    public static let OT_SCENE_RECORD_PACKED: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_SUPERSAMPLE [status=implemented hash=f4333039ec9a]
    public static let OT_SCENE_RECORD_SUPERSAMPLE: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_GRAYSCALE [status=implemented hash=8bf7144bfecb]
    public static let OT_SCENE_RECORD_GRAYSCALE: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_COLOR_MATRIX [status=implemented hash=81cdbcf9b0de]
    public static let OT_SCENE_RECORD_COLOR_MATRIX: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_TEXT_VIEW [status=implemented hash=c59df61f691d]
    public static let OT_SCENE_RECORD_TEXT_VIEW: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_EDITOR_VIEW [status=implemented hash=7dfacf2505c1]
    public static let OT_SCENE_RECORD_EDITOR_VIEW: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_SCENE_BODY [status=implemented hash=19c55fa1a6fd]
    public static let OT_SCENE_RECORD_SCENE_BODY: Int64 = 10
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_IMAGE [status=implemented hash=89b5c03a8342]
    public static let OT_SCENE_RECORD_IMAGE: Int64 = 11
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_UNICODE [status=implemented hash=897a5f37e244]
    public static let OT_SCENE_RECORD_UNICODE: Int64 = 12
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_CELLS [status=implemented hash=02f4420c1bb5]
    public static let OT_SCENE_RECORD_CELLS: Int64 = 13
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_GRAYSCALE_FOREGROUND [status=implemented hash=5b7425872caa]
    public static let OT_SCENE_RECORD_GRAYSCALE_FOREGROUND: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_GRAYSCALE_BACKGROUND [status=implemented hash=c8fdd75af0d7]
    public static let OT_SCENE_RECORD_GRAYSCALE_BACKGROUND: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_SCENE_RECORD_GRAYSCALE_SUPERSAMPLED [status=implemented hash=cd46880d88bb]
    public static let OT_SCENE_RECORD_GRAYSCALE_SUPERSAMPLED: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_INPUT_RESET_KEEP_REPLY [status=implemented hash=78044565dd93]
    public static let OT_INPUT_RESET_KEEP_REPLY: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_PENDING [status=implemented hash=b9f5c0470dde]
    public static let OT_CLIPBOARD_OPERATION_PENDING: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_READ [status=implemented hash=664c5912bc85]
    public static let OT_CLIPBOARD_OPERATION_READ: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_EMPTY [status=implemented hash=bc801f3a1ea5]
    public static let OT_CLIPBOARD_OPERATION_EMPTY: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_WRITTEN [status=implemented hash=45d58e1d95ef]
    public static let OT_CLIPBOARD_OPERATION_WRITTEN: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_CLEARED [status=implemented hash=d127067adaf9]
    public static let OT_CLIPBOARD_OPERATION_CLEARED: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_UNSUPPORTED [status=implemented hash=f2b177c70727]
    public static let OT_CLIPBOARD_OPERATION_UNSUPPORTED: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_CANCELLED [status=implemented hash=f72da2d48ecf]
    public static let OT_CLIPBOARD_OPERATION_CANCELLED: Int64 = 6
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_TIMED_OUT [status=implemented hash=ef22fdbde309]
    public static let OT_CLIPBOARD_OPERATION_TIMED_OUT: Int64 = 7
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_LIMIT_EXCEEDED [status=implemented hash=a93df2b78336]
    public static let OT_CLIPBOARD_OPERATION_LIMIT_EXCEEDED: Int64 = 8
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_FAILED [status=implemented hash=94382b9357a6]
    public static let OT_CLIPBOARD_OPERATION_FAILED: Int64 = 9
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_OPERATION_INVALID_HANDLE [status=implemented hash=15d76a23a694]
    public static let OT_CLIPBOARD_OPERATION_INVALID_HANDLE: Int64 = 10
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_START_OK [status=implemented hash=e400f16ba19c]
    public static let OT_CLIPBOARD_START_OK: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_START_INVALID_SERVICE [status=implemented hash=c8c3d80ae09e]
    public static let OT_CLIPBOARD_START_INVALID_SERVICE: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_START_SHUTTING_DOWN [status=implemented hash=e3e54d3e50a9]
    public static let OT_CLIPBOARD_START_SHUTTING_DOWN: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_START_LIMIT_EXCEEDED [status=implemented hash=9af1826c1dda]
    public static let OT_CLIPBOARD_START_LIMIT_EXCEEDED: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_START_INVALID_ARGUMENT [status=implemented hash=bde9e4ad5a2b]
    public static let OT_CLIPBOARD_START_INVALID_ARGUMENT: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_START_OUT_OF_MEMORY [status=implemented hash=e3a167af70d1]
    public static let OT_CLIPBOARD_START_OUT_OF_MEMORY: Int64 = 5
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_CANCEL_REQUESTED [status=implemented hash=17bb1c999758]
    public static let OT_CLIPBOARD_CANCEL_REQUESTED: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_CANCEL_ALREADY_TERMINAL [status=implemented hash=4a19715c230b]
    public static let OT_CLIPBOARD_CANCEL_ALREADY_TERMINAL: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_CANCEL_INVALID_HANDLE [status=implemented hash=e4ef1ec42b37]
    public static let OT_CLIPBOARD_CANCEL_INVALID_HANDLE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_COPY_OK [status=implemented hash=3e280052474e]
    public static let OT_CLIPBOARD_COPY_OK: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_COPY_BUFFER_TOO_SMALL [status=implemented hash=2f9afe7b8e20]
    public static let OT_CLIPBOARD_COPY_BUFFER_TOO_SMALL: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_COPY_INVALID_HANDLE [status=implemented hash=8c3830bd859f]
    public static let OT_CLIPBOARD_COPY_INVALID_HANDLE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_COPY_INVALID_STATE [status=implemented hash=c58c760d423d]
    public static let OT_CLIPBOARD_COPY_INVALID_STATE: Int64 = 3
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_COPY_INVALID_ARGUMENT [status=implemented hash=3eb85e5f8849]
    public static let OT_CLIPBOARD_COPY_INVALID_ARGUMENT: Int64 = 4
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_DESTROY_DESTROYED [status=implemented hash=8f463f452583]
    public static let OT_CLIPBOARD_DESTROY_DESTROYED: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_DESTROY_NOT_READY [status=implemented hash=cdd84296ef0a]
    public static let OT_CLIPBOARD_DESTROY_NOT_READY: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_DESTROY_INVALID_HANDLE [status=implemented hash=e5360d065973]
    public static let OT_CLIPBOARD_DESTROY_INVALID_HANDLE: Int64 = 2
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_SHUTDOWN_PENDING [status=implemented hash=e132171fe9a6]
    public static let OT_CLIPBOARD_SHUTDOWN_PENDING: Int64 = 0
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_SHUTDOWN_READY [status=implemented hash=36bb6a3b8b0d]
    public static let OT_CLIPBOARD_SHUTDOWN_READY: Int64 = 1
    // parity: core/src/native-abi.generated.ts#OT_CLIPBOARD_SHUTDOWN_INVALID_HANDLE [status=implemented hash=b2b9a782cccc]
    public static let OT_CLIPBOARD_SHUTDOWN_INVALID_HANDLE: Int64 = 2

    // parity: core/src/native-abi.generated.ts#nativeSymbols [status=implemented hash=a882592743a7]
    public static let nativeSymbols: [String: ABISymbolSignature] = buildNativeSymbols()

    // parity: core/src/native-abi.generated.ts#nativeCallbacks [status=implemented hash=ae42c62ccadb]
    public static let nativeCallbacks: [String: ABISymbolSignature] = buildNativeCallbacks()

    // parity: core/src/native-abi.generated.ts#nativeLayouts [status=implemented hash=37f5ea68d90e]
    public static let nativeLayouts: [String: ABIStructLayout] = buildNativeLayouts()

    // parity: core/src/native-abi.generated.ts#nativeConstants [status=implemented hash=704193546182]
    public static let nativeConstants: [String: Int64] = buildNativeConstants()

    private static func buildNativeCallbacks() -> [String: ABISymbolSignature] {
        var map: [String: ABISymbolSignature] = [:]
        map["ot_scene_measure_callback"] = ABISymbolSignature(args: ["u64", "u32", "u32", "f32", "u32", "f32", "u32", "ptr"], returns: "void")
        map["ot_edit_event_callback"] = ABISymbolSignature(args: ["u64", "u32", "u32", "u32"], returns: "void")
        map["ot_output_write_callback"] = ABISymbolSignature(args: ["ptr", "ptr", "u32"], returns: "i64")
        return map
    }

    private static func buildNativeSymbols() -> [String: ABISymbolSignature] {
        var map: [String: ABISymbolSignature] = [:]
        map.reserveCapacity(292)
        populateSymbolsChunk0(&map)
        populateSymbolsChunk1(&map)
        populateSymbolsChunk2(&map)
        populateSymbolsChunk3(&map)
        return map
    }
    private static func populateSymbolsChunk0(_ map: inout [String: ABISymbolSignature]) {
        map["ot_scene_set_hooks"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_frame_step_with_geometry"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "buffer", "ptr", "u32", "buffer", "buffer"], returns: "i32")
        map["ot_scene_frame_get_paint_slots"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_scene_frame_cancel"] = ABISymbolSignature(args: ["ptr", "buffer", "u64"], returns: "i32")
        map["ot_scene_create_node"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "buffer"], returns: "i32")
        map["ot_scene_destroy_node"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_scene_move_node"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32"], returns: "i32")
        map["ot_scene_clear_children"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_scene_set_measure"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr"], returns: "i32")
        map["ot_scene_has_measure"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_reaches_hooks"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_painted"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_mark_dirty"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_scene_set_style"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "u32", "f32", "u32"], returns: "i32")
        map["ot_scene_get_style"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "buffer"], returns: "i32")
        map["ot_scene_set_paint"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_flush"] = ABISymbolSignature(args: ["ptr", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_scene_set_surface"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr"], returns: "i32")
        map["ot_scene_set_box_details"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "ptr", "u32", "ptr", "u32"], returns: "i32")
        map["ot_scene_set_viewport"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr"], returns: "i32")
        map["ot_scene_set_scroll"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_set_scroll_arrow"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "buffer", "ptr", "u32"], returns: "i32")
        map["ot_scene_scroll_to"] = ABISymbolSignature(args: ["ptr", "buffer", "f64", "f64", "u32", "ptr"], returns: "i32")
        map["ot_scene_scroll_request"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "ptr", "u32", "u32", "ptr"], returns: "i32")
        map["ot_scene_get_scroll"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_set_focus"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_scene_set_slider"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_set_arrow"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "ptr", "u32"], returns: "i32")
        map["ot_scene_get_slider_thumb"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_set_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32"], returns: "i32")
        map["ot_scene_set_styled_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "ptr", "u32", "ptr", "u32"], returns: "i32")
        map["ot_scene_set_text_options"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_set_text_selection"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer"], returns: "i32")
        map["ot_scene_get_text_selection"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_get_selected_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_scene_get_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_scene_get_text_info"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_get_text_lines"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_scene_get_text_byte_at"] = ABISymbolSignature(args: ["ptr", "buffer", "i32", "i32", "buffer"], returns: "i32")
        map["ot_scene_get_layout"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_scene_paint"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32", "u32", "buffer"], returns: "i32")
        map["ot_scene_hit_test"] = ABISymbolSignature(args: ["ptr", "buffer", "i32", "i32", "buffer"], returns: "i32")
        map["ot_scene_hit_test_excluding"] = ABISymbolSignature(args: ["ptr", "buffer", "i32", "i32", "u32", "buffer"], returns: "i32")
        map["ot_scene_get_stats"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_set_debug_flags"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_scene_get_cursor_state"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_scene_frame_copy_buffer"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer"], returns: "i32")
        map["ot_scene_measure_layout"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_render_split"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "ptr", "u32", "u32", "u32", "buffer"], returns: "i32")
        map["ot_session_split_control"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer"], returns: "i32")
        map["ot_session_set_screen"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "buffer", "u32"], returns: "i32")
        map["ot_session_sync_detached"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_unicode_create"] = ABISymbolSignature(args: ["ptr", "ptr", "u32", "u32", "buffer"], returns: "i32")
        map["ot_unicode_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_unicode_get"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_buffer_draw_unicode"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "buffer", "u32", "i32", "i32", "buffer", "buffer", "u32"], returns: "i32")
        map["ot_embedded_terminal_create"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_embedded_terminal_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_embedded_terminal_write"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32"], returns: "i32")
        map["ot_embedded_terminal_resize"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32"], returns: "i32")
        map["ot_embedded_terminal_command"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "i32"], returns: "i32")
        map["ot_embedded_terminal_set_selection"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "u32"], returns: "i32")
        map["ot_embedded_terminal_get_selected_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_embedded_terminal_compose"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "ptr", "i32", "i32"], returns: "i32")
        map["ot_embedded_terminal_cursor_get"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_embedded_terminal_scrollbar_get"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_embedded_terminal_encode_key"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "ptr", "u32", "ptr", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_embedded_terminal_encode_mouse"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_embedded_terminal_encode_paste"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_embedded_terminal_encode_focus"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_embedded_terminal_drain_responses"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_edit_buffer_create"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_edit_buffer_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_editor_view_create"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "buffer"], returns: "i32")
        map["ot_editor_view_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_syntax_style_create"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_syntax_style_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_edit_buffer_set_syntax_style"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr"], returns: "i32")
        map["ot_edit_buffer_set_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "u32"], returns: "i32")
        map["ot_edit_buffer_insert_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32"], returns: "i32")
    }
    private static func populateSymbolsChunk1(_ map: inout [String: ABISymbolSignature]) {
        map["ot_edit_buffer_delete_range"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "u32"], returns: "i32")
        map["ot_edit_buffer_set_cursor"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32"], returns: "i32")
        map["ot_edit_buffer_get_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_edit_buffer_get_info"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_edit_buffer_set_tab_width"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_edit_buffer_command"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32"], returns: "i32")
        map["ot_edit_buffer_history"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_edit_buffer_get_position"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "buffer"], returns: "i32")
        map["ot_edit_buffer_get_range"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "u32", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_edit_buffer_convert_offset"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "buffer"], returns: "i32")
        map["ot_edit_buffer_measure_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_edit_measure_text"] = ABISymbolSignature(args: ["ptr", "ptr", "u32", "u32", "u32", "buffer"], returns: "i32")
        map["ot_edit_buffer_set_defaults"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_syntax_style_register"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer", "buffer"], returns: "i32")
        map["ot_syntax_style_resolve"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_syntax_style_get_count"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_edit_buffer_highlight"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "ptr"], returns: "i32")
        map["ot_edit_buffer_get_highlights"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_context_group_set"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_edit_buffer_set_layer"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "ptr", "u32"], returns: "i32")
        map["ot_edit_buffer_mark"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "ptr", "ptr"], returns: "i32")
        map["ot_edit_buffer_get_marks"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_markdown_create"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_markdown_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_markdown_set_options"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer"], returns: "i32")
        map["ot_markdown_append"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_markdown_set"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_markdown_finish"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_markdown_get_source"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer"], returns: "i32")
        map["ot_markdown_read_changes"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_markdown_read_source"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_markdown_read_leaf"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "ptr", "u32", "buffer", "ptr", "ptr", "u32", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_markdown_bind"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_editor_view_set_viewport"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32", "u32"], returns: "i32")
        map["ot_editor_view_get_viewport"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_editor_view_set_scroll_margin"] = ABISymbolSignature(args: ["ptr", "buffer", "f32"], returns: "i32")
        map["ot_editor_view_command"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32"], returns: "i32")
        map["ot_editor_view_replace_selection"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_editor_view_set_tab_color"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr"], returns: "i32")
        map["ot_editor_view_select"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer"], returns: "i32")
        map["ot_editor_view_get_info"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_editor_view_get_selection"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_editor_view_get_selected_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_editor_view_get_position"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_editor_view_get_lines"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_editor_view_measure"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "buffer"], returns: "i32")
        map["ot_editor_view_set_placeholder"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "ptr", "u32"], returns: "i32")
        map["ot_context_set_edit_event_callback"] = ABISymbolSignature(args: ["ptr", "ptr"], returns: "i32")
        map["ot_scene_set_editor_view"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr"], returns: "i32")
        map["ot_scene_set_editor_options"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_image_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_image_inspect"] = ABISymbolSignature(args: ["ptr", "buffer", "u64", "buffer"], returns: "i32")
        map["ot_image_decode"] = ABISymbolSignature(args: ["ptr", "buffer", "u64", "buffer"], returns: "i32")
        map["ot_image_create_pixels"] = ABISymbolSignature(args: ["ptr", "buffer", "u64", "u32", "u32", "u32", "u32", "u32", "buffer"], returns: "i32")
        map["ot_image_update_pixels"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u64", "u32", "u32", "u32"], returns: "i32")
        map["ot_image_clone"] = ABISymbolSignature(args: ["ptr", "ptr", "buffer", "buffer"], returns: "i32")
        map["ot_image_retain"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_image_get_info"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_image_resize"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "buffer"], returns: "i32")
        map["ot_image_extract"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "u32", "buffer"], returns: "i32")
        map["ot_image_extend"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "u32", "buffer", "buffer"], returns: "i32")
        map["ot_image_transform"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_image_composite"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "i32", "i32", "u32", "u8", "buffer"], returns: "i32")
        map["ot_image_copy_pixels"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u64", "u32", "u32"], returns: "i32")
        map["ot_image_copy_png"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u64", "buffer"], returns: "i32")
        map["ot_image_take_pixels"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_image_pixels_release"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_scene_set_image"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "u32", "ptr"], returns: "i32")
        map["ot_scene_set_crop"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "u32"], returns: "i32")
        map["ot_scene_set_video"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "ptr"], returns: "i32")
        map["ot_video_open"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "u32", "buffer"], returns: "i32")
        map["ot_video_play"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_video_pause"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_video_seek"] = ABISymbolSignature(args: ["ptr", "buffer", "i64"], returns: "i32")
        map["ot_video_set_loop"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_video_set_muted"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_video_set_volume"] = ABISymbolSignature(args: ["ptr", "buffer", "f32"], returns: "i32")
        map["ot_video_set_av_sync_offset"] = ABISymbolSignature(args: ["ptr", "buffer", "i64"], returns: "i32")
        map["ot_video_set_max_fps"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_video_get_state"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
    }
    private static func populateSymbolsChunk2(_ map: inout [String: ABISymbolSignature]) {
        map["ot_video_get_error"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_audio_create"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_audio_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_audio_start"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_audio_stop"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_audio_load"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u64", "buffer"], returns: "i32")
        map["ot_audio_play"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "f32", "buffer"], returns: "i32")
        map["ot_audio_stop_voice"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_audio_set_volume"] = ABISymbolSignature(args: ["ptr", "buffer", "f32"], returns: "i32")
        map["ot_audio_mix"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32", "u32"], returns: "i32")
        map["ot_buffer_draw_image"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "buffer", "buffer", "buffer"], returns: "i32")
        map["ot_session_set_image_resolution"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "u32"], returns: "i32")
        map["ot_session_set_kitty_image_transport"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_session_get_kitty_image_transport"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_poll_kitty_image_transport"] = ABISymbolSignature(args: ["ptr", "buffer", "u64", "buffer"], returns: "i32")
        map["ot_session_cancel_kitty_image_transport"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_session_process_kitty_image_reply"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_session_start_kitty_file_probe"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_text_buffer_create"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_text_buffer_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_text_buffer_view_create"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_text_buffer_view_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_text_buffer_set_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32"], returns: "i32")
        map["ot_text_buffer_append"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32"], returns: "i32")
        map["ot_text_buffer_clear"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_text_buffer_set_styled_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "ptr", "u32", "ptr", "u32"], returns: "i32")
        map["ot_text_buffer_replace_styled_batch"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer", "u32", "buffer", "u32", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_text_buffer_set_syntax_style"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr"], returns: "i32")
        map["ot_text_buffer_get_info"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_text_buffer_get_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_text_buffer_get_range"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_text_buffer_set_defaults"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_text_buffer_set_tab_width"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_text_buffer_set_width_method"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_text_buffer_highlight"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "ptr"], returns: "i32")
        map["ot_text_buffer_get_highlights"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_text_buffer_set_layer"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32", "ptr", "u32"], returns: "i32")
        map["ot_text_buffer_view_set_viewport"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32"], returns: "i32")
        map["ot_text_buffer_view_command"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32"], returns: "i32")
        map["ot_text_buffer_view_set_tab_color"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr"], returns: "i32")
        map["ot_text_buffer_view_select"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer"], returns: "i32")
        map["ot_text_buffer_view_get_info"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_text_buffer_view_get_selected_text"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_text_buffer_view_get_lines"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_text_buffer_view_measure"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "buffer"], returns: "i32")
        map["ot_scene_set_text_view"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr"], returns: "i32")
        map["ot_scene_set_text_view_paint"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_buffer_draw_text_view"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "buffer", "i32", "i32"], returns: "i32")
        map["ot_buffer_draw_editor_view"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "buffer", "i32", "i32"], returns: "i32")
        map["ot_buffer_draw_scene_body"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "buffer", "i32", "i32"], returns: "i32")
        map["ot_scene_frame_acquire_buffer_lease"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_scene_frame_commit"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_context_abi_version"] = ABISymbolSignature(args: [], returns: "u32")
        map["ot_context_create"] = ABISymbolSignature(args: ["buffer", "buffer"], returns: "i32")
        map["ot_context_destroy"] = ABISymbolSignature(args: ["ptr"], returns: "i32")
        map["ot_context_get_last_error"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_context_drain_diagnostics"] = ABISymbolSignature(args: ["ptr", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_context_get_link_url"] = ABISymbolSignature(args: ["ptr", "u32", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_buffer_create"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_buffer_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_buffer_resize"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32"], returns: "i32")
        map["ot_buffer_draw"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "buffer", "ptr", "buffer", "u32", "buffer", "u32"], returns: "i32")
        map["ot_buffer_stack"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "i32", "i32", "u32", "u32", "buffer", "buffer"], returns: "i32")
        map["ot_buffer_draw_grid"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "buffer", "buffer", "u32", "buffer", "u32"], returns: "i32")
        map["ot_buffer_draw_packed"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "ptr", "u32", "i32", "i32", "u32", "u32"], returns: "i32")
        map["ot_buffer_draw_supersample"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "ptr", "u32", "i32", "i32", "u32", "u32"], returns: "i32")
        map["ot_buffer_draw_grayscale"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "buffer", "u32", "i32", "i32", "u32", "u32", "ptr", "ptr", "u32"], returns: "i32")
        map["ot_buffer_color_matrix"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "buffer", "u32", "ptr", "u32", "buffer", "u32"], returns: "i32")
        map["ot_buffer_acquire_lease"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_create"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_attach_renderer"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_attach_renderer_with_env"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer"], returns: "i32")
        map["ot_session_render"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_session_resize_renderer"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32"], returns: "i32")
        map["ot_session_draw_buffer"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "i32", "i32"], returns: "i32")
        map["ot_scene_frame_draw_buffer"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "buffer", "i32", "i32"], returns: "i32")
        map["ot_session_set_debug_overlay"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32"], returns: "i32")
        map["ot_session_update_stats"] = ABISymbolSignature(args: ["ptr", "buffer", "f64", "u32", "f64"], returns: "i32")
        map["ot_session_update_memory_stats"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "u32"], returns: "i32")
        map["ot_session_dump_hit_grid"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
    }
    private static func populateSymbolsChunk3(_ map: inout [String: ABISymbolSignature]) {
        map["ot_session_get_renderer_state"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_acquire_buffer_lease"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_session_get_link_id"] = ABISymbolSignature(args: ["ptr", "buffer", "i32", "i32", "buffer"], returns: "i32")
        map["ot_buffer_lease_validate"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_buffer_lease_release"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_buffer_lease_get_real_char_size"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_buffer_lease_write_resolved_chars"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_session_setup_terminal"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_suspend"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_session_resume"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_session_get_terminal_state"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_control"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "ptr", "u32"], returns: "i32")
        map["ot_session_get_capabilities"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_clipboard"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_session_set_palette_state"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32", "buffer", "buffer", "u32"], returns: "i32")
        map["ot_session_notification"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_session_pump"] = ABISymbolSignature(args: ["ptr", "buffer", "u64", "u32", "buffer"], returns: "i32")
        map["ot_session_input_feed"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "u64", "buffer", "u32", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_session_input_expect"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_session_input_reset"] = ABISymbolSignature(args: ["ptr", "buffer", "u32"], returns: "i32")
        map["ot_session_get_write_limit"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_write"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32"], returns: "i32")
        map["ot_session_read_output"] = ABISymbolSignature(args: ["ptr", "buffer", "ptr", "u32", "buffer"], returns: "i32")
        map["ot_session_drain_output"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer", "ptr", "ptr"], returns: "i32")
        map["ot_session_drain_stdout"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "buffer"], returns: "i32")
        map["ot_session_post_stdout"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u32", "buffer", "buffer"], returns: "i32")
        map["ot_session_complete_output"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32"], returns: "i32")
        map["ot_session_close"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_session_drop_output"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_session_pump_exit"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_terminal_flush_input"] = ABISymbolSignature(args: [], returns: "i32")
        map["ot_session_cancel"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_session_get_state"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "i32")
        map["ot_session_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "i32")
        map["ot_clipboard_service_create"] = ABISymbolSignature(args: ["ptr", "u32", "u32", "ptr", "u32"], returns: "i32")
        map["ot_clipboard_service_begin_shutdown"] = ABISymbolSignature(args: ["ptr"], returns: "u8")
        map["ot_clipboard_service_poll_shutdown"] = ABISymbolSignature(args: ["ptr"], returns: "u8")
        map["ot_clipboard_service_destroy"] = ABISymbolSignature(args: ["ptr"], returns: "u8")
        map["ot_clipboard_service_drain"] = ABISymbolSignature(args: ["ptr"], returns: "u8")
        map["ot_clipboard_read_operation_start"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u8", "u32", "u32", "u32", "u32", "buffer"], returns: "u8")
        map["ot_clipboard_write_operation_start"] = ABISymbolSignature(args: ["ptr", "buffer", "u32", "u8", "u32", "buffer"], returns: "u8")
        map["ot_clipboard_clear_operation_start"] = ABISymbolSignature(args: ["ptr", "u8", "u32", "buffer"], returns: "u8")
        map["ot_clipboard_operation_poll"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "u8")
        map["ot_clipboard_operation_cancel"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "u8")
        map["ot_clipboard_operation_result_mime_length"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "u8")
        map["ot_clipboard_operation_result_mime_copy"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32"], returns: "u8")
        map["ot_clipboard_operation_result_data_length"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "u8")
        map["ot_clipboard_operation_result_data_copy"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32"], returns: "u8")
        map["ot_clipboard_operation_result_error_code"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "u8")
        map["ot_clipboard_operation_result_diagnostic_length"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer"], returns: "u8")
        map["ot_clipboard_operation_result_diagnostic_copy"] = ABISymbolSignature(args: ["ptr", "buffer", "buffer", "u32"], returns: "u8")
        map["ot_clipboard_operation_destroy"] = ABISymbolSignature(args: ["ptr", "buffer"], returns: "u8")
    }

    private static func buildNativeLayouts() -> [String: ABIStructLayout] {
        var map: [String: ABIStructLayout] = [:]
        map.reserveCapacity(101)
        populateLayoutsChunk0(&map)
        populateLayoutsChunk1(&map)
        populateLayoutsChunk2(&map)
        populateLayoutsChunk3(&map)
        populateLayoutsChunk4(&map)
        populateLayoutsChunk5(&map)
        return map
    }
    private static func populateLayoutsChunk0(_ map: inout [String: ABIStructLayout]) {
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["context_id"] = ABIFieldLayout(offset: 0, size: 8, alignment: 8, type: "u64")
            f["slot"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["generation"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            map["ot_handle"] = ABIStructLayout(size: 16, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["orientation"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["min"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "f64")
            f["max"] = ABIFieldLayout(offset: 24, size: 8, alignment: 8, type: "f64")
            f["value"] = ABIFieldLayout(offset: 32, size: 8, alignment: 8, type: "f64")
            f["viewport_size"] = ABIFieldLayout(offset: 40, size: 8, alignment: 8, type: "f64")
            f["foreground"] = ABIFieldLayout(offset: 48, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 56, size: 8, alignment: 2, type: "[4]u16")
            map["ot_scene_slider_options"] = ABIStructLayout(size: 64, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["size"] = ABIFieldLayout(offset: 8, size: 8, alignment: 8, type: "f64")
            f["start"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "f64")
            map["ot_scene_slider_thumb"] = ABIStructLayout(size: 24, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["direction"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["attributes"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 16, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 24, size: 8, alignment: 2, type: "[4]u16")
            map["ot_scene_arrow_options"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 8, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 16, size: 8, alignment: 2, type: "[4]u16")
            f["attributes"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["wrap_mode"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["truncate"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["first_line_offset"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            f["scroll_x"] = ABIFieldLayout(offset: 40, size: 8, alignment: 8, type: "f64")
            f["scroll_y"] = ABIFieldLayout(offset: 48, size: 8, alignment: 8, type: "f64")
            f["tab_indicator"] = ABIFieldLayout(offset: 56, size: 4, alignment: 4, type: "u32")
            f["tab_color_set"] = ABIFieldLayout(offset: 60, size: 4, alignment: 4, type: "u32")
            f["tab_color"] = ABIFieldLayout(offset: 64, size: 8, alignment: 2, type: "[4]u16")
            f["text_align"] = ABIFieldLayout(offset: 72, size: 4, alignment: 4, type: "u32")
            map["ot_scene_text_options"] = ABIStructLayout(size: 80, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["operation"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["behavior"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["anchor_x"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "i32")
            f["anchor_y"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "i32")
            f["focus_x"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "i32")
            f["focus_y"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "i32")
            f["flags"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            f["background"] = ABIFieldLayout(offset: 40, size: 8, alignment: 2, type: "[4]u16")
            f["foreground"] = ABIFieldLayout(offset: 48, size: 8, alignment: 2, type: "[4]u16")
            map["ot_scene_text_selection_options"] = ABIStructLayout(size: 56, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["byte_count"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 16, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 24, size: 8, alignment: 2, type: "[4]u16")
            f["attributes"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            f["link_offset"] = ABIFieldLayout(offset: 40, size: 4, alignment: 4, type: "u32")
            f["link_byte_count"] = ABIFieldLayout(offset: 44, size: 4, alignment: 4, type: "u32")
            map["ot_styled_text_chunk"] = ABIStructLayout(size: 48, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["byte_count"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["text_length"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["line_count"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["virtual_line_count"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["width_cols_max"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_scene_text_info"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["start_cols"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["width_cols"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["source_line"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["wrap_index"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            map["ot_scene_text_line"] = ABIStructLayout(size: 16, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["z_index"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "i32")
            f["opacity"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "f32")
            f["translate_x"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "f64")
            f["translate_y"] = ABIFieldLayout(offset: 24, size: 8, alignment: 8, type: "f64")
            f["border_sides"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["should_fill"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            f["background"] = ABIFieldLayout(offset: 40, size: 8, alignment: 2, type: "[4]u16")
            f["border_color"] = ABIFieldLayout(offset: 48, size: 8, alignment: 2, type: "[4]u16")
            f["border_style"] = ABIFieldLayout(offset: 56, size: 4, alignment: 4, type: "u32")
            f["focusable"] = ABIFieldLayout(offset: 60, size: 4, alignment: 4, type: "u32")
            f["focused_border_color"] = ABIFieldLayout(offset: 64, size: 8, alignment: 2, type: "[4]u16")
            f["reserved"] = ABIFieldLayout(offset: 72, size: 4, alignment: 4, type: "u32")
            map["ot_scene_paint_options"] = ABIStructLayout(size: 80, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["title_alignment"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["bottom_title_alignment"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["title_color"] = ABIFieldLayout(offset: 24, size: 8, alignment: 2, type: "[4]u16")
            f["border_characters"] = ABIFieldLayout(offset: 32, size: 44, alignment: 4, type: "[11]u32")
            map["ot_scene_box_details"] = ABIStructLayout(size: 76, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["unit"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["value"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "f32")
            map["ot_scene_style_value"] = ABIStructLayout(size: 16, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["left"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "f32")
            f["top"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "f32")
            f["right"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "f32")
            f["bottom"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "f32")
            f["width"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "f32")
            f["height"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "f32")
            f["screen_x"] = ABIFieldLayout(offset: 32, size: 8, alignment: 8, type: "f64")
            f["screen_y"] = ABIFieldLayout(offset: 40, size: 8, alignment: 8, type: "f64")
            map["ot_scene_layout"] = ABIStructLayout(size: 48, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["last_frame_time"] = ABIFieldLayout(offset: 8, size: 8, alignment: 8, type: "f64")
            f["average_frame_time"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "f64")
            f["render_time"] = ABIFieldLayout(offset: 24, size: 8, alignment: 8, type: "f64")
            f["stdout_write_time"] = ABIFieldLayout(offset: 32, size: 8, alignment: 8, type: "f64")
            f["frame_count"] = ABIFieldLayout(offset: 40, size: 8, alignment: 8, type: "u64")
            f["cells_updated"] = ABIFieldLayout(offset: 48, size: 4, alignment: 4, type: "u32")
            f["average_cells_updated"] = ABIFieldLayout(offset: 52, size: 4, alignment: 4, type: "u32")
            f["render_time_valid"] = ABIFieldLayout(offset: 56, size: 4, alignment: 4, type: "u32")
            f["stdout_write_time_valid"] = ABIFieldLayout(offset: 60, size: 4, alignment: 4, type: "u32")
            f["work_frame_id"] = ABIFieldLayout(offset: 64, size: 8, alignment: 8, type: "u64")
            f["candidate_visits"] = ABIFieldLayout(offset: 72, size: 8, alignment: 8, type: "u64")
            f["paint_visits"] = ABIFieldLayout(offset: 80, size: 8, alignment: 8, type: "u64")
            f["view_preparations"] = ABIFieldLayout(offset: 88, size: 8, alignment: 8, type: "u64")
            f["geometry_reads"] = ABIFieldLayout(offset: 96, size: 8, alignment: 8, type: "u64")
            f["yoga_solves"] = ABIFieldLayout(offset: 104, size: 8, alignment: 8, type: "u64")
            f["feedback_operations"] = ABIFieldLayout(offset: 112, size: 8, alignment: 8, type: "u64")
            f["visibility_steps"] = ABIFieldLayout(offset: 120, size: 8, alignment: 8, type: "u64")
            f["viewport_child_refreshes"] = ABIFieldLayout(offset: 128, size: 8, alignment: 8, type: "u64")
            f["overlap_tests"] = ABIFieldLayout(offset: 136, size: 8, alignment: 8, type: "u64")
            f["members_painted"] = ABIFieldLayout(offset: 144, size: 8, alignment: 8, type: "u64")
            f["member_cells"] = ABIFieldLayout(offset: 152, size: 8, alignment: 8, type: "u64")
            f["cells_cleared"] = ABIFieldLayout(offset: 160, size: 8, alignment: 8, type: "u64")
            f["hit_cells_written"] = ABIFieldLayout(offset: 168, size: 8, alignment: 8, type: "u64")
            f["hit_cells_cleared"] = ABIFieldLayout(offset: 176, size: 8, alignment: 8, type: "u64")
            f["hit_cells_compared"] = ABIFieldLayout(offset: 184, size: 8, alignment: 8, type: "u64")
            f["rows_compared"] = ABIFieldLayout(offset: 192, size: 8, alignment: 8, type: "u64")
            f["rows_diffed"] = ABIFieldLayout(offset: 200, size: 8, alignment: 8, type: "u64")
            f["full_path_reasons"] = ABIFieldLayout(offset: 208, size: 4, alignment: 4, type: "u32")
            f["host_requests"] = ABIFieldLayout(offset: 212, size: 4, alignment: 4, type: "u32")
            f["layout_rounds"] = ABIFieldLayout(offset: 216, size: 4, alignment: 4, type: "u32")
            f["damage_rows"] = ABIFieldLayout(offset: 220, size: 4, alignment: 4, type: "u32")
            map["ot_scene_stats"] = ABIStructLayout(size: 224, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["x"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["y"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["visible"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["style"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["blinking"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["r"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "f32")
            f["g"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "f32")
            f["b"] = ABIFieldLayout(offset: 40, size: 4, alignment: 4, type: "f32")
            f["a"] = ABIFieldLayout(offset: 44, size: 4, alignment: 4, type: "f32")
            map["ot_scene_cursor_state"] = ABIStructLayout(size: 48, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["generation"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "u64")
            f["initial_width"] = ABIFieldLayout(offset: 24, size: 8, alignment: 8, type: "f64")
            f["initial_height"] = ABIFieldLayout(offset: 32, size: 8, alignment: 8, type: "f64")
            map["ot_scene_hooks"] = ABIStructLayout(size: 40, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["background"] = ABIFieldLayout(offset: 8, size: 8, alignment: 2, type: "[4]u16")
            f["use_mouse"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["excluded_hit_num"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["max_layout_rounds"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["max_host_requests"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["preserve_unwritten"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            map["ot_scene_frame_options"] = ABIStructLayout(size: 36, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["session"] = ABIFieldLayout(offset: 8, size: 16, alignment: 8, type: "ot_handle")
            f["root"] = ABIFieldLayout(offset: 24, size: 16, alignment: 8, type: "ot_handle")
            f["node"] = ABIFieldLayout(offset: 40, size: 16, alignment: 8, type: "ot_handle")
            f["frame_id"] = ABIFieldLayout(offset: 56, size: 8, alignment: 8, type: "u64")
            f["request_id"] = ABIFieldLayout(offset: 64, size: 8, alignment: 8, type: "u64")
            f["layout_epoch"] = ABIFieldLayout(offset: 72, size: 8, alignment: 8, type: "u64")
            f["hook_generation"] = ABIFieldLayout(offset: 80, size: 8, alignment: 8, type: "u64")
            f["kind"] = ABIFieldLayout(offset: 88, size: 4, alignment: 4, type: "u32")
            f["num"] = ABIFieldLayout(offset: 92, size: 4, alignment: 4, type: "u32")
            f["width"] = ABIFieldLayout(offset: 96, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 100, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 104, size: 8, alignment: 4, type: "[2]u32")
            map["ot_scene_frame_request"] = ABIStructLayout(size: 112, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["paint"] = ABIFieldLayout(offset: 16, size: 48, alignment: 8, type: "ot_scene_layout")
            f["public_layout"] = ABIFieldLayout(offset: 64, size: 48, alignment: 8, type: "ot_scene_layout")
            map["ot_scene_frame_geometry"] = ABIStructLayout(size: 112, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["node"] = ABIFieldLayout(offset: 0, size: 16, alignment: 8, type: "ot_handle")
            f["hook_generation"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "u64")
            f["num"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["hooks"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["clip_x"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "i32")
            f["clip_y"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "i32")
            f["clip_width"] = ABIFieldLayout(offset: 40, size: 4, alignment: 4, type: "u32")
            f["clip_height"] = ABIFieldLayout(offset: 44, size: 4, alignment: 4, type: "u32")
            f["opacity"] = ABIFieldLayout(offset: 48, size: 4, alignment: 4, type: "f32")
            f["flags"] = ABIFieldLayout(offset: 52, size: 4, alignment: 4, type: "u32")
            f["paint"] = ABIFieldLayout(offset: 56, size: 48, alignment: 8, type: "ot_scene_layout")
            f["public_layout"] = ABIFieldLayout(offset: 104, size: 48, alignment: 8, type: "ot_scene_layout")
            map["ot_scene_paint_slot"] = ABIStructLayout(size: 152, alignment: 8, fields: f)
        }
    }
    private static func populateLayoutsChunk1(_ map: inout [String: ABIStructLayout]) {
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["node"] = ABIFieldLayout(offset: 0, size: 16, alignment: 8, type: "ot_handle")
            f["fields"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["size_bytes"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            map["ot_scene_property_update"] = ABIStructLayout(size: 24, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["group"] = ABIFieldLayout(offset: 0, size: 1, alignment: 1, type: "u8")
            f["kind"] = ABIFieldLayout(offset: 1, size: 1, alignment: 1, type: "u8")
            f["edge"] = ABIFieldLayout(offset: 2, size: 1, alignment: 1, type: "u8")
            f["unit"] = ABIFieldLayout(offset: 3, size: 1, alignment: 1, type: "u8")
            f["flags"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["value"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "f32")
            f["reserved"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            map["ot_scene_style_property"] = ABIStructLayout(size: 16, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["policy"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["placement"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["thickness"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["gap"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["arrows"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["track_foreground"] = ABIFieldLayout(offset: 24, size: 8, alignment: 2, type: "[4]u16")
            f["track_background"] = ABIFieldLayout(offset: 32, size: 8, alignment: 2, type: "[4]u16")
            map["ot_scene_scroll_bar_options"] = ABIStructLayout(size: 40, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["axes"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["follow"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["culling"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["fills"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["padding"] = ABIFieldLayout(offset: 24, size: 16, alignment: 4, type: "[4]f32")
            f["wrapper_background"] = ABIFieldLayout(offset: 40, size: 8, alignment: 2, type: "[4]u16")
            f["viewport_background"] = ABIFieldLayout(offset: 48, size: 8, alignment: 2, type: "[4]u16")
            f["content_background"] = ABIFieldLayout(offset: 56, size: 8, alignment: 2, type: "[4]u16")
            f["bars"] = ABIFieldLayout(offset: 64, size: 80, alignment: 4, type: "[2]ot_scene_scroll_bar_options")
            map["ot_scene_scroll_options"] = ABIStructLayout(size: 144, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["visible"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["track"] = ABIFieldLayout(offset: 8, size: 32, alignment: 8, type: "[4]f64")
            f["start_arrow"] = ABIFieldLayout(offset: 40, size: 32, alignment: 8, type: "[4]f64")
            f["end_arrow"] = ABIFieldLayout(offset: 72, size: 32, alignment: 8, type: "[4]f64")
            f["thumb_start"] = ABIFieldLayout(offset: 104, size: 8, alignment: 8, type: "f64")
            f["thumb_size"] = ABIFieldLayout(offset: 112, size: 8, alignment: 8, type: "f64")
            map["ot_scene_scroll_bar_state"] = ABIStructLayout(size: 120, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["stuck"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["changes"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["generation"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "u64")
            f["offset"] = ABIFieldLayout(offset: 24, size: 16, alignment: 8, type: "[2]f64")
            f["max"] = ABIFieldLayout(offset: 40, size: 16, alignment: 8, type: "[2]f64")
            f["content"] = ABIFieldLayout(offset: 56, size: 32, alignment: 8, type: "[4]f64")
            f["viewport"] = ABIFieldLayout(offset: 88, size: 32, alignment: 8, type: "[4]f64")
            f["bars"] = ABIFieldLayout(offset: 120, size: 240, alignment: 8, type: "[2]ot_scene_scroll_bar_state")
            map["ot_scene_scroll_state"] = ABIStructLayout(size: 360, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["chunk_size"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["span_capacity"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["max_bytes"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "u64")
            f["control_capacity"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_session_options"] = ABIStructLayout(size: 32, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["session"] = ABIFieldLayout(offset: 0, size: 16, alignment: 8, type: "ot_handle")
            f["request_id"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "u64")
            f["byte_count"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_output_ticket"] = ABIStructLayout(size: 32, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["width"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["remote"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            map["ot_session_renderer_options"] = ABIStructLayout(size: 24, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["width"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["remote_mode"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["entry_count"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["byte_count"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_session_renderer_env_options"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["buffer"] = ABIFieldLayout(offset: 0, size: 16, alignment: 8, type: "ot_handle")
            f["row_columns"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            map["ot_split_snapshot"] = ABIStructLayout(size: 24, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["command"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["arguments"] = ABIFieldLayout(offset: 12, size: 24, alignment: 4, type: "[6]u32")
            map["ot_split_control"] = ABIStructLayout(size: 36, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["width"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["frame_count"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "u64")
            f["frame_pending"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["image_uploads_pending"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["dropped_frames"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["dropped_frame_bytes"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            map["ot_session_renderer_state"] = ABIStructLayout(size: 40, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["width"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["width_method"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            map["ot_buffer_options"] = ABIStructLayout(size: 24, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["width"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["character"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            map["ot_unicode_char"] = ABIStructLayout(size: 8, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["cols"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["rows"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["max_scrollback"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            map["ot_embedded_terminal_options"] = ABIStructLayout(size: 24, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["x"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["y"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["has_value"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["visible"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["blinking"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["wide_tail"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["style"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["color_has_value"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            f["color_r"] = ABIFieldLayout(offset: 40, size: 4, alignment: 4, type: "u32")
            f["color_g"] = ABIFieldLayout(offset: 44, size: 4, alignment: 4, type: "u32")
            f["color_b"] = ABIFieldLayout(offset: 48, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 52, size: 4, alignment: 4, type: "u32")
            map["ot_embedded_terminal_cursor"] = ABIStructLayout(size: 56, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["offset"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["total"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["visible"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            map["ot_embedded_terminal_scrollbar"] = ABIStructLayout(size: 24, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["action"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["composing"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["mods"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["consumed_mods"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["unshifted_codepoint"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_embedded_terminal_key"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["action"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["button"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "i32")
            f["mods"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["any_button_pressed"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["x"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "f32")
            f["y"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "f32")
            map["ot_embedded_terminal_mouse"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
    }
    private static func populateLayoutsChunk2(_ map: inout [String: ABIStructLayout]) {
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["width_method"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            map["ot_edit_buffer_options"] = ABIStructLayout(size: 16, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["content_epoch"] = ABIFieldLayout(offset: 8, size: 8, alignment: 8, type: "u64")
            f["byte_count"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["line_count"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["cursor_row"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["cursor_col"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["cursor_offset"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["can_undo"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            f["can_redo"] = ABIFieldLayout(offset: 40, size: 4, alignment: 4, type: "u32")
            f["tab_width"] = ABIFieldLayout(offset: 44, size: 4, alignment: 4, type: "u32")
            map["ot_edit_buffer_info"] = ABIStructLayout(size: 48, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["show_cursor"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["style"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["blinking"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["color"] = ABIFieldLayout(offset: 24, size: 8, alignment: 2, type: "[4]u16")
            f["mouse_pointer"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["reserved2"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            map["ot_scene_editor_options"] = ABIStructLayout(size: 40, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["valid"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["row"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["col"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["offset"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            map["ot_edit_position"] = ABIStructLayout(size: 24, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["attributes"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 16, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 24, size: 8, alignment: 2, type: "[4]u16")
            map["ot_editor_style"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["start"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["end"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["style_id"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["priority"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["ref"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            map["ot_edit_highlight"] = ABIStructLayout(size: 20, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["start_byte"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["end_byte"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["group_set"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            map["ot_highlight_run"] = ABIStructLayout(size: 12, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["id"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["kind"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["style"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["value"] = ABIFieldLayout(offset: 24, size: 32, alignment: 4, type: "ot_editor_style")
            f["priority"] = ABIFieldLayout(offset: 56, size: 4, alignment: 4, type: "u32")
            f["start"] = ABIFieldLayout(offset: 60, size: 4, alignment: 4, type: "u32")
            f["end"] = ABIFieldLayout(offset: 64, size: 4, alignment: 4, type: "u32")
            f["start_byte"] = ABIFieldLayout(offset: 68, size: 4, alignment: 4, type: "u32")
            f["end_byte"] = ABIFieldLayout(offset: 72, size: 4, alignment: 4, type: "u32")
            map["ot_edit_mark"] = ABIStructLayout(size: 76, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["source_byte_limit"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["syntax_style"] = ABIFieldLayout(offset: 16, size: 16, alignment: 8, type: "ot_handle")
            f["hook_filter_byte_count"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            f["hook_filter"] = ABIFieldLayout(offset: 40, size: 256, alignment: 1, type: "[256]u8")
            map["ot_markdown_options"] = ABIStructLayout(size: 296, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["changed_block_count"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["committed_top_level_count"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["removed_from_index"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            map["ot_markdown_result"] = ABIStructLayout(size: 12, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["index"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["parent_index"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["kind"] = ABIFieldLayout(offset: 8, size: 2, alignment: 2, type: "u16")
            f["flags"] = ABIFieldLayout(offset: 10, size: 2, alignment: 2, type: "u16")
            f["source_start_byte"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["source_end_byte"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["info_start_byte"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["info_end_byte"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["number"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_markdown_block"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["x"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["y"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["width"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            map["ot_editor_viewport"] = ABIStructLayout(size: 24, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["operation"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["behavior"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["start"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["end"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["anchor_x"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "i32")
            f["anchor_y"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "i32")
            f["focus_x"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "i32")
            f["focus_y"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "i32")
            f["update_cursor"] = ABIFieldLayout(offset: 40, size: 4, alignment: 4, type: "u32")
            f["follow_cursor"] = ABIFieldLayout(offset: 44, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 48, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 52, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 56, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 64, size: 8, alignment: 2, type: "[4]u16")
            map["ot_editor_selection"] = ABIStructLayout(size: 72, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["virtual_line_count"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["total_virtual_line_count"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["selection_present"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["selection_start"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["selection_end"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["selection_occupancy"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_editor_view_info"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["visual_row"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["visual_col"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["logical_row"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["logical_col"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["offset"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            map["ot_editor_position"] = ABIStructLayout(size: 28, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["line_count"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["width_cols_max"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            map["ot_editor_measure"] = ABIStructLayout(size: 16, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["width"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["source_width"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["source_height"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["format"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["color_status"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["orientation"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["has_alpha"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_image_info"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["lease"] = ABIFieldLayout(offset: 0, size: 16, alignment: 8, type: "ot_handle")
            f["pixels"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "u64")
            f["byte_count"] = ABIFieldLayout(offset: 24, size: 8, alignment: 8, type: "u64")
            map["ot_image_pixels"] = ABIStructLayout(size: 32, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["duration_us"] = ABIFieldLayout(offset: 0, size: 8, alignment: 8, type: "i64")
            f["width"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["fps_num"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["fps_den"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["has_audio"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_video_info"] = ABIStructLayout(size: 32, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["current_time_us"] = ABIFieldLayout(offset: 0, size: 8, alignment: 8, type: "i64")
            f["frame_pts_us"] = ABIFieldLayout(offset: 8, size: 8, alignment: 8, type: "i64")
            f["flags"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["quality_tier"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            map["ot_video_state"] = ABIStructLayout(size: 24, alignment: 8, fields: f)
        }
    }
    private static func populateLayoutsChunk3(_ map: inout [String: ABIStructLayout]) {
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["protocol"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["x"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "i32")
            f["width"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["pixel_width"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["pixel_height"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            f["source_x"] = ABIFieldLayout(offset: 40, size: 4, alignment: 4, type: "u32")
            f["source_y"] = ABIFieldLayout(offset: 44, size: 4, alignment: 4, type: "u32")
            f["source_width"] = ABIFieldLayout(offset: 48, size: 4, alignment: 4, type: "u32")
            f["source_height"] = ABIFieldLayout(offset: 52, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 56, size: 8, alignment: 4, type: "[2]u32")
            map["ot_image_draw_options"] = ABIStructLayout(size: 64, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["requested"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["effective"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["file_state"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["fallback"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["pending_files"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["pending_bytes"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_session_kitty_image_transport"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["content_epoch"] = ABIFieldLayout(offset: 8, size: 8, alignment: 8, type: "u64")
            f["byte_count"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["text_length"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["line_count"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["highlight_count"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["tab_width"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            map["ot_text_buffer_info"] = ABIStructLayout(size: 40, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["buffer"] = ABIFieldLayout(offset: 8, size: 16, alignment: 8, type: "ot_handle")
            f["view"] = ABIFieldLayout(offset: 24, size: 16, alignment: 8, type: "ot_handle")
            f["byte_offset"] = ABIFieldLayout(offset: 40, size: 4, alignment: 4, type: "u32")
            f["byte_count"] = ABIFieldLayout(offset: 44, size: 4, alignment: 4, type: "u32")
            f["chunk_offset"] = ABIFieldLayout(offset: 48, size: 4, alignment: 4, type: "u32")
            f["chunk_count"] = ABIFieldLayout(offset: 52, size: 4, alignment: 4, type: "u32")
            map["ot_text_buffer_replacement"] = ABIStructLayout(size: 56, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["text_length"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["byte_count"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            map["ot_text_buffer_replacement_info"] = ABIStructLayout(size: 8, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["operation"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            map["ot_buffer_draw_header"] = ABIStructLayout(size: 16, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 16, alignment: 4, type: "ot_buffer_draw_header")
            f["background"] = ABIFieldLayout(offset: 16, size: 8, alignment: 2, type: "[4]u16")
            map["ot_buffer_draw_clear"] = ABIStructLayout(size: 24, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 16, alignment: 4, type: "ot_buffer_draw_header")
            f["x"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "i32")
            f["width"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["background"] = ABIFieldLayout(offset: 32, size: 8, alignment: 2, type: "[4]u16")
            map["ot_buffer_draw_fill"] = ABIStructLayout(size: 40, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 16, alignment: 4, type: "ot_buffer_draw_header")
            f["x"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "i32")
            f["attributes"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 28, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 36, size: 8, alignment: 2, type: "[4]u16")
            f["max_width"] = ABIFieldLayout(offset: 44, size: 4, alignment: 4, type: "u32")
            map["ot_buffer_draw_text_record"] = ABIStructLayout(size: 48, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 16, alignment: 4, type: "ot_buffer_draw_header")
            f["x"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "i32")
            f["character"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["attributes"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 32, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 40, size: 8, alignment: 2, type: "[4]u16")
            map["ot_buffer_draw_cell"] = ABIStructLayout(size: 48, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 16, alignment: 4, type: "ot_buffer_draw_header")
            f["x"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "i32")
            f["width"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["packed_options"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 36, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 44, size: 8, alignment: 2, type: "[4]u16")
            f["title_color"] = ABIFieldLayout(offset: 52, size: 8, alignment: 2, type: "[4]u16")
            f["border_chars"] = ABIFieldLayout(offset: 60, size: 44, alignment: 4, type: "[11]u32")
            map["ot_buffer_draw_box"] = ABIStructLayout(size: 104, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 16, alignment: 4, type: "ot_buffer_draw_header")
            f["x"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "i32")
            f["source_x"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["source_y"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["source_width"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["source_height"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            map["ot_buffer_draw_compose"] = ABIStructLayout(size: 40, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 16, alignment: 4, type: "ot_buffer_draw_header")
            f["enabled"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            map["ot_buffer_draw_alpha"] = ABIStructLayout(size: 20, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 16, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 24, size: 8, alignment: 2, type: "[4]u16")
            f["border_chars"] = ABIFieldLayout(offset: 32, size: 44, alignment: 4, type: "[11]u32")
            map["ot_buffer_grid_options"] = ABIStructLayout(size: 76, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["lease"] = ABIFieldLayout(offset: 8, size: 16, alignment: 8, type: "ot_handle")
            f["width"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["generation"] = ABIFieldLayout(offset: 32, size: 8, alignment: 8, type: "u64")
            f["char_ptr"] = ABIFieldLayout(offset: 40, size: 8, alignment: 8, type: "u64")
            f["fg_ptr"] = ABIFieldLayout(offset: 48, size: 8, alignment: 8, type: "u64")
            f["bg_ptr"] = ABIFieldLayout(offset: 56, size: 8, alignment: 8, type: "u64")
            f["attributes_ptr"] = ABIFieldLayout(offset: 64, size: 8, alignment: 8, type: "u64")
            f["reserved"] = ABIFieldLayout(offset: 72, size: 8, alignment: 8, type: "u64")
            map["ot_buffer_lease_snapshot"] = ABIStructLayout(size: 80, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["kitty_keyboard_flags"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            map["ot_session_terminal_options"] = ABIStructLayout(size: 16, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["kind"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["argument"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            map["ot_session_control_options"] = ABIStructLayout(size: 20, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["fields"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["x"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "i32")
            f["visible"] = ABIFieldLayout(offset: 12, size: 1, alignment: 1, type: "u8")
            f["style"] = ABIFieldLayout(offset: 13, size: 1, alignment: 1, type: "u8")
            f["blinking"] = ABIFieldLayout(offset: 14, size: 1, alignment: 1, type: "u8")
            f["mouse_pointer"] = ABIFieldLayout(offset: 15, size: 1, alignment: 1, type: "u8")
            f["color"] = ABIFieldLayout(offset: 16, size: 8, alignment: 2, type: "[4]u16")
            map["ot_session_cursor_update"] = ABIStructLayout(size: 24, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["state"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["kind"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["fields"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["progress"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["id_len"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["app_len"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["title_len"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["message_len"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_session_program_status"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["width_method"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["multiplexer"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["image_protocol"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["osc52_support"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["kitty_keyboard_flags"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["term_name_len"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "u32")
            f["term_version_len"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            f["term_from_xtversion"] = ABIFieldLayout(offset: 40, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 44, size: 4, alignment: 4, type: "u32")
            f["term_name"] = ABIFieldLayout(offset: 48, size: 64, alignment: 1, type: "[64]u8")
            f["term_version"] = ABIFieldLayout(offset: 112, size: 32, alignment: 1, type: "[32]u8")
            map["ot_session_capabilities"] = ABIStructLayout(size: 144, alignment: 4, fields: f)
        }
    }
    private static func populateLayoutsChunk4(_ map: inout [String: ABIStructLayout]) {
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["status"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["deadline_ns"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "u64")
            map["ot_session_pump_result"] = ABIStructLayout(size: 24, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["kind"] = ABIFieldLayout(offset: 0, size: 1, alignment: 1, type: "u8")
            f["action"] = ABIFieldLayout(offset: 1, size: 1, alignment: 1, type: "u8")
            f["modifiers"] = ABIFieldLayout(offset: 2, size: 1, alignment: 1, type: "u8")
            f["flags"] = ABIFieldLayout(offset: 3, size: 1, alignment: 1, type: "u8")
            f["code"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["base_code"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["x"] = ABIFieldLayout(offset: 12, size: 2, alignment: 2, type: "u16")
            f["y"] = ABIFieldLayout(offset: 14, size: 2, alignment: 2, type: "u16")
            f["raw_offset"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["raw_len"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["text_offset"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["text_len"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_input_event"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["consumed"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["count"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["payload_len"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["discarded"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["deadline_ns"] = ABIFieldLayout(offset: 24, size: 8, alignment: 8, type: "u64")
            map["ot_input_drain"] = ABIStructLayout(size: 32, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["object_capacity"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["render_cells_max"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 20, size: 12, alignment: 4, type: "[3]u32")
            map["ot_context_options"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["status"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "i32")
            f["reserved"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            map["ot_context_error"] = ABIStructLayout(size: 16, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["level"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["message_len"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["message"] = ABIFieldLayout(offset: 16, size: 4096, alignment: 1, type: "[4096]u8")
            map["ot_diagnostic"] = ABIStructLayout(size: 4112, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["struct_size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["abi_version"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["count"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["remaining"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            f["dropped"] = ABIFieldLayout(offset: 16, size: 8, alignment: 8, type: "u64")
            map["ot_diagnostic_drain"] = ABIStructLayout(size: 24, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["size"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["operation"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            map["ot_scene_record_header"] = ABIStructLayout(size: 8, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["slot"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["phase"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "u32")
            map["ot_scene_record_slot"] = ABIStructLayout(size: 16, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["source"] = ABIFieldLayout(offset: 8, size: 16, alignment: 8, type: "ot_handle")
            f["text_length"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["bottom_length"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_scene_record_draw"] = ABIStructLayout(size: 32, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["operation"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "u32")
            f["x"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "i32")
            f["width"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["opacity"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "f32")
            map["ot_scene_record_stack"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["options"] = ABIFieldLayout(offset: 8, size: 76, alignment: 4, type: "ot_buffer_grid_options")
            f["column_count"] = ABIFieldLayout(offset: 84, size: 4, alignment: 4, type: "u32")
            f["row_count"] = ABIFieldLayout(offset: 88, size: 4, alignment: 4, type: "u32")
            map["ot_scene_record_grid"] = ABIStructLayout(size: 92, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["x"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "i32")
            f["width"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["byte_count"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_scene_record_packed"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["x"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "i32")
            f["format"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["stride"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["byte_count"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["reserved"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            map["ot_scene_record_supersample"] = ABIStructLayout(size: 32, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["x"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "i32")
            f["width"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["height"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            f["flags"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["sample_count"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 32, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 40, size: 8, alignment: 2, type: "[4]u16")
            map["ot_scene_record_grayscale"] = ABIStructLayout(size: 48, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["matrix"] = ABIFieldLayout(offset: 8, size: 64, alignment: 4, type: "[16]f32")
            f["strength"] = ABIFieldLayout(offset: 72, size: 4, alignment: 4, type: "f32")
            f["channel"] = ABIFieldLayout(offset: 76, size: 4, alignment: 4, type: "u32")
            f["has_mask"] = ABIFieldLayout(offset: 80, size: 4, alignment: 4, type: "u32")
            f["mask_count"] = ABIFieldLayout(offset: 84, size: 4, alignment: 4, type: "u32")
            map["ot_scene_record_color_matrix"] = ABIStructLayout(size: 88, alignment: 4, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["source"] = ABIFieldLayout(offset: 8, size: 16, alignment: 8, type: "ot_handle")
            f["x"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "i32")
            map["ot_scene_record_view"] = ABIStructLayout(size: 32, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["image"] = ABIFieldLayout(offset: 8, size: 16, alignment: 8, type: "ot_handle")
            f["options"] = ABIFieldLayout(offset: 24, size: 64, alignment: 4, type: "ot_image_draw_options")
            map["ot_scene_record_image"] = ABIStructLayout(size: 88, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["unicode"] = ABIFieldLayout(offset: 8, size: 16, alignment: 8, type: "ot_handle")
            f["index"] = ABIFieldLayout(offset: 24, size: 4, alignment: 4, type: "u32")
            f["x"] = ABIFieldLayout(offset: 28, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 32, size: 4, alignment: 4, type: "i32")
            f["attributes"] = ABIFieldLayout(offset: 36, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 40, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 48, size: 8, alignment: 2, type: "[4]u16")
            map["ot_scene_record_unicode"] = ABIStructLayout(size: 56, alignment: 8, fields: f)
        }
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["character"] = ABIFieldLayout(offset: 0, size: 4, alignment: 4, type: "u32")
            f["attributes"] = ABIFieldLayout(offset: 4, size: 4, alignment: 4, type: "u32")
            f["foreground"] = ABIFieldLayout(offset: 8, size: 8, alignment: 2, type: "[4]u16")
            f["background"] = ABIFieldLayout(offset: 16, size: 8, alignment: 2, type: "[4]u16")
            map["ot_scene_cell"] = ABIStructLayout(size: 24, alignment: 4, fields: f)
        }
    }
    private static func populateLayoutsChunk5(_ map: inout [String: ABIStructLayout]) {
        do {
            var f: [String: ABIFieldLayout] = [:]
            f["header"] = ABIFieldLayout(offset: 0, size: 8, alignment: 4, type: "ot_scene_record_header")
            f["x"] = ABIFieldLayout(offset: 8, size: 4, alignment: 4, type: "i32")
            f["y"] = ABIFieldLayout(offset: 12, size: 4, alignment: 4, type: "i32")
            f["width"] = ABIFieldLayout(offset: 16, size: 4, alignment: 4, type: "u32")
            f["count"] = ABIFieldLayout(offset: 20, size: 4, alignment: 4, type: "u32")
            map["ot_scene_record_cells"] = ABIStructLayout(size: 24, alignment: 4, fields: f)
        }
    }

    private static func buildNativeConstants() -> [String: Int64] {
        var map: [String: Int64] = [:]
        map.reserveCapacity(855)
        populateConstantsChunk0(&map)
        populateConstantsChunk1(&map)
        populateConstantsChunk2(&map)
        populateConstantsChunk3(&map)
        populateConstantsChunk4(&map)
        populateConstantsChunk5(&map)
        return map
    }
    private static func populateConstantsChunk0(_ map: inout [String: Int64]) {
        map["OT_CONTEXT_ABI_VERSION"] = OT_CONTEXT_ABI_VERSION
        map["OT_OK"] = OT_OK
        map["OT_INVALID_ARGUMENT"] = OT_INVALID_ARGUMENT
        map["OT_UNSUPPORTED_VERSION"] = OT_UNSUPPORTED_VERSION
        map["OT_OUT_OF_MEMORY"] = OT_OUT_OF_MEMORY
        map["OT_WRONG_THREAD"] = OT_WRONG_THREAD
        map["OT_INTERNAL_ERROR"] = OT_INTERNAL_ERROR
        map["OT_CONTEXT_BUSY"] = OT_CONTEXT_BUSY
        map["OT_WRONG_CONTEXT"] = OT_WRONG_CONTEXT
        map["OT_WRONG_KIND"] = OT_WRONG_KIND
        map["OT_STALE_HANDLE"] = OT_STALE_HANDLE
        map["OT_WRONG_SESSION"] = OT_WRONG_SESSION
        map["OT_OUTPUT_BACKPRESSURE"] = OT_OUTPUT_BACKPRESSURE
        map["OT_SESSION_CLOSED"] = OT_SESSION_CLOSED
        map["OT_OUTPUT_BUSY"] = OT_OUTPUT_BUSY
        map["OT_STALE_OUTPUT"] = OT_STALE_OUTPUT
        map["OT_OUTPUT_FAILED"] = OT_OUTPUT_FAILED
        map["OT_OBJECT_LIMIT"] = OT_OBJECT_LIMIT
        map["OT_RENDERER_ATTACHED"] = OT_RENDERER_ATTACHED
        map["OT_RENDERER_NOT_ATTACHED"] = OT_RENDERER_NOT_ATTACHED
        map["OT_INVALID_PHASE"] = OT_INVALID_PHASE
        map["OT_CONTROL_PACKET_LIMIT"] = OT_CONTROL_PACKET_LIMIT
        map["OT_LEASE_LIMIT"] = OT_LEASE_LIMIT
        map["OT_LEASE_BYTES_LIMIT"] = OT_LEASE_BYTES_LIMIT
        map["OT_STALE_LEASE"] = OT_STALE_LEASE
        map["OT_UNSUPPORTED_RESOURCE"] = OT_UNSUPPORTED_RESOURCE
        map["OT_STALE_FRAME"] = OT_STALE_FRAME
        map["OT_LAYOUT_LIMIT"] = OT_LAYOUT_LIMIT
        map["OT_FRAME_BUSY"] = OT_FRAME_BUSY
        map["OT_FRAME_REQUEST_LIMIT"] = OT_FRAME_REQUEST_LIMIT
        map["OT_IMAGE_UNSUPPORTED_FORMAT"] = OT_IMAGE_UNSUPPORTED_FORMAT
        map["OT_IMAGE_UNSUPPORTED_COLOR_SPACE"] = OT_IMAGE_UNSUPPORTED_COLOR_SPACE
        map["OT_IMAGE_MALFORMED_DATA"] = OT_IMAGE_MALFORMED_DATA
        map["OT_IMAGE_DIMENSION_LIMIT"] = OT_IMAGE_DIMENSION_LIMIT
        map["OT_IMAGE_MEMORY_LIMIT"] = OT_IMAGE_MEMORY_LIMIT
        map["OT_IMAGE_OUTPUT_TOO_SMALL"] = OT_IMAGE_OUTPUT_TOO_SMALL
        map["OT_IMAGE_UNSUPPORTED_FEATURE"] = OT_IMAGE_UNSUPPORTED_FEATURE
        map["OT_IMAGE_BUSY"] = OT_IMAGE_BUSY
        map["OT_VIDEO_FAILED"] = OT_VIDEO_FAILED
        map["OT_AUDIO_DECODE_FAILED"] = OT_AUDIO_DECODE_FAILED
        map["OT_AUDIO_DEVICE_FAILED"] = OT_AUDIO_DEVICE_FAILED
        map["OT_SCENE_ROOT"] = OT_SCENE_ROOT
        map["OT_SCENE_BOX"] = OT_SCENE_BOX
        map["OT_SCENE_TEXT"] = OT_SCENE_TEXT
        map["OT_SCENE_SLIDER"] = OT_SCENE_SLIDER
        map["OT_SCENE_ARROW"] = OT_SCENE_ARROW
        map["OT_SCENE_EDITOR"] = OT_SCENE_EDITOR
        map["OT_SCENE_CUSTOM"] = OT_SCENE_CUSTOM
        map["OT_SCENE_TEXT_VIEW"] = OT_SCENE_TEXT_VIEW
        map["OT_SCENE_IMAGE"] = OT_SCENE_IMAGE
        map["OT_SCENE_VIDEO"] = OT_SCENE_VIDEO
        map["OT_SCENE_WRAP_NONE"] = OT_SCENE_WRAP_NONE
        map["OT_SCENE_WRAP_CHAR"] = OT_SCENE_WRAP_CHAR
        map["OT_SCENE_WRAP_WORD"] = OT_SCENE_WRAP_WORD
        map["OT_SCENE_ALIGN_LEFT"] = OT_SCENE_ALIGN_LEFT
        map["OT_SCENE_ALIGN_CENTER"] = OT_SCENE_ALIGN_CENTER
        map["OT_SCENE_ALIGN_RIGHT"] = OT_SCENE_ALIGN_RIGHT
        map["OT_STYLE_ENUM"] = OT_STYLE_ENUM
        map["OT_STYLE_FLOAT"] = OT_STYLE_FLOAT
        map["OT_STYLE_VALUE"] = OT_STYLE_VALUE
        map["OT_STYLE_BORDER"] = OT_STYLE_BORDER
        map["OT_STYLE_DIMENSION"] = OT_STYLE_DIMENSION
        map["OT_STYLE_BORDER_WIDTH"] = OT_STYLE_BORDER_WIDTH
        map["OT_STYLE_FLAGS_NONE"] = OT_STYLE_FLAGS_NONE
        map["OT_STYLE_DISABLE_FLEX_SHRINK"] = OT_STYLE_DISABLE_FLEX_SHRINK
        map["OT_STYLE_CONTENT"] = OT_STYLE_CONTENT
        map["OT_STYLE_ENUM_DIRECTION"] = OT_STYLE_ENUM_DIRECTION
        map["OT_STYLE_ENUM_FLEX_DIRECTION"] = OT_STYLE_ENUM_FLEX_DIRECTION
        map["OT_STYLE_ENUM_JUSTIFY_CONTENT"] = OT_STYLE_ENUM_JUSTIFY_CONTENT
        map["OT_STYLE_ENUM_ALIGN_CONTENT"] = OT_STYLE_ENUM_ALIGN_CONTENT
        map["OT_STYLE_ENUM_ALIGN_ITEMS"] = OT_STYLE_ENUM_ALIGN_ITEMS
        map["OT_STYLE_ENUM_ALIGN_SELF"] = OT_STYLE_ENUM_ALIGN_SELF
        map["OT_STYLE_ENUM_POSITION_TYPE"] = OT_STYLE_ENUM_POSITION_TYPE
        map["OT_STYLE_ENUM_FLEX_WRAP"] = OT_STYLE_ENUM_FLEX_WRAP
        map["OT_STYLE_ENUM_OVERFLOW"] = OT_STYLE_ENUM_OVERFLOW
        map["OT_STYLE_ENUM_DISPLAY"] = OT_STYLE_ENUM_DISPLAY
        map["OT_STYLE_ENUM_BOX_SIZING"] = OT_STYLE_ENUM_BOX_SIZING
        map["OT_STYLE_ENUM_LAYOUT_MODE"] = OT_STYLE_ENUM_LAYOUT_MODE
        map["OT_STYLE_FLOAT_FLEX"] = OT_STYLE_FLOAT_FLEX
        map["OT_STYLE_FLOAT_FLEX_GROW"] = OT_STYLE_FLOAT_FLEX_GROW
        map["OT_STYLE_FLOAT_FLEX_SHRINK"] = OT_STYLE_FLOAT_FLEX_SHRINK
        map["OT_STYLE_FLOAT_ASPECT_RATIO"] = OT_STYLE_FLOAT_ASPECT_RATIO
        map["OT_STYLE_VALUE_WIDTH"] = OT_STYLE_VALUE_WIDTH
        map["OT_STYLE_VALUE_HEIGHT"] = OT_STYLE_VALUE_HEIGHT
        map["OT_STYLE_VALUE_MIN_WIDTH"] = OT_STYLE_VALUE_MIN_WIDTH
        map["OT_STYLE_VALUE_MIN_HEIGHT"] = OT_STYLE_VALUE_MIN_HEIGHT
        map["OT_STYLE_VALUE_MAX_WIDTH"] = OT_STYLE_VALUE_MAX_WIDTH
        map["OT_STYLE_VALUE_MAX_HEIGHT"] = OT_STYLE_VALUE_MAX_HEIGHT
        map["OT_STYLE_VALUE_FLEX_BASIS"] = OT_STYLE_VALUE_FLEX_BASIS
        map["OT_STYLE_VALUE_MARGIN"] = OT_STYLE_VALUE_MARGIN
        map["OT_STYLE_VALUE_PADDING"] = OT_STYLE_VALUE_PADDING
        map["OT_STYLE_VALUE_POSITION"] = OT_STYLE_VALUE_POSITION
        map["OT_STYLE_VALUE_GAP"] = OT_STYLE_VALUE_GAP
        map["OT_DIMENSION_WIDTH"] = OT_DIMENSION_WIDTH
        map["OT_DIMENSION_HEIGHT"] = OT_DIMENSION_HEIGHT
        map["OT_UNIT_UNDEFINED"] = OT_UNIT_UNDEFINED
        map["OT_UNIT_POINT"] = OT_UNIT_POINT
        map["OT_UNIT_PERCENT"] = OT_UNIT_PERCENT
        map["OT_UNIT_AUTO"] = OT_UNIT_AUTO
        map["OT_EDGE_NONE"] = OT_EDGE_NONE
        map["OT_EDGE_LEFT"] = OT_EDGE_LEFT
        map["OT_EDGE_TOP"] = OT_EDGE_TOP
        map["OT_EDGE_RIGHT"] = OT_EDGE_RIGHT
        map["OT_EDGE_BOTTOM"] = OT_EDGE_BOTTOM
        map["OT_EDGE_START"] = OT_EDGE_START
        map["OT_EDGE_END"] = OT_EDGE_END
        map["OT_EDGE_HORIZONTAL"] = OT_EDGE_HORIZONTAL
        map["OT_EDGE_VERTICAL"] = OT_EDGE_VERTICAL
        map["OT_EDGE_ALL"] = OT_EDGE_ALL
        map["OT_GUTTER_COLUMN"] = OT_GUTTER_COLUMN
        map["OT_GUTTER_ROW"] = OT_GUTTER_ROW
        map["OT_GUTTER_ALL"] = OT_GUTTER_ALL
        map["OT_DIRECTION_INHERIT"] = OT_DIRECTION_INHERIT
        map["OT_DIRECTION_LTR"] = OT_DIRECTION_LTR
        map["OT_DIRECTION_RTL"] = OT_DIRECTION_RTL
        map["OT_FLEX_DIRECTION_COLUMN"] = OT_FLEX_DIRECTION_COLUMN
        map["OT_FLEX_DIRECTION_COLUMN_REVERSE"] = OT_FLEX_DIRECTION_COLUMN_REVERSE
        map["OT_FLEX_DIRECTION_ROW"] = OT_FLEX_DIRECTION_ROW
        map["OT_FLEX_DIRECTION_ROW_REVERSE"] = OT_FLEX_DIRECTION_ROW_REVERSE
        map["OT_JUSTIFY_FLEX_START"] = OT_JUSTIFY_FLEX_START
        map["OT_JUSTIFY_CENTER"] = OT_JUSTIFY_CENTER
        map["OT_JUSTIFY_FLEX_END"] = OT_JUSTIFY_FLEX_END
        map["OT_JUSTIFY_SPACE_BETWEEN"] = OT_JUSTIFY_SPACE_BETWEEN
        map["OT_JUSTIFY_SPACE_AROUND"] = OT_JUSTIFY_SPACE_AROUND
        map["OT_JUSTIFY_SPACE_EVENLY"] = OT_JUSTIFY_SPACE_EVENLY
        map["OT_ALIGN_AUTO"] = OT_ALIGN_AUTO
        map["OT_ALIGN_FLEX_START"] = OT_ALIGN_FLEX_START
        map["OT_ALIGN_CENTER"] = OT_ALIGN_CENTER
        map["OT_ALIGN_FLEX_END"] = OT_ALIGN_FLEX_END
        map["OT_ALIGN_STRETCH"] = OT_ALIGN_STRETCH
        map["OT_ALIGN_BASELINE"] = OT_ALIGN_BASELINE
        map["OT_ALIGN_SPACE_BETWEEN"] = OT_ALIGN_SPACE_BETWEEN
        map["OT_ALIGN_SPACE_AROUND"] = OT_ALIGN_SPACE_AROUND
        map["OT_ALIGN_SPACE_EVENLY"] = OT_ALIGN_SPACE_EVENLY
        map["OT_POSITION_STATIC"] = OT_POSITION_STATIC
        map["OT_POSITION_RELATIVE"] = OT_POSITION_RELATIVE
        map["OT_POSITION_ABSOLUTE"] = OT_POSITION_ABSOLUTE
        map["OT_FLEX_WRAP_NONE"] = OT_FLEX_WRAP_NONE
        map["OT_FLEX_WRAP_WRAP"] = OT_FLEX_WRAP_WRAP
        map["OT_FLEX_WRAP_REVERSE"] = OT_FLEX_WRAP_REVERSE
        map["OT_OVERFLOW_VISIBLE"] = OT_OVERFLOW_VISIBLE
        map["OT_OVERFLOW_HIDDEN"] = OT_OVERFLOW_HIDDEN
        map["OT_OVERFLOW_SCROLL"] = OT_OVERFLOW_SCROLL
        map["OT_DISPLAY_FLEX"] = OT_DISPLAY_FLEX
        map["OT_DISPLAY_NONE"] = OT_DISPLAY_NONE
        map["OT_BOX_SIZING_BORDER_BOX"] = OT_BOX_SIZING_BORDER_BOX
        map["OT_BOX_SIZING_CONTENT_BOX"] = OT_BOX_SIZING_CONTENT_BOX
        map["OT_LAYOUT_MODE_FLEX"] = OT_LAYOUT_MODE_FLEX
        map["OT_LAYOUT_MODE_LIST"] = OT_LAYOUT_MODE_LIST
        map["OT_DISPLAY_CONTENTS"] = OT_DISPLAY_CONTENTS
    }
    private static func populateConstantsChunk1(_ map: inout [String: Int64]) {
        map["OT_YOGA_ERRATA_NONE"] = OT_YOGA_ERRATA_NONE
        map["OT_YOGA_ERRATA_STRETCH_FLEX_BASIS"] = OT_YOGA_ERRATA_STRETCH_FLEX_BASIS
        map["OT_YOGA_ERRATA_ABSOLUTE_POSITION_WITHOUT_INSETS_EXCLUDES_PADDING"] = OT_YOGA_ERRATA_ABSOLUTE_POSITION_WITHOUT_INSETS_EXCLUDES_PADDING
        map["OT_YOGA_ERRATA_ABSOLUTE_PERCENT_AGAINST_INNER_SIZE"] = OT_YOGA_ERRATA_ABSOLUTE_PERCENT_AGAINST_INNER_SIZE
        map["OT_YOGA_ERRATA_ALL"] = OT_YOGA_ERRATA_ALL
        map["OT_YOGA_ERRATA_CLASSIC"] = OT_YOGA_ERRATA_CLASSIC
        map["OT_YOGA_EXPERIMENTAL_FEATURE_WEB_FLEX_BASIS"] = OT_YOGA_EXPERIMENTAL_FEATURE_WEB_FLEX_BASIS
        map["OT_YOGA_LOG_LEVEL_ERROR"] = OT_YOGA_LOG_LEVEL_ERROR
        map["OT_YOGA_LOG_LEVEL_WARN"] = OT_YOGA_LOG_LEVEL_WARN
        map["OT_YOGA_LOG_LEVEL_INFO"] = OT_YOGA_LOG_LEVEL_INFO
        map["OT_YOGA_LOG_LEVEL_DEBUG"] = OT_YOGA_LOG_LEVEL_DEBUG
        map["OT_YOGA_LOG_LEVEL_VERBOSE"] = OT_YOGA_LOG_LEVEL_VERBOSE
        map["OT_YOGA_LOG_LEVEL_FATAL"] = OT_YOGA_LOG_LEVEL_FATAL
        map["OT_YOGA_NODE_TYPE_DEFAULT"] = OT_YOGA_NODE_TYPE_DEFAULT
        map["OT_YOGA_NODE_TYPE_TEXT"] = OT_YOGA_NODE_TYPE_TEXT
        map["OT_STYLE_ENUM_DIRECTION_MAX"] = OT_STYLE_ENUM_DIRECTION_MAX
        map["OT_STYLE_ENUM_FLEX_DIRECTION_MAX"] = OT_STYLE_ENUM_FLEX_DIRECTION_MAX
        map["OT_STYLE_ENUM_JUSTIFY_CONTENT_MAX"] = OT_STYLE_ENUM_JUSTIFY_CONTENT_MAX
        map["OT_STYLE_ENUM_ALIGN_CONTENT_MAX"] = OT_STYLE_ENUM_ALIGN_CONTENT_MAX
        map["OT_STYLE_ENUM_ALIGN_ITEMS_MAX"] = OT_STYLE_ENUM_ALIGN_ITEMS_MAX
        map["OT_STYLE_ENUM_ALIGN_SELF_MAX"] = OT_STYLE_ENUM_ALIGN_SELF_MAX
        map["OT_STYLE_ENUM_POSITION_TYPE_MAX"] = OT_STYLE_ENUM_POSITION_TYPE_MAX
        map["OT_STYLE_ENUM_FLEX_WRAP_MAX"] = OT_STYLE_ENUM_FLEX_WRAP_MAX
        map["OT_STYLE_ENUM_OVERFLOW_MAX"] = OT_STYLE_ENUM_OVERFLOW_MAX
        map["OT_STYLE_ENUM_DISPLAY_MAX"] = OT_STYLE_ENUM_DISPLAY_MAX
        map["OT_STYLE_ENUM_BOX_SIZING_MAX"] = OT_STYLE_ENUM_BOX_SIZING_MAX
        map["OT_STYLE_ENUM_LAYOUT_MODE_MAX"] = OT_STYLE_ENUM_LAYOUT_MODE_MAX
        map["OT_MEASURE_UNDEFINED"] = OT_MEASURE_UNDEFINED
        map["OT_MEASURE_EXACTLY"] = OT_MEASURE_EXACTLY
        map["OT_MEASURE_AT_MOST"] = OT_MEASURE_AT_MOST
        map["OT_LAYOUT_PUBLIC"] = OT_LAYOUT_PUBLIC
        map["OT_LAYOUT_YOGA"] = OT_LAYOUT_YOGA
        map["OT_LAYOUT_PAINT"] = OT_LAYOUT_PAINT
        map["OT_LAYOUT_CONTENT"] = OT_LAYOUT_CONTENT
        map["OT_BORDER_NONE"] = OT_BORDER_NONE
        map["OT_BORDER_LEFT"] = OT_BORDER_LEFT
        map["OT_BORDER_BOTTOM"] = OT_BORDER_BOTTOM
        map["OT_BORDER_RIGHT"] = OT_BORDER_RIGHT
        map["OT_BORDER_TOP"] = OT_BORDER_TOP
        map["OT_BORDER_ALL"] = OT_BORDER_ALL
        map["OT_BORDER_SINGLE"] = OT_BORDER_SINGLE
        map["OT_BORDER_DOUBLE"] = OT_BORDER_DOUBLE
        map["OT_BORDER_ROUNDED"] = OT_BORDER_ROUNDED
        map["OT_BORDER_HEAVY"] = OT_BORDER_HEAVY
        map["OT_COLOR_RGB"] = OT_COLOR_RGB
        map["OT_COLOR_INDEXED"] = OT_COLOR_INDEXED
        map["OT_COLOR_DEFAULT"] = OT_COLOR_DEFAULT
        map["OT_COLOR_CHANNEL_MASK"] = OT_COLOR_CHANNEL_MASK
        map["OT_COLOR_META_SHIFT"] = OT_COLOR_META_SHIFT
        map["OT_COLOR_ANSI_0"] = OT_COLOR_ANSI_0
        map["OT_COLOR_ANSI_1"] = OT_COLOR_ANSI_1
        map["OT_COLOR_ANSI_2"] = OT_COLOR_ANSI_2
        map["OT_COLOR_ANSI_3"] = OT_COLOR_ANSI_3
        map["OT_COLOR_ANSI_4"] = OT_COLOR_ANSI_4
        map["OT_COLOR_ANSI_5"] = OT_COLOR_ANSI_5
        map["OT_COLOR_ANSI_6"] = OT_COLOR_ANSI_6
        map["OT_COLOR_ANSI_7"] = OT_COLOR_ANSI_7
        map["OT_COLOR_ANSI_8"] = OT_COLOR_ANSI_8
        map["OT_COLOR_ANSI_9"] = OT_COLOR_ANSI_9
        map["OT_COLOR_ANSI_10"] = OT_COLOR_ANSI_10
        map["OT_COLOR_ANSI_11"] = OT_COLOR_ANSI_11
        map["OT_COLOR_ANSI_12"] = OT_COLOR_ANSI_12
        map["OT_COLOR_ANSI_13"] = OT_COLOR_ANSI_13
        map["OT_COLOR_ANSI_14"] = OT_COLOR_ANSI_14
        map["OT_COLOR_ANSI_15"] = OT_COLOR_ANSI_15
        map["OT_COLOR_CUBE_BASE"] = OT_COLOR_CUBE_BASE
        map["OT_COLOR_CUBE_STEP"] = OT_COLOR_CUBE_STEP
        map["OT_COLOR_GRAY_BASE"] = OT_COLOR_GRAY_BASE
        map["OT_COLOR_GRAY_STEP"] = OT_COLOR_GRAY_STEP
        map["OT_ATTR_BOLD"] = OT_ATTR_BOLD
        map["OT_ATTR_DIM"] = OT_ATTR_DIM
        map["OT_ATTR_ITALIC"] = OT_ATTR_ITALIC
        map["OT_ATTR_UNDERLINE"] = OT_ATTR_UNDERLINE
        map["OT_ATTR_BLINK"] = OT_ATTR_BLINK
        map["OT_ATTR_INVERSE"] = OT_ATTR_INVERSE
        map["OT_ATTR_HIDDEN"] = OT_ATTR_HIDDEN
        map["OT_ATTR_STRIKETHROUGH"] = OT_ATTR_STRIKETHROUGH
        map["OT_ATTR_BASE_MASK"] = OT_ATTR_BASE_MASK
        map["OT_ATTR_LINK_SHIFT"] = OT_ATTR_LINK_SHIFT
        map["OT_ATTR_LINK_MASK"] = OT_ATTR_LINK_MASK
        map["OT_SCENE_TEXT_SELECTION_RESET"] = OT_SCENE_TEXT_SELECTION_RESET
        map["OT_SCENE_TEXT_SELECTION_SET"] = OT_SCENE_TEXT_SELECTION_SET
        map["OT_SCENE_TEXT_SELECTION_UPDATE"] = OT_SCENE_TEXT_SELECTION_UPDATE
        map["OT_SCENE_TEXT_SELECTION_COLORS"] = OT_SCENE_TEXT_SELECTION_COLORS
        map["OT_SCENE_TEXT_SELECTION_CELL"] = OT_SCENE_TEXT_SELECTION_CELL
        map["OT_SCENE_TEXT_SELECTION_WORD"] = OT_SCENE_TEXT_SELECTION_WORD
        map["OT_SCENE_TEXT_SELECTION_LINE"] = OT_SCENE_TEXT_SELECTION_LINE
        map["OT_SCENE_TEXT_SELECTION_BACKGROUND"] = OT_SCENE_TEXT_SELECTION_BACKGROUND
        map["OT_SCENE_TEXT_SELECTION_FOREGROUND"] = OT_SCENE_TEXT_SELECTION_FOREGROUND
        map["OT_SCENE_TEXT_FOREGROUND"] = OT_SCENE_TEXT_FOREGROUND
        map["OT_SCENE_TEXT_BACKGROUND"] = OT_SCENE_TEXT_BACKGROUND
        map["OT_SCENE_TEXT_LINK"] = OT_SCENE_TEXT_LINK
        map["OT_SCENE_MUTATIONS_MAX"] = OT_SCENE_MUTATIONS_MAX
        map["OT_SCENE_FULL_PATH_FORCED"] = OT_SCENE_FULL_PATH_FORCED
        map["OT_SCENE_FULL_PATH_SCREEN"] = OT_SCENE_FULL_PATH_SCREEN
        map["OT_SCENE_FULL_PATH_IMAGES"] = OT_SCENE_FULL_PATH_IMAGES
        map["OT_SCENE_FULL_PATH_TAINTED"] = OT_SCENE_FULL_PATH_TAINTED
        map["OT_SCENE_FULL_PATH_UNRETAINED"] = OT_SCENE_FULL_PATH_UNRETAINED
        map["OT_SCENE_FULL_PATH_OPTIONS"] = OT_SCENE_FULL_PATH_OPTIONS
        map["OT_SCENE_FULL_PATH_NON_LOCAL"] = OT_SCENE_FULL_PATH_NON_LOCAL
        map["OT_CURSOR_STYLE_BLOCK"] = OT_CURSOR_STYLE_BLOCK
        map["OT_CURSOR_STYLE_LINE"] = OT_CURSOR_STYLE_LINE
        map["OT_CURSOR_STYLE_UNDERLINE"] = OT_CURSOR_STYLE_UNDERLINE
        map["OT_CURSOR_STYLE_DEFAULT"] = OT_CURSOR_STYLE_DEFAULT
        map["OT_SCENE_HOOK_UPDATE"] = OT_SCENE_HOOK_UPDATE
        map["OT_SCENE_HOOK_RESIZE"] = OT_SCENE_HOOK_RESIZE
        map["OT_SCENE_HOOK_LAYOUT_CHANGED"] = OT_SCENE_HOOK_LAYOUT_CHANGED
        map["OT_SCENE_HOOK_RENDER_BEFORE"] = OT_SCENE_HOOK_RENDER_BEFORE
        map["OT_SCENE_HOOK_RENDER_AFTER"] = OT_SCENE_HOOK_RENDER_AFTER
        map["OT_SCENE_HOOK_RENDER_SELF"] = OT_SCENE_HOOK_RENDER_SELF
        map["OT_SCENE_HOOK_IDLE_UPDATE"] = OT_SCENE_HOOK_IDLE_UPDATE
        map["OT_SCENE_HOOK_SCROLL"] = OT_SCENE_HOOK_SCROLL
        map["OT_SCENE_FRAME_DONE"] = OT_SCENE_FRAME_DONE
        map["OT_SCENE_FRAME_UPDATE"] = OT_SCENE_FRAME_UPDATE
        map["OT_SCENE_FRAME_RESIZE"] = OT_SCENE_FRAME_RESIZE
        map["OT_SCENE_FRAME_LAYOUT_CHANGED"] = OT_SCENE_FRAME_LAYOUT_CHANGED
        map["OT_SCENE_FRAME_RECORD"] = OT_SCENE_FRAME_RECORD
        map["OT_SCENE_FRAME_SCROLL"] = OT_SCENE_FRAME_SCROLL
        map["OT_SCENE_GEOMETRY_PAINT"] = OT_SCENE_GEOMETRY_PAINT
        map["OT_SCENE_GEOMETRY_PUBLIC"] = OT_SCENE_GEOMETRY_PUBLIC
        map["OT_SCENE_PROPERTY_Z_INDEX"] = OT_SCENE_PROPERTY_Z_INDEX
        map["OT_SCENE_PROPERTY_OPACITY"] = OT_SCENE_PROPERTY_OPACITY
        map["OT_SCENE_PROPERTY_TRANSLATE_X"] = OT_SCENE_PROPERTY_TRANSLATE_X
        map["OT_SCENE_PROPERTY_TRANSLATE_Y"] = OT_SCENE_PROPERTY_TRANSLATE_Y
        map["OT_SCENE_PROPERTY_BORDER"] = OT_SCENE_PROPERTY_BORDER
        map["OT_SCENE_PROPERTY_SHOULD_FILL"] = OT_SCENE_PROPERTY_SHOULD_FILL
        map["OT_SCENE_PROPERTY_BACKGROUND"] = OT_SCENE_PROPERTY_BACKGROUND
        map["OT_SCENE_PROPERTY_BORDER_COLOR"] = OT_SCENE_PROPERTY_BORDER_COLOR
        map["OT_SCENE_PROPERTY_BORDER_STYLE"] = OT_SCENE_PROPERTY_BORDER_STYLE
        map["OT_SCENE_PROPERTY_FOCUSABLE"] = OT_SCENE_PROPERTY_FOCUSABLE
        map["OT_SCENE_PROPERTY_FOCUSED_BORDER_COLOR"] = OT_SCENE_PROPERTY_FOCUSED_BORDER_COLOR
        map["OT_SCENE_PROPERTY_STYLE"] = OT_SCENE_PROPERTY_STYLE
        map["OT_SCENE_PROPERTY_RESET_BORDER_CHARACTERS"] = OT_SCENE_PROPERTY_RESET_BORDER_CHARACTERS
        map["OT_SCENE_PROPERTY_RECORD_MAX"] = OT_SCENE_PROPERTY_RECORD_MAX
        map["OT_SCENE_PROPERTY_BYTES_MAX"] = OT_SCENE_PROPERTY_BYTES_MAX
        map["OT_SCENE_SCROLL_X"] = OT_SCENE_SCROLL_X
        map["OT_SCENE_SCROLL_Y"] = OT_SCENE_SCROLL_Y
        map["OT_SCENE_SCROLL_FOLLOW_NONE"] = OT_SCENE_SCROLL_FOLLOW_NONE
        map["OT_SCENE_SCROLL_FOLLOW_TOP"] = OT_SCENE_SCROLL_FOLLOW_TOP
        map["OT_SCENE_SCROLL_FOLLOW_BOTTOM"] = OT_SCENE_SCROLL_FOLLOW_BOTTOM
        map["OT_SCENE_SCROLL_FOLLOW_LEFT"] = OT_SCENE_SCROLL_FOLLOW_LEFT
        map["OT_SCENE_SCROLL_FOLLOW_RIGHT"] = OT_SCENE_SCROLL_FOLLOW_RIGHT
        map["OT_SCENE_SCROLL_FILL_WRAPPER"] = OT_SCENE_SCROLL_FILL_WRAPPER
        map["OT_SCENE_SCROLL_FILL_VIEWPORT"] = OT_SCENE_SCROLL_FILL_VIEWPORT
        map["OT_SCENE_SCROLL_FILL_CONTENT"] = OT_SCENE_SCROLL_FILL_CONTENT
        map["OT_SCENE_SCROLL_BAR_AUTO"] = OT_SCENE_SCROLL_BAR_AUTO
        map["OT_SCENE_SCROLL_BAR_ALWAYS"] = OT_SCENE_SCROLL_BAR_ALWAYS
        map["OT_SCENE_SCROLL_BAR_NEVER"] = OT_SCENE_SCROLL_BAR_NEVER
        map["OT_SCENE_SCROLL_BAR_INSET"] = OT_SCENE_SCROLL_BAR_INSET
        map["OT_SCENE_SCROLL_BAR_OVERLAY"] = OT_SCENE_SCROLL_BAR_OVERLAY
    }
    private static func populateConstantsChunk2(_ map: inout [String: Int64]) {
        map["OT_SCENE_SCROLL_RELATIVE_X"] = OT_SCENE_SCROLL_RELATIVE_X
        map["OT_SCENE_SCROLL_RELATIVE_Y"] = OT_SCENE_SCROLL_RELATIVE_Y
        map["OT_SCENE_SCROLL_REAPPLY"] = OT_SCENE_SCROLL_REAPPLY
        map["OT_SCENE_SCROLL_REQUEST_INTO_VIEW"] = OT_SCENE_SCROLL_REQUEST_INTO_VIEW
        map["OT_SCENE_SCROLL_REQUEST_ANCHOR"] = OT_SCENE_SCROLL_REQUEST_ANCHOR
        map["OT_SCENE_SCROLL_REQUEST_LAYOUT"] = OT_SCENE_SCROLL_REQUEST_LAYOUT
        map["OT_SCENE_SCROLL_ALIGN_NEAREST"] = OT_SCENE_SCROLL_ALIGN_NEAREST
        map["OT_SCENE_SCROLL_ALIGN_START"] = OT_SCENE_SCROLL_ALIGN_START
        map["OT_SCENE_SCROLL_ALIGN_END"] = OT_SCENE_SCROLL_ALIGN_END
        map["OT_SCENE_SCROLL_PADDING_MAX"] = OT_SCENE_SCROLL_PADDING_MAX
        map["OT_SCENE_SCROLL_CHANGED_OFFSET_X"] = OT_SCENE_SCROLL_CHANGED_OFFSET_X
        map["OT_SCENE_SCROLL_CHANGED_OFFSET_Y"] = OT_SCENE_SCROLL_CHANGED_OFFSET_Y
        map["OT_SCENE_SCROLL_CHANGED_CONTENT"] = OT_SCENE_SCROLL_CHANGED_CONTENT
        map["OT_SCENE_SCROLL_CHANGED_VIEWPORT"] = OT_SCENE_SCROLL_CHANGED_VIEWPORT
        map["OT_SCENE_SCROLL_CHANGED_LAYOUT"] = OT_SCENE_SCROLL_CHANGED_LAYOUT
        map["OT_SCENE_DEBUG_FULL_FRAME"] = OT_SCENE_DEBUG_FULL_FRAME
        map["OT_SCENE_DEBUG_VERIFY"] = OT_SCENE_DEBUG_VERIFY
        map["OT_SESSION_OPEN"] = OT_SESSION_OPEN
        map["OT_SESSION_CLOSING"] = OT_SESSION_CLOSING
        map["OT_SESSION_CLOSED_STATE"] = OT_SESSION_CLOSED_STATE
        map["OT_SESSION_FAILED"] = OT_SESSION_FAILED
        map["OT_SESSION_CANCELLED_STATE"] = OT_SESSION_CANCELLED_STATE
        map["OT_SESSION_REMOTE_AUTO"] = OT_SESSION_REMOTE_AUTO
        map["OT_SESSION_REMOTE_LOCAL"] = OT_SESSION_REMOTE_LOCAL
        map["OT_SESSION_REMOTE_REMOTE"] = OT_SESSION_REMOTE_REMOTE
        map["OT_SESSION_ENV_ENTRIES_MAX"] = OT_SESSION_ENV_ENTRIES_MAX
        map["OT_SESSION_ENV_BYTES_MAX"] = OT_SESSION_ENV_BYTES_MAX
        map["OT_RENDER_PRESENTED"] = OT_RENDER_PRESENTED
        map["OT_RENDER_PENDING"] = OT_RENDER_PENDING
        map["OT_RENDER_SKIPPED"] = OT_RENDER_SKIPPED
        map["OT_RENDER_FAILED"] = OT_RENDER_FAILED
        map["OT_SPLIT_SNAPSHOTS_MAX"] = OT_SPLIT_SNAPSHOTS_MAX
        map["OT_SESSION_BUFFER_CURRENT"] = OT_SESSION_BUFFER_CURRENT
        map["OT_SESSION_BUFFER_NEXT"] = OT_SESSION_BUFFER_NEXT
        map["OT_WIDTH_METHOD_WCWIDTH"] = OT_WIDTH_METHOD_WCWIDTH
        map["OT_WIDTH_METHOD_UNICODE"] = OT_WIDTH_METHOD_UNICODE
        map["OT_WIDTH_METHOD_NO_ZWJ"] = OT_WIDTH_METHOD_NO_ZWJ
        map["OT_WIDTH_METHOD_UNICODE_WIDE"] = OT_WIDTH_METHOD_UNICODE_WIDE
        map["OT_BUFFER_RESPECT_ALPHA"] = OT_BUFFER_RESPECT_ALPHA
        map["OT_EMBEDDED_TERMINAL_CURSOR_BAR"] = OT_EMBEDDED_TERMINAL_CURSOR_BAR
        map["OT_EMBEDDED_TERMINAL_CURSOR_BLOCK"] = OT_EMBEDDED_TERMINAL_CURSOR_BLOCK
        map["OT_EMBEDDED_TERMINAL_CURSOR_UNDERLINE"] = OT_EMBEDDED_TERMINAL_CURSOR_UNDERLINE
        map["OT_EMBEDDED_TERMINAL_CURSOR_BLOCK_HOLLOW"] = OT_EMBEDDED_TERMINAL_CURSOR_BLOCK_HOLLOW
        map["OT_EMBEDDED_TERMINAL_MOD_SHIFT"] = OT_EMBEDDED_TERMINAL_MOD_SHIFT
        map["OT_EMBEDDED_TERMINAL_MOD_CTRL"] = OT_EMBEDDED_TERMINAL_MOD_CTRL
        map["OT_EMBEDDED_TERMINAL_MOD_ALT"] = OT_EMBEDDED_TERMINAL_MOD_ALT
        map["OT_EMBEDDED_TERMINAL_MOD_SUPER"] = OT_EMBEDDED_TERMINAL_MOD_SUPER
        map["OT_EMBEDDED_TERMINAL_MOD_CAPS_LOCK"] = OT_EMBEDDED_TERMINAL_MOD_CAPS_LOCK
        map["OT_EMBEDDED_TERMINAL_MOD_NUM_LOCK"] = OT_EMBEDDED_TERMINAL_MOD_NUM_LOCK
        map["OT_EMBEDDED_TERMINAL_KEY_RELEASE"] = OT_EMBEDDED_TERMINAL_KEY_RELEASE
        map["OT_EMBEDDED_TERMINAL_KEY_PRESS"] = OT_EMBEDDED_TERMINAL_KEY_PRESS
        map["OT_EMBEDDED_TERMINAL_KEY_REPEAT"] = OT_EMBEDDED_TERMINAL_KEY_REPEAT
        map["OT_EMBEDDED_TERMINAL_MOUSE_PRESS"] = OT_EMBEDDED_TERMINAL_MOUSE_PRESS
        map["OT_EMBEDDED_TERMINAL_MOUSE_RELEASE"] = OT_EMBEDDED_TERMINAL_MOUSE_RELEASE
        map["OT_EMBEDDED_TERMINAL_MOUSE_MOTION"] = OT_EMBEDDED_TERMINAL_MOUSE_MOTION
        map["OT_EMBEDDED_TERMINAL_BUTTON_NONE"] = OT_EMBEDDED_TERMINAL_BUTTON_NONE
        map["OT_EMBEDDED_TERMINAL_BUTTON_UNKNOWN"] = OT_EMBEDDED_TERMINAL_BUTTON_UNKNOWN
        map["OT_EMBEDDED_TERMINAL_BUTTON_LEFT"] = OT_EMBEDDED_TERMINAL_BUTTON_LEFT
        map["OT_EMBEDDED_TERMINAL_BUTTON_RIGHT"] = OT_EMBEDDED_TERMINAL_BUTTON_RIGHT
        map["OT_EMBEDDED_TERMINAL_BUTTON_MIDDLE"] = OT_EMBEDDED_TERMINAL_BUTTON_MIDDLE
        map["OT_EMBEDDED_TERMINAL_BUTTON_FOUR"] = OT_EMBEDDED_TERMINAL_BUTTON_FOUR
        map["OT_EMBEDDED_TERMINAL_BUTTON_FIVE"] = OT_EMBEDDED_TERMINAL_BUTTON_FIVE
        map["OT_EMBEDDED_TERMINAL_BUTTON_SIX"] = OT_EMBEDDED_TERMINAL_BUTTON_SIX
        map["OT_EMBEDDED_TERMINAL_BUTTON_SEVEN"] = OT_EMBEDDED_TERMINAL_BUTTON_SEVEN
        map["OT_EMBEDDED_TERMINAL_INPUT_BYTES_MAX"] = OT_EMBEDDED_TERMINAL_INPUT_BYTES_MAX
        map["OT_EMBEDDED_TERMINAL_INVALIDATE"] = OT_EMBEDDED_TERMINAL_INVALIDATE
        map["OT_EMBEDDED_TERMINAL_SCROLL"] = OT_EMBEDDED_TERMINAL_SCROLL
        map["OT_EMBEDDED_TERMINAL_CLEAR_SELECTION"] = OT_EMBEDDED_TERMINAL_CLEAR_SELECTION
        map["OT_EMBEDDED_TERMINAL_SET_TRANSPARENT_BACKGROUND"] = OT_EMBEDDED_TERMINAL_SET_TRANSPARENT_BACKGROUND
        map["OT_EMBEDDED_TERMINAL_RESPONSE_BYTES_MAX"] = OT_EMBEDDED_TERMINAL_RESPONSE_BYTES_MAX
        map["OT_EDIT_BUFFER_FOLLOW_SESSION_WIDTH"] = OT_EDIT_BUFFER_FOLLOW_SESSION_WIDTH
        map["OT_EDIT_CURSOR_CHANGED"] = OT_EDIT_CURSOR_CHANGED
        map["OT_EDIT_CONTENT_CHANGED"] = OT_EDIT_CONTENT_CHANGED
        map["OT_EDIT_HISTORY_CURSOR_CHANGED"] = OT_EDIT_HISTORY_CURSOR_CHANGED
        map["OT_MOUSE_POINTER_AUTO"] = OT_MOUSE_POINTER_AUTO
        map["OT_MOUSE_POINTER_DEFAULT"] = OT_MOUSE_POINTER_DEFAULT
        map["OT_MOUSE_POINTER_NONE"] = OT_MOUSE_POINTER_NONE
        map["OT_MOUSE_POINTER_CONTEXT_MENU"] = OT_MOUSE_POINTER_CONTEXT_MENU
        map["OT_MOUSE_POINTER_HELP"] = OT_MOUSE_POINTER_HELP
        map["OT_MOUSE_POINTER_POINTER"] = OT_MOUSE_POINTER_POINTER
        map["OT_MOUSE_POINTER_PROGRESS"] = OT_MOUSE_POINTER_PROGRESS
        map["OT_MOUSE_POINTER_WAIT"] = OT_MOUSE_POINTER_WAIT
        map["OT_MOUSE_POINTER_CELL"] = OT_MOUSE_POINTER_CELL
        map["OT_MOUSE_POINTER_CROSSHAIR"] = OT_MOUSE_POINTER_CROSSHAIR
        map["OT_MOUSE_POINTER_TEXT"] = OT_MOUSE_POINTER_TEXT
        map["OT_MOUSE_POINTER_VERTICAL_TEXT"] = OT_MOUSE_POINTER_VERTICAL_TEXT
        map["OT_MOUSE_POINTER_ALIAS"] = OT_MOUSE_POINTER_ALIAS
        map["OT_MOUSE_POINTER_COPY"] = OT_MOUSE_POINTER_COPY
        map["OT_MOUSE_POINTER_MOVE"] = OT_MOUSE_POINTER_MOVE
        map["OT_MOUSE_POINTER_NO_DROP"] = OT_MOUSE_POINTER_NO_DROP
        map["OT_MOUSE_POINTER_NOT_ALLOWED"] = OT_MOUSE_POINTER_NOT_ALLOWED
        map["OT_MOUSE_POINTER_GRAB"] = OT_MOUSE_POINTER_GRAB
        map["OT_MOUSE_POINTER_GRABBING"] = OT_MOUSE_POINTER_GRABBING
        map["OT_MOUSE_POINTER_ALL_SCROLL"] = OT_MOUSE_POINTER_ALL_SCROLL
        map["OT_MOUSE_POINTER_COL_RESIZE"] = OT_MOUSE_POINTER_COL_RESIZE
        map["OT_MOUSE_POINTER_ROW_RESIZE"] = OT_MOUSE_POINTER_ROW_RESIZE
        map["OT_MOUSE_POINTER_N_RESIZE"] = OT_MOUSE_POINTER_N_RESIZE
        map["OT_MOUSE_POINTER_E_RESIZE"] = OT_MOUSE_POINTER_E_RESIZE
        map["OT_MOUSE_POINTER_S_RESIZE"] = OT_MOUSE_POINTER_S_RESIZE
        map["OT_MOUSE_POINTER_W_RESIZE"] = OT_MOUSE_POINTER_W_RESIZE
        map["OT_MOUSE_POINTER_NE_RESIZE"] = OT_MOUSE_POINTER_NE_RESIZE
        map["OT_MOUSE_POINTER_NW_RESIZE"] = OT_MOUSE_POINTER_NW_RESIZE
        map["OT_MOUSE_POINTER_SE_RESIZE"] = OT_MOUSE_POINTER_SE_RESIZE
        map["OT_MOUSE_POINTER_SW_RESIZE"] = OT_MOUSE_POINTER_SW_RESIZE
        map["OT_MOUSE_POINTER_EW_RESIZE"] = OT_MOUSE_POINTER_EW_RESIZE
        map["OT_MOUSE_POINTER_NS_RESIZE"] = OT_MOUSE_POINTER_NS_RESIZE
        map["OT_MOUSE_POINTER_NESW_RESIZE"] = OT_MOUSE_POINTER_NESW_RESIZE
        map["OT_MOUSE_POINTER_NWSE_RESIZE"] = OT_MOUSE_POINTER_NWSE_RESIZE
        map["OT_MOUSE_POINTER_ZOOM_IN"] = OT_MOUSE_POINTER_ZOOM_IN
        map["OT_MOUSE_POINTER_ZOOM_OUT"] = OT_MOUSE_POINTER_ZOOM_OUT
        map["OT_MOUSE_POINTER_MAX"] = OT_MOUSE_POINTER_MAX
        map["OT_MOUSE_POINTER_UNCHANGED"] = OT_MOUSE_POINTER_UNCHANGED
        map["OT_EDIT_DELETE_FORWARD"] = OT_EDIT_DELETE_FORWARD
        map["OT_EDIT_BACKSPACE"] = OT_EDIT_BACKSPACE
        map["OT_EDIT_NEW_LINE"] = OT_EDIT_NEW_LINE
        map["OT_EDIT_DELETE_LINE"] = OT_EDIT_DELETE_LINE
        map["OT_EDIT_MOVE_LEFT"] = OT_EDIT_MOVE_LEFT
        map["OT_EDIT_MOVE_RIGHT"] = OT_EDIT_MOVE_RIGHT
        map["OT_EDIT_MOVE_UP"] = OT_EDIT_MOVE_UP
        map["OT_EDIT_MOVE_DOWN"] = OT_EDIT_MOVE_DOWN
        map["OT_EDIT_GOTO_LINE"] = OT_EDIT_GOTO_LINE
        map["OT_EDIT_CURSOR_OFFSET"] = OT_EDIT_CURSOR_OFFSET
        map["OT_EDIT_CLEAR"] = OT_EDIT_CLEAR
        map["OT_EDIT_CLEAR_HISTORY"] = OT_EDIT_CLEAR_HISTORY
        map["OT_EDIT_DEBUG_ROPE"] = OT_EDIT_DEBUG_ROPE
        map["OT_EDIT_CURSOR_OFFSET_ATOMIC"] = OT_EDIT_CURSOR_OFFSET_ATOMIC
        map["OT_EDIT_KEEP_OUTSIDE"] = OT_EDIT_KEEP_OUTSIDE
        map["OT_EDIT_ATOMIC"] = OT_EDIT_ATOMIC
        map["OT_EDIT_POSITION_CURSOR"] = OT_EDIT_POSITION_CURSOR
        map["OT_EDIT_POSITION_NEXT_WORD"] = OT_EDIT_POSITION_NEXT_WORD
        map["OT_EDIT_POSITION_PREV_WORD"] = OT_EDIT_POSITION_PREV_WORD
        map["OT_EDIT_POSITION_EOL"] = OT_EDIT_POSITION_EOL
        map["OT_EDIT_POSITION_OFFSET"] = OT_EDIT_POSITION_OFFSET
        map["OT_EDIT_POSITION_COORDS"] = OT_EDIT_POSITION_COORDS
        map["OT_EDIT_POSITION_LINE_START"] = OT_EDIT_POSITION_LINE_START
        map["OT_EDIT_POSITION_END"] = OT_EDIT_POSITION_END
        map["OT_EDIT_POSITION_PREV_CHAR"] = OT_EDIT_POSITION_PREV_CHAR
        map["OT_EDIT_BYTE_TO_CELL"] = OT_EDIT_BYTE_TO_CELL
        map["OT_EDIT_CELL_TO_BYTE"] = OT_EDIT_CELL_TO_BYTE
        map["OT_EDIT_UTF16_TO_CELL"] = OT_EDIT_UTF16_TO_CELL
        map["OT_EDIT_CELL_TO_UTF16"] = OT_EDIT_CELL_TO_UTF16
        map["OT_EDITOR_STYLE_FOREGROUND"] = OT_EDITOR_STYLE_FOREGROUND
        map["OT_EDITOR_STYLE_BACKGROUND"] = OT_EDITOR_STYLE_BACKGROUND
        map["OT_EDITOR_STYLE_ATTRIBUTES"] = OT_EDITOR_STYLE_ATTRIBUTES
        map["OT_EDITOR_STYLE_ATTRIBUTE_MASK"] = OT_EDITOR_STYLE_ATTRIBUTE_MASK
        map["OT_EDIT_HIGHLIGHT_ADD_LINE"] = OT_EDIT_HIGHLIGHT_ADD_LINE
        map["OT_EDIT_HIGHLIGHT_ADD_RANGE"] = OT_EDIT_HIGHLIGHT_ADD_RANGE
        map["OT_EDIT_HIGHLIGHT_REMOVE_REF"] = OT_EDIT_HIGHLIGHT_REMOVE_REF
        map["OT_EDIT_HIGHLIGHT_CLEAR_LINE"] = OT_EDIT_HIGHLIGHT_CLEAR_LINE
        map["OT_EDIT_HIGHLIGHT_CLEAR_ALL"] = OT_EDIT_HIGHLIGHT_CLEAR_ALL
    }
    private static func populateConstantsChunk3(_ map: inout [String: Int64]) {
        map["OT_STYLE_RUN_FLAG"] = OT_STYLE_RUN_FLAG
        map["OT_GROUP_SET_NAME_COUNT_MAX"] = OT_GROUP_SET_NAME_COUNT_MAX
        map["OT_GROUP_SET_NAME_BYTE_COUNT_MAX"] = OT_GROUP_SET_NAME_BYTE_COUNT_MAX
        map["OT_EDIT_MARK_ADD"] = OT_EDIT_MARK_ADD
        map["OT_EDIT_MARK_REMOVE"] = OT_EDIT_MARK_REMOVE
        map["OT_EDIT_MARK_CLEAR"] = OT_EDIT_MARK_CLEAR
        map["OT_EDIT_MARK_ATOMIC"] = OT_EDIT_MARK_ATOMIC
        map["OT_EDIT_MARK_STYLE_VALUE"] = OT_EDIT_MARK_STYLE_VALUE
        map["OT_EDIT_MARK_ANY_KIND"] = OT_EDIT_MARK_ANY_KIND
        map["OT_MD_CONCEAL"] = OT_MD_CONCEAL
        map["OT_MD_HYPERLINKS"] = OT_MD_HYPERLINKS
        map["OT_MD_MATH"] = OT_MD_MATH
        map["OT_MD_HOOK"] = OT_MD_HOOK
        map["OT_MD_HOOK_FILTER_BYTE_COUNT_MAX"] = OT_MD_HOOK_FILTER_BYTE_COUNT_MAX
        map["OT_MD_PARAGRAPH"] = OT_MD_PARAGRAPH
        map["OT_MD_HEADING"] = OT_MD_HEADING
        map["OT_MD_CODE"] = OT_MD_CODE
        map["OT_MD_HTML"] = OT_MD_HTML
        map["OT_MD_RULE"] = OT_MD_RULE
        map["OT_MD_TABLE"] = OT_MD_TABLE
        map["OT_MD_TABLE_ROW"] = OT_MD_TABLE_ROW
        map["OT_MD_TABLE_CELL"] = OT_MD_TABLE_CELL
        map["OT_MD_QUOTE"] = OT_MD_QUOTE
        map["OT_MD_LIST"] = OT_MD_LIST
        map["OT_MD_ITEM"] = OT_MD_ITEM
        map["OT_MD_BLOCK_CLOSED"] = OT_MD_BLOCK_CLOSED
        map["OT_MD_BLOCK_SETEXT"] = OT_MD_BLOCK_SETEXT
        map["OT_MD_BLOCK_ORDERED"] = OT_MD_BLOCK_ORDERED
        map["OT_MD_BLOCK_TIGHT"] = OT_MD_BLOCK_TIGHT
        map["OT_MD_BLOCK_TASK"] = OT_MD_BLOCK_TASK
        map["OT_MD_BLOCK_CHECKED"] = OT_MD_BLOCK_CHECKED
        map["OT_MD_BLOCK_BLANK_AFTER"] = OT_MD_BLOCK_BLANK_AFTER
        map["OT_MD_BLOCK_FENCED"] = OT_MD_BLOCK_FENCED
        map["OT_MD_BLOCK_HOOKED"] = OT_MD_BLOCK_HOOKED
        map["OT_MD_BLOCK_MATH"] = OT_MD_BLOCK_MATH
        map["OT_MD_BLOCK_HEADER"] = OT_MD_BLOCK_HEADER
        map["OT_MD_BLOCK_OPEN"] = OT_MD_BLOCK_OPEN
        map["OT_MD_BLOCK_ALIGN_LEFT"] = OT_MD_BLOCK_ALIGN_LEFT
        map["OT_MD_BLOCK_ALIGN_RIGHT"] = OT_MD_BLOCK_ALIGN_RIGHT
        map["OT_MD_SPAN_CODE"] = OT_MD_SPAN_CODE
        map["OT_MD_SPAN_MATH"] = OT_MD_SPAN_MATH
        map["OT_EDITOR_MOVE_UP"] = OT_EDITOR_MOVE_UP
        map["OT_EDITOR_MOVE_DOWN"] = OT_EDITOR_MOVE_DOWN
        map["OT_EDITOR_GOTO_LINE_END"] = OT_EDITOR_GOTO_LINE_END
        map["OT_EDITOR_DELETE_SELECTION"] = OT_EDITOR_DELETE_SELECTION
        map["OT_EDITOR_CURSOR_OFFSET"] = OT_EDITOR_CURSOR_OFFSET
        map["OT_EDITOR_WRAP_MODE"] = OT_EDITOR_WRAP_MODE
        map["OT_EDITOR_TAB_INDICATOR"] = OT_EDITOR_TAB_INDICATOR
        map["OT_EDITOR_SELECT_SET"] = OT_EDITOR_SELECT_SET
        map["OT_EDITOR_SELECT_UPDATE"] = OT_EDITOR_SELECT_UPDATE
        map["OT_EDITOR_SELECT_RESET"] = OT_EDITOR_SELECT_RESET
        map["OT_EDITOR_SELECT_LOCAL"] = OT_EDITOR_SELECT_LOCAL
        map["OT_EDITOR_SELECT_LOCAL_UPDATE"] = OT_EDITOR_SELECT_LOCAL_UPDATE
        map["OT_EDITOR_SELECT_LOCAL_RESET"] = OT_EDITOR_SELECT_LOCAL_RESET
        map["OT_EDITOR_SELECT_CELL"] = OT_EDITOR_SELECT_CELL
        map["OT_EDITOR_SELECT_OCCUPANCY"] = OT_EDITOR_SELECT_OCCUPANCY
        map["OT_EDITOR_SELECT_INCLUSIVE"] = OT_EDITOR_SELECT_INCLUSIVE
        map["OT_EDITOR_SELECT_COLORS"] = OT_EDITOR_SELECT_COLORS
        map["OT_SELECT_DOCUMENT_SET"] = OT_SELECT_DOCUMENT_SET
        map["OT_SELECT_DOCUMENT_UPDATE"] = OT_SELECT_DOCUMENT_UPDATE
        map["OT_SELECT_DOCUMENT_RESET"] = OT_SELECT_DOCUMENT_RESET
        map["OT_SELECT_VIEWPORT_SET"] = OT_SELECT_VIEWPORT_SET
        map["OT_SELECT_VIEWPORT_UPDATE"] = OT_SELECT_VIEWPORT_UPDATE
        map["OT_SELECT_VIEWPORT_RESET"] = OT_SELECT_VIEWPORT_RESET
        map["OT_SELECTION_CELL"] = OT_SELECTION_CELL
        map["OT_SELECTION_WORD"] = OT_SELECTION_WORD
        map["OT_SELECTION_LINE"] = OT_SELECTION_LINE
        map["OT_SELECTION_OCCUPANCY_CELL"] = OT_SELECTION_OCCUPANCY_CELL
        map["OT_SELECTION_OCCUPANCY_BOUNDARY"] = OT_SELECTION_OCCUPANCY_BOUNDARY
        map["OT_EDITOR_POSITION_CURSOR"] = OT_EDITOR_POSITION_CURSOR
        map["OT_EDITOR_POSITION_NEXT_WORD"] = OT_EDITOR_POSITION_NEXT_WORD
        map["OT_EDITOR_POSITION_PREV_WORD"] = OT_EDITOR_POSITION_PREV_WORD
        map["OT_EDITOR_POSITION_EOL"] = OT_EDITOR_POSITION_EOL
        map["OT_EDITOR_POSITION_VISUAL_SOL"] = OT_EDITOR_POSITION_VISUAL_SOL
        map["OT_EDITOR_POSITION_VISUAL_EOL"] = OT_EDITOR_POSITION_VISUAL_EOL
        map["OT_IMAGE_FIT"] = OT_IMAGE_FIT
        map["OT_IMAGE_COVER"] = OT_IMAGE_COVER
        map["OT_IMAGE_FILL"] = OT_IMAGE_FILL
        map["OT_IMAGE_PROTOCOL_AUTO"] = OT_IMAGE_PROTOCOL_AUTO
        map["OT_IMAGE_PROTOCOL_KITTY"] = OT_IMAGE_PROTOCOL_KITTY
        map["OT_IMAGE_PROTOCOL_SIXEL"] = OT_IMAGE_PROTOCOL_SIXEL
        map["OT_IMAGE_PROTOCOL_BLOCKS"] = OT_IMAGE_PROTOCOL_BLOCKS
        map["OT_IMAGE_DRAW_SOURCE_WIDTH"] = OT_IMAGE_DRAW_SOURCE_WIDTH
        map["OT_IMAGE_DRAW_SOURCE_HEIGHT"] = OT_IMAGE_DRAW_SOURCE_HEIGHT
        map["OT_IMAGE_ENCODED_BYTES_MAX"] = OT_IMAGE_ENCODED_BYTES_MAX
        map["OT_IMAGE_FORMAT_UNKNOWN"] = OT_IMAGE_FORMAT_UNKNOWN
        map["OT_IMAGE_FORMAT_PNG"] = OT_IMAGE_FORMAT_PNG
        map["OT_IMAGE_FORMAT_RGBA"] = OT_IMAGE_FORMAT_RGBA
        map["OT_IMAGE_FORMAT_JPEG"] = OT_IMAGE_FORMAT_JPEG
        map["OT_IMAGE_FORMAT_WEBP"] = OT_IMAGE_FORMAT_WEBP
        map["OT_IMAGE_FORMAT_GIF"] = OT_IMAGE_FORMAT_GIF
        map["OT_IMAGE_ASSUMED_SRGB"] = OT_IMAGE_ASSUMED_SRGB
        map["OT_IMAGE_EXPLICIT_SRGB"] = OT_IMAGE_EXPLICIT_SRGB
        map["OT_IMAGE_RGBA8"] = OT_IMAGE_RGBA8
        map["OT_IMAGE_BGRA8"] = OT_IMAGE_BGRA8
        map["OT_IMAGE_ALPHA_STRAIGHT"] = OT_IMAGE_ALPHA_STRAIGHT
        map["OT_IMAGE_ALPHA_OPAQUE"] = OT_IMAGE_ALPHA_OPAQUE
        map["OT_IMAGE_FILTER_DEFAULT"] = OT_IMAGE_FILTER_DEFAULT
        map["OT_IMAGE_FILTER_AREA"] = OT_IMAGE_FILTER_AREA
        map["OT_IMAGE_FILTER_TRIANGLE"] = OT_IMAGE_FILTER_TRIANGLE
        map["OT_IMAGE_FILTER_CUBIC_BSPLINE"] = OT_IMAGE_FILTER_CUBIC_BSPLINE
        map["OT_IMAGE_FILTER_CATMULL_ROM"] = OT_IMAGE_FILTER_CATMULL_ROM
        map["OT_IMAGE_FILTER_MITCHELL"] = OT_IMAGE_FILTER_MITCHELL
        map["OT_IMAGE_FILTER_NEAREST"] = OT_IMAGE_FILTER_NEAREST
        map["OT_IMAGE_ROTATE_90"] = OT_IMAGE_ROTATE_90
        map["OT_IMAGE_ROTATE_180"] = OT_IMAGE_ROTATE_180
        map["OT_IMAGE_ROTATE_270"] = OT_IMAGE_ROTATE_270
        map["OT_IMAGE_FLIP"] = OT_IMAGE_FLIP
        map["OT_IMAGE_FLOP"] = OT_IMAGE_FLOP
        map["OT_IMAGE_BLEND_SOURCE_OVER"] = OT_IMAGE_BLEND_SOURCE_OVER
        map["OT_IMAGE_BLEND_SOURCE"] = OT_IMAGE_BLEND_SOURCE
        map["OT_IMAGE_BLEND_DESTINATION_OVER"] = OT_IMAGE_BLEND_DESTINATION_OVER
        map["OT_VIDEO_OPEN_NO_AUDIO"] = OT_VIDEO_OPEN_NO_AUDIO
        map["OT_VIDEO_PLAYING"] = OT_VIDEO_PLAYING
        map["OT_VIDEO_ENDED"] = OT_VIDEO_ENDED
        map["OT_VIDEO_BUFFERING"] = OT_VIDEO_BUFFERING
        map["OT_VIDEO_AUDIO"] = OT_VIDEO_AUDIO
        map["OT_VIDEO_HAS_FRAME"] = OT_VIDEO_HAS_FRAME
        map["OT_VIDEO_ERROR"] = OT_VIDEO_ERROR
        map["OT_AUDIO_START_NO_DEVICE"] = OT_AUDIO_START_NO_DEVICE
        map["OT_TEXT_VIEW_WRAP_WIDTH"] = OT_TEXT_VIEW_WRAP_WIDTH
        map["OT_TEXT_VIEW_WRAP_MODE"] = OT_TEXT_VIEW_WRAP_MODE
        map["OT_TEXT_VIEW_FIRST_LINE_OFFSET"] = OT_TEXT_VIEW_FIRST_LINE_OFFSET
        map["OT_TEXT_VIEW_TAB_INDICATOR"] = OT_TEXT_VIEW_TAB_INDICATOR
        map["OT_TEXT_VIEW_TRUNCATE"] = OT_TEXT_VIEW_TRUNCATE
        map["OT_TEXT_VIEW_TEXT_ALIGN"] = OT_TEXT_VIEW_TEXT_ALIGN
        map["OT_TEXT_REPLACEMENT_COUNT_MAX"] = OT_TEXT_REPLACEMENT_COUNT_MAX
        map["OT_TEXT_REPLACEMENT_CHUNKS_MAX"] = OT_TEXT_REPLACEMENT_CHUNKS_MAX
        map["OT_TEXT_REPLACEMENT_BYTES_MAX"] = OT_TEXT_REPLACEMENT_BYTES_MAX
        map["OT_TEXT_REPLACEMENT_URL_BYTES_MAX"] = OT_TEXT_REPLACEMENT_URL_BYTES_MAX
        map["OT_BUFFER_TEXT_BYTES_MAX"] = OT_BUFFER_TEXT_BYTES_MAX
        map["OT_BUFFER_DRAW_CLEAR"] = OT_BUFFER_DRAW_CLEAR
        map["OT_BUFFER_DRAW_FILL"] = OT_BUFFER_DRAW_FILL
        map["OT_BUFFER_DRAW_TEXT"] = OT_BUFFER_DRAW_TEXT
        map["OT_BUFFER_DRAW_CELL"] = OT_BUFFER_DRAW_CELL
        map["OT_BUFFER_DRAW_CELL_BLEND"] = OT_BUFFER_DRAW_CELL_BLEND
        map["OT_BUFFER_DRAW_CHAR"] = OT_BUFFER_DRAW_CHAR
        map["OT_BUFFER_DRAW_BOX"] = OT_BUFFER_DRAW_BOX
        map["OT_BUFFER_DRAW_COMPOSE"] = OT_BUFFER_DRAW_COMPOSE
        map["OT_BUFFER_DRAW_RESPECT_ALPHA"] = OT_BUFFER_DRAW_RESPECT_ALPHA
        map["OT_BUFFER_DRAW_HAS_BACKGROUND"] = OT_BUFFER_DRAW_HAS_BACKGROUND
        map["OT_BUFFER_DRAW_HAS_SOURCE_WIDTH"] = OT_BUFFER_DRAW_HAS_SOURCE_WIDTH
        map["OT_BUFFER_DRAW_HAS_SOURCE_HEIGHT"] = OT_BUFFER_DRAW_HAS_SOURCE_HEIGHT
        map["OT_BUFFER_DRAW_FIT_ELLIPSIS"] = OT_BUFFER_DRAW_FIT_ELLIPSIS
        map["OT_BUFFER_STACK_DEPTH_MAX"] = OT_BUFFER_STACK_DEPTH_MAX
        map["OT_BUFFER_STACK_GET_OPACITY"] = OT_BUFFER_STACK_GET_OPACITY
        map["OT_BUFFER_STACK_PUSH_SCISSOR"] = OT_BUFFER_STACK_PUSH_SCISSOR
        map["OT_BUFFER_STACK_POP_SCISSOR"] = OT_BUFFER_STACK_POP_SCISSOR
        map["OT_BUFFER_STACK_CLEAR_SCISSORS"] = OT_BUFFER_STACK_CLEAR_SCISSORS
        map["OT_BUFFER_STACK_PUSH_OPACITY"] = OT_BUFFER_STACK_PUSH_OPACITY
    }
    private static func populateConstantsChunk4(_ map: inout [String: Int64]) {
        map["OT_BUFFER_STACK_POP_OPACITY"] = OT_BUFFER_STACK_POP_OPACITY
        map["OT_BUFFER_STACK_CLEAR_OPACITY"] = OT_BUFFER_STACK_CLEAR_OPACITY
        map["OT_BUFFER_GRID_INNER"] = OT_BUFFER_GRID_INNER
        map["OT_BUFFER_GRID_OUTER"] = OT_BUFFER_GRID_OUTER
        map["OT_CELL_CHAR_KIND_MASK"] = OT_CELL_CHAR_KIND_MASK
        map["OT_CELL_CHAR_IMAGE"] = OT_CELL_CHAR_IMAGE
        map["OT_CELL_CHAR_GRAPHEME"] = OT_CELL_CHAR_GRAPHEME
        map["OT_CELL_CHAR_CONTINUATION"] = OT_CELL_CHAR_CONTINUATION
        map["OT_SESSION_CONTROL_PACKET_BYTES"] = OT_SESSION_CONTROL_PACKET_BYTES
        map["OT_TERMINAL_ALTERNATE_SCREEN"] = OT_TERMINAL_ALTERNATE_SCREEN
        map["OT_TERMINAL_MOUSE"] = OT_TERMINAL_MOUSE
        map["OT_TERMINAL_MOUSE_MOVEMENT"] = OT_TERMINAL_MOUSE_MOVEMENT
        map["OT_TERMINAL_CLEAR_ON_CLOSE"] = OT_TERMINAL_CLEAR_ON_CLOSE
        map["OT_TERMINAL_REPLY_SENTINEL"] = OT_TERMINAL_REPLY_SENTINEL
        map["OT_TERMINAL_SYNC_ALWAYS"] = OT_TERMINAL_SYNC_ALWAYS
        map["OT_TERMINAL_SYNC_NEVER"] = OT_TERMINAL_SYNC_NEVER
        map["OT_TERMINAL_HOST_MULTIPLEXER"] = OT_TERMINAL_HOST_MULTIPLEXER
        map["OT_KITTY_KEYBOARD_DISAMBIGUATE"] = OT_KITTY_KEYBOARD_DISAMBIGUATE
        map["OT_KITTY_KEYBOARD_EVENT_TYPES"] = OT_KITTY_KEYBOARD_EVENT_TYPES
        map["OT_KITTY_KEYBOARD_ALTERNATE_KEYS"] = OT_KITTY_KEYBOARD_ALTERNATE_KEYS
        map["OT_KITTY_KEYBOARD_ALL_KEYS_AS_ESCAPES"] = OT_KITTY_KEYBOARD_ALL_KEYS_AS_ESCAPES
        map["OT_KITTY_KEYBOARD_REPORT_TEXT"] = OT_KITTY_KEYBOARD_REPORT_TEXT
        map["OT_KITTY_KEYBOARD_ALL"] = OT_KITTY_KEYBOARD_ALL
        map["OT_CONTROL_CAPABILITY_RESPONSE"] = OT_CONTROL_CAPABILITY_RESPONSE
        map["OT_CONTROL_TITLE"] = OT_CONTROL_TITLE
        map["OT_CONTROL_MOUSE"] = OT_CONTROL_MOUSE
        map["OT_CONTROL_KITTY_KEYBOARD_FLAGS"] = OT_CONTROL_KITTY_KEYBOARD_FLAGS
        map["OT_CONTROL_RESTORE_MODES"] = OT_CONTROL_RESTORE_MODES
        map["OT_CONTROL_QUERY_PIXEL_RESOLUTION"] = OT_CONTROL_QUERY_PIXEL_RESOLUTION
        map["OT_CONTROL_QUERY_THEME_COLORS"] = OT_CONTROL_QUERY_THEME_COLORS
        map["OT_CONTROL_CURSOR"] = OT_CONTROL_CURSOR
        map["OT_CONTROL_RESET_BACKGROUND"] = OT_CONTROL_RESET_BACKGROUND
        map["OT_CONTROL_PALETTE_QUERY"] = OT_CONTROL_PALETTE_QUERY
        map["OT_CONTROL_PROGRAM_STATUS"] = OT_CONTROL_PROGRAM_STATUS
        map["OT_CONTROL_END_REPLY_SENTINEL"] = OT_CONTROL_END_REPLY_SENTINEL
        map["OT_CURSOR_POSITION"] = OT_CURSOR_POSITION
        map["OT_CURSOR_STYLE"] = OT_CURSOR_STYLE
        map["OT_CURSOR_BLINKING"] = OT_CURSOR_BLINKING
        map["OT_CURSOR_COLOR"] = OT_CURSOR_COLOR
        map["OT_CURSOR_MOUSE_POINTER"] = OT_CURSOR_MOUSE_POINTER
        map["OT_PROGRAM_STATE_IDLE"] = OT_PROGRAM_STATE_IDLE
        map["OT_PROGRAM_STATE_WORKING"] = OT_PROGRAM_STATE_WORKING
        map["OT_PROGRAM_STATE_DONE"] = OT_PROGRAM_STATE_DONE
        map["OT_PROGRAM_STATE_BLOCKED"] = OT_PROGRAM_STATE_BLOCKED
        map["OT_PROGRAM_STATE_ERROR"] = OT_PROGRAM_STATE_ERROR
        map["OT_PROGRAM_STATE_CLEAR"] = OT_PROGRAM_STATE_CLEAR
        map["OT_PROGRAM_KIND_PERMISSION"] = OT_PROGRAM_KIND_PERMISSION
        map["OT_PROGRAM_KIND_QUESTION"] = OT_PROGRAM_KIND_QUESTION
        map["OT_PROGRAM_KIND_AUTH"] = OT_PROGRAM_KIND_AUTH
        map["OT_PROGRAM_STATUS_PROGRESS"] = OT_PROGRAM_STATUS_PROGRESS
        map["OT_CAP_KITTY_KEYBOARD"] = OT_CAP_KITTY_KEYBOARD
        map["OT_CAP_KITTY_GRAPHICS"] = OT_CAP_KITTY_GRAPHICS
        map["OT_CAP_RGB"] = OT_CAP_RGB
        map["OT_CAP_ANSI256"] = OT_CAP_ANSI256
        map["OT_CAP_SGR_PIXELS"] = OT_CAP_SGR_PIXELS
        map["OT_CAP_COLOR_SCHEME_UPDATES"] = OT_CAP_COLOR_SCHEME_UPDATES
        map["OT_CAP_EXPLICIT_WIDTH"] = OT_CAP_EXPLICIT_WIDTH
        map["OT_CAP_SCALED_TEXT"] = OT_CAP_SCALED_TEXT
        map["OT_CAP_SIXEL"] = OT_CAP_SIXEL
        map["OT_CAP_FOCUS_TRACKING"] = OT_CAP_FOCUS_TRACKING
        map["OT_CAP_SYNC"] = OT_CAP_SYNC
        map["OT_CAP_BRACKETED_PASTE"] = OT_CAP_BRACKETED_PASTE
        map["OT_CAP_HYPERLINKS"] = OT_CAP_HYPERLINKS
        map["OT_CAP_OSC52"] = OT_CAP_OSC52
        map["OT_CAP_NOTIFICATIONS"] = OT_CAP_NOTIFICATIONS
        map["OT_CAP_EXPLICIT_CURSOR_POSITIONING"] = OT_CAP_EXPLICIT_CURSOR_POSITIONING
        map["OT_CAP_REMOTE"] = OT_CAP_REMOTE
        map["OT_CAP_PROGRAM_STATUS"] = OT_CAP_PROGRAM_STATUS
        map["OT_TERMINAL_UNINITIALIZED"] = OT_TERMINAL_UNINITIALIZED
        map["OT_TERMINAL_SETTING_UP"] = OT_TERMINAL_SETTING_UP
        map["OT_TERMINAL_ACTIVE"] = OT_TERMINAL_ACTIVE
        map["OT_TERMINAL_SUSPENDING"] = OT_TERMINAL_SUSPENDING
        map["OT_TERMINAL_SUSPENDED"] = OT_TERMINAL_SUSPENDED
        map["OT_TERMINAL_RESUMING"] = OT_TERMINAL_RESUMING
        map["OT_TERMINAL_CLOSING"] = OT_TERMINAL_CLOSING
        map["OT_TERMINAL_RESTORED"] = OT_TERMINAL_RESTORED
        map["OT_TERMINAL_FAILED"] = OT_TERMINAL_FAILED
        map["OT_TERMINAL_CANCELLED"] = OT_TERMINAL_CANCELLED
        map["OT_PUMP_IDLE"] = OT_PUMP_IDLE
        map["OT_PUMP_AGAIN"] = OT_PUMP_AGAIN
        map["OT_PUMP_OUTPUT_PENDING"] = OT_PUMP_OUTPUT_PENDING
        map["OT_PUMP_WAIT_UNTIL"] = OT_PUMP_WAIT_UNTIL
        map["OT_PUMP_CLOSED"] = OT_PUMP_CLOSED
        map["OT_STDOUT_IDLE"] = OT_STDOUT_IDLE
        map["OT_STDOUT_IN_FLIGHT"] = OT_STDOUT_IN_FLIGHT
        map["OT_INPUT_KEY"] = OT_INPUT_KEY
        map["OT_INPUT_MOUSE"] = OT_INPUT_MOUSE
        map["OT_INPUT_PASTE"] = OT_INPUT_PASTE
        map["OT_INPUT_FOCUS"] = OT_INPUT_FOCUS
        map["OT_INPUT_REPLY"] = OT_INPUT_REPLY
        map["OT_INPUT_KEY_PRESS"] = OT_INPUT_KEY_PRESS
        map["OT_INPUT_KEY_REPEAT"] = OT_INPUT_KEY_REPEAT
        map["OT_INPUT_KEY_RELEASE"] = OT_INPUT_KEY_RELEASE
        map["OT_INPUT_MOUSE_DOWN"] = OT_INPUT_MOUSE_DOWN
        map["OT_INPUT_MOUSE_UP"] = OT_INPUT_MOUSE_UP
        map["OT_INPUT_MOUSE_MOVE"] = OT_INPUT_MOUSE_MOVE
        map["OT_INPUT_MOUSE_DRAG"] = OT_INPUT_MOUSE_DRAG
        map["OT_INPUT_MOUSE_SCROLL"] = OT_INPUT_MOUSE_SCROLL
        map["OT_INPUT_MOUSE_BUTTON_NONE"] = OT_INPUT_MOUSE_BUTTON_NONE
        map["OT_INPUT_FOCUS_OUT"] = OT_INPUT_FOCUS_OUT
        map["OT_INPUT_FOCUS_IN"] = OT_INPUT_FOCUS_IN
        map["OT_INPUT_MOD_SHIFT"] = OT_INPUT_MOD_SHIFT
        map["OT_INPUT_MOD_ALT"] = OT_INPUT_MOD_ALT
        map["OT_INPUT_MOD_CTRL"] = OT_INPUT_MOD_CTRL
        map["OT_INPUT_MOD_SUPER"] = OT_INPUT_MOD_SUPER
        map["OT_INPUT_MOD_HYPER"] = OT_INPUT_MOD_HYPER
        map["OT_INPUT_MOD_META"] = OT_INPUT_MOD_META
        map["OT_INPUT_MOD_CAPS_LOCK"] = OT_INPUT_MOD_CAPS_LOCK
        map["OT_INPUT_MOD_NUM_LOCK"] = OT_INPUT_MOD_NUM_LOCK
        map["OT_INPUT_KEY_KITTY"] = OT_INPUT_KEY_KITTY
        map["OT_INPUT_KEY_TEXT_TRUNCATED"] = OT_INPUT_KEY_TEXT_TRUNCATED
        map["OT_INPUT_KEY_TYPED"] = OT_INPUT_KEY_TYPED
        map["OT_INPUT_PASTE_START"] = OT_INPUT_PASTE_START
        map["OT_INPUT_PASTE_END"] = OT_INPUT_PASTE_END
        map["OT_INPUT_REPLY_FRAGMENT"] = OT_INPUT_REPLY_FRAGMENT
        map["OT_INPUT_REPLY_CURSOR_POSITION"] = OT_INPUT_REPLY_CURSOR_POSITION
        map["OT_INPUT_REPLY_CSI"] = OT_INPUT_REPLY_CSI
        map["OT_INPUT_REPLY_SS3"] = OT_INPUT_REPLY_SS3
        map["OT_INPUT_REPLY_OSC"] = OT_INPUT_REPLY_OSC
        map["OT_INPUT_REPLY_DCS"] = OT_INPUT_REPLY_DCS
        map["OT_INPUT_REPLY_APC"] = OT_INPUT_REPLY_APC
        map["OT_INPUT_KEY_ESCAPE"] = OT_INPUT_KEY_ESCAPE
        map["OT_INPUT_KEY_ENTER"] = OT_INPUT_KEY_ENTER
        map["OT_INPUT_KEY_TAB"] = OT_INPUT_KEY_TAB
        map["OT_INPUT_KEY_BACKSPACE"] = OT_INPUT_KEY_BACKSPACE
        map["OT_INPUT_KEY_INSERT"] = OT_INPUT_KEY_INSERT
        map["OT_INPUT_KEY_DELETE"] = OT_INPUT_KEY_DELETE
        map["OT_INPUT_KEY_LEFT"] = OT_INPUT_KEY_LEFT
        map["OT_INPUT_KEY_RIGHT"] = OT_INPUT_KEY_RIGHT
        map["OT_INPUT_KEY_UP"] = OT_INPUT_KEY_UP
        map["OT_INPUT_KEY_DOWN"] = OT_INPUT_KEY_DOWN
        map["OT_INPUT_KEY_PAGE_UP"] = OT_INPUT_KEY_PAGE_UP
        map["OT_INPUT_KEY_PAGE_DOWN"] = OT_INPUT_KEY_PAGE_DOWN
        map["OT_INPUT_KEY_HOME"] = OT_INPUT_KEY_HOME
        map["OT_INPUT_KEY_END"] = OT_INPUT_KEY_END
        map["OT_INPUT_KEY_CAPS_LOCK"] = OT_INPUT_KEY_CAPS_LOCK
        map["OT_INPUT_KEY_SCROLL_LOCK"] = OT_INPUT_KEY_SCROLL_LOCK
        map["OT_INPUT_KEY_NUM_LOCK"] = OT_INPUT_KEY_NUM_LOCK
        map["OT_INPUT_KEY_PRINT_SCREEN"] = OT_INPUT_KEY_PRINT_SCREEN
        map["OT_INPUT_KEY_PAUSE"] = OT_INPUT_KEY_PAUSE
        map["OT_INPUT_KEY_MENU"] = OT_INPUT_KEY_MENU
        map["OT_INPUT_KEY_F1"] = OT_INPUT_KEY_F1
        map["OT_INPUT_KEY_F35"] = OT_INPUT_KEY_F35
        map["OT_INPUT_KEY_KP_0"] = OT_INPUT_KEY_KP_0
        map["OT_INPUT_KEY_KP_9"] = OT_INPUT_KEY_KP_9
        map["OT_INPUT_KEY_KP_DECIMAL"] = OT_INPUT_KEY_KP_DECIMAL
        map["OT_INPUT_KEY_KP_DIVIDE"] = OT_INPUT_KEY_KP_DIVIDE
        map["OT_INPUT_KEY_KP_MULTIPLY"] = OT_INPUT_KEY_KP_MULTIPLY
        map["OT_INPUT_KEY_KP_SUBTRACT"] = OT_INPUT_KEY_KP_SUBTRACT
        map["OT_INPUT_KEY_KP_ADD"] = OT_INPUT_KEY_KP_ADD
    }
    private static func populateConstantsChunk5(_ map: inout [String: Int64]) {
        map["OT_INPUT_KEY_KP_ENTER"] = OT_INPUT_KEY_KP_ENTER
        map["OT_INPUT_KEY_KP_EQUAL"] = OT_INPUT_KEY_KP_EQUAL
        map["OT_INPUT_KEY_KP_SEPARATOR"] = OT_INPUT_KEY_KP_SEPARATOR
        map["OT_INPUT_KEY_KP_LEFT"] = OT_INPUT_KEY_KP_LEFT
        map["OT_INPUT_KEY_KP_RIGHT"] = OT_INPUT_KEY_KP_RIGHT
        map["OT_INPUT_KEY_KP_UP"] = OT_INPUT_KEY_KP_UP
        map["OT_INPUT_KEY_KP_DOWN"] = OT_INPUT_KEY_KP_DOWN
        map["OT_INPUT_KEY_KP_PAGE_UP"] = OT_INPUT_KEY_KP_PAGE_UP
        map["OT_INPUT_KEY_KP_PAGE_DOWN"] = OT_INPUT_KEY_KP_PAGE_DOWN
        map["OT_INPUT_KEY_KP_HOME"] = OT_INPUT_KEY_KP_HOME
        map["OT_INPUT_KEY_KP_END"] = OT_INPUT_KEY_KP_END
        map["OT_INPUT_KEY_KP_INSERT"] = OT_INPUT_KEY_KP_INSERT
        map["OT_INPUT_KEY_KP_DELETE"] = OT_INPUT_KEY_KP_DELETE
        map["OT_INPUT_KEY_KP_BEGIN"] = OT_INPUT_KEY_KP_BEGIN
        map["OT_INPUT_KEY_MEDIA_PLAY"] = OT_INPUT_KEY_MEDIA_PLAY
        map["OT_INPUT_KEY_MEDIA_PAUSE"] = OT_INPUT_KEY_MEDIA_PAUSE
        map["OT_INPUT_KEY_MEDIA_PLAY_PAUSE"] = OT_INPUT_KEY_MEDIA_PLAY_PAUSE
        map["OT_INPUT_KEY_MEDIA_REVERSE"] = OT_INPUT_KEY_MEDIA_REVERSE
        map["OT_INPUT_KEY_MEDIA_STOP"] = OT_INPUT_KEY_MEDIA_STOP
        map["OT_INPUT_KEY_MEDIA_FAST_FORWARD"] = OT_INPUT_KEY_MEDIA_FAST_FORWARD
        map["OT_INPUT_KEY_MEDIA_REWIND"] = OT_INPUT_KEY_MEDIA_REWIND
        map["OT_INPUT_KEY_MEDIA_TRACK_NEXT"] = OT_INPUT_KEY_MEDIA_TRACK_NEXT
        map["OT_INPUT_KEY_MEDIA_TRACK_PREVIOUS"] = OT_INPUT_KEY_MEDIA_TRACK_PREVIOUS
        map["OT_INPUT_KEY_MEDIA_RECORD"] = OT_INPUT_KEY_MEDIA_RECORD
        map["OT_INPUT_KEY_LOWER_VOLUME"] = OT_INPUT_KEY_LOWER_VOLUME
        map["OT_INPUT_KEY_RAISE_VOLUME"] = OT_INPUT_KEY_RAISE_VOLUME
        map["OT_INPUT_KEY_MUTE_VOLUME"] = OT_INPUT_KEY_MUTE_VOLUME
        map["OT_INPUT_KEY_LEFT_SHIFT"] = OT_INPUT_KEY_LEFT_SHIFT
        map["OT_INPUT_KEY_LEFT_CONTROL"] = OT_INPUT_KEY_LEFT_CONTROL
        map["OT_INPUT_KEY_LEFT_ALT"] = OT_INPUT_KEY_LEFT_ALT
        map["OT_INPUT_KEY_LEFT_SUPER"] = OT_INPUT_KEY_LEFT_SUPER
        map["OT_INPUT_KEY_LEFT_HYPER"] = OT_INPUT_KEY_LEFT_HYPER
        map["OT_INPUT_KEY_LEFT_META"] = OT_INPUT_KEY_LEFT_META
        map["OT_INPUT_KEY_RIGHT_SHIFT"] = OT_INPUT_KEY_RIGHT_SHIFT
        map["OT_INPUT_KEY_RIGHT_CONTROL"] = OT_INPUT_KEY_RIGHT_CONTROL
        map["OT_INPUT_KEY_RIGHT_ALT"] = OT_INPUT_KEY_RIGHT_ALT
        map["OT_INPUT_KEY_RIGHT_SUPER"] = OT_INPUT_KEY_RIGHT_SUPER
        map["OT_INPUT_KEY_RIGHT_HYPER"] = OT_INPUT_KEY_RIGHT_HYPER
        map["OT_INPUT_KEY_RIGHT_META"] = OT_INPUT_KEY_RIGHT_META
        map["OT_INPUT_KEY_ISO_LEVEL3_SHIFT"] = OT_INPUT_KEY_ISO_LEVEL3_SHIFT
        map["OT_INPUT_KEY_ISO_LEVEL5_SHIFT"] = OT_INPUT_KEY_ISO_LEVEL5_SHIFT
        map["OT_INPUT_EXPECT_REPLIES"] = OT_INPUT_EXPECT_REPLIES
        map["OT_INPUT_EXPECT_KITTY_KEYBOARD"] = OT_INPUT_EXPECT_KITTY_KEYBOARD
        map["OT_INPUT_EXPECT_CURSOR_POSITION"] = OT_INPUT_EXPECT_CURSOR_POSITION
        map["OT_INPUT_EXPECT_SENTINEL"] = OT_INPUT_EXPECT_SENTINEL
        map["OT_INPUT_EXPECT_ESCAPE_PREFIX"] = OT_INPUT_EXPECT_ESCAPE_PREFIX
        map["OT_INPUT_EVENTS_MIN"] = OT_INPUT_EVENTS_MIN
        map["OT_INPUT_PAYLOAD_BYTES_MIN"] = OT_INPUT_PAYLOAD_BYTES_MIN
        map["OT_INPUT_TIMEOUT_NS"] = OT_INPUT_TIMEOUT_NS
        map["OT_DIAGNOSTIC_MESSAGE_BYTES"] = OT_DIAGNOSTIC_MESSAGE_BYTES
        map["OT_DIAGNOSTIC_TRUNCATED"] = OT_DIAGNOSTIC_TRUNCATED
        map["OT_DIAGNOSTIC_QUEUE_MAX"] = OT_DIAGNOSTIC_QUEUE_MAX
        map["OT_SCENE_RECORD_BYTES_MAX"] = OT_SCENE_RECORD_BYTES_MAX
        map["OT_SCENE_RECORD_PHASE_BEFORE"] = OT_SCENE_RECORD_PHASE_BEFORE
        map["OT_SCENE_RECORD_PHASE_SELF"] = OT_SCENE_RECORD_PHASE_SELF
        map["OT_SCENE_RECORD_PHASE_AFTER"] = OT_SCENE_RECORD_PHASE_AFTER
        map["OT_SCENE_RECORD_SLOT"] = OT_SCENE_RECORD_SLOT
        map["OT_SCENE_RECORD_DRAW"] = OT_SCENE_RECORD_DRAW
        map["OT_SCENE_RECORD_STACK"] = OT_SCENE_RECORD_STACK
        map["OT_SCENE_RECORD_GRID"] = OT_SCENE_RECORD_GRID
        map["OT_SCENE_RECORD_PACKED"] = OT_SCENE_RECORD_PACKED
        map["OT_SCENE_RECORD_SUPERSAMPLE"] = OT_SCENE_RECORD_SUPERSAMPLE
        map["OT_SCENE_RECORD_GRAYSCALE"] = OT_SCENE_RECORD_GRAYSCALE
        map["OT_SCENE_RECORD_COLOR_MATRIX"] = OT_SCENE_RECORD_COLOR_MATRIX
        map["OT_SCENE_RECORD_TEXT_VIEW"] = OT_SCENE_RECORD_TEXT_VIEW
        map["OT_SCENE_RECORD_EDITOR_VIEW"] = OT_SCENE_RECORD_EDITOR_VIEW
        map["OT_SCENE_RECORD_SCENE_BODY"] = OT_SCENE_RECORD_SCENE_BODY
        map["OT_SCENE_RECORD_IMAGE"] = OT_SCENE_RECORD_IMAGE
        map["OT_SCENE_RECORD_UNICODE"] = OT_SCENE_RECORD_UNICODE
        map["OT_SCENE_RECORD_CELLS"] = OT_SCENE_RECORD_CELLS
        map["OT_SCENE_RECORD_GRAYSCALE_FOREGROUND"] = OT_SCENE_RECORD_GRAYSCALE_FOREGROUND
        map["OT_SCENE_RECORD_GRAYSCALE_BACKGROUND"] = OT_SCENE_RECORD_GRAYSCALE_BACKGROUND
        map["OT_SCENE_RECORD_GRAYSCALE_SUPERSAMPLED"] = OT_SCENE_RECORD_GRAYSCALE_SUPERSAMPLED
        map["OT_INPUT_RESET_KEEP_REPLY"] = OT_INPUT_RESET_KEEP_REPLY
        map["OT_CLIPBOARD_OPERATION_PENDING"] = OT_CLIPBOARD_OPERATION_PENDING
        map["OT_CLIPBOARD_OPERATION_READ"] = OT_CLIPBOARD_OPERATION_READ
        map["OT_CLIPBOARD_OPERATION_EMPTY"] = OT_CLIPBOARD_OPERATION_EMPTY
        map["OT_CLIPBOARD_OPERATION_WRITTEN"] = OT_CLIPBOARD_OPERATION_WRITTEN
        map["OT_CLIPBOARD_OPERATION_CLEARED"] = OT_CLIPBOARD_OPERATION_CLEARED
        map["OT_CLIPBOARD_OPERATION_UNSUPPORTED"] = OT_CLIPBOARD_OPERATION_UNSUPPORTED
        map["OT_CLIPBOARD_OPERATION_CANCELLED"] = OT_CLIPBOARD_OPERATION_CANCELLED
        map["OT_CLIPBOARD_OPERATION_TIMED_OUT"] = OT_CLIPBOARD_OPERATION_TIMED_OUT
        map["OT_CLIPBOARD_OPERATION_LIMIT_EXCEEDED"] = OT_CLIPBOARD_OPERATION_LIMIT_EXCEEDED
        map["OT_CLIPBOARD_OPERATION_FAILED"] = OT_CLIPBOARD_OPERATION_FAILED
        map["OT_CLIPBOARD_OPERATION_INVALID_HANDLE"] = OT_CLIPBOARD_OPERATION_INVALID_HANDLE
        map["OT_CLIPBOARD_START_OK"] = OT_CLIPBOARD_START_OK
        map["OT_CLIPBOARD_START_INVALID_SERVICE"] = OT_CLIPBOARD_START_INVALID_SERVICE
        map["OT_CLIPBOARD_START_SHUTTING_DOWN"] = OT_CLIPBOARD_START_SHUTTING_DOWN
        map["OT_CLIPBOARD_START_LIMIT_EXCEEDED"] = OT_CLIPBOARD_START_LIMIT_EXCEEDED
        map["OT_CLIPBOARD_START_INVALID_ARGUMENT"] = OT_CLIPBOARD_START_INVALID_ARGUMENT
        map["OT_CLIPBOARD_START_OUT_OF_MEMORY"] = OT_CLIPBOARD_START_OUT_OF_MEMORY
        map["OT_CLIPBOARD_CANCEL_REQUESTED"] = OT_CLIPBOARD_CANCEL_REQUESTED
        map["OT_CLIPBOARD_CANCEL_ALREADY_TERMINAL"] = OT_CLIPBOARD_CANCEL_ALREADY_TERMINAL
        map["OT_CLIPBOARD_CANCEL_INVALID_HANDLE"] = OT_CLIPBOARD_CANCEL_INVALID_HANDLE
        map["OT_CLIPBOARD_COPY_OK"] = OT_CLIPBOARD_COPY_OK
        map["OT_CLIPBOARD_COPY_BUFFER_TOO_SMALL"] = OT_CLIPBOARD_COPY_BUFFER_TOO_SMALL
        map["OT_CLIPBOARD_COPY_INVALID_HANDLE"] = OT_CLIPBOARD_COPY_INVALID_HANDLE
        map["OT_CLIPBOARD_COPY_INVALID_STATE"] = OT_CLIPBOARD_COPY_INVALID_STATE
        map["OT_CLIPBOARD_COPY_INVALID_ARGUMENT"] = OT_CLIPBOARD_COPY_INVALID_ARGUMENT
        map["OT_CLIPBOARD_DESTROY_DESTROYED"] = OT_CLIPBOARD_DESTROY_DESTROYED
        map["OT_CLIPBOARD_DESTROY_NOT_READY"] = OT_CLIPBOARD_DESTROY_NOT_READY
        map["OT_CLIPBOARD_DESTROY_INVALID_HANDLE"] = OT_CLIPBOARD_DESTROY_INVALID_HANDLE
        map["OT_CLIPBOARD_SHUTDOWN_PENDING"] = OT_CLIPBOARD_SHUTDOWN_PENDING
        map["OT_CLIPBOARD_SHUTDOWN_READY"] = OT_CLIPBOARD_SHUTDOWN_READY
        map["OT_CLIPBOARD_SHUTDOWN_INVALID_HANDLE"] = OT_CLIPBOARD_SHUTDOWN_INVALID_HANDLE
    }
}

// MARK: - Little-Endian Binary Packing Helpers

/// Pure-Swift little-endian binary reader/writer for C-ABI struct serialization.
public enum ZigBinaryCodec {
    @inlinable
    public static func readU8(_ bytes: [UInt8], at offset: Int) -> UInt8 {
        guard offset >= 0, offset < bytes.count else { return 0 }
        return bytes[offset]
    }

    @inlinable
    public static func writeU8(_ value: UInt8, into bytes: inout [UInt8], at offset: Int) {
        guard offset >= 0, offset < bytes.count else { return }
        bytes[offset] = value
    }

    @inlinable
    public static func readBoolU8(_ bytes: [UInt8], at offset: Int) -> Bool {
        readU8(bytes, at: offset) != 0
    }

    @inlinable
    public static func writeBoolU8(_ value: Bool, into bytes: inout [UInt8], at offset: Int) {
        writeU8(value ? 1 : 0, into: &bytes, at: offset)
    }

    @inlinable
    public static func readU16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= bytes.count else { return 0 }
        return UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    @inlinable
    public static func writeU16(_ value: UInt16, into bytes: inout [UInt8], at offset: Int) {
        guard offset >= 0, offset + 2 <= bytes.count else { return }
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }

    @inlinable
    public static func readU32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    @inlinable
    public static func writeU32(_ value: UInt32, into bytes: inout [UInt8], at offset: Int) {
        guard offset >= 0, offset + 4 <= bytes.count else { return }
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    @inlinable
    public static func readI32(_ bytes: [UInt8], at offset: Int) -> Int32 {
        Int32(bitPattern: readU32(bytes, at: offset))
    }

    @inlinable
    public static func writeI32(_ value: Int32, into bytes: inout [UInt8], at offset: Int) {
        writeU32(UInt32(bitPattern: value), into: &bytes, at: offset)
    }

    @inlinable
    public static func readU64(_ bytes: [UInt8], at offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= bytes.count else { return 0 }
        let lo = UInt64(readU32(bytes, at: offset))
        let hi = UInt64(readU32(bytes, at: offset + 4))
        return lo | (hi << 32)
    }

    @inlinable
    public static func writeU64(_ value: UInt64, into bytes: inout [UInt8], at offset: Int) {
        guard offset >= 0, offset + 8 <= bytes.count else { return }
        writeU32(UInt32(truncatingIfNeeded: value), into: &bytes, at: offset)
        writeU32(UInt32(truncatingIfNeeded: value >> 32), into: &bytes, at: offset + 4)
    }

    @inlinable
    public static func readF32(_ bytes: [UInt8], at offset: Int) -> Float {
        Float(bitPattern: readU32(bytes, at: offset))
    }

    @inlinable
    public static func writeF32(_ value: Float, into bytes: inout [UInt8], at offset: Int) {
        writeU32(value.bitPattern, into: &bytes, at: offset)
    }

    @inlinable
    public static func readF64(_ bytes: [UInt8], at offset: Int) -> Double {
        Double(bitPattern: readU64(bytes, at: offset))
    }

    @inlinable
    public static func writeF64(_ value: Double, into bytes: inout [UInt8], at offset: Int) {
        writeU64(value.bitPattern, into: &bytes, at: offset)
    }

    @inlinable
    public static func readRGBA16(_ bytes: [UInt8], at offset: Int) -> RGBA {
        let r = readU16(bytes, at: offset)
        let g = readU16(bytes, at: offset + 2)
        let b = readU16(bytes, at: offset + 4)
        let a = readU16(bytes, at: offset + 6)
        return RGBA.fromArray([r, g, b, a])
    }

    @inlinable
    public static func writeRGBA16(_ color: RGBA, into bytes: inout [UInt8], at offset: Int) {
        writeU16(color.b0, into: &bytes, at: offset)
        writeU16(color.b1, into: &bytes, at: offset + 2)
        writeU16(color.b2, into: &bytes, at: offset + 4)
        writeU16(color.b3, into: &bytes, at: offset + 6)
    }
}

/// Errors thrown while unpacking a binary C-ABI struct buffer.
public enum ZigStructError: Error, Equatable, Hashable, Sendable {
    case bufferTooSmall(expected: Int, actual: Int)
}

/// Protocol for C-ABI value structs supporting deterministic little-endian pack/unpack.
public protocol ZigPackableStruct: Equatable, Sendable {
    static var byteSize: Int { get }
    static var alignment: Int { get }
    func pack() -> [UInt8]
    static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> Self
}

/// Descriptor wrapper matching `defineStruct(...)` in `core/src/zig-structs.ts`.
public struct ZigStructCodec<Value: ZigPackableStruct>: Sendable {
    public let size: Int
    public let alignment: Int
    public let fieldNames: [String]

    public init(fieldNames: [String]) {
        self.size = Value.byteSize
        self.alignment = Value.alignment
        self.fieldNames = fieldNames
    }

    public func pack(_ value: Value) -> [UInt8] {
        value.pack()
    }

    public func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> Value {
        try Value.unpack(bytes)
    }

    public func alloc() -> [UInt8] {
        Array(repeating: 0, count: size)
    }
}

// MARK: - core/src/zig-structs.ts (34 symbols)

// parity: core/src/zig-structs.ts#NativeImageInfo [status=implemented hash=eba31d65eed1]
public struct NativeImageInfo: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 32
    public static let alignment: Int = 4

    public var width: UInt32
    public var height: UInt32
    public var sourceWidth: UInt32
    public var sourceHeight: UInt32
    public var format: UInt32
    public var colorStatus: UInt32
    public var orientation: UInt32
    public var hasAlpha: UInt32

    public init(
        width: UInt32 = 0,
        height: UInt32 = 0,
        sourceWidth: UInt32 = 0,
        sourceHeight: UInt32 = 0,
        format: UInt32 = 0,
        colorStatus: UInt32 = 0,
        orientation: UInt32 = 1,
        hasAlpha: UInt32 = 1
    ) {
        self.width = width
        self.height = height
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.format = format
        self.colorStatus = colorStatus
        self.orientation = orientation
        self.hasAlpha = hasAlpha
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(width, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(height, into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(sourceWidth, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(sourceHeight, into: &bytes, at: 12)
        ZigBinaryCodec.writeU32(format, into: &bytes, at: 16)
        ZigBinaryCodec.writeU32(colorStatus, into: &bytes, at: 20)
        ZigBinaryCodec.writeU32(orientation, into: &bytes, at: 24)
        ZigBinaryCodec.writeU32(hasAlpha, into: &bytes, at: 28)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> NativeImageInfo {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return NativeImageInfo(
            width: ZigBinaryCodec.readU32(bytes, at: 0),
            height: ZigBinaryCodec.readU32(bytes, at: 4),
            sourceWidth: ZigBinaryCodec.readU32(bytes, at: 8),
            sourceHeight: ZigBinaryCodec.readU32(bytes, at: 12),
            format: ZigBinaryCodec.readU32(bytes, at: 16),
            colorStatus: ZigBinaryCodec.readU32(bytes, at: 20),
            orientation: ZigBinaryCodec.readU32(bytes, at: 24),
            hasAlpha: ZigBinaryCodec.readU32(bytes, at: 28)
        )
    }
}

// parity: core/src/zig-structs.ts#BuildOptions [status=implemented hash=20cd46766a92]
public struct BuildOptions: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 2
    public static let alignment: Int = 1

    public var gpaSafeStats: Bool
    public var gpaMemoryLimitTracking: Bool

    public init(gpaSafeStats: Bool = false, gpaMemoryLimitTracking: Bool = false) {
        self.gpaSafeStats = gpaSafeStats
        self.gpaMemoryLimitTracking = gpaMemoryLimitTracking
    }

    public func pack() -> [UInt8] {
        [gpaSafeStats ? 1 : 0, gpaMemoryLimitTracking ? 1 : 0]
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> BuildOptions {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return BuildOptions(
            gpaSafeStats: ZigBinaryCodec.readBoolU8(bytes, at: 0),
            gpaMemoryLimitTracking: ZigBinaryCodec.readBoolU8(bytes, at: 1)
        )
    }
}

// parity: core/src/zig-structs.ts#BuildOptionsStruct [status=implemented hash=12d99bb07dc3]
public let BuildOptionsStruct = ZigStructCodec<BuildOptions>(
    fieldNames: ["gpaSafeStats", "gpaMemoryLimitTracking"]
)

// parity: core/src/zig-structs.ts#AllocatorStats [status=implemented hash=ab9ed5f70181]
public struct AllocatorStats: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 40
    public static let alignment: Int = 8

    public var totalRequestedBytes: UInt64
    public var activeAllocations: UInt64
    public var smallAllocations: UInt64
    public var largeAllocations: UInt64
    public var requestedBytesValid: Bool

    public init(
        totalRequestedBytes: UInt64 = 0,
        activeAllocations: UInt64 = 0,
        smallAllocations: UInt64 = 0,
        largeAllocations: UInt64 = 0,
        requestedBytesValid: Bool = false
    ) {
        self.totalRequestedBytes = totalRequestedBytes
        self.activeAllocations = activeAllocations
        self.smallAllocations = smallAllocations
        self.largeAllocations = largeAllocations
        self.requestedBytesValid = requestedBytesValid
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU64(totalRequestedBytes, into: &bytes, at: 0)
        ZigBinaryCodec.writeU64(activeAllocations, into: &bytes, at: 8)
        ZigBinaryCodec.writeU64(smallAllocations, into: &bytes, at: 16)
        ZigBinaryCodec.writeU64(largeAllocations, into: &bytes, at: 24)
        ZigBinaryCodec.writeBoolU8(requestedBytesValid, into: &bytes, at: 32)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> AllocatorStats {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return AllocatorStats(
            totalRequestedBytes: ZigBinaryCodec.readU64(bytes, at: 0),
            activeAllocations: ZigBinaryCodec.readU64(bytes, at: 8),
            smallAllocations: ZigBinaryCodec.readU64(bytes, at: 16),
            largeAllocations: ZigBinaryCodec.readU64(bytes, at: 24),
            requestedBytesValid: ZigBinaryCodec.readBoolU8(bytes, at: 32)
        )
    }
}

// parity: core/src/zig-structs.ts#AllocatorStatsStruct [status=implemented hash=c62c7868dc35]
public let AllocatorStatsStruct = ZigStructCodec<AllocatorStats>(
    fieldNames: [
        "totalRequestedBytes",
        "activeAllocations",
        "smallAllocations",
        "largeAllocations",
        "requestedBytesValid",
    ]
)

// parity: core/src/zig-structs.ts#NativeFrameWork [status=implemented hash=4a6a1283adf3]
public struct NativeFrameWork: Equatable, Hashable, Sendable, Codable {
    public var workFrameId: UInt64
    public var candidateVisits: UInt32
    public var paintVisits: UInt32
    public var viewPreparations: UInt32
    public var geometryReads: UInt32
    public var yogaSolves: UInt32
    public var feedbackOperations: UInt32
    public var visibilitySteps: UInt32
    public var viewportChildRefreshes: UInt32
    public var overlapTests: UInt32
    public var membersPainted: UInt32
    public var memberCells: UInt32
    public var cellsCleared: UInt32
    public var hitCellsWritten: UInt32
    public var hitCellsCleared: UInt32
    public var hitCellsCompared: UInt32
    public var rowsCompared: UInt32
    public var rowsDiffed: UInt32
    public var fullPathReasons: UInt32
    public var hostRequests: UInt32
    public var layoutRounds: UInt32
    public var damageRows: UInt32

    public init(
        workFrameId: UInt64 = 0,
        candidateVisits: UInt32 = 0,
        paintVisits: UInt32 = 0,
        viewPreparations: UInt32 = 0,
        geometryReads: UInt32 = 0,
        yogaSolves: UInt32 = 0,
        feedbackOperations: UInt32 = 0,
        visibilitySteps: UInt32 = 0,
        viewportChildRefreshes: UInt32 = 0,
        overlapTests: UInt32 = 0,
        membersPainted: UInt32 = 0,
        memberCells: UInt32 = 0,
        cellsCleared: UInt32 = 0,
        hitCellsWritten: UInt32 = 0,
        hitCellsCleared: UInt32 = 0,
        hitCellsCompared: UInt32 = 0,
        rowsCompared: UInt32 = 0,
        rowsDiffed: UInt32 = 0,
        fullPathReasons: UInt32 = 0,
        hostRequests: UInt32 = 0,
        layoutRounds: UInt32 = 0,
        damageRows: UInt32 = 0
    ) {
        self.workFrameId = workFrameId
        self.candidateVisits = candidateVisits
        self.paintVisits = paintVisits
        self.viewPreparations = viewPreparations
        self.geometryReads = geometryReads
        self.yogaSolves = yogaSolves
        self.feedbackOperations = feedbackOperations
        self.visibilitySteps = visibilitySteps
        self.viewportChildRefreshes = viewportChildRefreshes
        self.overlapTests = overlapTests
        self.membersPainted = membersPainted
        self.memberCells = memberCells
        self.cellsCleared = cellsCleared
        self.hitCellsWritten = hitCellsWritten
        self.hitCellsCleared = hitCellsCleared
        self.hitCellsCompared = hitCellsCompared
        self.rowsCompared = rowsCompared
        self.rowsDiffed = rowsDiffed
        self.fullPathReasons = fullPathReasons
        self.hostRequests = hostRequests
        self.layoutRounds = layoutRounds
        self.damageRows = damageRows
    }
}

// parity: core/src/zig-structs.ts#NativeRenderStats [status=implemented hash=655d2e8ddf5f]
public struct NativeRenderStats: Equatable, Hashable, Sendable, Codable {
    public var nativeLastFrameTime: Double
    public var nativeAverageFrameTime: Double
    public var nativeFrameCount: UInt64
    public var cellsUpdated: UInt32
    public var averageCellsUpdated: Double
    public var nativeRenderTime: Double?
    public var nativeStdoutWriteTime: Double?
    public var frameWork: NativeFrameWork

    public init(
        nativeLastFrameTime: Double = 0,
        nativeAverageFrameTime: Double = 0,
        nativeFrameCount: UInt64 = 0,
        cellsUpdated: UInt32 = 0,
        averageCellsUpdated: Double = 0,
        nativeRenderTime: Double? = nil,
        nativeStdoutWriteTime: Double? = nil,
        frameWork: NativeFrameWork = NativeFrameWork()
    ) {
        self.nativeLastFrameTime = nativeLastFrameTime
        self.nativeAverageFrameTime = nativeAverageFrameTime
        self.nativeFrameCount = nativeFrameCount
        self.cellsUpdated = cellsUpdated
        self.averageCellsUpdated = averageCellsUpdated
        self.nativeRenderTime = nativeRenderTime
        self.nativeStdoutWriteTime = nativeStdoutWriteTime
        self.frameWork = frameWork
    }
}

// parity: core/src/zig-structs.ts#GrowthPolicy [status=implemented hash=8d39e4734590]
public typealias ZigGrowthPolicy = GrowthPolicy

// parity: core/src/zig-structs.ts#NativeSpanFeedOptions [status=implemented hash=ed24741bf5c9]
public struct ZigNativeSpanFeedOptions: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 24
    public static let alignment: Int = 8

    public var chunkSize: UInt32
    public var initialChunks: UInt32
    public var maxBytes: UInt64
    public var growthPolicy: GrowthPolicy
    public var autoCommitOnFull: Bool
    public var spanQueueCapacity: UInt32

    public init(
        chunkSize: UInt32 = 64 * 1024,
        initialChunks: UInt32 = 2,
        maxBytes: UInt64 = 0,
        growthPolicy: GrowthPolicy = .grow,
        autoCommitOnFull: Bool = true,
        spanQueueCapacity: UInt32 = 0
    ) {
        self.chunkSize = chunkSize
        self.initialChunks = initialChunks
        self.maxBytes = maxBytes
        self.growthPolicy = growthPolicy
        self.autoCommitOnFull = autoCommitOnFull
        self.spanQueueCapacity = spanQueueCapacity
    }

    public init(_ options: NativeSpanFeedOptions) {
        self.init(
            chunkSize: UInt32(max(1, options.chunkSize)),
            initialChunks: UInt32(max(1, options.initialChunks)),
            maxBytes: options.maxBytes,
            growthPolicy: options.growthPolicy,
            autoCommitOnFull: options.autoCommitOnFull,
            spanQueueCapacity: UInt32(max(0, options.spanQueueCapacity))
        )
    }

    public func toNativeSpanFeedOptions() -> NativeSpanFeedOptions {
        NativeSpanFeedOptions(
            chunkSize: Int(chunkSize),
            initialChunks: Int(initialChunks),
            maxBytes: maxBytes,
            growthPolicy: growthPolicy,
            autoCommitOnFull: autoCommitOnFull,
            spanQueueCapacity: spanQueueCapacity == 0 ? 256 : Int(spanQueueCapacity)
        )
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(chunkSize, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(initialChunks, into: &bytes, at: 4)
        ZigBinaryCodec.writeU64(maxBytes, into: &bytes, at: 8)
        ZigBinaryCodec.writeU8(growthPolicy == .block ? 1 : 0, into: &bytes, at: 16)
        ZigBinaryCodec.writeBoolU8(autoCommitOnFull, into: &bytes, at: 17)
        ZigBinaryCodec.writeU32(spanQueueCapacity, into: &bytes, at: 20)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigNativeSpanFeedOptions {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigNativeSpanFeedOptions(
            chunkSize: ZigBinaryCodec.readU32(bytes, at: 0),
            initialChunks: ZigBinaryCodec.readU32(bytes, at: 4),
            maxBytes: ZigBinaryCodec.readU64(bytes, at: 8),
            growthPolicy: ZigBinaryCodec.readU8(bytes, at: 16) == 1 ? .block : .grow,
            autoCommitOnFull: ZigBinaryCodec.readBoolU8(bytes, at: 17),
            spanQueueCapacity: ZigBinaryCodec.readU32(bytes, at: 20)
        )
    }
}

// parity: core/src/zig-structs.ts#NativeSpanFeedStats [status=implemented hash=d70555e40470]
public struct ZigNativeSpanFeedStats: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 40
    public static let alignment: Int = 8

    public var bytesWritten: UInt64
    public var spansCommitted: UInt64
    public var chunks: UInt32
    public var pendingSpans: UInt32
    public var outstandingSpans: UInt32
    public var outstandingBytes: UInt64

    public init(
        bytesWritten: UInt64 = 0,
        spansCommitted: UInt64 = 0,
        chunks: UInt32 = 0,
        pendingSpans: UInt32 = 0,
        outstandingSpans: UInt32 = 0,
        outstandingBytes: UInt64 = 0
    ) {
        self.bytesWritten = bytesWritten
        self.spansCommitted = spansCommitted
        self.chunks = chunks
        self.pendingSpans = pendingSpans
        self.outstandingSpans = outstandingSpans
        self.outstandingBytes = outstandingBytes
    }

    public init(_ stats: NativeSpanFeedStats) {
        self.init(
            bytesWritten: stats.bytesWritten,
            spansCommitted: stats.spansCommitted,
            chunks: UInt32(max(0, stats.chunks)),
            pendingSpans: UInt32(max(0, stats.pendingSpans)),
            outstandingSpans: UInt32(max(0, stats.outstandingSpans)),
            outstandingBytes: stats.outstandingBytes
        )
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU64(bytesWritten, into: &bytes, at: 0)
        ZigBinaryCodec.writeU64(spansCommitted, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(chunks, into: &bytes, at: 16)
        ZigBinaryCodec.writeU32(pendingSpans, into: &bytes, at: 20)
        ZigBinaryCodec.writeU32(outstandingSpans, into: &bytes, at: 24)
        ZigBinaryCodec.writeU32(0, into: &bytes, at: 28)
        ZigBinaryCodec.writeU64(outstandingBytes, into: &bytes, at: 32)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigNativeSpanFeedStats {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigNativeSpanFeedStats(
            bytesWritten: ZigBinaryCodec.readU64(bytes, at: 0),
            spansCommitted: ZigBinaryCodec.readU64(bytes, at: 8),
            chunks: ZigBinaryCodec.readU32(bytes, at: 16),
            pendingSpans: ZigBinaryCodec.readU32(bytes, at: 20),
            outstandingSpans: ZigBinaryCodec.readU32(bytes, at: 24),
            outstandingBytes: ZigBinaryCodec.readU64(bytes, at: 32)
        )
    }
}

// parity: core/src/zig-structs.ts#SpanInfo [status=implemented hash=690ee127dc4f]
public struct ZigSpanInfo: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 32
    public static let alignment: Int = 8

    public var chunkPtr: FFIPointer
    public var offset: UInt32
    public var len: UInt32
    public var chunkIndex: UInt32
    public var slotIndex: UInt32
    public var releaseId: UInt64

    public init(
        chunkPtr: FFIPointer = .null,
        offset: UInt32 = 0,
        len: UInt32 = 0,
        chunkIndex: UInt32 = 0,
        slotIndex: UInt32 = 0,
        releaseId: UInt64 = 0
    ) {
        self.chunkPtr = chunkPtr
        self.offset = offset
        self.len = len
        self.chunkIndex = chunkIndex
        self.slotIndex = slotIndex
        self.releaseId = releaseId
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU64(chunkPtr.address, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(offset, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(len, into: &bytes, at: 12)
        ZigBinaryCodec.writeU32(chunkIndex, into: &bytes, at: 16)
        ZigBinaryCodec.writeU32(slotIndex, into: &bytes, at: 20)
        ZigBinaryCodec.writeU64(releaseId, into: &bytes, at: 24)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigSpanInfo {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigSpanInfo(
            chunkPtr: FFIPointer(address: ZigBinaryCodec.readU64(bytes, at: 0)),
            offset: ZigBinaryCodec.readU32(bytes, at: 8),
            len: ZigBinaryCodec.readU32(bytes, at: 12),
            chunkIndex: ZigBinaryCodec.readU32(bytes, at: 16),
            slotIndex: ZigBinaryCodec.readU32(bytes, at: 20),
            releaseId: ZigBinaryCodec.readU64(bytes, at: 24)
        )
    }
}

// parity: core/src/zig-structs.ts#ReserveInfo [status=implemented hash=162adbbb7b8b]
public struct ReserveInfo: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 16
    public static let alignment: Int = 8

    public var ptr: FFIPointer
    public var len: UInt32

    public init(ptr: FFIPointer = .null, len: UInt32 = 0) {
        self.ptr = ptr
        self.len = len
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU64(ptr.address, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(len, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(0, into: &bytes, at: 12)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ReserveInfo {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ReserveInfo(
            ptr: FFIPointer(address: ZigBinaryCodec.readU64(bytes, at: 0)),
            len: ZigBinaryCodec.readU32(bytes, at: 8)
        )
    }
}

// parity: core/src/zig-structs.ts#NativeSpanFeedOptionsStruct [status=implemented hash=3fd53deb7e63]
public let NativeSpanFeedOptionsStruct = ZigStructCodec<ZigNativeSpanFeedOptions>(
    fieldNames: [
        "chunkSize",
        "initialChunks",
        "maxBytes",
        "growthPolicy",
        "autoCommitOnFull",
        "spanQueueCapacity",
    ]
)

// parity: core/src/zig-structs.ts#NativeSpanFeedStatsStruct [status=implemented hash=affdd18fde20]
public let NativeSpanFeedStatsStruct = ZigStructCodec<ZigNativeSpanFeedStats>(
    fieldNames: [
        "bytesWritten",
        "spansCommitted",
        "chunks",
        "pendingSpans",
        "outstandingSpans",
        "reserved",
        "outstandingBytes",
    ]
)

// parity: core/src/zig-structs.ts#SpanInfoStruct [status=implemented hash=59b0946653dc]
public let SpanInfoStruct = ZigStructCodec<ZigSpanInfo>(
    fieldNames: ["chunkPtr", "offset", "len", "chunkIndex", "slotIndex", "releaseId"]
)

// parity: core/src/zig-structs.ts#ReserveInfoStruct [status=implemented hash=d5db49c14f6a]
public let ReserveInfoStruct = ZigStructCodec<ReserveInfo>(
    fieldNames: ["ptr", "len", "reserved"]
)

// parity: core/src/zig-structs.ts#AudioCreateOptions [status=implemented hash=589b849a49e7]
public struct AudioCreateOptions: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 8
    public static let alignment: Int = 4

    public var sampleRate: UInt32
    public var playbackChannels: UInt32

    public init(sampleRate: UInt32 = 48_000, playbackChannels: UInt32 = 2) {
        self.sampleRate = sampleRate
        self.playbackChannels = playbackChannels
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(sampleRate, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(playbackChannels, into: &bytes, at: 4)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> AudioCreateOptions {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return AudioCreateOptions(
            sampleRate: ZigBinaryCodec.readU32(bytes, at: 0),
            playbackChannels: ZigBinaryCodec.readU32(bytes, at: 4)
        )
    }
}

// parity: core/src/zig-structs.ts#AudioStartOptions [status=implemented hash=bf19b69b5e36]
public struct ZigAudioStartOptions: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 24
    public static let alignment: Int = 4

    public var periodSizeInFrames: UInt32
    public var periodSizeInMilliseconds: UInt32
    public var periods: UInt32
    public var performanceProfile: UInt8
    public var shareMode: UInt8
    public var noPreSilencedOutputBuffer: Bool
    public var noClip: Bool
    public var noDisableDenormals: Bool
    public var noFixedSizedCallback: Bool
    public var wasapiNoAutoConvertSrc: Bool
    public var wasapiNoDefaultQualitySrc: Bool
    public var alsaNoMMap: Bool
    public var alsaNoAutoFormat: Bool
    public var alsaNoAutoChannels: Bool
    public var alsaNoAutoResample: Bool

    public init(
        periodSizeInFrames: UInt32 = 0,
        periodSizeInMilliseconds: UInt32 = 0,
        periods: UInt32 = 0,
        performanceProfile: UInt8 = 0,
        shareMode: UInt8 = 0,
        noPreSilencedOutputBuffer: Bool = false,
        noClip: Bool = false,
        noDisableDenormals: Bool = false,
        noFixedSizedCallback: Bool = false,
        wasapiNoAutoConvertSrc: Bool = false,
        wasapiNoDefaultQualitySrc: Bool = false,
        alsaNoMMap: Bool = false,
        alsaNoAutoFormat: Bool = false,
        alsaNoAutoChannels: Bool = false,
        alsaNoAutoResample: Bool = false
    ) {
        self.periodSizeInFrames = periodSizeInFrames
        self.periodSizeInMilliseconds = periodSizeInMilliseconds
        self.periods = periods
        self.performanceProfile = performanceProfile
        self.shareMode = shareMode
        self.noPreSilencedOutputBuffer = noPreSilencedOutputBuffer
        self.noClip = noClip
        self.noDisableDenormals = noDisableDenormals
        self.noFixedSizedCallback = noFixedSizedCallback
        self.wasapiNoAutoConvertSrc = wasapiNoAutoConvertSrc
        self.wasapiNoDefaultQualitySrc = wasapiNoDefaultQualitySrc
        self.alsaNoMMap = alsaNoMMap
        self.alsaNoAutoFormat = alsaNoAutoFormat
        self.alsaNoAutoChannels = alsaNoAutoChannels
        self.alsaNoAutoResample = alsaNoAutoResample
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(periodSizeInFrames, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(periodSizeInMilliseconds, into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(periods, into: &bytes, at: 8)
        ZigBinaryCodec.writeU8(performanceProfile, into: &bytes, at: 12)
        ZigBinaryCodec.writeU8(shareMode, into: &bytes, at: 13)
        ZigBinaryCodec.writeBoolU8(noPreSilencedOutputBuffer, into: &bytes, at: 14)
        ZigBinaryCodec.writeBoolU8(noClip, into: &bytes, at: 15)
        ZigBinaryCodec.writeBoolU8(noDisableDenormals, into: &bytes, at: 16)
        ZigBinaryCodec.writeBoolU8(noFixedSizedCallback, into: &bytes, at: 17)
        ZigBinaryCodec.writeBoolU8(wasapiNoAutoConvertSrc, into: &bytes, at: 18)
        ZigBinaryCodec.writeBoolU8(wasapiNoDefaultQualitySrc, into: &bytes, at: 19)
        ZigBinaryCodec.writeBoolU8(alsaNoMMap, into: &bytes, at: 20)
        ZigBinaryCodec.writeBoolU8(alsaNoAutoFormat, into: &bytes, at: 21)
        ZigBinaryCodec.writeBoolU8(alsaNoAutoChannels, into: &bytes, at: 22)
        ZigBinaryCodec.writeBoolU8(alsaNoAutoResample, into: &bytes, at: 23)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigAudioStartOptions {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigAudioStartOptions(
            periodSizeInFrames: ZigBinaryCodec.readU32(bytes, at: 0),
            periodSizeInMilliseconds: ZigBinaryCodec.readU32(bytes, at: 4),
            periods: ZigBinaryCodec.readU32(bytes, at: 8),
            performanceProfile: ZigBinaryCodec.readU8(bytes, at: 12),
            shareMode: ZigBinaryCodec.readU8(bytes, at: 13),
            noPreSilencedOutputBuffer: ZigBinaryCodec.readBoolU8(bytes, at: 14),
            noClip: ZigBinaryCodec.readBoolU8(bytes, at: 15),
            noDisableDenormals: ZigBinaryCodec.readBoolU8(bytes, at: 16),
            noFixedSizedCallback: ZigBinaryCodec.readBoolU8(bytes, at: 17),
            wasapiNoAutoConvertSrc: ZigBinaryCodec.readBoolU8(bytes, at: 18),
            wasapiNoDefaultQualitySrc: ZigBinaryCodec.readBoolU8(bytes, at: 19),
            alsaNoMMap: ZigBinaryCodec.readBoolU8(bytes, at: 20),
            alsaNoAutoFormat: ZigBinaryCodec.readBoolU8(bytes, at: 21),
            alsaNoAutoChannels: ZigBinaryCodec.readBoolU8(bytes, at: 22),
            alsaNoAutoResample: ZigBinaryCodec.readBoolU8(bytes, at: 23)
        )
    }
}

// parity: core/src/zig-structs.ts#AudioVoiceOptions [status=implemented hash=374163bc77aa]
public struct AudioVoiceOptions: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 16
    public static let alignment: Int = 4

    public var volume: Float
    public var pan: Float
    public var loop: Bool
    public var groupId: UInt32

    public init(volume: Float = 1.0, pan: Float = 0.0, loop: Bool = false, groupId: UInt32 = 0) {
        self.volume = volume
        self.pan = pan
        self.loop = loop
        self.groupId = groupId
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeF32(volume, into: &bytes, at: 0)
        ZigBinaryCodec.writeF32(pan, into: &bytes, at: 4)
        ZigBinaryCodec.writeBoolU8(loop, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(groupId, into: &bytes, at: 12)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> AudioVoiceOptions {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return AudioVoiceOptions(
            volume: ZigBinaryCodec.readF32(bytes, at: 0),
            pan: ZigBinaryCodec.readF32(bytes, at: 4),
            loop: ZigBinaryCodec.readBoolU8(bytes, at: 8),
            groupId: ZigBinaryCodec.readU32(bytes, at: 12)
        )
    }
}

// parity: core/src/zig-structs.ts#NativeAudioStreamFormat [status=implemented hash=fb8d03c92326]
public enum NativeAudioStreamFormat: UInt32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case mp3 = 1
    case flac = 2
    case pcm = 3
}

// parity: core/src/zig-structs.ts#AudioStreamCreateOptions [status=implemented hash=bffb896b09bd]
public struct AudioStreamCreateOptions: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 40
    public static let alignment: Int = 4

    public var capacityMs: UInt32
    public var startupMs: UInt32
    public var resumeMs: UInt32
    public var volume: Float
    public var pan: Float
    public var groupId: UInt32
    public var maxProbeBytes: UInt32
    public var format: NativeAudioStreamFormat
    public var sampleRate: UInt32
    public var channels: UInt32

    public init(
        capacityMs: UInt32 = 2_000,
        startupMs: UInt32 = 250,
        resumeMs: UInt32 = 250,
        volume: Float = 1.0,
        pan: Float = 0.0,
        groupId: UInt32 = 0,
        maxProbeBytes: UInt32 = 65_536,
        format: NativeAudioStreamFormat = .pcm,
        sampleRate: UInt32 = 0,
        channels: UInt32 = 0
    ) {
        self.capacityMs = capacityMs
        self.startupMs = startupMs
        self.resumeMs = resumeMs
        self.volume = volume
        self.pan = pan
        self.groupId = groupId
        self.maxProbeBytes = maxProbeBytes
        self.format = format
        self.sampleRate = sampleRate
        self.channels = channels
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(capacityMs, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(startupMs, into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(resumeMs, into: &bytes, at: 8)
        ZigBinaryCodec.writeF32(volume, into: &bytes, at: 12)
        ZigBinaryCodec.writeF32(pan, into: &bytes, at: 16)
        ZigBinaryCodec.writeU32(groupId, into: &bytes, at: 20)
        ZigBinaryCodec.writeU32(maxProbeBytes, into: &bytes, at: 24)
        ZigBinaryCodec.writeU32(format.rawValue, into: &bytes, at: 28)
        ZigBinaryCodec.writeU32(sampleRate, into: &bytes, at: 32)
        ZigBinaryCodec.writeU32(channels, into: &bytes, at: 36)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> AudioStreamCreateOptions {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return AudioStreamCreateOptions(
            capacityMs: ZigBinaryCodec.readU32(bytes, at: 0),
            startupMs: ZigBinaryCodec.readU32(bytes, at: 4),
            resumeMs: ZigBinaryCodec.readU32(bytes, at: 8),
            volume: ZigBinaryCodec.readF32(bytes, at: 12),
            pan: ZigBinaryCodec.readF32(bytes, at: 16),
            groupId: ZigBinaryCodec.readU32(bytes, at: 20),
            maxProbeBytes: ZigBinaryCodec.readU32(bytes, at: 24),
            format: NativeAudioStreamFormat(rawValue: ZigBinaryCodec.readU32(bytes, at: 28)) ?? .pcm,
            sampleRate: ZigBinaryCodec.readU32(bytes, at: 32),
            channels: ZigBinaryCodec.readU32(bytes, at: 36)
        )
    }
}

// parity: core/src/zig-structs.ts#NativeAudioStreamStats [status=implemented hash=3308a823ad62]
public struct NativeAudioStreamStats: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 56
    public static let alignment: Int = 8

    public var bytesReceived: UInt64
    public var framesDecoded: UInt64
    public var framesPlayed: UInt64
    public var state: UInt32
    public var sampleRate: UInt32
    public var channels: UInt32
    public var bufferedFrames: UInt32
    public var capacityFrames: UInt32
    public var underruns: UInt32
    public var errorCode: Int32
    public var readyGeneration: UInt32

    public init(
        bytesReceived: UInt64 = 0,
        framesDecoded: UInt64 = 0,
        framesPlayed: UInt64 = 0,
        state: UInt32 = 0,
        sampleRate: UInt32 = 48_000,
        channels: UInt32 = 2,
        bufferedFrames: UInt32 = 0,
        capacityFrames: UInt32 = 0,
        underruns: UInt32 = 0,
        errorCode: Int32 = 0,
        readyGeneration: UInt32 = 0
    ) {
        self.bytesReceived = bytesReceived
        self.framesDecoded = framesDecoded
        self.framesPlayed = framesPlayed
        self.state = state
        self.sampleRate = sampleRate
        self.channels = channels
        self.bufferedFrames = bufferedFrames
        self.capacityFrames = capacityFrames
        self.underruns = underruns
        self.errorCode = errorCode
        self.readyGeneration = readyGeneration
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU64(bytesReceived, into: &bytes, at: 0)
        ZigBinaryCodec.writeU64(framesDecoded, into: &bytes, at: 8)
        ZigBinaryCodec.writeU64(framesPlayed, into: &bytes, at: 16)
        ZigBinaryCodec.writeU32(state, into: &bytes, at: 24)
        ZigBinaryCodec.writeU32(sampleRate, into: &bytes, at: 28)
        ZigBinaryCodec.writeU32(channels, into: &bytes, at: 32)
        ZigBinaryCodec.writeU32(bufferedFrames, into: &bytes, at: 36)
        ZigBinaryCodec.writeU32(capacityFrames, into: &bytes, at: 40)
        ZigBinaryCodec.writeU32(underruns, into: &bytes, at: 44)
        ZigBinaryCodec.writeI32(errorCode, into: &bytes, at: 48)
        ZigBinaryCodec.writeU32(readyGeneration, into: &bytes, at: 52)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> NativeAudioStreamStats {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return NativeAudioStreamStats(
            bytesReceived: ZigBinaryCodec.readU64(bytes, at: 0),
            framesDecoded: ZigBinaryCodec.readU64(bytes, at: 8),
            framesPlayed: ZigBinaryCodec.readU64(bytes, at: 16),
            state: ZigBinaryCodec.readU32(bytes, at: 24),
            sampleRate: ZigBinaryCodec.readU32(bytes, at: 28),
            channels: ZigBinaryCodec.readU32(bytes, at: 32),
            bufferedFrames: ZigBinaryCodec.readU32(bytes, at: 36),
            capacityFrames: ZigBinaryCodec.readU32(bytes, at: 40),
            underruns: ZigBinaryCodec.readU32(bytes, at: 44),
            errorCode: ZigBinaryCodec.readI32(bytes, at: 48),
            readyGeneration: ZigBinaryCodec.readU32(bytes, at: 52)
        )
    }
}

// parity: core/src/zig-structs.ts#NativeAudioStreamState [status=implemented hash=e1212c4c337e]
public enum NativeAudioStreamState: UInt32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case initializing = 0
    case buffering = 1
    case playing = 2
    case ended = 3
    case failed = 4
    case cancelled = 5
    case reconnecting = 6
}

// parity: core/src/zig-structs.ts#NativeAudioStreamStateNames [status=implemented hash=809a07ce2945]
public let NativeAudioStreamStateNames: [String] = [
    "initializing",
    "buffering",
    "playing",
    "ended",
    "errored",
    "disposed",
    "reconnecting",
]

// parity: core/src/zig-structs.ts#NativeAudioStreamCloseReason [status=implemented hash=aa422eae36ab]
public enum NativeAudioStreamCloseReason: UInt32, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case preserveNativeTerminal = 0
    case transportError = 1
    case disposed = 2
}

// parity: core/src/zig-structs.ts#AudioStats [status=implemented hash=d91311cef151]
public struct ZigAudioStats: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 32
    public static let alignment: Int = 8

    public var soundsLoaded: UInt32
    public var voicesActive: UInt32
    public var framesMixed: UInt64
    public var lockMisses: UInt32
    public var lastPeak: Float
    public var lastRms: Float

    public init(
        soundsLoaded: UInt32 = 0,
        voicesActive: UInt32 = 0,
        framesMixed: UInt64 = 0,
        lockMisses: UInt32 = 0,
        lastPeak: Float = 0,
        lastRms: Float = 0
    ) {
        self.soundsLoaded = soundsLoaded
        self.voicesActive = voicesActive
        self.framesMixed = framesMixed
        self.lockMisses = lockMisses
        self.lastPeak = lastPeak
        self.lastRms = lastRms
    }

    public init(_ stats: AudioStats) {
        self.init(
            soundsLoaded: UInt32(max(0, stats.soundsLoaded)),
            voicesActive: UInt32(max(0, stats.voicesActive)),
            framesMixed: stats.framesMixed,
            lockMisses: UInt32(max(0, stats.lockMisses)),
            lastPeak: stats.lastPeak,
            lastRms: stats.lastRms
        )
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(soundsLoaded, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(voicesActive, into: &bytes, at: 4)
        ZigBinaryCodec.writeU64(framesMixed, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(lockMisses, into: &bytes, at: 16)
        ZigBinaryCodec.writeF32(lastPeak, into: &bytes, at: 20)
        ZigBinaryCodec.writeF32(lastRms, into: &bytes, at: 24)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigAudioStats {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigAudioStats(
            soundsLoaded: ZigBinaryCodec.readU32(bytes, at: 0),
            voicesActive: ZigBinaryCodec.readU32(bytes, at: 4),
            framesMixed: ZigBinaryCodec.readU64(bytes, at: 8),
            lockMisses: ZigBinaryCodec.readU32(bytes, at: 16),
            lastPeak: ZigBinaryCodec.readF32(bytes, at: 20),
            lastRms: ZigBinaryCodec.readF32(bytes, at: 24)
        )
    }
}

// parity: core/src/zig-structs.ts#NativeAudioCaptureStats [status=implemented hash=08f92e26e5cd]
public struct NativeAudioCaptureStats: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 40
    public static let alignment: Int = 8

    public var framesReceived: UInt64
    public var framesRead: UInt64
    public var framesDropped: UInt64
    public var sampleRate: UInt32
    public var channels: UInt32
    public var bufferedFrames: UInt32
    public var capacityFrames: UInt32

    public init(
        framesReceived: UInt64 = 0,
        framesRead: UInt64 = 0,
        framesDropped: UInt64 = 0,
        sampleRate: UInt32 = 48_000,
        channels: UInt32 = 1,
        bufferedFrames: UInt32 = 0,
        capacityFrames: UInt32 = 0
    ) {
        self.framesReceived = framesReceived
        self.framesRead = framesRead
        self.framesDropped = framesDropped
        self.sampleRate = sampleRate
        self.channels = channels
        self.bufferedFrames = bufferedFrames
        self.capacityFrames = capacityFrames
    }

    public init(_ stats: AudioCaptureStats) {
        self.init(
            framesReceived: stats.framesReceived,
            framesRead: stats.framesRead,
            framesDropped: stats.framesDropped,
            sampleRate: UInt32(max(0, stats.sampleRate)),
            channels: UInt32(max(0, stats.channels)),
            bufferedFrames: UInt32(max(0, stats.bufferedFrames)),
            capacityFrames: UInt32(max(0, stats.capacityFrames))
        )
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU64(framesReceived, into: &bytes, at: 0)
        ZigBinaryCodec.writeU64(framesRead, into: &bytes, at: 8)
        ZigBinaryCodec.writeU64(framesDropped, into: &bytes, at: 16)
        ZigBinaryCodec.writeU32(sampleRate, into: &bytes, at: 24)
        ZigBinaryCodec.writeU32(channels, into: &bytes, at: 28)
        ZigBinaryCodec.writeU32(bufferedFrames, into: &bytes, at: 32)
        ZigBinaryCodec.writeU32(capacityFrames, into: &bytes, at: 36)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> NativeAudioCaptureStats {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return NativeAudioCaptureStats(
            framesReceived: ZigBinaryCodec.readU64(bytes, at: 0),
            framesRead: ZigBinaryCodec.readU64(bytes, at: 8),
            framesDropped: ZigBinaryCodec.readU64(bytes, at: 16),
            sampleRate: ZigBinaryCodec.readU32(bytes, at: 24),
            channels: ZigBinaryCodec.readU32(bytes, at: 28),
            bufferedFrames: ZigBinaryCodec.readU32(bytes, at: 32),
            capacityFrames: ZigBinaryCodec.readU32(bytes, at: 36)
        )
    }
}

// parity: core/src/zig-structs.ts#AudioCreateOptionsStruct [status=implemented hash=41233f08cc97]
public let AudioCreateOptionsStruct = ZigStructCodec<AudioCreateOptions>(
    fieldNames: ["sampleRate", "playbackChannels"]
)

// parity: core/src/zig-structs.ts#AudioStartOptionsStruct [status=implemented hash=9a27f8f9e369]
public let AudioStartOptionsStruct = ZigStructCodec<ZigAudioStartOptions>(
    fieldNames: [
        "periodSizeInFrames",
        "periodSizeInMilliseconds",
        "periods",
        "performanceProfile",
        "shareMode",
        "noPreSilencedOutputBuffer",
        "noClip",
        "noDisableDenormals",
        "noFixedSizedCallback",
        "wasapiNoAutoConvertSrc",
        "wasapiNoDefaultQualitySrc",
        "alsaNoMMap",
        "alsaNoAutoFormat",
        "alsaNoAutoChannels",
        "alsaNoAutoResample",
    ]
)

// parity: core/src/zig-structs.ts#AudioVoiceOptionsStruct [status=implemented hash=dc3add80e3db]
public let AudioVoiceOptionsStruct = ZigStructCodec<AudioVoiceOptions>(
    fieldNames: ["volume", "pan", "loop", "groupId"]
)

// parity: core/src/zig-structs.ts#AudioStreamCreateOptionsStruct [status=implemented hash=689cf8068e57]
public let AudioStreamCreateOptionsStruct = ZigStructCodec<AudioStreamCreateOptions>(
    fieldNames: [
        "capacityMs",
        "startupMs",
        "resumeMs",
        "volume",
        "pan",
        "groupId",
        "maxProbeBytes",
        "format",
        "sampleRate",
        "channels",
    ]
)

// parity: core/src/zig-structs.ts#AudioStreamStatsStruct [status=implemented hash=4487b688e458]
public let AudioStreamStatsStruct = ZigStructCodec<NativeAudioStreamStats>(
    fieldNames: [
        "bytesReceived",
        "framesDecoded",
        "framesPlayed",
        "state",
        "sampleRate",
        "channels",
        "bufferedFrames",
        "capacityFrames",
        "underruns",
        "errorCode",
        "readyGeneration",
    ]
)

// parity: core/src/zig-structs.ts#AudioCaptureStatsStruct [status=implemented hash=13d3ad48428b]
public let AudioCaptureStatsStruct = ZigStructCodec<NativeAudioCaptureStats>(
    fieldNames: [
        "framesReceived",
        "framesRead",
        "framesDropped",
        "sampleRate",
        "channels",
        "bufferedFrames",
        "capacityFrames",
    ]
)

// parity: core/src/zig-structs.ts#AudioStatsStruct [status=implemented hash=0236591b64c3]
public let AudioStatsStruct = ZigStructCodec<ZigAudioStats>(
    fieldNames: [
        "soundsLoaded",
        "voicesActive",
        "framesMixed",
        "lockMisses",
        "lastPeak",
        "lastRms",
    ]
)

// MARK: - C-ABI Scene/Editor/Text Packable Structs Matching `NativeABI.nativeLayouts`

/// C-ABI `ot_handle` (16 bytes, alignment 8).
public struct ZigHandle: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 16
    public static let alignment: Int = 8

    public var contextId: UInt64
    public var slot: UInt32
    public var generation: UInt32

    public init(contextId: UInt64 = 0, slot: UInt32 = 0, generation: UInt32 = 0) {
        self.contextId = contextId
        self.slot = slot
        self.generation = generation
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU64(contextId, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(slot, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(generation, into: &bytes, at: 12)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigHandle {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigHandle(
            contextId: ZigBinaryCodec.readU64(bytes, at: 0),
            slot: ZigBinaryCodec.readU32(bytes, at: 8),
            generation: ZigBinaryCodec.readU32(bytes, at: 12)
        )
    }
}

/// C-ABI `[4]f64` rectangle matching `ot_scene_scroll_state.{content,viewport}` (32 bytes, alignment 8).
public struct ZigSceneRect: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 32
    public static let alignment: Int = 8

    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double = 0, y: Double = 0, width: Double = 0, height: Double = 0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeF64(x, into: &bytes, at: 0)
        ZigBinaryCodec.writeF64(y, into: &bytes, at: 8)
        ZigBinaryCodec.writeF64(width, into: &bytes, at: 16)
        ZigBinaryCodec.writeF64(height, into: &bytes, at: 24)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigSceneRect {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigSceneRect(
            x: ZigBinaryCodec.readF64(bytes, at: 0),
            y: ZigBinaryCodec.readF64(bytes, at: 8),
            width: ZigBinaryCodec.readF64(bytes, at: 16),
            height: ZigBinaryCodec.readF64(bytes, at: 24)
        )
    }
}

/// C-ABI `ot_scene_scroll_bar_state` (120 bytes, alignment 8).
public struct ZigScrollBarState: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 120
    public static let alignment: Int = 8

    public var visible: Bool
    public var track: ZigSceneRect
    public var startArrow: ZigSceneRect
    public var endArrow: ZigSceneRect
    public var thumbStart: Double
    public var thumbSize: Double

    public init(
        visible: Bool = false,
        track: ZigSceneRect = ZigSceneRect(),
        startArrow: ZigSceneRect = ZigSceneRect(),
        endArrow: ZigSceneRect = ZigSceneRect(),
        thumbStart: Double = 0,
        thumbSize: Double = 0
    ) {
        self.visible = visible
        self.track = track
        self.startArrow = startArrow
        self.endArrow = endArrow
        self.thumbStart = thumbStart
        self.thumbSize = thumbSize
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(visible ? 1 : 0, into: &bytes, at: 0)
        bytes.replaceSubrange(8..<40, with: track.pack())
        bytes.replaceSubrange(40..<72, with: startArrow.pack())
        bytes.replaceSubrange(72..<104, with: endArrow.pack())
        ZigBinaryCodec.writeF64(thumbStart, into: &bytes, at: 104)
        ZigBinaryCodec.writeF64(thumbSize, into: &bytes, at: 112)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigScrollBarState {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigScrollBarState(
            visible: ZigBinaryCodec.readU32(bytes, at: 0) != 0,
            track: try ZigSceneRect.unpack(Array(bytes[8..<40])),
            startArrow: try ZigSceneRect.unpack(Array(bytes[40..<72])),
            endArrow: try ZigSceneRect.unpack(Array(bytes[72..<104])),
            thumbStart: ZigBinaryCodec.readF64(bytes, at: 104),
            thumbSize: ZigBinaryCodec.readF64(bytes, at: 112)
        )
    }
}

/// C-ABI `ot_scene_scroll_state` (360 bytes, alignment 8).
public struct ZigScrollState: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 360
    public static let alignment: Int = 8

    public var stuck: UInt32
    public var changes: UInt32
    public var generation: UInt64
    public var offsetX: Double
    public var offsetY: Double
    public var maxX: Double
    public var maxY: Double
    public var content: ZigSceneRect
    public var viewport: ZigSceneRect
    public var horizontalBar: ZigScrollBarState
    public var verticalBar: ZigScrollBarState

    public init(
        stuck: UInt32 = 0,
        changes: UInt32 = 0,
        generation: UInt64 = 0,
        offsetX: Double = 0,
        offsetY: Double = 0,
        maxX: Double = 0,
        maxY: Double = 0,
        content: ZigSceneRect = ZigSceneRect(),
        viewport: ZigSceneRect = ZigSceneRect(),
        horizontalBar: ZigScrollBarState = ZigScrollBarState(),
        verticalBar: ZigScrollBarState = ZigScrollBarState()
    ) {
        self.stuck = stuck
        self.changes = changes
        self.generation = generation
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.maxX = maxX
        self.maxY = maxY
        self.content = content
        self.viewport = viewport
        self.horizontalBar = horizontalBar
        self.verticalBar = verticalBar
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(UInt32(Self.byteSize), into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(UInt32(NativeABI.OT_CONTEXT_ABI_VERSION), into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(stuck, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(changes, into: &bytes, at: 12)
        ZigBinaryCodec.writeU64(generation, into: &bytes, at: 16)
        ZigBinaryCodec.writeF64(offsetX, into: &bytes, at: 24)
        ZigBinaryCodec.writeF64(offsetY, into: &bytes, at: 32)
        ZigBinaryCodec.writeF64(maxX, into: &bytes, at: 40)
        ZigBinaryCodec.writeF64(maxY, into: &bytes, at: 48)
        bytes.replaceSubrange(56..<88, with: content.pack())
        bytes.replaceSubrange(88..<120, with: viewport.pack())
        bytes.replaceSubrange(120..<240, with: horizontalBar.pack())
        bytes.replaceSubrange(240..<360, with: verticalBar.pack())
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigScrollState {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigScrollState(
            stuck: ZigBinaryCodec.readU32(bytes, at: 8),
            changes: ZigBinaryCodec.readU32(bytes, at: 12),
            generation: ZigBinaryCodec.readU64(bytes, at: 16),
            offsetX: ZigBinaryCodec.readF64(bytes, at: 24),
            offsetY: ZigBinaryCodec.readF64(bytes, at: 32),
            maxX: ZigBinaryCodec.readF64(bytes, at: 40),
            maxY: ZigBinaryCodec.readF64(bytes, at: 48),
            content: try ZigSceneRect.unpack(Array(bytes[56..<88])),
            viewport: try ZigSceneRect.unpack(Array(bytes[88..<120])),
            horizontalBar: try ZigScrollBarState.unpack(Array(bytes[120..<240])),
            verticalBar: try ZigScrollBarState.unpack(Array(bytes[240..<360]))
        )
    }
}

/// C-ABI `ot_scene_cursor_state` (48 bytes, alignment 4).
public struct ZigCursorState: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 48
    public static let alignment: Int = 4

    public var x: UInt32
    public var y: UInt32
    public var visible: Bool
    public var style: UInt32
    public var blinking: Bool
    public var r: Float
    public var g: Float
    public var b: Float
    public var a: Float

    public init(
        x: UInt32 = 0,
        y: UInt32 = 0,
        visible: Bool = false,
        style: UInt32 = 0,
        blinking: Bool = false,
        r: Float = 1,
        g: Float = 1,
        b: Float = 1,
        a: Float = 1
    ) {
        self.x = x
        self.y = y
        self.visible = visible
        self.style = style
        self.blinking = blinking
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(UInt32(Self.byteSize), into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(UInt32(NativeABI.OT_CONTEXT_ABI_VERSION), into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(x, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(y, into: &bytes, at: 12)
        ZigBinaryCodec.writeU32(visible ? 1 : 0, into: &bytes, at: 16)
        ZigBinaryCodec.writeU32(style, into: &bytes, at: 20)
        ZigBinaryCodec.writeU32(blinking ? 1 : 0, into: &bytes, at: 24)
        ZigBinaryCodec.writeF32(r, into: &bytes, at: 32)
        ZigBinaryCodec.writeF32(g, into: &bytes, at: 36)
        ZigBinaryCodec.writeF32(b, into: &bytes, at: 40)
        ZigBinaryCodec.writeF32(a, into: &bytes, at: 44)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigCursorState {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigCursorState(
            x: ZigBinaryCodec.readU32(bytes, at: 8),
            y: ZigBinaryCodec.readU32(bytes, at: 12),
            visible: ZigBinaryCodec.readU32(bytes, at: 16) != 0,
            style: ZigBinaryCodec.readU32(bytes, at: 20),
            blinking: ZigBinaryCodec.readU32(bytes, at: 24) != 0,
            r: ZigBinaryCodec.readF32(bytes, at: 32),
            g: ZigBinaryCodec.readF32(bytes, at: 36),
            b: ZigBinaryCodec.readF32(bytes, at: 40),
            a: ZigBinaryCodec.readF32(bytes, at: 44)
        )
    }
}

/// C-ABI `ot_scene_text_line` (16 bytes, alignment 4).
public struct ZigLineInfo: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 16
    public static let alignment: Int = 4

    public var startCols: UInt32
    public var widthCols: UInt32
    public var sourceLine: UInt32
    public var wrapIndex: UInt32

    public init(startCols: UInt32 = 0, widthCols: UInt32 = 0, sourceLine: UInt32 = 0, wrapIndex: UInt32 = 0) {
        self.startCols = startCols
        self.widthCols = widthCols
        self.sourceLine = sourceLine
        self.wrapIndex = wrapIndex
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(startCols, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(widthCols, into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(sourceLine, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(wrapIndex, into: &bytes, at: 12)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigLineInfo {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigLineInfo(
            startCols: ZigBinaryCodec.readU32(bytes, at: 0),
            widthCols: ZigBinaryCodec.readU32(bytes, at: 4),
            sourceLine: ZigBinaryCodec.readU32(bytes, at: 8),
            wrapIndex: ZigBinaryCodec.readU32(bytes, at: 12)
        )
    }
}

/// C-ABI `ot_editor_position` (28 bytes, alignment 4).
public struct ZigVisualCursor: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 28
    public static let alignment: Int = 4

    public var visualRow: UInt32
    public var visualCol: UInt32
    public var logicalRow: UInt32
    public var logicalCol: UInt32
    public var offset: UInt32

    public init(
        visualRow: UInt32 = 0,
        visualCol: UInt32 = 0,
        logicalRow: UInt32 = 0,
        logicalCol: UInt32 = 0,
        offset: UInt32 = 0
    ) {
        self.visualRow = visualRow
        self.visualCol = visualCol
        self.logicalRow = logicalRow
        self.logicalCol = logicalCol
        self.offset = offset
    }

    public init(_ cursor: VisualCursor) {
        self.init(
            visualRow: UInt32(max(0, cursor.visualRow)),
            visualCol: UInt32(max(0, cursor.visualCol)),
            logicalRow: UInt32(max(0, cursor.logicalRow)),
            logicalCol: UInt32(max(0, cursor.logicalCol)),
            offset: UInt32(max(0, cursor.offset))
        )
    }

    public func toVisualCursor() -> VisualCursor {
        VisualCursor(
            visualRow: Int(visualRow),
            visualCol: Int(visualCol),
            logicalRow: Int(logicalRow),
            logicalCol: Int(logicalCol),
            offset: Int(offset)
        )
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(UInt32(Self.byteSize), into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(UInt32(NativeABI.OT_CONTEXT_ABI_VERSION), into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(visualRow, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(visualCol, into: &bytes, at: 12)
        ZigBinaryCodec.writeU32(logicalRow, into: &bytes, at: 16)
        ZigBinaryCodec.writeU32(logicalCol, into: &bytes, at: 20)
        ZigBinaryCodec.writeU32(offset, into: &bytes, at: 24)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigVisualCursor {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigVisualCursor(
            visualRow: ZigBinaryCodec.readU32(bytes, at: 8),
            visualCol: ZigBinaryCodec.readU32(bytes, at: 12),
            logicalRow: ZigBinaryCodec.readU32(bytes, at: 16),
            logicalCol: ZigBinaryCodec.readU32(bytes, at: 20),
            offset: ZigBinaryCodec.readU32(bytes, at: 24)
        )
    }
}

/// C-ABI `ot_edit_position` (24 bytes, alignment 4).
public struct ZigLogicalCursor: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 24
    public static let alignment: Int = 4

    public var valid: Bool
    public var row: UInt32
    public var col: UInt32
    public var offset: UInt32

    public init(valid: Bool = true, row: UInt32 = 0, col: UInt32 = 0, offset: UInt32 = 0) {
        self.valid = valid
        self.row = row
        self.col = col
        self.offset = offset
    }

    public init(_ cursor: LogicalCursor) {
        self.init(
            valid: true,
            row: UInt32(max(0, cursor.row)),
            col: UInt32(max(0, cursor.col)),
            offset: UInt32(max(0, cursor.offset))
        )
    }

    public func toLogicalCursor() -> LogicalCursor {
        LogicalCursor(row: Int(row), col: Int(col), offset: Int(offset))
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(UInt32(Self.byteSize), into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(UInt32(NativeABI.OT_CONTEXT_ABI_VERSION), into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(valid ? 1 : 0, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(row, into: &bytes, at: 12)
        ZigBinaryCodec.writeU32(col, into: &bytes, at: 16)
        ZigBinaryCodec.writeU32(offset, into: &bytes, at: 20)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigLogicalCursor {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigLogicalCursor(
            valid: ZigBinaryCodec.readU32(bytes, at: 8) != 0,
            row: ZigBinaryCodec.readU32(bytes, at: 12),
            col: ZigBinaryCodec.readU32(bytes, at: 16),
            offset: ZigBinaryCodec.readU32(bytes, at: 20)
        )
    }
}

/// C-ABI `ot_edit_highlight` (20 bytes, alignment 4).
public struct ZigHighlight: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 20
    public static let alignment: Int = 4

    public var start: UInt32
    public var end: UInt32
    public var styleId: UInt32
    public var priority: UInt32
    public var ref: UInt32

    public init(start: UInt32 = 0, end: UInt32 = 0, styleId: UInt32 = 0, priority: UInt32 = 0, ref: UInt32 = 0) {
        self.start = start
        self.end = end
        self.styleId = styleId
        self.priority = priority
        self.ref = ref
    }

    public init(_ highlight: Highlight) {
        self.init(
            start: UInt32(max(0, highlight.start)),
            end: UInt32(max(0, highlight.end)),
            styleId: highlight.styleId,
            priority: UInt32(max(0, highlight.priority ?? 0)),
            ref: UInt32(max(0, highlight.hlRef ?? 0))
        )
    }

    public func toHighlight() -> Highlight {
        Highlight(
            start: Int(start),
            end: Int(end),
            styleId: styleId,
            priority: Int(priority),
            hlRef: Int(ref)
        )
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(start, into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(end, into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(styleId, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(priority, into: &bytes, at: 12)
        ZigBinaryCodec.writeU32(ref, into: &bytes, at: 16)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigHighlight {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigHighlight(
            start: ZigBinaryCodec.readU32(bytes, at: 0),
            end: ZigBinaryCodec.readU32(bytes, at: 4),
            styleId: ZigBinaryCodec.readU32(bytes, at: 8),
            priority: ZigBinaryCodec.readU32(bytes, at: 12),
            ref: ZigBinaryCodec.readU32(bytes, at: 16)
        )
    }
}

/// C-ABI `ot_editor_measure` (16 bytes, alignment 4).
public struct ZigMeasuredSize: ZigPackableStruct, Hashable, Codable {
    public static let byteSize: Int = 16
    public static let alignment: Int = 4

    public var lineCount: UInt32
    public var widthColsMax: UInt32

    public init(lineCount: UInt32 = 0, widthColsMax: UInt32 = 0) {
        self.lineCount = lineCount
        self.widthColsMax = widthColsMax
    }

    public init(_ result: MeasureResult) {
        self.init(
            lineCount: UInt32(max(0, result.lineCount)),
            widthColsMax: UInt32(max(0, result.widthColsMax))
        )
    }

    public func toMeasureResult() -> MeasureResult {
        MeasureResult(lineCount: Int(lineCount), widthColsMax: Int(widthColsMax))
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(UInt32(Self.byteSize), into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(UInt32(NativeABI.OT_CONTEXT_ABI_VERSION), into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(lineCount, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(widthColsMax, into: &bytes, at: 12)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigMeasuredSize {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigMeasuredSize(
            lineCount: ZigBinaryCodec.readU32(bytes, at: 8),
            widthColsMax: ZigBinaryCodec.readU32(bytes, at: 12)
        )
    }
}

/// C-ABI `ot_styled_text_chunk` (48 bytes, alignment 4).
public struct ZigTextChunk: ZigPackableStruct, Hashable {
    public static let byteSize: Int = 48
    public static let alignment: Int = 4

    public var byteCount: UInt32
    public var flags: UInt32
    public var foreground: RGBA
    public var background: RGBA
    public var attributes: UInt32
    public var linkOffset: UInt32
    public var linkByteCount: UInt32

    public init(
        byteCount: UInt32 = 0,
        flags: UInt32 = 0,
        foreground: RGBA = .defaultForeground(),
        background: RGBA = RGBA.fromInts(0, 0, 0, 0),
        attributes: UInt32 = TextAttributes.none,
        linkOffset: UInt32 = 0,
        linkByteCount: UInt32 = 0
    ) {
        self.byteCount = byteCount
        self.flags = flags
        self.foreground = foreground
        self.background = background
        self.attributes = attributes
        self.linkOffset = linkOffset
        self.linkByteCount = linkByteCount
    }

    public func pack() -> [UInt8] {
        var bytes = Array(repeating: UInt8(0), count: Self.byteSize)
        ZigBinaryCodec.writeU32(UInt32(Self.byteSize), into: &bytes, at: 0)
        ZigBinaryCodec.writeU32(UInt32(NativeABI.OT_CONTEXT_ABI_VERSION), into: &bytes, at: 4)
        ZigBinaryCodec.writeU32(byteCount, into: &bytes, at: 8)
        ZigBinaryCodec.writeU32(flags, into: &bytes, at: 12)
        ZigBinaryCodec.writeRGBA16(foreground, into: &bytes, at: 16)
        ZigBinaryCodec.writeRGBA16(background, into: &bytes, at: 24)
        ZigBinaryCodec.writeU32(attributes, into: &bytes, at: 32)
        ZigBinaryCodec.writeU32(0, into: &bytes, at: 36)
        ZigBinaryCodec.writeU32(linkOffset, into: &bytes, at: 40)
        ZigBinaryCodec.writeU32(linkByteCount, into: &bytes, at: 44)
        return bytes
    }

    public static func unpack(_ bytes: [UInt8]) throws(ZigStructError) -> ZigTextChunk {
        guard bytes.count >= byteSize else {
            throw .bufferTooSmall(expected: byteSize, actual: bytes.count)
        }
        return ZigTextChunk(
            byteCount: ZigBinaryCodec.readU32(bytes, at: 8),
            flags: ZigBinaryCodec.readU32(bytes, at: 12),
            foreground: ZigBinaryCodec.readRGBA16(bytes, at: 16),
            background: ZigBinaryCodec.readRGBA16(bytes, at: 24),
            attributes: ZigBinaryCodec.readU32(bytes, at: 32),
            linkOffset: ZigBinaryCodec.readU32(bytes, at: 40),
            linkByteCount: ZigBinaryCodec.readU32(bytes, at: 44)
        )
    }
}

// MARK: - core/src/platform/ffi.ts (31 symbols / 5 functions)

/// Errors thrown by the pure-Swift FFI adapter (`core/src/platform/ffi.ts`).
public enum FFIError: Error, Equatable, Hashable, Sendable, CustomStringConvertible {
    case unavailable(String)
    case libraryClosed(String)
    case invalidPointer(String)
    case invalidOffset(String)
    case unsupported(String)
    case missingSymbol(String)

    public var description: String {
        switch self {
        case .unavailable(let msg),
             .libraryClosed(let msg),
             .invalidPointer(let msg),
             .invalidOffset(let msg),
             .unsupported(let msg),
             .missingSymbol(let msg):
            return msg
        }
    }
}

// parity: core/src/platform/ffi.ts#PointerInput [status=implemented hash=66ee0da36f30]
public enum PointerInput: Equatable, Hashable, Sendable {
    case int(Int64)
    case uint(UInt64)
    case pointer(FFIPointer)
}

// parity: core/src/platform/ffi.ts#Pointer [status=implemented hash=718ac4820383]
public struct FFIPointer: Equatable, Hashable, Sendable, Codable, ExpressibleByIntegerLiteral {
    public let address: UInt64

    public static let null = FFIPointer(address: 0)

    public init(address: UInt64) {
        self.address = address
    }

    public init(integerLiteral value: UInt64) {
        self.address = value
    }

    public var isNull: Bool { address == 0 }

    public func offset(by delta: Int) throws(FFIError) -> FFIPointer {
        guard delta >= 0 else {
            throw .invalidOffset(POINTER_OFFSET_NEGATIVE)
        }
        return FFIPointer(address: address &+ UInt64(delta))
    }
}

public typealias Pointer = FFIPointer

// parity: core/src/platform/ffi.ts#FFIType [status=implemented hash=a2056fd7fbdc]
public enum FFIType: String, Equatable, Hashable, Sendable, Codable, CaseIterable {
    case char = "char"
    case int8_t = "int8_t"
    case i8 = "i8"
    case uint8_t = "uint8_t"
    case u8 = "u8"
    case int16_t = "int16_t"
    case i16 = "i16"
    case uint16_t = "uint16_t"
    case u16 = "u16"
    case int32_t = "int32_t"
    case i32 = "i32"
    case int = "int"
    case uint32_t = "uint32_t"
    case u32 = "u32"
    case int64_t = "int64_t"
    case i64 = "i64"
    case uint64_t = "uint64_t"
    case u64 = "u64"
    case double = "double"
    case f64 = "f64"
    case float = "float"
    case f32 = "f32"
    case bool = "bool"
    case ptr = "ptr"
    case pointer = "pointer"
    case void = "void"
    case cstring = "cstring"
    case function = "function"
    case usize = "usize"
    case callback = "callback"
    case napi_env = "napi_env"
    case napi_value = "napi_value"
    case buffer = "buffer"
}

// parity: core/src/platform/ffi.ts#FFITypeOrString [status=implemented hash=7db78ccc255c]
public typealias FFITypeOrString = FFIType

// parity: core/src/platform/ffi.ts#FFIFunction [status=implemented hash=975b659fd763]
public struct FFIFunction: Equatable, Hashable, Sendable, Codable {
    public let args: [FFITypeOrString]
    public let returns: FFITypeOrString
    public let ptr: FFIPointer?
    public let threadsafe: Bool

    public init(
        args: [FFITypeOrString] = [],
        returns: FFITypeOrString = .void,
        ptr: FFIPointer? = nil,
        threadsafe: Bool = false
    ) {
        self.args = args
        self.returns = returns
        self.ptr = ptr
        self.threadsafe = threadsafe
    }
}

/// Safe pure-Swift view over an arena-allocated FFI byte buffer.
public struct FFIBufferView: Equatable, Hashable, Sendable {
    public let pointer: FFIPointer
    public let byteOffset: Int
    public let byteLength: Int
    public var bytes: [UInt8]

    public init(pointer: FFIPointer, byteOffset: Int = 0, bytes: [UInt8]) {
        self.pointer = pointer
        self.byteOffset = byteOffset
        self.byteLength = bytes.count
        self.bytes = bytes
    }
}

/// Symbol lookup table for a loaded pure-Swift FFI library.
public struct FFISymbolTable: Sendable {
    public typealias Invoker = @Sendable ([Any]) throws -> Any

    private let symbols: [String: Invoker]

    public init(_ symbols: [String: Invoker] = [:]) {
        self.symbols = symbols
    }

    public subscript(_ name: String) -> Invoker? {
        symbols[name]
    }

    public var names: [String] {
        symbols.keys.sorted()
    }

    public func call(_ name: String, _ args: [Any] = []) throws -> Any {
        guard let fn = symbols[name] else {
            throw FFIError.missingSymbol("FFI symbol not found: \(name)")
        }
        return try fn(args)
    }
}

// parity: core/src/platform/ffi.ts#FFICallbackInstance [status=adapted hash=d7ec3ae74bb1]
public final class FFICallbackInstance: @unchecked Sendable {
    private let lock = Mutex<State>(State())
    private struct State {
        var ptr: FFIPointer?
        var closed: Bool = false
        var onClose: (@Sendable () -> Void)?
    }

    public let threadsafe: Bool
    public let handler: @Sendable ([Any]) -> Any

    public init(
        ptr: FFIPointer,
        threadsafe: Bool = false,
        handler: @escaping @Sendable ([Any]) -> Any,
        onClose: (@Sendable () -> Void)? = nil
    ) {
        self.threadsafe = threadsafe
        self.handler = handler
        self.lock.withLock { state in
            state.ptr = ptr
            state.onClose = onClose
        }
    }

    public var ptr: FFIPointer? {
        lock.withLock { $0.ptr }
    }

    public var isClosed: Bool {
        lock.withLock { $0.closed }
    }

    public func close() {
        let onClose: (@Sendable () -> Void)? = lock.withLock { state in
            guard !state.closed else { return nil }
            state.closed = true
            state.ptr = nil
            let cb = state.onClose
            state.onClose = nil
            return cb
        }
        onClose?()
    }
}

// parity: core/src/platform/ffi.ts#Library [status=adapted hash=f096513c4ec3]
public final class FFILibrary: @unchecked Sendable {
    private struct State {
        var closed: Bool = false
        var callbacks: [UInt64: FFICallbackInstance] = [:]
    }

    private let lock = Mutex<State>(State())
    private let runtime: SwiftFFIRuntime
    private let rejectThreadsafeCallbacks: Bool
    public let path: String?
    public let definitions: [String: FFIFunction]
    public let symbols: FFISymbolTable

    public init(
        path: String?,
        definitions: [String: FFIFunction],
        symbols: FFISymbolTable = FFISymbolTable(),
        runtime: SwiftFFIRuntime = .shared,
        rejectThreadsafeCallbacks: Bool = false
    ) {
        self.path = path
        self.definitions = definitions
        self.symbols = symbols
        self.runtime = runtime
        self.rejectThreadsafeCallbacks = rejectThreadsafeCallbacks
    }

    public var isClosed: Bool {
        lock.withLock { $0.closed }
    }

    public func createCallback(
        _ callback: @escaping @Sendable ([Any]) -> Any,
        definition: FFIFunction = FFIFunction()
    ) throws(FFIError) -> FFICallbackInstance {
        let isClosed = lock.withLock { $0.closed }
        if isClosed {
            throw .libraryClosed(LIBRARY_CLOSED)
        }
        if rejectThreadsafeCallbacks && definition.threadsafe {
            throw .unsupported(NODE_CALLBACK_THREADSAFE)
        }
        let pointer = runtime.allocateCallbackPointer()
        let instance = FFICallbackInstance(
            ptr: pointer,
            threadsafe: definition.threadsafe,
            handler: callback
        ) { [weak self] in
            self?.lock.withLock { state in
                _ = state.callbacks.removeValue(forKey: pointer.address)
            }
        }
        lock.withLock { state in
            state.callbacks[pointer.address] = instance
        }
        return instance
    }

    public func close() {
        let remaining: [FFICallbackInstance] = lock.withLock { state in
            guard !state.closed else { return [] }
            state.closed = true
            let list = Array(state.callbacks.values)
            state.callbacks.removeAll()
            return list
        }
        for cb in remaining {
            cb.close()
        }
    }
}

public typealias Library = FFILibrary

// parity: core/src/platform/ffi.ts#FFI_UNAVAILABLE [status=implemented hash=910ac91ada7e]
public let FFI_UNAVAILABLE = "OpenTUI native FFI is not available for this runtime yet"

// parity: core/src/platform/ffi.ts#BUN_DLOPEN_NULL [status=implemented hash=684a6029b65b]
public let BUN_DLOPEN_NULL = "Bun FFI backend does not support dlopen(null)"

// parity: core/src/platform/ffi.ts#LIBRARY_CLOSED [status=implemented hash=d94227eef466]
public let LIBRARY_CLOSED = "Cannot create FFI callback after library.close() has been called"

// parity: core/src/platform/ffi.ts#NODE_CALLBACK_THREADSAFE [status=implemented hash=9ef7d6352244]
public let NODE_CALLBACK_THREADSAFE =
    "Node FFI callbacks are same-thread only and do not support threadsafe callbacks"

// parity: core/src/platform/ffi.ts#NODE_NAPI_UNSUPPORTED [status=implemented hash=874b7311b3cd]
public let NODE_NAPI_UNSUPPORTED = "Node FFI backend does not support Bun N-API FFI types"

// parity: core/src/platform/ffi.ts#NODE_POINTER_OVERRIDE [status=implemented hash=9dc9cf6a5f15]
public let NODE_POINTER_OVERRIDE = "Node FFI backend does not support FFIFunction.ptr overrides"

// parity: core/src/platform/ffi.ts#NODE_POINTER_ARGUMENT [status=implemented hash=5001df44f9cc]
public let NODE_POINTER_ARGUMENT =
    "Node FFI pointer arguments must be a Pointer, ArrayBuffer, or ArrayBufferView"

// parity: core/src/platform/ffi.ts#NODE_PTR_VALUE [status=implemented hash=0d90102c446b]
public let NODE_PTR_VALUE =
    "node:ffi ptr() only supports ArrayBuffer and ArrayBufferView values backed by ArrayBuffer"

// parity: core/src/platform/ffi.ts#NODE_STRING_RETURN [status=implemented hash=b59e11af69da]
public let NODE_STRING_RETURN = "Node FFI backend does not normalize string return values (yet)"

// parity: core/src/platform/ffi.ts#NODE_USIZE_UNSUPPORTED [status=implemented hash=34a3aa89ff82]
public let NODE_USIZE_UNSUPPORTED = "Node FFI backend does not support usize yet"

// parity: core/src/platform/ffi.ts#POINTER_NEGATIVE [status=implemented hash=7135e92c85e3]
public let POINTER_NEGATIVE = "Pointer must be non-negative"

// parity: core/src/platform/ffi.ts#POINTER_OFFSET_NEGATIVE [status=implemented hash=1a1fce2bfa8c]
public let POINTER_OFFSET_NEGATIVE = "Pointer offset must be non-negative"

// parity: core/src/platform/ffi.ts#POINTER_OFFSET_UNSAFE [status=implemented hash=a9f41d84e16a]
public let POINTER_OFFSET_UNSAFE = "Pointer offset must be a safe integer"

// parity: core/src/platform/ffi.ts#POINTER_UNSAFE [status=implemented hash=f37c5821dcbb]
public let POINTER_UNSAFE = "Pointer exceeds safe integer range"

// parity: core/src/platform/ffi.ts#usesBunFFI [status=adapted hash=770b799bff3d]
public let usesBunFFI: Bool = false

/// Safe pure-Swift FFI memory arena and backend runtime (zero OS / C pointer UB).
public final class SwiftFFIRuntime: @unchecked Sendable {
    public static let shared = SwiftFFIRuntime()

    private struct ArenaState {
        var nextAddress: UInt64 = 0x1000_0000
        var buffers: [UInt64: [UInt8]] = [:]
        var nextCallbackAddress: UInt64 = 0x8000_0000
    }

    private let lock = Mutex<ArenaState>(ArenaState())
    public let suffix: String

    public init(suffix: String = "dylib") {
        self.suffix = suffix
    }

    public func pinBuffer(_ bytes: [UInt8]) -> FFIPointer {
        lock.withLock { state in
            let addr = state.nextAddress
            let step = UInt64(max(16, ((bytes.count + 15) / 16) * 16))
            state.nextAddress &+= step
            state.buffers[addr] = bytes
            return FFIPointer(address: addr)
        }
    }

    public func updateBuffer(at pointer: FFIPointer, bytes: [UInt8]) {
        lock.withLock { state in
            state.buffers[pointer.address] = bytes
        }
    }

    public func releaseBuffer(at pointer: FFIPointer) {
        lock.withLock { state in
            _ = state.buffers.removeValue(forKey: pointer.address)
        }
    }

    public func readBytes(pointer: FFIPointer, offset: Int = 0, length: Int) throws(FFIError) -> [UInt8] {
        guard offset >= 0 else {
            throw .invalidOffset(POINTER_OFFSET_NEGATIVE)
        }
        guard length >= 0 else {
            throw .invalidOffset(POINTER_OFFSET_NEGATIVE)
        }
        if length == 0 { return [] }
        return lock.withLock { state in
            if let exact = state.buffers[pointer.address] {
                let start = min(offset, exact.count)
                let end = min(start + length, exact.count)
                if end - start == length {
                    return Array(exact[start..<end])
                }
                var out = Array(exact[start..<end])
                out.append(contentsOf: repeatElement(UInt8(0), count: length - out.count))
                return out
            }
            for (base, buf) in state.buffers {
                if pointer.address >= base {
                    let baseOffset = Int(pointer.address - base) + offset
                    if baseOffset >= 0, baseOffset <= buf.count {
                        let end = min(baseOffset + length, buf.count)
                        var out = Array(buf[baseOffset..<end])
                        if out.count < length {
                            out.append(contentsOf: repeatElement(UInt8(0), count: length - out.count))
                        }
                        return out
                    }
                }
            }
            return Array(repeating: 0, count: length)
        }
    }

    public func allocateCallbackPointer() -> FFIPointer {
        lock.withLock { state in
            let addr = state.nextCallbackAddress
            state.nextCallbackAddress &+= 16
            return FFIPointer(address: addr)
        }
    }
}

/// Pure-Swift FFI backend descriptor matching `FfiBackend` in `core/src/platform/ffi.ts`.
public struct FFIBackend: Sendable {
    public let name: String
    public let suffix: String
    public let runtime: SwiftFFIRuntime
    private let rejectNullPath: Bool
    private let rejectThreadsafeCallbacks: Bool

    public init(
        name: String,
        suffix: String = "dylib",
        runtime: SwiftFFIRuntime = .shared,
        rejectNullPath: Bool = false,
        rejectThreadsafeCallbacks: Bool = false
    ) {
        self.name = name
        self.suffix = suffix
        self.runtime = runtime
        self.rejectNullPath = rejectNullPath
        self.rejectThreadsafeCallbacks = rejectThreadsafeCallbacks
    }

    public func dlopen(
        _ path: String?,
        symbols: [String: FFIFunction],
        implementations: FFISymbolTable = FFISymbolTable()
    ) throws(FFIError) -> FFILibrary {
        if rejectNullPath && path == nil {
            throw .unsupported(BUN_DLOPEN_NULL)
        }
        return FFILibrary(
            path: path,
            definitions: symbols,
            symbols: implementations,
            runtime: runtime,
            rejectThreadsafeCallbacks: rejectThreadsafeCallbacks
        )
    }

    public func ptr(_ bytes: [UInt8]) -> FFIPointer {
        runtime.pinBuffer(bytes)
    }

    public func toArrayBuffer(pointer: FFIPointer, offset: Int = 0, length: Int) throws(FFIError) -> [UInt8] {
        try runtime.readBytes(pointer: pointer, offset: offset, length: length)
    }
}

private let maxSafeJSInteger: UInt64 = 9_007_199_254_740_991

// parity: core/src/platform/ffi.ts#toPointer [status=implemented hash=c3498092791b]
public func toPointer(_ value: PointerInput) throws(FFIError) -> FFIPointer {
    switch value {
    case .pointer(let p):
        return p
    case .int(let n):
        guard n >= 0 else {
            throw .invalidPointer(POINTER_NEGATIVE)
        }
        let u = UInt64(n)
        guard u <= maxSafeJSInteger else {
            throw .invalidPointer(POINTER_UNSAFE)
        }
        return FFIPointer(address: u)
    case .uint(let u):
        guard u <= maxSafeJSInteger else {
            throw .invalidPointer(POINTER_UNSAFE)
        }
        return FFIPointer(address: u)
    }
}

// parity: core/src/platform/ffi.ts#ffiBool [status=implemented hash=a00190e89218]
@inlinable
public func ffiBool(_ value: Bool) -> UInt8 {
    value ? 1 : 0
}

// parity: core/src/platform/ffi.ts#trimNodeFFIOutputBytes [status=implemented hash=020d05efb1a3]
public func trimNodeFFIOutputBytes(_ buffer: [UInt8], length: Int) -> [UInt8] {
    let clamped = max(0, min(length, buffer.count))
    if clamped == buffer.count { return buffer }
    return Array(buffer.prefix(clamped))
}

// parity: core/src/platform/ffi.ts#createBunBackend [status=adapted hash=5d53c3540c6a]
public func createBunBackend(runtime: SwiftFFIRuntime = .shared) -> FFIBackend {
    FFIBackend(
        name: "swift-bun-compat",
        suffix: runtime.suffix,
        runtime: runtime,
        rejectNullPath: true,
        rejectThreadsafeCallbacks: false
    )
}

// parity: core/src/platform/ffi.ts#createNodeBackend [status=adapted hash=2b874caabdfb]
public func createNodeBackend(runtime: SwiftFFIRuntime = .shared) -> FFIBackend {
    FFIBackend(
        name: "swift-node-compat",
        suffix: runtime.suffix,
        runtime: runtime,
        rejectNullPath: false,
        rejectThreadsafeCallbacks: true
    )
}

private let defaultSwiftFFIBackend = FFIBackend(name: "swift-pure", runtime: .shared)

// parity: core/src/platform/ffi.ts#dlopen [status=adapted hash=5fb7242f0f63]
public func dlopen(
    _ path: String?,
    symbols: [String: FFIFunction],
    implementations: FFISymbolTable = FFISymbolTable()
) throws(FFIError) -> FFILibrary {
    try defaultSwiftFFIBackend.dlopen(path, symbols: symbols, implementations: implementations)
}

// parity: core/src/platform/ffi.ts#ptr [status=adapted hash=80ee70ebe6f4]
public func ptr(_ bytes: [UInt8]) -> FFIPointer {
    defaultSwiftFFIBackend.ptr(bytes)
}

// parity: core/src/platform/ffi.ts#suffix [status=adapted hash=a502fd05108c]
public let suffix: String = defaultSwiftFFIBackend.suffix

// parity: core/src/platform/ffi.ts#toArrayBuffer [status=adapted hash=d7b14d95010d]
public func toArrayBuffer(pointer: FFIPointer, offset: Int = 0, length: Int) throws(FFIError) -> [UInt8] {
    try defaultSwiftFFIBackend.toArrayBuffer(pointer: pointer, offset: offset, length: length)
}
