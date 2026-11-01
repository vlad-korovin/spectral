import Foundation

// Small dependency-free ZIP writer. Store mode preserves raw floating-point depth bytes exactly.
enum StoredZIP {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 == 1 ? (value >> 1) ^ 0xedb88320 : value >> 1 }
        return value
    }

    static func archive(_ files: [(String, Data)]) -> Data {
        var output = Data(), directory = Data()
        func number(_ value: UInt32, _ count: Int, to data: inout Data) {
            for i in 0..<count { data.append(UInt8(truncatingIfNeeded: value >> (i * 8))) }
        }
        for (name, bytes) in files {
            let nameBytes = Data(name.utf8)
            var crc: UInt32 = 0xffffffff
            for byte in bytes { crc = table[Int((crc ^ UInt32(byte)) & 255)] ^ (crc >> 8) }
            crc ^= 0xffffffff
            let offset = UInt32(output.count), size = UInt32(bytes.count)
            number(0x04034b50, 4, to: &output)
            for v: UInt32 in [20, 0x800, 0, 0, 0x21] { number(v, 2, to: &output) }
            for v in [crc, size, size] { number(v, 4, to: &output) }
            number(UInt32(nameBytes.count), 2, to: &output); number(0, 2, to: &output)
            output.append(nameBytes); output.append(bytes)
            number(0x02014b50, 4, to: &directory)
            for v: UInt32 in [20, 20, 0x800, 0, 0, 0x21] { number(v, 2, to: &directory) }
            for v in [crc, size, size] { number(v, 4, to: &directory) }
            for v: UInt32 in [UInt32(nameBytes.count), 0, 0, 0, 0] { number(v, 2, to: &directory) }
            number(0, 4, to: &directory); number(offset, 4, to: &directory)
            directory.append(nameBytes)
        }
        let start = UInt32(output.count)
        output.append(directory)
        number(0x06054b50, 4, to: &output)
        number(0, 2, to: &output); number(0, 2, to: &output)
        number(UInt32(files.count), 2, to: &output); number(UInt32(files.count), 2, to: &output)
        number(UInt32(directory.count), 4, to: &output); number(start, 4, to: &output)
        number(0, 2, to: &output)
        return output
    }
}
