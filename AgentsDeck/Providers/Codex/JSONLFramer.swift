import Foundation

struct JSONLFramer: Sendable {
    private(set) var buffer = Data()
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = 1_048_576) {
        self.maximumLineBytes = maximumLineBytes
    }

    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        if buffer.count > maximumLineBytes, !buffer.contains(0x0A) {
            buffer.removeAll(keepingCapacity: false)
            throw ProviderBoundaryError.messageTooLarge
        }

        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            var line = buffer[..<newline]
            if line.last == 0x0D { line = line.dropLast() }
            guard line.count <= maximumLineBytes else {
                buffer.removeSubrange(...newline)
                throw ProviderBoundaryError.messageTooLarge
            }
            if !line.isEmpty { lines.append(Data(line)) }
            buffer.removeSubrange(...newline)
        }
        return lines
    }
}
