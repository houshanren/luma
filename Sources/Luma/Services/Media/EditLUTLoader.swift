import Foundation

/// 3D LUT 的落盘与解析：外部 .cube 复制进图库，渲染层只按名称取数据。
enum EditLUTLoader {
    private static let lock = NSLock()
    private static var cache: [String: (data: Data, size: Int)] = [:]

    static func url(for name: String) -> URL {
        LibraryPaths.lutsDir.appendingPathComponent(name)
    }

    /// 把外部 .cube 复制进图库，返回库内文件名。
    static func importLUT(from url: URL) throws -> String {
        let name = url.lastPathComponent
        let destination = self.url(for: name)
        try FileManager.default.createDirectory(at: LibraryPaths.lutsDir,
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        lock.lock()
        cache[name] = nil
        lock.unlock()
        return name
    }

    static func load(name: String) -> (data: Data, size: Int)? {
        lock.lock()
        if let hit = cache[name] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let file = url(for: name)
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let parsed = parse(text) else { return nil }
        lock.lock()
        cache[name] = parsed
        lock.unlock()
        return parsed
    }

    static func parse(_ text: String) -> (data: Data, size: Int)? {
        var size = 0
        var values = [Float]()
        for rawLine in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let upper = line.uppercased()
            if upper.hasPrefix("LUT_3D_SIZE") {
                size = Int(line.split(whereSeparator: { $0 == " " || $0 == "\t" }).last ?? "") ?? 0
                continue
            }
            if upper.hasPrefix("TITLE") || upper.hasPrefix("LUT_1D")
                || upper.hasPrefix("DOMAIN") || upper.hasPrefix("LUT_3D_INPUT") {
                continue
            }
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.count >= 3,
                  let r = Float(parts[0]), let g = Float(parts[1]), let b = Float(parts[2]) else {
                continue
            }
            values.append(r)
            values.append(g)
            values.append(b)
            values.append(1)
        }
        guard size >= 2, size <= 64, values.count == size * size * size * 4 else { return nil }
        let data = values.withUnsafeBufferPointer { Data(buffer: $0) }
        return (data, size)
    }
}
