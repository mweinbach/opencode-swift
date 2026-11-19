import Synchronization

// MARK: - VT100 / xterm / Ghostty-Compatible Terminal Emulation Engine

extension ProcessDaemon {
    /// Actor-local VT100/xterm/VT520 terminal emulation engine and libghostty C API compatibility layer
    /// (`packages/process-daemon/src/ghostty/*`).
    public enum Ghostty {
        // MARK: - FFI Constants, Types & Engine Operations (`src/ghostty/ffi.rs`)

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyResult [status=implemented hash=d21ff620aa7f]
        public typealias GhosttyResult = Int32

        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_SUCCESS [status=implemented hash=2e5cc2fe6c52]
        public static let GHOSTTY_SUCCESS: GhosttyResult = 0
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_OUT_OF_MEMORY [status=implemented hash=da205cf93665]
        public static let GHOSTTY_OUT_OF_MEMORY: GhosttyResult = -1
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_INVALID_VALUE [status=implemented hash=390e8d4dfc36]
        public static let GHOSTTY_INVALID_VALUE: GhosttyResult = -2
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_OUT_OF_SPACE [status=implemented hash=a74e4ac1411b]
        public static let GHOSTTY_OUT_OF_SPACE: GhosttyResult = -3
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_NO_VALUE [status=implemented hash=cd4db837adf9]
        public static let GHOSTTY_NO_VALUE: GhosttyResult = -4
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_RESULT_MAX_VALUE [status=implemented hash=eced87a8da33]
        public static let GHOSTTY_RESULT_MAX_VALUE: GhosttyResult = 2_147_483_647

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyFormatterFormat [status=implemented hash=9803e8b78fd3]
        public typealias GhosttyFormatterFormat = UInt32
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_FORMATTER_FORMAT_PLAIN [status=implemented hash=ec0d9d9e56e8]
        public static let GHOSTTY_FORMATTER_FORMAT_PLAIN: GhosttyFormatterFormat = 0
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_FORMATTER_FORMAT_VT [status=implemented hash=fbce1f48d079]
        public static let GHOSTTY_FORMATTER_FORMAT_VT: GhosttyFormatterFormat = 1
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_FORMATTER_FORMAT_HTML [status=implemented hash=67f3bd6f4ff6]
        public static let GHOSTTY_FORMATTER_FORMAT_HTML: GhosttyFormatterFormat = 2
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_FORMATTER_FORMAT_MAX_VALUE [status=implemented hash=8ca4636e9718]
        public static let GHOSTTY_FORMATTER_FORMAT_MAX_VALUE: GhosttyFormatterFormat = 2_147_483_647

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyPointTag [status=implemented hash=6974b446b991]
        public typealias GhosttyPointTag = UInt32
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_POINT_TAG_ACTIVE [status=implemented hash=acdc0e1fa1d6]
        public static let GHOSTTY_POINT_TAG_ACTIVE: GhosttyPointTag = 0
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_POINT_TAG_VIEWPORT [status=implemented hash=7e8fd475bf84]
        public static let GHOSTTY_POINT_TAG_VIEWPORT: GhosttyPointTag = 1
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_POINT_TAG_SCREEN [status=implemented hash=dd53646d66d2]
        public static let GHOSTTY_POINT_TAG_SCREEN: GhosttyPointTag = 2
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_POINT_TAG_HISTORY [status=implemented hash=05e06d6df97f]
        public static let GHOSTTY_POINT_TAG_HISTORY: GhosttyPointTag = 3
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_POINT_TAG_MAX_VALUE [status=implemented hash=007f70a3f87f]
        public static let GHOSTTY_POINT_TAG_MAX_VALUE: GhosttyPointTag = 2_147_483_647

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyTerminalScrollViewportTag [status=implemented hash=01a4c79f5c18]
        public typealias GhosttyTerminalScrollViewportTag = UInt32
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_SCROLL_VIEWPORT_TOP [status=implemented hash=977b3582af37]
        public static let GHOSTTY_SCROLL_VIEWPORT_TOP: GhosttyTerminalScrollViewportTag = 0
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_SCROLL_VIEWPORT_BOTTOM [status=implemented hash=57cf83d3afb7]
        public static let GHOSTTY_SCROLL_VIEWPORT_BOTTOM: GhosttyTerminalScrollViewportTag = 1
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_SCROLL_VIEWPORT_DELTA [status=implemented hash=4acc330d7600]
        public static let GHOSTTY_SCROLL_VIEWPORT_DELTA: GhosttyTerminalScrollViewportTag = 2
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_SCROLL_VIEWPORT_ROW [status=implemented hash=41c399e4bb97]
        public static let GHOSTTY_SCROLL_VIEWPORT_ROW: GhosttyTerminalScrollViewportTag = 3
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_SCROLL_VIEWPORT_MAX_VALUE [status=implemented hash=bf33a7948d76]
        public static let GHOSTTY_SCROLL_VIEWPORT_MAX_VALUE: GhosttyTerminalScrollViewportTag = 2_147_483_647

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyTerminalOption [status=implemented hash=9be8e308a083]
        public typealias GhosttyTerminalOption = UInt32
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_USERDATA [status=implemented hash=2b7c410c54a2]
        public static let GHOSTTY_TERMINAL_OPT_USERDATA: GhosttyTerminalOption = 0
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_WRITE_PTY [status=implemented hash=447d082c24df]
        public static let GHOSTTY_TERMINAL_OPT_WRITE_PTY: GhosttyTerminalOption = 1
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_BELL [status=implemented hash=c7d1c25b4de2]
        public static let GHOSTTY_TERMINAL_OPT_BELL: GhosttyTerminalOption = 2
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_ENQUIRY [status=implemented hash=e622621dae73]
        public static let GHOSTTY_TERMINAL_OPT_ENQUIRY: GhosttyTerminalOption = 3
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_XTVERSION [status=implemented hash=c5d8910b0c56]
        public static let GHOSTTY_TERMINAL_OPT_XTVERSION: GhosttyTerminalOption = 4
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_TITLE_CHANGED [status=implemented hash=d501286b857d]
        public static let GHOSTTY_TERMINAL_OPT_TITLE_CHANGED: GhosttyTerminalOption = 5
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_SIZE [status=implemented hash=dabae913333e]
        public static let GHOSTTY_TERMINAL_OPT_SIZE: GhosttyTerminalOption = 6
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_COLOR_SCHEME [status=implemented hash=37a8cd2665e0]
        public static let GHOSTTY_TERMINAL_OPT_COLOR_SCHEME: GhosttyTerminalOption = 7
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES [status=implemented hash=70eb9a2c9508]
        public static let GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES: GhosttyTerminalOption = 8
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_TITLE [status=implemented hash=d3bedc0a0107]
        public static let GHOSTTY_TERMINAL_OPT_TITLE: GhosttyTerminalOption = 9
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_PWD [status=implemented hash=d9f889a98820]
        public static let GHOSTTY_TERMINAL_OPT_PWD: GhosttyTerminalOption = 10
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND [status=implemented hash=3d5a5c9bd688]
        public static let GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND: GhosttyTerminalOption = 11
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND [status=implemented hash=bfab8dcbffc0]
        public static let GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND: GhosttyTerminalOption = 12
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_COLOR_CURSOR [status=implemented hash=296801750944]
        public static let GHOSTTY_TERMINAL_OPT_COLOR_CURSOR: GhosttyTerminalOption = 13
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_COLOR_PALETTE [status=implemented hash=6117667ff16f]
        public static let GHOSTTY_TERMINAL_OPT_COLOR_PALETTE: GhosttyTerminalOption = 14
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT [status=implemented hash=c40d11529651]
        public static let GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT: GhosttyTerminalOption = 15
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE [status=implemented hash=460dd645b425]
        public static let GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_FILE: GhosttyTerminalOption = 16
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE [status=implemented hash=152f633f5116]
        public static let GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_TEMP_FILE: GhosttyTerminalOption = 17
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM [status=implemented hash=efc5baceca4c]
        public static let GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_MEDIUM_SHARED_MEM: GhosttyTerminalOption = 18
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES [status=implemented hash=82fe0ac6d2ec]
        public static let GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES: GhosttyTerminalOption = 19
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY [status=implemented hash=940d35f017ea]
        public static let GHOSTTY_TERMINAL_OPT_APC_MAX_BYTES_KITTY: GhosttyTerminalOption = 20
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_SELECTION [status=implemented hash=a01589524b12]
        public static let GHOSTTY_TERMINAL_OPT_SELECTION: GhosttyTerminalOption = 21
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE [status=implemented hash=e7503869ee86]
        public static let GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE: GhosttyTerminalOption = 22
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK [status=implemented hash=ef89f2fed8ed]
        public static let GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK: GhosttyTerminalOption = 23
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_GLYPH_PROTOCOL [status=implemented hash=d60f13a7194d]
        public static let GHOSTTY_TERMINAL_OPT_GLYPH_PROTOCOL: GhosttyTerminalOption = 24
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_PWD_CHANGED [status=implemented hash=254a5a728a03]
        public static let GHOSTTY_TERMINAL_OPT_PWD_CHANGED: GhosttyTerminalOption = 25
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE [status=implemented hash=d868f118aef6]
        public static let GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE: GhosttyTerminalOption = 26
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_OPT_MAX_VALUE [status=implemented hash=d1f3006d1a48]
        public static let GHOSTTY_TERMINAL_OPT_MAX_VALUE: GhosttyTerminalOption = 2_147_483_647

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyTerminalData [status=implemented hash=566204073a14]
        public typealias GhosttyTerminalData = UInt32
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_INVALID [status=implemented hash=e74807d5bb28]
        public static let GHOSTTY_TERMINAL_DATA_INVALID: GhosttyTerminalData = 0
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_COLS [status=implemented hash=1ae298d5b91d]
        public static let GHOSTTY_TERMINAL_DATA_COLS: GhosttyTerminalData = 1
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_ROWS [status=implemented hash=e5ac89d7af55]
        public static let GHOSTTY_TERMINAL_DATA_ROWS: GhosttyTerminalData = 2
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_CURSOR_X [status=implemented hash=937b37490e60]
        public static let GHOSTTY_TERMINAL_DATA_CURSOR_X: GhosttyTerminalData = 3
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_CURSOR_Y [status=implemented hash=96cc66237f0c]
        public static let GHOSTTY_TERMINAL_DATA_CURSOR_Y: GhosttyTerminalData = 4
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP [status=implemented hash=19085463130f]
        public static let GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP: GhosttyTerminalData = 5
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN [status=implemented hash=8fd2973f7617]
        public static let GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN: GhosttyTerminalData = 6
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE [status=implemented hash=a0b95480af30]
        public static let GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE: GhosttyTerminalData = 7
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS [status=implemented hash=4f497969f89c]
        public static let GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS: GhosttyTerminalData = 8
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_SCROLLBAR [status=implemented hash=c4daeb88d43b]
        public static let GHOSTTY_TERMINAL_DATA_SCROLLBAR: GhosttyTerminalData = 9
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_CURSOR_STYLE [status=implemented hash=4adb6f535b17]
        public static let GHOSTTY_TERMINAL_DATA_CURSOR_STYLE: GhosttyTerminalData = 10
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING [status=implemented hash=73dc44ec801d]
        public static let GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING: GhosttyTerminalData = 11
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_TITLE [status=implemented hash=9e9b8de247ae]
        public static let GHOSTTY_TERMINAL_DATA_TITLE: GhosttyTerminalData = 12
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_PWD [status=implemented hash=cdc353172cf3]
        public static let GHOSTTY_TERMINAL_DATA_PWD: GhosttyTerminalData = 13
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_TOTAL_ROWS [status=implemented hash=107405136fe7]
        public static let GHOSTTY_TERMINAL_DATA_TOTAL_ROWS: GhosttyTerminalData = 14
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS [status=implemented hash=d979fea85481]
        public static let GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS: GhosttyTerminalData = 15
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_WIDTH_PX [status=implemented hash=f223dc2ce486]
        public static let GHOSTTY_TERMINAL_DATA_WIDTH_PX: GhosttyTerminalData = 16
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_HEIGHT_PX [status=implemented hash=edfc8a18741c]
        public static let GHOSTTY_TERMINAL_DATA_HEIGHT_PX: GhosttyTerminalData = 17
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND [status=implemented hash=d8c3cd680f6d]
        public static let GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND: GhosttyTerminalData = 18
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND [status=implemented hash=804e6b268634]
        public static let GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND: GhosttyTerminalData = 19
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_COLOR_CURSOR [status=implemented hash=2c2b8570bb10]
        public static let GHOSTTY_TERMINAL_DATA_COLOR_CURSOR: GhosttyTerminalData = 20
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_COLOR_PALETTE [status=implemented hash=d2dd735cfbe7]
        public static let GHOSTTY_TERMINAL_DATA_COLOR_PALETTE: GhosttyTerminalData = 21
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT [status=implemented hash=2d8561a9e201]
        public static let GHOSTTY_TERMINAL_DATA_COLOR_FOREGROUND_DEFAULT: GhosttyTerminalData = 22
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT [status=implemented hash=09055ee9b748]
        public static let GHOSTTY_TERMINAL_DATA_COLOR_BACKGROUND_DEFAULT: GhosttyTerminalData = 23
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT [status=implemented hash=9851192f9f3e]
        public static let GHOSTTY_TERMINAL_DATA_COLOR_CURSOR_DEFAULT: GhosttyTerminalData = 24
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT [status=implemented hash=3d5a3257b683]
        public static let GHOSTTY_TERMINAL_DATA_COLOR_PALETTE_DEFAULT: GhosttyTerminalData = 25
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT [status=implemented hash=d290b83fd3fd]
        public static let GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_STORAGE_LIMIT: GhosttyTerminalData = 26
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_FILE [status=implemented hash=a72eeeef191a]
        public static let GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_FILE: GhosttyTerminalData = 27
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_TEMP_FILE [status=implemented hash=c6f31c057bca]
        public static let GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_TEMP_FILE: GhosttyTerminalData = 28
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_SHARED_MEM [status=implemented hash=d5e6cc06a3d1]
        public static let GHOSTTY_TERMINAL_DATA_KITTY_IMAGE_MEDIUM_SHARED_MEM: GhosttyTerminalData = 29
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS [status=implemented hash=7449347b47be]
        public static let GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS: GhosttyTerminalData = 30
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_SELECTION [status=implemented hash=410659c1b47c]
        public static let GHOSTTY_TERMINAL_DATA_SELECTION: GhosttyTerminalData = 31
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE [status=implemented hash=2f7bb8e2f900]
        public static let GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE: GhosttyTerminalData = 32
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR [status=implemented hash=88b2061e8c21]
        public static let GHOSTTY_TERMINAL_DATA_VT_PROCESSING_ERROR: GhosttyTerminalData = 33
        // parity: process-daemon/src/ghostty/ffi.rs#GHOSTTY_TERMINAL_DATA_MAX_VALUE [status=implemented hash=484ac5183f99]
        public static let GHOSTTY_TERMINAL_DATA_MAX_VALUE: GhosttyTerminalData = 2_147_483_647

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyString [status=adapted hash=a5a5601e37d8]
        public struct GhosttyString: Equatable, Hashable, Sendable {
            public var bytes: [UInt8]
            public var len: Int { bytes.count }

            public init(bytes: [UInt8] = []) {
                self.bytes = bytes
            }

            public init(_ string: String) {
                self.bytes = Array(string.utf8)
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyAllocatorVtable [status=adapted hash=0320654993ef]
        public struct GhosttyAllocatorVtable: Sendable {
            public let alloc: (@Sendable (Int) -> [UInt8])?
            public let free: (@Sendable ([UInt8]) -> Void)?

            public init(
                alloc: (@Sendable (Int) -> [UInt8])? = nil,
                free: (@Sendable ([UInt8]) -> Void)? = nil
            ) {
                self.alloc = alloc
                self.free = free
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyAllocator [status=adapted hash=cd05fb02fd15]
        public struct GhosttyAllocator: Sendable {
            public let vtable: GhosttyAllocatorVtable?

            public init(vtable: GhosttyAllocatorVtable? = nil) {
                self.vtable = vtable
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyGridRef [status=adapted hash=5df471f86fba]
        public struct GhosttyGridRef: Equatable, Hashable, Sendable {
            public var size: Int
            public var x: UInt16
            public var y: UInt32
            public var isAlternate: Bool

            public init(size: Int = MemoryLayout<GhosttyGridRef>.size, x: UInt16 = 0, y: UInt32 = 0, isAlternate: Bool = false) {
                self.size = size
                self.x = x
                self.y = y
                self.isAlternate = isAlternate
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyPointCoordinate [status=implemented hash=7818f2d6c297]
        public struct GhosttyPointCoordinate: Equatable, Hashable, Sendable {
            public var x: UInt16
            public var y: UInt32

            public init(x: UInt16 = 0, y: UInt32 = 0) {
                self.x = x
                self.y = y
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyPoint [status=implemented hash=f57624f33d82]
        public struct GhosttyPoint: Equatable, Hashable, Sendable {
            public var tag: GhosttyPointTag
            public var coordinate: GhosttyPointCoordinate

            public init(tag: GhosttyPointTag = GHOSTTY_POINT_TAG_SCREEN, coordinate: GhosttyPointCoordinate = GhosttyPointCoordinate()) {
                self.tag = tag
                self.coordinate = coordinate
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttySelection [status=implemented hash=1ebd7ea9bfac]
        public struct GhosttySelection: Equatable, Hashable, Sendable {
            public var size: Int
            public var start: GhosttyGridRef
            public var end: GhosttyGridRef
            public var rectangle: Bool

            public init(
                size: Int = MemoryLayout<GhosttySelection>.size,
                start: GhosttyGridRef = GhosttyGridRef(),
                end: GhosttyGridRef = GhosttyGridRef(),
                rectangle: Bool = false
            ) {
                self.size = size
                self.start = start
                self.end = end
                self.rectangle = rectangle
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyTerminalSelectionFormatOptions [status=implemented hash=987c7301e64e]
        public struct GhosttyTerminalSelectionFormatOptions: Equatable, Hashable, Sendable {
            public var size: Int
            public var emit: GhosttyFormatterFormat
            public var unwrap: Bool
            public var trim: Bool
            public var selection: GhosttySelection?

            public init(
                size: Int = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size,
                emit: GhosttyFormatterFormat = GHOSTTY_FORMATTER_FORMAT_PLAIN,
                unwrap: Bool = true,
                trim: Bool = true,
                selection: GhosttySelection? = nil
            ) {
                self.size = size
                self.emit = emit
                self.unwrap = unwrap
                self.trim = trim
                self.selection = selection
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyTerminalOptions [status=implemented hash=44a77c24aa7e]
        public struct GhosttyTerminalOptions: Equatable, Hashable, Sendable {
            public var cols: UInt16
            public var rows: UInt16
            public var max_scrollback: Int

            public init(cols: UInt16, rows: UInt16, max_scrollback: Int) {
                self.cols = cols
                self.rows = rows
                self.max_scrollback = max_scrollback
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyTerminalScrollViewport [status=implemented hash=24dec672c1eb]
        public struct GhosttyTerminalScrollViewport: Equatable, Hashable, Sendable {
            public var tag: GhosttyTerminalScrollViewportTag
            public var delta: Int
            public var row: Int

            public init(tag: GhosttyTerminalScrollViewportTag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM, delta: Int = 0, row: Int = 0) {
                self.tag = tag
                self.delta = delta
                self.row = row
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyFormatterScreenExtra [status=implemented hash=b61c630a4d8e]
        public struct GhosttyFormatterScreenExtra: Equatable, Hashable, Sendable {
            public var size: Int
            public var cursor: Bool
            public var style: Bool
            public var hyperlink: Bool
            public var protection: Bool
            public var kitty_keyboard: Bool
            public var charsets: Bool

            public init(
                size: Int = MemoryLayout<GhosttyFormatterScreenExtra>.size,
                cursor: Bool = false,
                style: Bool = false,
                hyperlink: Bool = false,
                protection: Bool = false,
                kitty_keyboard: Bool = false,
                charsets: Bool = false
            ) {
                self.size = size
                self.cursor = cursor
                self.style = style
                self.hyperlink = hyperlink
                self.protection = protection
                self.kitty_keyboard = kitty_keyboard
                self.charsets = charsets
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyFormatterTerminalExtra [status=implemented hash=c1baba824755]
        public struct GhosttyFormatterTerminalExtra: Equatable, Hashable, Sendable {
            public var size: Int
            public var palette: Bool
            public var modes: Bool
            public var scrolling_region: Bool
            public var tabstops: Bool
            public var pwd: Bool
            public var keyboard: Bool
            public var screen: GhosttyFormatterScreenExtra

            public init(
                size: Int = MemoryLayout<GhosttyFormatterTerminalExtra>.size,
                palette: Bool = false,
                modes: Bool = false,
                scrolling_region: Bool = false,
                tabstops: Bool = false,
                pwd: Bool = false,
                keyboard: Bool = false,
                screen: GhosttyFormatterScreenExtra = GhosttyFormatterScreenExtra()
            ) {
                self.size = size
                self.palette = palette
                self.modes = modes
                self.scrolling_region = scrolling_region
                self.tabstops = tabstops
                self.pwd = pwd
                self.keyboard = keyboard
                self.screen = screen
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyFormatterTerminalOptions [status=implemented hash=d548faffa348]
        public struct GhosttyFormatterTerminalOptions: Equatable, Hashable, Sendable {
            public var size: Int
            public var emit: GhosttyFormatterFormat
            public var unwrap: Bool
            public var trim: Bool
            public var extra: GhosttyFormatterTerminalExtra
            public var selection: GhosttySelection?

            public init(
                size: Int = MemoryLayout<GhosttyFormatterTerminalOptions>.size,
                emit: GhosttyFormatterFormat = GHOSTTY_FORMATTER_FORMAT_PLAIN,
                unwrap: Bool = false,
                trim: Bool = true,
                extra: GhosttyFormatterTerminalExtra = GhosttyFormatterTerminalExtra(),
                selection: GhosttySelection? = nil
            ) {
                self.size = size
                self.emit = emit
                self.unwrap = unwrap
                self.trim = trim
                self.extra = extra
                self.selection = selection
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyTerminalTitleChangedFn [status=adapted hash=5ca6841b1b25]
        public typealias GhosttyTerminalTitleChangedFn = (@Sendable (GhosttyTerminal, Effects?) -> Void)?

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyTerminalWritePtyFn [status=adapted hash=1aab63db2bba]
        public typealias GhosttyTerminalWritePtyFn = (@Sendable (GhosttyTerminal, Effects?, [UInt8]) -> Void)?

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyTerminal [status=adapted hash=5743a988688b]
        public typealias GhosttyTerminal = GhosttyTerminalImpl?

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyFormatter [status=adapted hash=fadae4da7d72]
        public typealias GhosttyFormatter = GhosttyFormatterImpl?

        // MARK: - Effects Callback Bridge (`src/ghostty/effects.rs`)

        // parity: process-daemon/src/ghostty/effects.rs#Effects [status=adapted hash=861f3a336ef0]
        public final class Effects: Sendable {
            private struct State: Sendable {
                var writes: [[UInt8]] = []
                var titleChanged: Bool = false
                var panicMessage: String?
            }

            private let state = Mutex(State())

            public init() {}

            // parity: process-daemon/src/ghostty/effects.rs#userdata [status=adapted hash=66f37ab86244]
            public func userdata() -> Effects {
                self
            }

            // parity: process-daemon/src/ghostty/effects.rs#take_writes [status=implemented hash=bcbf9f30a739]
            public func take_writes() -> [[UInt8]] {
                state.withLock { s in
                    let out = s.writes
                    s.writes.removeAll(keepingCapacity: true)
                    return out
                }
            }

            // parity: process-daemon/src/ghostty/effects.rs#take_title_changed [status=implemented hash=6d6fce88fd6d]
            public func take_title_changed() -> Bool {
                state.withLock { s in
                    let changed = s.titleChanged
                    s.titleChanged = false
                    return changed
                }
            }

            // parity: process-daemon/src/ghostty/effects.rs#resume_panic [status=adapted hash=a233f99e1418]
            public func resume_panic() {
                let message = state.withLock { s -> String? in
                    let msg = s.panicMessage
                    s.panicMessage = nil
                    return msg
                }
                if let message {
                    preconditionFailure("Ghostty callback panic: \(message)")
                }
            }

            public func recordWrite(_ bytes: [UInt8]) {
                guard !bytes.isEmpty else { return }
                state.withLock { s in
                    guard s.panicMessage == nil else { return }
                    s.writes.append(bytes)
                }
            }

            public func markTitleChanged() {
                state.withLock { $0.titleChanged = true }
            }

            // parity: process-daemon/src/ghostty/effects.rs#write_pty [status=adapted hash=d6750b14a161]
            public static func write_pty(_ terminal: GhosttyTerminal, userdata: Effects?, data: [UInt8]) {
                _ = terminal
                guard let userdata, !data.isEmpty else { return }
                userdata.recordWrite(data)
            }

            // parity: process-daemon/src/ghostty/effects.rs#title_changed [status=adapted hash=ea2e161e5d18]
            public static func title_changed(_ terminal: GhosttyTerminal, userdata: Effects?) {
                _ = terminal
                userdata?.markTitleChanged()
            }

            public static let writePtyCallback: @Sendable (GhosttyTerminal, Effects?, [UInt8]) -> Void = { terminal, effects, bytes in
                Effects.write_pty(terminal, userdata: effects, data: bytes)
            }

            public static let titleChangedCallback: @Sendable (GhosttyTerminal, Effects?) -> Void = { terminal, effects in
                Effects.title_changed(terminal, userdata: effects)
            }
        }

        // MARK: - Native Pure-Swift VT Screen & Scrollback Implementation

        internal struct Cell: Equatable, Sendable {
            var text: String = ""
            var width: UInt8 = 1 // 1 = normal, 2 = wide lead, 0 = wide continuation
            var sgr: String = "" // active SGR sequence if non-default

            var isEmpty: Bool {
                text.isEmpty && width == 1
            }
        }

        internal struct Row: Equatable, Sendable {
            var cells: [Cell]
            var wrapped: Bool = false

            init(cols: Int, wrapped: Bool = false) {
                self.cells = Array(repeating: Cell(), count: cols)
                self.wrapped = wrapped
            }

            func plainText(trimTrailing: Bool) -> String {
                var lastNonSpace = -1
                if trimTrailing {
                    for idx in stride(from: cells.count - 1, through: 0, by: -1) {
                        let cell = cells[idx]
                        if cell.width == 0 {
                            lastNonSpace = idx
                            break
                        }
                        if !cell.text.isEmpty && cell.text != " " {
                            lastNonSpace = idx
                            break
                        }
                    }
                    if lastNonSpace < 0 { return "" }
                } else {
                    lastNonSpace = cells.count - 1
                }
                var out = ""
                out.reserveCapacity(lastNonSpace + 1)
                for idx in 0...lastNonSpace {
                    let cell = cells[idx]
                    if cell.width == 0 { continue }
                    if cell.text.isEmpty {
                        out.append(" ")
                    } else {
                        out.append(cell.text)
                    }
                }
                return out
            }

            func vtText() -> String {
                var lastNonEmpty = -1
                for idx in stride(from: cells.count - 1, through: 0, by: -1) {
                    let cell = cells[idx]
                    if cell.width == 0 || !cell.text.isEmpty || !cell.sgr.isEmpty {
                        lastNonEmpty = idx
                        break
                    }
                }
                if lastNonEmpty < 0 { return "" }
                var out = ""
                var currentSGR = ""
                for idx in 0...lastNonEmpty {
                    let cell = cells[idx]
                    if cell.width == 0 { continue }
                    if cell.sgr != currentSGR {
                        if cell.sgr.isEmpty {
                            out.append("\u{1B}[0m")
                        } else {
                            out.append(cell.sgr)
                        }
                        currentSGR = cell.sgr
                    }
                    out.append(cell.text.isEmpty ? " " : cell.text)
                }
                if !currentSGR.isEmpty {
                    out.append("\u{1B}[0m")
                }
                return out
            }
        }

        internal struct ScreenBuffer: Sendable {
            var cols: Int
            var rows: Int
            var maxScrollbackRows: Int
            var scrollback: [Row] = []
            var active: [Row]
            var cursorX: Int = 0
            var cursorY: Int = 0
            var pendingWrap: Bool = false
            var savedCursorX: Int = 0
            var savedCursorY: Int = 0
            var scrollTop: Int = 0
            var scrollBottom: Int
            var viewportOffsetFromTop: Int? = nil // nil means pinned to bottom (active)

            init(cols: Int, rows: Int, maxScrollbackRows: Int) {
                self.cols = cols
                self.rows = rows
                self.maxScrollbackRows = maxScrollbackRows
                self.active = (0..<rows).map { _ in Row(cols: cols) }
                self.scrollBottom = max(0, rows - 1)
            }

            var totalRows: Int {
                scrollback.count + active.count
            }

            func row(atScreenY y: Int) -> Row? {
                if y < 0 || y >= totalRows { return nil }
                if y < scrollback.count {
                    return scrollback[y]
                }
                return active[y - scrollback.count]
            }

            mutating func pushScrollback(_ row: Row) {
                guard maxScrollbackRows > 0 else { return }
                scrollback.append(row)
                if scrollback.count > maxScrollbackRows {
                    let overflow = scrollback.count - maxScrollbackRows
                    scrollback.removeFirst(overflow)
                    if let offset = viewportOffsetFromTop {
                        viewportOffsetFromTop = max(0, offset - overflow)
                    }
                }
            }

            mutating func scrollUp(lines: Int = 1) {
                let top = max(0, min(scrollTop, rows - 1))
                let bottom = max(top, min(scrollBottom, rows - 1))
                let count = min(lines, bottom - top + 1)
                for _ in 0..<count {
                    let evicted = active.remove(at: top)
                    if top == 0 && bottom == rows - 1 {
                        pushScrollback(evicted)
                    }
                    active.insert(Row(cols: cols), at: bottom)
                }
            }

            mutating func scrollDown(lines: Int = 1) {
                let top = max(0, min(scrollTop, rows - 1))
                let bottom = max(top, min(scrollBottom, rows - 1))
                let count = min(lines, bottom - top + 1)
                for _ in 0..<count {
                    active.remove(at: bottom)
                    active.insert(Row(cols: cols), at: top)
                }
            }

            mutating func newline() {
                pendingWrap = false
                if cursorY == scrollBottom {
                    scrollUp(lines: 1)
                } else if cursorY < rows - 1 {
                    cursorY += 1
                }
            }

            mutating func writeScalar(_ scalar: UnicodeScalar, currentSGR: String) {
                let width = displayWidth(of: scalar)
                if width == 0 {
                    // Combining mark attaches to the preceding cell if available
                    let targetY = cursorY
                    let targetX: Int
                    if pendingWrap {
                        targetX = cols - 1
                    } else if cursorX > 0 {
                        targetX = cursorX - 1
                    } else {
                        return
                    }
                    var attachX = targetX
                    if attachX > 0 && active[targetY].cells[attachX].width == 0 {
                        attachX -= 1
                    }
                    if !active[targetY].cells[attachX].text.isEmpty {
                        active[targetY].cells[attachX].text.unicodeScalars.append(scalar)
                    }
                    return
                }

                if pendingWrap {
                    active[cursorY].wrapped = true
                    cursorX = 0
                    newline()
                }

                if width == 2 && cursorX == cols - 1 && cols > 1 {
                    active[cursorY].wrapped = true
                    active[cursorY].cells[cursorX] = Cell()
                    cursorX = 0
                    newline()
                }

                if cursorX >= cols {
                    cursorX = cols - 1
                }

                // Clear overwriting wide cell halves
                if active[cursorY].cells[cursorX].width == 0 && cursorX > 0 {
                    active[cursorY].cells[cursorX - 1] = Cell()
                } else if active[cursorY].cells[cursorX].width == 2 && cursorX + 1 < cols {
                    active[cursorY].cells[cursorX + 1] = Cell()
                }

                active[cursorY].cells[cursorX] = Cell(
                    text: String(scalar),
                    width: UInt8(width),
                    sgr: currentSGR
                )
                if width == 2 && cursorX + 1 < cols {
                    active[cursorY].cells[cursorX + 1] = Cell(text: "", width: 0, sgr: currentSGR)
                }

                if cursorX + width >= cols {
                    cursorX = cols - 1
                    pendingWrap = true
                } else {
                    cursorX += width
                    pendingWrap = false
                }
            }

            /// Reflows soft-wrapped logical lines on resize, preserving scrollback and cursor position.
            mutating func resize(newCols: Int, newRows: Int) {
                guard newCols > 0 && newRows > 0 else { return }
                if newCols == cols && newRows == rows { return }

                // Step 1: Collect all rows (scrollback + active), trimming trailing blank rows below cursorY
                let allRows = scrollback + active
                let cursorAbsRow = scrollback.count + cursorY
                var effectiveCount = allRows.count
                while effectiveCount > cursorAbsRow + 1 {
                    let row = allRows[effectiveCount - 1]
                    if !row.wrapped && row.plainText(trimTrailing: true).isEmpty {
                        effectiveCount -= 1
                    } else {
                        break
                    }
                }
                let usedRows = Array(allRows.prefix(effectiveCount))

                // Step 2: Reconstruct logical lines (sequences of cells joined while row.wrapped == true)
                struct LogicalLine {
                    var cells: [Cell]
                    var cursorCellIndex: Int?
                }

                var logicalLines: [LogicalLine] = []
                var currentCells: [Cell] = []
                var currentCursorIdx: Int? = nil
                var cursorFound = false

                for (rowIdx, row) in usedRows.enumerated() {
                    let lineStartOffset = currentCells.count
                    if rowIdx == cursorAbsRow {
                        currentCursorIdx = lineStartOffset + min(cursorX, max(0, row.cells.count - 1))
                        cursorFound = true
                    }
                    if row.wrapped {
                        currentCells.append(contentsOf: row.cells)
                    } else {
                        var lastUsed = -1
                        for cIdx in stride(from: row.cells.count - 1, through: 0, by: -1) {
                            let c = row.cells[cIdx]
                            if c.width == 0 || !c.text.isEmpty {
                                lastUsed = cIdx
                                break
                            }
                        }
                        if lastUsed >= 0 {
                            currentCells.append(contentsOf: row.cells[0...lastUsed])
                        }
                        logicalLines.append(LogicalLine(cells: currentCells, cursorCellIndex: currentCursorIdx))
                        currentCells = []
                        currentCursorIdx = nil
                    }
                }
                if !currentCells.isEmpty || currentCursorIdx != nil {
                    logicalLines.append(LogicalLine(cells: currentCells, cursorCellIndex: currentCursorIdx))
                }
                if logicalLines.isEmpty {
                    logicalLines.append(LogicalLine(cells: [], cursorCellIndex: 0))
                }

                // Step 3: Re-wrap each logical line to newCols
                var reflowed: [Row] = []
                var newCursorAbsRow = 0
                var newCursorX = 0

                for line in logicalLines {
                    if line.cells.isEmpty {
                        if line.cursorCellIndex != nil {
                            newCursorAbsRow = reflowed.count
                            newCursorX = 0
                        }
                        reflowed.append(Row(cols: newCols, wrapped: false))
                        continue
                    }

                    var row = Row(cols: newCols, wrapped: false)
                    var col = 0
                    var i = 0
                    while i < line.cells.count {
                        let cell = line.cells[i]
                        if cell.width == 0 {
                            i += 1
                            continue
                        }
                        let w = Int(cell.width)
                        if col + w > newCols {
                            row.wrapped = true
                            reflowed.append(row)
                            row = Row(cols: newCols, wrapped: false)
                            col = 0
                        }
                        if line.cursorCellIndex == i {
                            newCursorAbsRow = reflowed.count
                            newCursorX = col
                        }
                        row.cells[col] = cell
                        if w == 2 && col + 1 < newCols {
                            row.cells[col + 1] = Cell(text: "", width: 0, sgr: cell.sgr)
                        }
                        col += w
                        i += (w == 2 && i + 1 < line.cells.count && line.cells[i + 1].width == 0) ? 2 : 1
                    }
                    if let cIdx = line.cursorCellIndex, cIdx >= line.cells.count {
                        newCursorAbsRow = reflowed.count
                        newCursorX = min(col, newCols - 1)
                    }
                    reflowed.append(row)
                }

                if !cursorFound {
                    newCursorAbsRow = max(0, reflowed.count - 1)
                    newCursorX = min(cursorX, newCols - 1)
                }

                // Step 4: Split into scrollback + active rows of height newRows
                if reflowed.count <= newRows {
                    scrollback = []
                    active = reflowed
                    while active.count < newRows {
                        active.append(Row(cols: newCols))
                    }
                    cursorY = min(newCursorAbsRow, newRows - 1)
                } else {
                    let splitAt = reflowed.count - newRows
                    scrollback = Array(reflowed[0..<splitAt])
                    if scrollback.count > maxScrollbackRows {
                        scrollback.removeFirst(scrollback.count - maxScrollbackRows)
                    }
                    active = Array(reflowed[splitAt...])
                    cursorY = max(0, min(newCursorAbsRow - splitAt, newRows - 1))
                }
                cols = newCols
                rows = newRows
                cursorX = max(0, min(newCursorX, newCols - 1))
                pendingWrap = false
                scrollTop = 0
                scrollBottom = max(0, newRows - 1)
                viewportOffsetFromTop = nil
            }
        }

        private static func displayWidth(of scalar: UnicodeScalar) -> Int {
            let v = scalar.value
            // Combining diacritical marks & zero-width joiners/variation selectors
            if (0x0300...0x036F).contains(v)
                || (0x1AB0...0x1AFF).contains(v)
                || (0x1DC0...0x1DFF).contains(v)
                || (0x20D0...0x20FF).contains(v)
                || (0xFE00...0xFE0F).contains(v)
                || (0xFE20...0xFE2F).contains(v)
                || v == 0x200B || v == 0x200C || v == 0x200D || v == 0xFEFF {
                return 0
            }
            // CJK / Hangul / Fullwidth / Emoji wide ranges
            if (0x1100...0x115F).contains(v)
                || (0x2329...0x232A).contains(v)
                || (0x2E80...0x303E).contains(v)
                || (0x3040...0xA4CF).contains(v)
                || (0xAC00...0xD7A3).contains(v)
                || (0xF900...0xFAFF).contains(v)
                || (0xFE10...0xFE19).contains(v)
                || (0xFE30...0xFE6F).contains(v)
                || (0xFF00...0xFF60).contains(v)
                || (0xFFE0...0xFFE6).contains(v)
                || (0x1F300...0x1FAFF).contains(v)
                || (0x20000...0x3FFFD).contains(v) {
                return 2
            }
            return 1
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyTerminalImpl [status=adapted hash=93f273ee8d7a]
        public final class GhosttyTerminalImpl: @unchecked Sendable {
            private enum ParseState {
                case ground
                case escape
                case csi
                case osc
                case oscEscape
                case charset
            }

            internal var primary: ScreenBuffer
            internal var alternate: ScreenBuffer
            internal var usingAlternate: Bool = false
            internal var cursorVisible: Bool = true
            internal var title: String = ""
            internal var pwd: String = ""
            internal var currentSGR: String = ""
            internal var selection: GhosttySelection? = nil
            internal var userdata: Effects? = nil
            internal var writePtyFn: GhosttyTerminalWritePtyFn = nil
            internal var titleChangedFn: GhosttyTerminalTitleChangedFn = nil
            private var parseState: ParseState = .ground
            private var csiBuffer: [UInt8] = []
            private var oscBuffer: [UInt8] = []
            private var utf8Pending: [UInt8] = []
            private var utf8Expected: Int = 0

            internal var activeBuffer: ScreenBuffer {
                get { usingAlternate ? alternate : primary }
                set {
                    if usingAlternate {
                        alternate = newValue
                    } else {
                        primary = newValue
                    }
                }
            }

            public init(options: GhosttyTerminalOptions) {
                let cols = max(1, Int(options.cols))
                let rows = max(1, Int(options.rows))
                // Cap scrollback rows derived from byte budget (assuming ~64 bytes/row floor)
                let maxScrollbackRows = options.max_scrollback == 0
                    ? 0
                    : max(100, min(100_000, options.max_scrollback / max(1, cols)))
                self.primary = ScreenBuffer(cols: cols, rows: rows, maxScrollbackRows: maxScrollbackRows)
                self.alternate = ScreenBuffer(cols: cols, rows: rows, maxScrollbackRows: 0)
            }

            internal func feed(_ bytes: [UInt8]) {
                for byte in bytes {
                    processByte(byte)
                }
            }

            private func processByte(_ byte: UInt8) {
                switch parseState {
                case .ground:
                    if utf8Expected > 0 {
                        if (byte & 0xC0) == 0x80 {
                            utf8Pending.append(byte)
                            if utf8Pending.count == utf8Expected {
                                let str = String(decoding: utf8Pending, as: UTF8.self)
                                utf8Pending.removeAll(keepingCapacity: true)
                                utf8Expected = 0
                                for scalar in str.unicodeScalars {
                                    activeBuffer.writeScalar(scalar, currentSGR: currentSGR)
                                }
                            }
                            return
                        } else {
                            utf8Pending.removeAll(keepingCapacity: true)
                            utf8Expected = 0
                        }
                    }

                    switch byte {
                    case 0x1B: // ESC
                        parseState = .escape
                    case 0x0D: // CR
                        activeBuffer.cursorX = 0
                        activeBuffer.pendingWrap = false
                    case 0x0A, 0x0B, 0x0C: // LF, VT, FF
                        activeBuffer.newline()
                    case 0x08: // BS
                        activeBuffer.pendingWrap = false
                        if activeBuffer.cursorX > 0 {
                            activeBuffer.cursorX -= 1
                        }
                    case 0x09: // TAB
                        activeBuffer.pendingWrap = false
                        let nextTab = ((activeBuffer.cursorX / 8) + 1) * 8
                        activeBuffer.cursorX = min(nextTab, activeBuffer.cols - 1)
                    case 0x07: // BEL
                        break
                    case 0x00..<0x20, 0x7F:
                        break
                    case 0x20..<0x7F:
                        activeBuffer.writeScalar(UnicodeScalar(byte), currentSGR: currentSGR)
                    default:
                        if (byte & 0xE0) == 0xC0 {
                            utf8Pending = [byte]
                            utf8Expected = 2
                        } else if (byte & 0xF0) == 0xE0 {
                            utf8Pending = [byte]
                            utf8Expected = 3
                        } else if (byte & 0xF8) == 0xF0 {
                            utf8Pending = [byte]
                            utf8Expected = 4
                        }
                    }

                case .escape:
                    switch byte {
                    case UInt8(ascii: "["):
                        csiBuffer.removeAll(keepingCapacity: true)
                        parseState = .csi
                    case UInt8(ascii: "]"):
                        oscBuffer.removeAll(keepingCapacity: true)
                        parseState = .osc
                    case UInt8(ascii: "("), UInt8(ascii: ")"), UInt8(ascii: "*"), UInt8(ascii: "+"):
                        parseState = .charset
                    case UInt8(ascii: "7"): // DECSC save cursor
                        activeBuffer.savedCursorX = activeBuffer.cursorX
                        activeBuffer.savedCursorY = activeBuffer.cursorY
                        parseState = .ground
                    case UInt8(ascii: "8"): // DECRC restore cursor
                        activeBuffer.cursorX = min(activeBuffer.savedCursorX, activeBuffer.cols - 1)
                        activeBuffer.cursorY = min(activeBuffer.savedCursorY, activeBuffer.rows - 1)
                        activeBuffer.pendingWrap = false
                        parseState = .ground
                    case UInt8(ascii: "M"): // RI reverse index
                        activeBuffer.pendingWrap = false
                        if activeBuffer.cursorY == activeBuffer.scrollTop {
                            activeBuffer.scrollDown(lines: 1)
                        } else if activeBuffer.cursorY > 0 {
                            activeBuffer.cursorY -= 1
                        }
                        parseState = .ground
                    case UInt8(ascii: "D"): // IND index
                        activeBuffer.newline()
                        parseState = .ground
                    case UInt8(ascii: "E"): // NEL next line
                        activeBuffer.cursorX = 0
                        activeBuffer.newline()
                        parseState = .ground
                    case UInt8(ascii: "c"): // RIS full reset
                        let cols = primary.cols
                        let rows = primary.rows
                        let maxSb = primary.maxScrollbackRows
                        primary = ScreenBuffer(cols: cols, rows: rows, maxScrollbackRows: maxSb)
                        alternate = ScreenBuffer(cols: cols, rows: rows, maxScrollbackRows: 0)
                        usingAlternate = false
                        currentSGR = ""
                        parseState = .ground
                    default:
                        parseState = .ground
                    }

                case .charset:
                    parseState = .ground

                case .csi:
                    if (0x40...0x7E).contains(byte) {
                        executeCSI(finalByte: byte)
                        parseState = .ground
                    } else if byte == 0x1B {
                        parseState = .escape
                    } else {
                        if csiBuffer.count < 256 {
                            csiBuffer.append(byte)
                        }
                    }

                case .osc:
                    if byte == 0x07 { // BEL terminates OSC
                        executeOSC()
                        parseState = .ground
                    } else if byte == 0x1B {
                        parseState = .oscEscape
                    } else {
                        if oscBuffer.count < 16_384 {
                            oscBuffer.append(byte)
                        }
                    }

                case .oscEscape:
                    if byte == UInt8(ascii: "\\") { // ST terminates OSC
                        executeOSC()
                        parseState = .ground
                    } else {
                        executeOSC()
                        parseState = .escape
                        processByte(byte)
                    }
                }
            }

            private func executeOSC() {
                let text = String(decoding: oscBuffer, as: UTF8.self)
                oscBuffer.removeAll(keepingCapacity: true)
                guard let semi = text.firstIndex(of: ";") else { return }
                let code = String(text[..<semi])
                let payload = String(text[text.index(after: semi)...])
                switch code {
                case "0", "2":
                    title = payload
                    titleChangedFn?(self, userdata)
                case "7":
                    pwd = payload
                default:
                    break
                }
            }

            private func executeCSI(finalByte: UInt8) {
                let raw = String(decoding: csiBuffer, as: UTF8.self)
                csiBuffer.removeAll(keepingCapacity: true)
                let isPrivate = raw.hasPrefix("?")
                let paramString = isPrivate ? String(raw.dropFirst()) : raw
                let params: [Int] = paramString.isEmpty
                    ? []
                    : paramString.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }

                func param(_ idx: Int, default defaultVal: Int) -> Int {
                    guard idx < params.count, params[idx] > 0 else { return defaultVal }
                    return params[idx]
                }

                switch finalByte {
                case UInt8(ascii: "h") where isPrivate:
                    for p in params {
                        switch p {
                        case 25:
                            cursorVisible = true
                        case 47, 1047, 1049:
                            if p == 1049 {
                                primary.savedCursorX = primary.cursorX
                                primary.savedCursorY = primary.cursorY
                            }
                            if !usingAlternate {
                                alternate = ScreenBuffer(cols: primary.cols, rows: primary.rows, maxScrollbackRows: 0)
                                usingAlternate = true
                            }
                        default:
                            break
                        }
                    }

                case UInt8(ascii: "l") where isPrivate:
                    for p in params {
                        switch p {
                        case 25:
                            cursorVisible = false
                        case 47, 1047, 1049:
                            if usingAlternate {
                                usingAlternate = false
                                if p == 1049 {
                                    primary.cursorX = min(primary.savedCursorX, primary.cols - 1)
                                    primary.cursorY = min(primary.savedCursorY, primary.rows - 1)
                                    primary.pendingWrap = false
                                }
                            }
                        default:
                            break
                        }
                    }

                case UInt8(ascii: "A"): // CUU
                    activeBuffer.pendingWrap = false
                    activeBuffer.cursorY = max(0, activeBuffer.cursorY - param(0, default: 1))
                case UInt8(ascii: "B"): // CUD
                    activeBuffer.pendingWrap = false
                    activeBuffer.cursorY = min(activeBuffer.rows - 1, activeBuffer.cursorY + param(0, default: 1))
                case UInt8(ascii: "C"): // CUF
                    activeBuffer.pendingWrap = false
                    activeBuffer.cursorX = min(activeBuffer.cols - 1, activeBuffer.cursorX + param(0, default: 1))
                case UInt8(ascii: "D"): // CUB
                    activeBuffer.pendingWrap = false
                    activeBuffer.cursorX = max(0, activeBuffer.cursorX - param(0, default: 1))
                case UInt8(ascii: "E"): // CNL
                    activeBuffer.pendingWrap = false
                    activeBuffer.cursorX = 0
                    activeBuffer.cursorY = min(activeBuffer.rows - 1, activeBuffer.cursorY + param(0, default: 1))
                case UInt8(ascii: "F"): // CPL
                    activeBuffer.pendingWrap = false
                    activeBuffer.cursorX = 0
                    activeBuffer.cursorY = max(0, activeBuffer.cursorY - param(0, default: 1))
                case UInt8(ascii: "G"): // CHA
                    activeBuffer.pendingWrap = false
                    activeBuffer.cursorX = max(0, min(activeBuffer.cols - 1, param(0, default: 1) - 1))
                case UInt8(ascii: "d"): // VPA
                    activeBuffer.pendingWrap = false
                    activeBuffer.cursorY = max(0, min(activeBuffer.rows - 1, param(0, default: 1) - 1))
                case UInt8(ascii: "H"), UInt8(ascii: "f"): // CUP
                    activeBuffer.pendingWrap = false
                    let row = max(0, min(activeBuffer.rows - 1, param(0, default: 1) - 1))
                    let col = max(0, min(activeBuffer.cols - 1, param(1, default: 1) - 1))
                    activeBuffer.cursorY = row
                    activeBuffer.cursorX = col
                case UInt8(ascii: "J"): // ED
                    let mode = params.first ?? 0
                    let y = activeBuffer.cursorY
                    let x = activeBuffer.cursorX
                    switch mode {
                    case 0:
                        for c in x..<activeBuffer.cols { activeBuffer.active[y].cells[c] = Cell() }
                        for r in (y + 1)..<activeBuffer.rows { activeBuffer.active[r] = Row(cols: activeBuffer.cols) }
                    case 1:
                        for r in 0..<y { activeBuffer.active[r] = Row(cols: activeBuffer.cols) }
                        for c in 0...min(x, activeBuffer.cols - 1) { activeBuffer.active[y].cells[c] = Cell() }
                    case 2:
                        for r in 0..<activeBuffer.rows { activeBuffer.active[r] = Row(cols: activeBuffer.cols) }
                    case 3:
                        activeBuffer.scrollback.removeAll()
                        for r in 0..<activeBuffer.rows { activeBuffer.active[r] = Row(cols: activeBuffer.cols) }
                    default:
                        break
                    }
                case UInt8(ascii: "K"): // EL
                    let mode = params.first ?? 0
                    let y = activeBuffer.cursorY
                    let x = activeBuffer.cursorX
                    switch mode {
                    case 0:
                        for c in x..<activeBuffer.cols { activeBuffer.active[y].cells[c] = Cell() }
                    case 1:
                        for c in 0...min(x, activeBuffer.cols - 1) { activeBuffer.active[y].cells[c] = Cell() }
                    case 2:
                        activeBuffer.active[y] = Row(cols: activeBuffer.cols)
                    default:
                        break
                    }
                case UInt8(ascii: "L"): // IL
                    let n = min(param(0, default: 1), activeBuffer.rows - activeBuffer.cursorY)
                    for _ in 0..<n {
                        activeBuffer.active.remove(at: activeBuffer.scrollBottom)
                        activeBuffer.active.insert(Row(cols: activeBuffer.cols), at: activeBuffer.cursorY)
                    }
                case UInt8(ascii: "M"): // DL
                    let n = min(param(0, default: 1), activeBuffer.rows - activeBuffer.cursorY)
                    for _ in 0..<n {
                        activeBuffer.active.remove(at: activeBuffer.cursorY)
                        activeBuffer.active.insert(Row(cols: activeBuffer.cols), at: activeBuffer.scrollBottom)
                    }
                case UInt8(ascii: "P"): // DCH
                    let n = min(param(0, default: 1), activeBuffer.cols - activeBuffer.cursorX)
                    let y = activeBuffer.cursorY
                    activeBuffer.active[y].cells.removeSubrange(activeBuffer.cursorX..<(activeBuffer.cursorX + n))
                    activeBuffer.active[y].cells.append(contentsOf: Array(repeating: Cell(), count: n))
                case UInt8(ascii: "@"): // ICH
                    let n = min(param(0, default: 1), activeBuffer.cols - activeBuffer.cursorX)
                    let y = activeBuffer.cursorY
                    activeBuffer.active[y].cells.insert(contentsOf: Array(repeating: Cell(), count: n), at: activeBuffer.cursorX)
                    activeBuffer.active[y].cells.removeLast(n)
                case UInt8(ascii: "S"): // SU
                    activeBuffer.scrollUp(lines: param(0, default: 1))
                case UInt8(ascii: "T"): // SD
                    activeBuffer.scrollDown(lines: param(0, default: 1))
                case UInt8(ascii: "r"): // DECSTBM
                    let top = max(0, min(activeBuffer.rows - 1, param(0, default: 1) - 1))
                    let bottom = max(top, min(activeBuffer.rows - 1, param(1, default: activeBuffer.rows) - 1))
                    activeBuffer.scrollTop = top
                    activeBuffer.scrollBottom = bottom
                    activeBuffer.cursorX = 0
                    activeBuffer.cursorY = 0
                    activeBuffer.pendingWrap = false
                case UInt8(ascii: "s"):
                    activeBuffer.savedCursorX = activeBuffer.cursorX
                    activeBuffer.savedCursorY = activeBuffer.cursorY
                case UInt8(ascii: "u"):
                    activeBuffer.cursorX = min(activeBuffer.savedCursorX, activeBuffer.cols - 1)
                    activeBuffer.cursorY = min(activeBuffer.savedCursorY, activeBuffer.rows - 1)
                    activeBuffer.pendingWrap = false
                case UInt8(ascii: "m"): // SGR
                    if params.isEmpty || (params.count == 1 && params[0] == 0) {
                        currentSGR = ""
                    } else {
                        currentSGR = "\u{1B}[\(paramString)m"
                    }
                case UInt8(ascii: "n") where !isPrivate: // DSR
                    let query = params.first ?? 0
                    if query == 5 {
                        writePtyFn?(self, userdata, Array("\u{1B}[0n".utf8))
                    } else if query == 6 {
                        let reply = "\u{1B}[\(activeBuffer.cursorY + 1);\(activeBuffer.cursorX + 1)R"
                        writePtyFn?(self, userdata, Array(reply.utf8))
                    }
                case UInt8(ascii: "c") where !isPrivate: // DA1
                    if params.isEmpty || params[0] == 0 {
                        writePtyFn?(self, userdata, Array("\u{1B}[?62;22c".utf8))
                    }
                default:
                    break
                }
            }

            internal func formatScreen(options: GhosttyFormatterTerminalOptions) -> [UInt8] {
                if let sel = options.selection {
                    let text = formatSelectionText(
                        selection: sel,
                        unwrap: options.unwrap,
                        trim: options.trim
                    )
                    return Array(text.utf8)
                }

                let buf = activeBuffer
                switch options.emit {
                case GHOSTTY_FORMATTER_FORMAT_PLAIN:
                    var lines = buf.active.map { $0.plainText(trimTrailing: options.trim) }
                    if options.trim {
                        while lines.last?.isEmpty == true {
                            lines.removeLast()
                        }
                    }
                    return Array(lines.joined(separator: "\n").utf8)
                case GHOSTTY_FORMATTER_FORMAT_VT:
                    var out = ""
                    if usingAlternate {
                        out.append("\u{1B}[?1049h")
                    }
                    out.append("\u{1B}[2J\u{1B}[H")
                    var lastNonEmptyRow = -1
                    for idx in stride(from: buf.active.count - 1, through: 0, by: -1) {
                        if !buf.active[idx].vtText().isEmpty {
                            lastNonEmptyRow = idx
                            break
                        }
                    }
                    if lastNonEmptyRow >= 0 {
                        for idx in 0...lastNonEmptyRow {
                            if idx > 0 { out.append("\r\n") }
                            out.append(buf.active[idx].vtText())
                        }
                    }
                    if !cursorVisible {
                        out.append("\u{1B}[?25l")
                    }
                    return Array(out.utf8)
                default:
                    let lines = buf.active.map { $0.plainText(trimTrailing: options.trim) }
                    return Array(lines.joined(separator: "\n").utf8)
                }
            }

            internal func formatSelectionText(
                selection sel: GhosttySelection,
                unwrap: Bool,
                trim: Bool
            ) -> String {
                let buf = sel.start.isAlternate ? alternate : primary
                let startY = Int(sel.start.y)
                let endY = Int(sel.end.y)
                let startX = Int(sel.start.x)
                let endX = Int(sel.end.x)
                guard startY <= endY else { return "" }

                var result = ""
                for y in startY...endY {
                    guard let row = buf.row(atScreenY: y) else { continue }
                    let colStart = (y == startY || sel.rectangle) ? max(0, min(startX, row.cells.count - 1)) : 0
                    let colEnd = (y == endY || sel.rectangle) ? max(0, min(endX, row.cells.count - 1)) : (row.cells.count - 1)
                    if colStart > colEnd { continue }

                    var sliceEnd = colEnd
                    if trim {
                        while sliceEnd >= colStart {
                            let c = row.cells[sliceEnd]
                            if c.width == 0 || (!c.text.isEmpty && c.text != " ") {
                                break
                            }
                            sliceEnd -= 1
                        }
                    }
                    if sliceEnd >= colStart {
                        for col in colStart...sliceEnd {
                            let cell = row.cells[col]
                            if cell.width == 0 { continue }
                            result.append(cell.text.isEmpty ? " " : cell.text)
                        }
                    }
                    if y < endY && !(unwrap && row.wrapped) {
                        result.append("\n")
                    }
                }
                return result
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#GhosttyFormatterImpl [status=adapted hash=f2872ab73c6e]
        public final class GhosttyFormatterImpl: @unchecked Sendable {
            internal let terminal: GhosttyTerminalImpl
            internal let options: GhosttyFormatterTerminalOptions

            public init(terminal: GhosttyTerminalImpl, options: GhosttyFormatterTerminalOptions) {
                self.terminal = terminal
                self.options = options
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_free [status=adapted hash=b3b94545d16e]
        public static func ghostty_free(_ allocator: GhosttyAllocator?, _ bytes: inout [UInt8]) {
            if let freeFn = allocator?.vtable?.free {
                freeFn(bytes)
            }
            bytes.removeAll()
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_terminal_new [status=adapted hash=6ddb818e3ea0]
        public static func ghostty_terminal_new(
            _ allocator: GhosttyAllocator?,
            _ outTerminal: inout GhosttyTerminal,
            _ options: GhosttyTerminalOptions
        ) -> GhosttyResult {
            _ = allocator
            guard options.cols > 0 && options.rows > 0 else {
                return GHOSTTY_INVALID_VALUE
            }
            outTerminal = GhosttyTerminalImpl(options: options)
            return GHOSTTY_SUCCESS
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_terminal_free [status=adapted hash=16f252ba4d70]
        public static func ghostty_terminal_free(_ terminal: inout GhosttyTerminal) {
            terminal?.userdata = nil
            terminal?.writePtyFn = nil
            terminal?.titleChangedFn = nil
            terminal = nil
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_terminal_resize [status=adapted hash=980df9c11511]
        public static func ghostty_terminal_resize(
            _ terminal: GhosttyTerminal,
            _ cols: UInt16,
            _ rows: UInt16,
            _ cellWidthPx: UInt32 = 0,
            _ cellHeightPx: UInt32 = 0
        ) -> GhosttyResult {
            _ = (cellWidthPx, cellHeightPx)
            guard let terminal, cols > 0, rows > 0 else {
                return GHOSTTY_INVALID_VALUE
            }
            terminal.primary.resize(newCols: Int(cols), newRows: Int(rows))
            terminal.alternate.resize(newCols: Int(cols), newRows: Int(rows))
            return GHOSTTY_SUCCESS
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_terminal_set [status=adapted hash=793e1c007a6c]
        public static func ghostty_terminal_set(
            _ terminal: GhosttyTerminal,
            _ option: GhosttyTerminalOption,
            _ value: Any?
        ) -> GhosttyResult {
            guard let terminal else { return GHOSTTY_INVALID_VALUE }
            switch option {
            case GHOSTTY_TERMINAL_OPT_USERDATA:
                terminal.userdata = value as? Effects
                return GHOSTTY_SUCCESS
            case GHOSTTY_TERMINAL_OPT_WRITE_PTY:
                terminal.writePtyFn = value as? (@Sendable (GhosttyTerminal, Effects?, [UInt8]) -> Void)
                return GHOSTTY_SUCCESS
            case GHOSTTY_TERMINAL_OPT_TITLE_CHANGED:
                terminal.titleChangedFn = value as? (@Sendable (GhosttyTerminal, Effects?) -> Void)
                return GHOSTTY_SUCCESS
            case GHOSTTY_TERMINAL_OPT_SELECTION:
                terminal.selection = value as? GhosttySelection
                return GHOSTTY_SUCCESS
            case GHOSTTY_TERMINAL_OPT_TITLE:
                if let str = value as? String {
                    terminal.title = str
                    return GHOSTTY_SUCCESS
                }
                return GHOSTTY_INVALID_VALUE
            case GHOSTTY_TERMINAL_OPT_PWD:
                if let str = value as? String {
                    terminal.pwd = str
                    return GHOSTTY_SUCCESS
                }
                return GHOSTTY_INVALID_VALUE
            default:
                return GHOSTTY_SUCCESS
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_terminal_vt_write [status=adapted hash=ab71db93f53f]
        public static func ghostty_terminal_vt_write(_ terminal: GhosttyTerminal, _ bytes: [UInt8]) {
            terminal?.feed(bytes)
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_terminal_scroll_viewport [status=adapted hash=e2becb2c6c05]
        public static func ghostty_terminal_scroll_viewport(
            _ terminal: GhosttyTerminal,
            _ behavior: GhosttyTerminalScrollViewport
        ) {
            guard let terminal else { return }
            let maxTop = terminal.activeBuffer.scrollback.count
            switch behavior.tag {
            case GHOSTTY_SCROLL_VIEWPORT_TOP:
                terminal.activeBuffer.viewportOffsetFromTop = 0
            case GHOSTTY_SCROLL_VIEWPORT_BOTTOM:
                terminal.activeBuffer.viewportOffsetFromTop = nil
            case GHOSTTY_SCROLL_VIEWPORT_DELTA:
                let current = terminal.activeBuffer.viewportOffsetFromTop ?? maxTop
                let next = max(0, min(maxTop, current + behavior.delta))
                terminal.activeBuffer.viewportOffsetFromTop = (next == maxTop) ? nil : next
            case GHOSTTY_SCROLL_VIEWPORT_ROW:
                let next = max(0, min(maxTop, behavior.row))
                terminal.activeBuffer.viewportOffsetFromTop = (next == maxTop) ? nil : next
            default:
                break
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_terminal_get [status=adapted hash=358fefe417b2]
        public static func ghostty_terminal_get(
            _ terminal: GhosttyTerminal,
            _ data: GhosttyTerminalData
        ) -> (GhosttyResult, Any?) {
            guard let terminal else { return (GHOSTTY_INVALID_VALUE, nil) }
            let buf = terminal.activeBuffer
            switch data {
            case GHOSTTY_TERMINAL_DATA_COLS:
                return (GHOSTTY_SUCCESS, UInt16(buf.cols))
            case GHOSTTY_TERMINAL_DATA_ROWS:
                return (GHOSTTY_SUCCESS, UInt16(buf.rows))
            case GHOSTTY_TERMINAL_DATA_CURSOR_X:
                return (GHOSTTY_SUCCESS, UInt16(buf.cursorX))
            case GHOSTTY_TERMINAL_DATA_CURSOR_Y:
                return (GHOSTTY_SUCCESS, UInt16(buf.cursorY))
            case GHOSTTY_TERMINAL_DATA_CURSOR_PENDING_WRAP:
                return (GHOSTTY_SUCCESS, buf.pendingWrap)
            case GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN:
                return (GHOSTTY_SUCCESS, terminal.usingAlternate ? UInt32(1) : UInt32(0))
            case GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE:
                return (GHOSTTY_SUCCESS, terminal.cursorVisible)
            case GHOSTTY_TERMINAL_DATA_TITLE:
                return (GHOSTTY_SUCCESS, GhosttyString(terminal.title))
            case GHOSTTY_TERMINAL_DATA_PWD:
                return (GHOSTTY_SUCCESS, GhosttyString(terminal.pwd))
            case GHOSTTY_TERMINAL_DATA_TOTAL_ROWS:
                return (GHOSTTY_SUCCESS, buf.totalRows)
            case GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS:
                return (GHOSTTY_SUCCESS, buf.scrollback.count)
            case GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE:
                return (GHOSTTY_SUCCESS, buf.viewportOffsetFromTop == nil)
            default:
                return (GHOSTTY_NO_VALUE, nil)
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_terminal_grid_ref [status=adapted hash=c4d883b0b351]
        public static func ghostty_terminal_grid_ref(
            _ terminal: GhosttyTerminal,
            _ point: GhosttyPoint,
            _ outRef: inout GhosttyGridRef
        ) -> GhosttyResult {
            guard let terminal else { return GHOSTTY_INVALID_VALUE }
            let buf = terminal.activeBuffer
            let screenY: Int
            switch point.tag {
            case GHOSTTY_POINT_TAG_SCREEN:
                screenY = Int(point.coordinate.y)
            case GHOSTTY_POINT_TAG_ACTIVE:
                screenY = buf.scrollback.count + Int(point.coordinate.y)
            case GHOSTTY_POINT_TAG_VIEWPORT:
                let top = buf.viewportOffsetFromTop ?? buf.scrollback.count
                screenY = top + Int(point.coordinate.y)
            case GHOSTTY_POINT_TAG_HISTORY:
                screenY = Int(point.coordinate.y)
            default:
                return GHOSTTY_INVALID_VALUE
            }
            guard Int(point.coordinate.x) < buf.cols, screenY >= 0, screenY < buf.totalRows else {
                return GHOSTTY_INVALID_VALUE
            }
            outRef = GhosttyGridRef(
                x: point.coordinate.x,
                y: UInt32(screenY),
                isAlternate: terminal.usingAlternate
            )
            return GHOSTTY_SUCCESS
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_terminal_point_from_grid_ref [status=adapted hash=7da96d67a23e]
        public static func ghostty_terminal_point_from_grid_ref(
            _ terminal: GhosttyTerminal,
            _ ref: GhosttyGridRef,
            _ tag: GhosttyPointTag,
            _ out: inout GhosttyPointCoordinate
        ) -> GhosttyResult {
            guard let terminal else { return GHOSTTY_INVALID_VALUE }
            let buf = ref.isAlternate ? terminal.alternate : terminal.primary
            let screenY = Int(ref.y)
            guard screenY >= 0 && screenY < buf.totalRows else {
                return GHOSTTY_INVALID_VALUE
            }
            switch tag {
            case GHOSTTY_POINT_TAG_SCREEN:
                out = GhosttyPointCoordinate(x: ref.x, y: ref.y)
                return GHOSTTY_SUCCESS
            case GHOSTTY_POINT_TAG_ACTIVE:
                guard screenY >= buf.scrollback.count else { return GHOSTTY_NO_VALUE }
                out = GhosttyPointCoordinate(x: ref.x, y: UInt32(screenY - buf.scrollback.count))
                return GHOSTTY_SUCCESS
            case GHOSTTY_POINT_TAG_VIEWPORT:
                let top = buf.viewportOffsetFromTop ?? buf.scrollback.count
                guard screenY >= top && screenY < top + buf.rows else { return GHOSTTY_NO_VALUE }
                out = GhosttyPointCoordinate(x: ref.x, y: UInt32(screenY - top))
                return GHOSTTY_SUCCESS
            case GHOSTTY_POINT_TAG_HISTORY:
                guard screenY < buf.scrollback.count else { return GHOSTTY_NO_VALUE }
                out = GhosttyPointCoordinate(x: ref.x, y: ref.y)
                return GHOSTTY_SUCCESS
            default:
                return GHOSTTY_INVALID_VALUE
            }
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_terminal_selection_format_buf [status=adapted hash=329a843c0de8]
        public static func ghostty_terminal_selection_format_buf(
            _ terminal: GhosttyTerminal,
            _ options: GhosttyTerminalSelectionFormatOptions,
            _ buf: inout [UInt8],
            _ outWritten: inout Int
        ) -> GhosttyResult {
            guard let terminal else { return GHOSTTY_INVALID_VALUE }
            guard let sel = options.selection ?? terminal.selection else {
                return GHOSTTY_NO_VALUE
            }
            let formatted = Array(terminal.formatSelectionText(
                selection: sel,
                unwrap: options.unwrap,
                trim: options.trim
            ).utf8)
            guard formatted.count <= buf.count else {
                return GHOSTTY_OUT_OF_SPACE
            }
            for i in 0..<formatted.count {
                buf[i] = formatted[i]
            }
            outWritten = formatted.count
            return GHOSTTY_SUCCESS
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_formatter_terminal_new [status=adapted hash=616198c9431c]
        public static func ghostty_formatter_terminal_new(
            _ allocator: GhosttyAllocator?,
            _ outFormatter: inout GhosttyFormatter,
            _ terminal: GhosttyTerminal,
            _ options: GhosttyFormatterTerminalOptions
        ) -> GhosttyResult {
            _ = allocator
            guard let terminal else { return GHOSTTY_INVALID_VALUE }
            outFormatter = GhosttyFormatterImpl(terminal: terminal, options: options)
            return GHOSTTY_SUCCESS
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_formatter_format_buf [status=adapted hash=0ec4348db27a]
        public static func ghostty_formatter_format_buf(
            _ formatter: GhosttyFormatter,
            _ buf: inout [UInt8],
            _ outWritten: inout Int
        ) -> GhosttyResult {
            guard let formatter else { return GHOSTTY_INVALID_VALUE }
            let formatted = formatter.terminal.formatScreen(options: formatter.options)
            guard formatted.count <= buf.count else {
                return GHOSTTY_OUT_OF_SPACE
            }
            for i in 0..<formatted.count {
                buf[i] = formatted[i]
            }
            outWritten = formatted.count
            return GHOSTTY_SUCCESS
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_formatter_format_alloc [status=adapted hash=14f4deb7e44c]
        public static func ghostty_formatter_format_alloc(
            _ formatter: GhosttyFormatter,
            _ allocator: GhosttyAllocator?,
            _ outBytes: inout [UInt8]
        ) -> GhosttyResult {
            _ = allocator
            guard let formatter else { return GHOSTTY_INVALID_VALUE }
            outBytes = formatter.terminal.formatScreen(options: formatter.options)
            return GHOSTTY_SUCCESS
        }

        // parity: process-daemon/src/ghostty/ffi.rs#ghostty_formatter_free [status=adapted hash=42cec39fac44]
        public static func ghostty_formatter_free(_ formatter: inout GhosttyFormatter) {
            formatter = nil
        }

        // MARK: - High-Level Terminal Wrapper (`src/ghostty/mod.rs`)

        // parity: process-daemon/src/ghostty/mod.rs#TerminalOptions [status=implemented hash=021743f050df]
        public struct TerminalOptions: Equatable, Hashable, Sendable {
            public let cols: UInt16
            public let rows: UInt16
            public let maxScrollback: Int

            public init(cols: UInt16, rows: UInt16, maxScrollback: Int) {
                self.cols = cols
                self.rows = rows
                self.maxScrollback = maxScrollback
            }
        }

        // parity: process-daemon/src/ghostty/mod.rs#Format [status=implemented hash=e5355ac70f88]
        public enum Format: Equatable, Hashable, Sendable {
            case plain
            case vt
        }

        // parity: process-daemon/src/ghostty/mod.rs#Terminal [status=implemented hash=cd8a1f70b9d6]
        public final class Terminal: @unchecked Sendable {
            private var raw: GhosttyTerminal
            private let effects: Effects

            private init(raw: GhosttyTerminal, effects: Effects) {
                self.raw = raw
                self.effects = effects
            }

            deinit {
                ghostty_terminal_free(&raw)
            }

            // parity: process-daemon/src/ghostty/mod.rs#new [status=implemented hash=55759a70d115]
            public static func new(_ options: TerminalOptions) throws -> Terminal {
                guard options.cols > 0 && options.rows > 0 else {
                    throw DaemonError("terminal dimensions must be positive")
                }
                var raw: GhosttyTerminal = nil
                try checkResult(ghostty_terminal_new(
                    nil,
                    &raw,
                    GhosttyTerminalOptions(
                        cols: options.cols,
                        rows: options.rows,
                        max_scrollback: options.maxScrollback
                    )
                ))
                guard raw != nil else {
                    throw DaemonError("Ghostty returned a null terminal")
                }
                let effects = Effects()
                try checkResult(ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_USERDATA, effects.userdata()))
                try checkResult(ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_WRITE_PTY, Effects.writePtyCallback))
                try checkResult(ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, Effects.titleChangedCallback))
                return Terminal(raw: raw, effects: effects)
            }

            // parity: process-daemon/src/ghostty/mod.rs#vt_write [status=implemented hash=f936c23fd83b]
            public func vt_write(_ bytes: [UInt8]) {
                ghostty_terminal_vt_write(raw, bytes)
                effects.resume_panic()
            }

            // parity: process-daemon/src/ghostty/mod.rs#take_writes [status=implemented hash=5c6c42724ee1]
            public func take_writes() -> [[UInt8]] {
                effects.take_writes()
            }

            // parity: process-daemon/src/ghostty/mod.rs#take_title [status=implemented hash=a5ab2bcb97e3]
            public func take_title() -> String? {
                guard effects.take_title_changed() else { return nil }
                let (rc, value) = ghostty_terminal_get(raw, GHOSTTY_TERMINAL_DATA_TITLE)
                guard rc == GHOSTTY_SUCCESS, let gs = value as? GhosttyString else { return nil }
                return String(decoding: gs.bytes, as: UTF8.self)
            }

            // parity: process-daemon/src/ghostty/mod.rs#resize [status=implemented hash=478d188844d9]
            public func resize(cols: UInt16, rows: UInt16) throws {
                guard cols > 0 && rows > 0 else {
                    throw DaemonError("terminal dimensions must be positive")
                }
                let rc = ghostty_terminal_resize(raw, cols, rows, 0, 0)
                effects.resume_panic()
                try Self.checkResult(rc)
            }

            // parity: process-daemon/src/ghostty/mod.rs#cols [status=implemented hash=b65f95ef1d19]
            public func cols() throws -> UInt16 {
                try getValue(GHOSTTY_TERMINAL_DATA_COLS, as: UInt16.self)
            }

            // parity: process-daemon/src/ghostty/mod.rs#rows [status=implemented hash=d102333749b3]
            public func rows() throws -> UInt16 {
                try getValue(GHOSTTY_TERMINAL_DATA_ROWS, as: UInt16.self)
            }

            // parity: process-daemon/src/ghostty/mod.rs#cursor_x [status=implemented hash=9f4936548e1a]
            public func cursor_x() throws -> UInt16 {
                try getValue(GHOSTTY_TERMINAL_DATA_CURSOR_X, as: UInt16.self)
            }

            // parity: process-daemon/src/ghostty/mod.rs#cursor_y [status=implemented hash=1c491c5f36d6]
            public func cursor_y() throws -> UInt16 {
                try getValue(GHOSTTY_TERMINAL_DATA_CURSOR_Y, as: UInt16.self)
            }

            // parity: process-daemon/src/ghostty/mod.rs#total_rows [status=implemented hash=d687bb7d37b8]
            public func total_rows() throws -> Int {
                try getValue(GHOSTTY_TERMINAL_DATA_TOTAL_ROWS, as: Int.self)
            }

            // parity: process-daemon/src/ghostty/mod.rs#format [status=implemented hash=c79921b5ad8b]
            public func format(_ format: Format) throws -> [UInt8] {
                let emit: GhosttyFormatterFormat = format == .plain
                    ? GHOSTTY_FORMATTER_FORMAT_PLAIN
                    : GHOSTTY_FORMATTER_FORMAT_VT
                let options = GhosttyFormatterTerminalOptions(
                    emit: emit,
                    unwrap: false,
                    trim: true,
                    extra: GhosttyFormatterTerminalExtra(
                        modes: true,
                        scrolling_region: true,
                        tabstops: true,
                        pwd: true,
                        keyboard: true,
                        screen: GhosttyFormatterScreenExtra(
                            cursor: false,
                            style: true,
                            hyperlink: true,
                            protection: true,
                            kitty_keyboard: true,
                            charsets: true
                        )
                    ),
                    selection: nil
                )
                var formatter: GhosttyFormatter = nil
                try Self.checkResult(ghostty_formatter_terminal_new(nil, &formatter, raw, options))
                defer { ghostty_formatter_free(&formatter) }
                var outBytes: [UInt8] = []
                try Self.checkResult(ghostty_formatter_format_alloc(formatter, nil, &outBytes))
                return outBytes
            }

            // parity: process-daemon/src/ghostty/mod.rs#format_row [status=implemented hash=3373104ea99c]
            public func format_row(_ y: UInt32, buffer: inout [UInt8]) throws -> Int {
                let width = try cols()
                let sel = try makeSelection(start: (0, y), end: (width - 1, y))
                let options = GhosttyFormatterTerminalOptions(
                    emit: GHOSTTY_FORMATTER_FORMAT_PLAIN,
                    unwrap: false,
                    trim: true,
                    selection: sel
                )
                var formatter: GhosttyFormatter = nil
                try Self.checkResult(ghostty_formatter_terminal_new(nil, &formatter, raw, options))
                defer { ghostty_formatter_free(&formatter) }
                var written = 0
                try Self.checkResult(ghostty_formatter_format_buf(formatter, &buffer, &written))
                guard written <= buffer.count else {
                    throw DaemonError("Ghostty wrote beyond the row buffer")
                }
                return written
            }

            // parity: process-daemon/src/ghostty/mod.rs#scroll_to_top [status=implemented hash=d65b992d8120]
            public func scroll_to_top() {
                ghostty_terminal_scroll_viewport(raw, GhosttyTerminalScrollViewport(tag: GHOSTTY_SCROLL_VIEWPORT_TOP))
            }

            // parity: process-daemon/src/ghostty/mod.rs#viewport_row [status=implemented hash=8b05eb7b09c6]
            public func viewport_row() throws -> UInt32 {
                let origin = try gridRef(tag: GHOSTTY_POINT_TAG_VIEWPORT, x: 0, y: 0)
                var point = GhosttyPointCoordinate()
                try Self.checkResult(ghostty_terminal_point_from_grid_ref(raw, origin, GHOSTTY_POINT_TAG_SCREEN, &point))
                return point.y
            }

            // parity: process-daemon/src/ghostty/mod.rs#set_selection [status=implemented hash=b41593ec87c3]
            public func set_selection(start: (UInt16, UInt32), end: (UInt16, UInt32)) throws {
                let sel = try makeSelection(start: start, end: end)
                try Self.checkResult(ghostty_terminal_set(raw, GHOSTTY_TERMINAL_OPT_SELECTION, sel))
            }

            // parity: process-daemon/src/ghostty/mod.rs#selection_text [status=implemented hash=e297ca5e2d11]
            public func selection_text(buffer: inout [UInt8]) throws -> Int? {
                var written = 0
                let rc = ghostty_terminal_selection_format_buf(
                    raw,
                    GhosttyTerminalSelectionFormatOptions(
                        emit: GHOSTTY_FORMATTER_FORMAT_PLAIN,
                        unwrap: true,
                        trim: true,
                        selection: nil
                    ),
                    &buffer,
                    &written
                )
                if rc == GHOSTTY_NO_VALUE { return nil }
                try Self.checkResult(rc)
                guard written <= buffer.count else {
                    throw DaemonError("Ghostty wrote beyond the selection buffer")
                }
                return written
            }

            private func getValue<T>(_ data: GhosttyTerminalData, as type: T.Type) throws -> T {
                let (rc, val) = ghostty_terminal_get(raw, data)
                try Self.checkResult(rc)
                guard let typed = val as? T else {
                    throw DaemonError("Ghostty returned unexpected value type")
                }
                return typed
            }

            private func gridRef(tag: GhosttyPointTag, x: UInt16, y: UInt32) throws -> GhosttyGridRef {
                var ref = GhosttyGridRef()
                let pt = GhosttyPoint(tag: tag, coordinate: GhosttyPointCoordinate(x: x, y: y))
                try Self.checkResult(ghostty_terminal_grid_ref(raw, pt, &ref))
                return ref
            }

            private func makeSelection(start: (UInt16, UInt32), end: (UInt16, UInt32)) throws -> GhosttySelection {
                GhosttySelection(
                    start: try gridRef(tag: GHOSTTY_POINT_TAG_SCREEN, x: start.0, y: start.1),
                    end: try gridRef(tag: GHOSTTY_POINT_TAG_SCREEN, x: end.0, y: end.1),
                    rectangle: false
                )
            }

            private static func checkResult(_ result: GhosttyResult) throws {
                switch result {
                case GHOSTTY_SUCCESS:
                    return
                case GHOSTTY_OUT_OF_MEMORY:
                    throw DaemonError("Ghostty allocation failed")
                case GHOSTTY_INVALID_VALUE:
                    throw DaemonError("Ghostty rejected an invalid value")
                case GHOSTTY_OUT_OF_SPACE:
                    throw DaemonError("Ghostty output buffer is too small")
                case GHOSTTY_NO_VALUE:
                    throw DaemonError("Ghostty value is unavailable")
                default:
                    throw DaemonError("Ghostty failed with result \(result)")
                }
            }
        }
    }
}
