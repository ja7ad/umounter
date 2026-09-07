/// Decodes NUL-terminated C strings from fixed-size char arrays/tuples that the
/// Darwin structs (`statfs`, `vnode_info_path`, …) import as Swift tuples.
enum CStringTuple {
    static func string<T>(_ tuple: inout T) -> String {
        withUnsafeBytes(of: &tuple) { decode($0) }
    }

    static func string(_ buffer: [CChar]) -> String {
        buffer.withUnsafeBytes { decode($0) }
    }

    private static func decode(_ raw: UnsafeRawBufferPointer) -> String {
        let bytes = raw.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }
}
