import Foundation

/// 检索索引里的一份文档：一张照片的可检索文本 + 量化向量。
struct SearchDocument {
    let id: UUID
    let title: String
    let keywords: String
    let labels: String
    let ocr: String
    let place: String
    let people: String
    let camera: String
    let capturedAt: Date
    let feature: Data?
}

/// 本地图库的检索索引：FTS5 词法表 + 768 位符号位向量表。
///
/// 只服务拾光自己的图库；系统图库与网盘复用各自已有的内存缓存。
/// 向量用「符号位 + 汉明距离」预筛，1M 张照片约 96MB，避免每次查询扫 3GB 的浮点特征。
final class SearchIndex {
    static let shared = SearchIndex()

    private let lock = NSLock()
    private var cachedSignature: String?
    private var cachedPath: String?
    private var vectorIDs: [String] = []
    private var vectorWords: [[UInt64]] = []

    // MARK: - 构建

    func rebuild(db: SQLiteDatabase, documents: [SearchDocument], signature: String) throws {
        let now = Date().timeIntervalSince1970
        var ids: [String] = []
        var words: [[UInt64]] = []
        ids.reserveCapacity(documents.count)
        words.reserveCapacity(documents.count)

        var docRows: [[Any?]] = []
        docRows.reserveCapacity(documents.count)
        var ftsRows: [[Any?]] = []
        ftsRows.reserveCapacity(documents.count)
        var vectorRows: [[Any?]] = []
        vectorRows.reserveCapacity(documents.count)

        for document in documents {
            let docID = document.id.uuidString
            docRows.append([
                docID, docID, document.title, document.keywords, document.labels,
                document.ocr, document.place, document.people, document.camera,
                document.capturedAt.timeIntervalSince1970, now
            ])
            ftsRows.append([
                docID, document.title, document.keywords, document.labels,
                document.ocr, document.place, document.people, document.camera
            ])
            if let feature = document.feature,
               let quantized = Self.quantizedWords(from: feature) {
                let data = quantized.withUnsafeBufferPointer { Data(buffer: $0) }
                vectorRows.append([docID, data, now])
                ids.append(docID)
                words.append(quantized)
            }
        }

        try db.transaction {
            try db.execute("DELETE FROM search_docs;")
            try? db.execute("DELETE FROM search_fts;")
            try db.execute("DELETE FROM search_vectors;")
            try db.executeMany("""
                INSERT INTO search_docs
                (doc_id, asset_id, title, keywords, labels, ocr, place, people, camera, captured_at, updated_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, rows: docRows)
            // FTS 表可能因系统 SQLite 版本缺少 trigram 而没建起来：词法召回降级，不阻断主索引。
            try? db.executeMany("""
                INSERT INTO search_fts (doc_id, title, keywords, labels, ocr, place, people, camera)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, rows: ftsRows)
            try db.executeMany("""
                INSERT INTO search_vectors (doc_id, bits, updated_at) VALUES (?, ?, ?)
                """, rows: vectorRows)
        }

        lock.lock()
        cachedSignature = signature
        cachedPath = db.path
        vectorIDs = ids
        vectorWords = words
        lock.unlock()
    }

    // MARK: - 词法检索

    func lexicalSearch(db: SQLiteDatabase, tokens: [String], limit: Int) -> [(docID: String, score: Double)] {
        guard !tokens.isEmpty, limit > 0 else { return [] }
        var scores: [String: Double] = [:]
        let longTokens = tokens.filter { $0.count >= 3 }
        let shortTokens = tokens.filter { !$0.isEmpty && $0.count < 3 }

        if !longTokens.isEmpty {
            let phrase = longTokens
                .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " OR ")
            if let rows = try? db.query("""
                SELECT doc_id, bm25(search_fts) AS rank
                FROM search_fts WHERE search_fts MATCH ?
                ORDER BY rank LIMIT ?
                """, [phrase, limit]) {
                for row in rows {
                    guard let id = row["doc_id"]?.string else { continue }
                    let rank = row["rank"]?.double ?? 0
                    scores[id, default: 0] += max(0.0001, -rank)
                }
            }
        }

        // trigram 至少需要 3 个字符，中文两字词（京都 / 猫）走 LIKE 兜底。
        for token in shortTokens {
            let like = "%\(token)%"
            if let rows = try? db.query("""
                SELECT doc_id FROM search_docs
                WHERE title LIKE ? OR keywords LIKE ? OR labels LIKE ? OR ocr LIKE ?
                   OR place LIKE ? OR people LIKE ? OR camera LIKE ?
                LIMIT ?
                """, [like, like, like, like, like, like, like, limit]) {
                for row in rows {
                    guard let id = row["doc_id"]?.string else { continue }
                    scores[id, default: 0] += 0.01
                }
            }
        }

        return scores.sorted { $0.value > $1.value }
            .prefix(limit)
            .map { (docID: $0.key, score: $0.value) }
    }

    // MARK: - 向量检索

    func vectorSearch(db: SQLiteDatabase,
                      query: [Float],
                      limit: Int) -> [(docID: String, score: Double)] {
        guard limit > 0, let queryWords = Self.quantizedWords(from: query) else { return [] }
        ensureVectorCache(db: db)
        lock.lock()
        let ids = vectorIDs
        let words = vectorWords
        lock.unlock()
        guard !ids.isEmpty else { return [] }

        let dimension = max(1, queryWords.count * 64)
        var scored: [(String, Double)] = []
        scored.reserveCapacity(ids.count)
        for index in 0..<ids.count {
            let distance = Self.hamming(queryWords, words[index])
            let score = 1 - Double(distance) / Double(dimension)
            scored.append((ids[index], score))
        }
        scored.sort { $0.1 > $1.1 }
        return scored.prefix(limit).map { (docID: $0.0, score: $0.1) }
    }

    private func ensureVectorCache(db: SQLiteDatabase) {
        lock.lock()
        let ready = cachedPath == db.path && !vectorIDs.isEmpty
        lock.unlock()
        guard !ready else { return }

        var ids: [String] = []
        var words: [[UInt64]] = []
        try? db.forEachRow("SELECT doc_id, bits FROM search_vectors") { row in
            guard let id = row["doc_id"]?.string, let data = row["bits"]?.data else { return }
            let quantized = data.withUnsafeBytes { Array($0.bindMemory(to: UInt64.self)) }
            guard !quantized.isEmpty else { return }
            ids.append(id)
            words.append(quantized)
        }

        lock.lock()
        vectorIDs = ids
        vectorWords = words
        cachedPath = db.path
        lock.unlock()
    }

    func documentCount(db: SQLiteDatabase) -> Int {
        (try? db.query("SELECT COUNT(*) AS c FROM search_docs").first?["c"]?.int) ?? 0
    }

    // MARK: - 读取文档

    func loadDocuments(db: SQLiteDatabase, ids: [String]) -> [String: SearchDocument] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        guard let rows = try? db.query("""
            SELECT * FROM search_docs WHERE doc_id IN (\(placeholders))
            """, ids) else { return [:] }
        var result: [String: SearchDocument] = [:]
        for row in rows {
            guard let docID = row["doc_id"]?.string,
                  let assetID = row["asset_id"]?.string.flatMap({ UUID(uuidString: $0) }) else { continue }
            result[docID] = SearchDocument(
                id: assetID,
                title: row["title"]?.string ?? "",
                keywords: row["keywords"]?.string ?? "",
                labels: row["labels"]?.string ?? "",
                ocr: row["ocr"]?.string ?? "",
                place: row["place"]?.string ?? "",
                people: row["people"]?.string ?? "",
                camera: row["camera"]?.string ?? "",
                capturedAt: Date(timeIntervalSince1970: row["captured_at"]?.double ?? 0),
                feature: nil
            )
        }
        return result
    }

    // MARK: - 量化

    /// Float32 特征 → 符号位（>0 记 1）。768 维压到 96 字节。
    static func quantizedWords(from feature: Data) -> [UInt64]? {
        let floats: [Float] = feature.withUnsafeBytes { buffer in
            guard buffer.count >= MemoryLayout<Float>.size else { return [] }
            return Array(buffer.bindMemory(to: Float.self))
        }
        return quantizedWords(from: floats)
    }

    static func quantizedWords(from floats: [Float]) -> [UInt64]? {
        guard floats.count >= 64 else { return nil }
        var words = [UInt64](repeating: 0, count: (floats.count + 63) / 64)
        for (index, value) in floats.enumerated() where value > 0 {
            words[index >> 6] |= (UInt64(1) << UInt64(index & 63))
        }
        return words
    }

    static func hamming(_ lhs: [UInt64], _ rhs: [UInt64]) -> Int {
        let count = min(lhs.count, rhs.count)
        var distance = 0
        for index in 0..<count {
            distance += (lhs[index] ^ rhs[index]).nonzeroBitCount
        }
        return distance
    }
}
