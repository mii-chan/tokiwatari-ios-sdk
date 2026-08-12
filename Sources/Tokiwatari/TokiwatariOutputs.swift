public struct TokiwatariOutputs: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// SQLite-backed event storage read by `tokiwatari-cli`.
    public static let storage = Self(rawValue: 1 << 0)

    /// `OSSignposter` event markers usable as anchors in Instruments traces.
    public static let signposts = Self(rawValue: 1 << 1)

    static let supported: Self = [.storage, .signposts]
}
