import Foundation

/// 全库检索：本地图库走持久化 FTS + 量化向量，系统图库 / 网盘复用已有内存缓存。
/// 召回结果只包含元数据，不读原图，供「问一问」与标签治理使用。
@MainActor
final class RetrievalService {
    static let shared = RetrievalService()

    private let index = SearchIndex()

    // MARK: - 索引

    /// 按需构建 / 刷新本地索引。索引内容没变化时直接跳过。
    func prepare(store: LibraryStore) async {
        guard !store.isSystemScope, !store.isCloudScope,
              let metadata = store.metadataStore else { return }
        let db = metadata.db
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            metadata.queue.async {
                do {
                    try Self.rebuildIfNeeded(db: db)
                } catch {
                    FileHandle.standardError.write(Data("search index rebuild failed: \(error)\n".utf8))
                }
                continuation.resume()
            }
        }
    }

    private nonisolated static func rebuildIfNeeded(db: SQLiteDatabase) throws {
        let signature = try signature(db: db)
        if let stored = try db.query("SELECT value FROM search_state WHERE key = 'local'")
            .first?["value"]?.string,
           stored == signature,
           SearchIndex.shared.documentCount(db: db) > 0 {
            return
        }
        let documents = try buildDocuments(db: db)
        try SearchIndex.shared.rebuild(db: db, documents: documents, signature: signature)
        try db.execute("INSERT OR REPLACE INTO search_state(key, value) VALUES('local', ?)", [signature])
    }

    /// 只统计会影响文档内容的维度，避免每次问一问都全量重扫。
    private nonisolated static func signature(db: SQLiteDatabase) throws -> String {
        let assets = try db.query("""
            SELECT COUNT(*) AS c,
                   COALESCE(SUM(LENGTH(keywords)), 0) AS k,
                   COALESCE(SUM(LENGTH(title)), 0) AS t
            FROM assets WHERE deleted_at IS NULL
            """).first
        let analysis = try db.query("""
            SELECT COUNT(*) AS c, COALESCE(MAX(updated_at), 0) AS m FROM asset_analysis
            """).first
        let people = try db.query("SELECT COUNT(*) AS c FROM person_assets").first
        return [
            "v1",
            String(assets?["c"]?.int ?? 0),
            String(assets?["k"]?.int ?? 0),
            String(assets?["t"]?.int ?? 0),
            String(analysis?["c"]?.int ?? 0),
            String(analysis?["m"]?.double ?? 0),
            String(people?["c"]?.int ?? 0)
        ].joined(separator: "|")
    }

    private nonisolated static func buildDocuments(db: SQLiteDatabase) throws -> [SearchDocument] {
        var peopleByAsset: [String: [String]] = [:]
        try db.forEachRow("""
            SELECT pa.asset_id, p.name FROM person_assets pa
            JOIN people p ON p.id = pa.person_id
            """) { row in
            guard let asset = row["asset_id"]?.string,
                  let name = row["name"]?.string, !name.isEmpty else { return }
            peopleByAsset[asset, default: []].append(name)
        }

        var documents: [SearchDocument] = []
        try db.forEachRow("""
            SELECT a.id, a.title, a.keywords, a.filename, a.original_name,
                   a.make, a.model, a.lens,
                   a.place_country, a.place_province, a.place_city, a.place_district, a.place_poi,
                   a.captured_at, aa.labels, aa.text, aa.feature
            FROM assets a
            LEFT JOIN asset_analysis aa ON aa.asset_id = a.id
            WHERE a.deleted_at IS NULL
            """) { row in
            guard let idString = row["id"]?.string,
                  let id = UUID(uuidString: idString) else { return }
            let title = row["title"]?.string
                ?? row["filename"]?.string
                ?? row["original_name"]?.string
                ?? ""
            let place = [
                row["place_country"]?.string, row["place_province"]?.string,
                row["place_city"]?.string, row["place_district"]?.string,
                row["place_poi"]?.string
            ].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            let camera = [row["make"]?.string, row["model"]?.string, row["lens"]?.string]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
            documents.append(SearchDocument(
                id: id,
                title: title,
                keywords: keywordText(row["keywords"]?.string),
                labels: row["labels"]?.string ?? "",
                ocr: String((row["text"]?.string ?? "").prefix(2000)),
                place: place,
                people: (peopleByAsset[idString] ?? []).joined(separator: " "),
                camera: camera,
                capturedAt: Date(timeIntervalSince1970: row["captured_at"]?.double ?? 0),
                feature: row["feature"]?.data
            ))
        }
        return documents
    }

    private nonisolated static func keywordText(_ json: String?) -> String {
        guard let json, let data = json.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data) else {
            return json ?? ""
        }
        return list.joined(separator: " ")
    }

    // MARK: - 检索

    func retrieve(text: String, store: LibraryStore, limit: Int = 30) -> RetrievalOutcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var outcome = RetrievalOutcome()
        outcome.scope = store.isSystemScope ? .system : (store.isCloudScope ? .cloud : .local)
        guard !trimmed.isEmpty else { return outcome }

        let query = parsedQuery(trimmed, store: store)
        outcome.tokens = query.tokens
        guard !query.isEmpty else { return outcome }

        guard outcome.scope == .local,
              let metadata = store.metadataStore else {
            outcome.hits = memoryHits(query: query, store: store, limit: limit)
            return outcome
        }
        let db = metadata.db

        let lexical = index.lexicalSearch(db: db, tokens: query.tokens, limit: 200)
        var semantic: [(docID: String, score: Double)] = []
        if let vector = SigLIPEngine.shared.textEmbedding(for: trimmed) {
            semantic = index.vectorSearch(db: db, query: vector, limit: 200)
        }
        outcome.usedVector = !semantic.isEmpty
        outcome.indexTotal = index.documentCount(db: db)

        // Reciprocal Rank Fusion：两路分数量纲不同，只融合名次。
        var scores: [String: Double] = [:]
        var lexicalScores: [String: Double] = [:]
        var semanticScores: [String: Double] = [:]
        for (rank, hit) in lexical.enumerated() {
            scores[hit.docID, default: 0] += 1.0 / Double(60 + rank + 1)
            lexicalScores[hit.docID] = hit.score
        }
        for (rank, hit) in semantic.enumerated() {
            scores[hit.docID, default: 0] += 1.0 / Double(60 + rank + 1)
            semanticScores[hit.docID] = hit.score
        }
        guard !scores.isEmpty else {
            // 只有结构化条件（例如「收藏的视频」「去年」）时不需要词法 / 向量召回。
            outcome.hits = memoryHits(query: query, store: store, limit: limit)
            return outcome
        }

        let ranked = scores.sorted { $0.value > $1.value }
        let docIDs = ranked.prefix(max(limit * 4, 80)).map(\.key)
        let documents = index.loadDocuments(db: db, ids: docIDs)

        // 结构化条件（时间 / 收藏 / 类型 / 人物）在排序后过滤，避免召回阶段漏掉语义命中。
        let photosByID = loadPhotos(db: db, ids: docIDs, metadata: metadata)
        let personAssetIDs = allowedPersonAssets(query.personIDs, db: db)

        var hits: [RetrievalHit] = []
        for (docID, score) in ranked {
            guard let document = documents[docID],
                  let photo = photosByID[document.id],
                  passes(photo, query: query, personAssets: personAssetIDs) else { continue }
            hits.append(RetrievalHit(
                id: document.id,
                score: score,
                lexicalScore: lexicalScores[docID] ?? 0,
                semanticScore: semanticScores[docID] ?? 0,
                title: document.title,
                snippet: snippet(document),
                capturedAt: document.capturedAt
            ))
            if hits.count >= limit { break }
        }
        outcome.hits = hits
        return outcome
    }

    func indexCount(store: LibraryStore) -> Int {
        guard let db = store.metadataStore?.db else { return 0 }
        return index.documentCount(db: db)
    }

    // MARK: - 内存回退（系统图库 / 网盘）

    private func memoryHits(query: SearchQuery, store: LibraryStore, limit: Int) -> [RetrievalHit] {
        let peopleByID = store.localPeople.reduce(into: [UUID: LocalPerson]()) { $0[$1.id] = $1 }
        return store.photos
            .filter { $0.deletedAt == nil && store.matchesSearch($0, query: query, peopleByID: peopleByID) }
            .prefix(limit)
            .map { photo in
                let analysis = store.analysisIndex[photo.id]
                    ?? (store.isSystemScope ? store.systemAnalysisIndex[photo.id] : nil)
                    ?? (photo.isCloud ? store.cloudModel.analysis[photo.id] : nil)
                let labels = analysis.map { Array($0.labels).sorted().joined(separator: " ") } ?? ""
                let ocr = analysis?.text ?? ""
                let snippet = String([labels, ocr].filter { !$0.isEmpty }.joined(separator: " · ").prefix(90))
                return RetrievalHit(
                    id: photo.id,
                    score: 1,
                    lexicalScore: 1,
                    semanticScore: 0,
                    title: photo.displayTitle,
                    snippet: snippet,
                    capturedAt: photo.capturedAt
                )
            }
    }

    // MARK: - 工具

    private func parsedQuery(_ text: String, store: LibraryStore) -> SearchQuery {
        var query = SearchQueryParser.parse(text)
        guard !query.tokens.isEmpty, !store.localPeople.isEmpty else { return query }
        var matched: Set<UUID> = []
        query.tokens.removeAll { token in
            guard let person = store.localPeople.first(where: {
                $0.name.lowercased() == token && !$0.assetIDs.isEmpty
            }) else { return false }
            matched.insert(person.id)
            return true
        }
        query.personIDs.formUnion(matched)
        return query
    }

    private func loadPhotos(db: SQLiteDatabase, ids: [String], metadata: MetadataStore) -> [UUID: PhotoItem] {
        guard !ids.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        guard let rows = try? db.query("SELECT * FROM assets WHERE id IN (\(placeholders))", ids) else {
            return [:]
        }
        var result: [UUID: PhotoItem] = [:]
        for row in rows {
            guard let photo = metadata.photo(from: row) else { continue }
            result[photo.id] = photo
        }
        return result
    }

    private func allowedPersonAssets(_ personIDs: Set<UUID>, db: SQLiteDatabase) -> Set<UUID>? {
        guard !personIDs.isEmpty else { return nil }
        let ids = personIDs.map(\.uuidString)
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        guard let rows = try? db.query("""
            SELECT DISTINCT asset_id FROM person_assets WHERE person_id IN (\(placeholders))
            """, ids) else { return [] }
        return Set(rows.compactMap { UUID(uuidString: $0["asset_id"]?.string ?? "") })
    }

    private func passes(_ photo: PhotoItem, query: SearchQuery, personAssets: Set<UUID>?) -> Bool {
        if let start = query.startDate, photo.capturedAt < start { return false }
        if let end = query.endDate, photo.capturedAt >= end { return false }
        if query.onlyFavorites, !photo.isFavorite { return false }
        if query.onlyVideos, !photo.isVideo { return false }
        if query.onlyPhotos, photo.isVideo { return false }
        if query.onlyScreenshots, photo.kind != .screenshot { return false }
        if query.onlyLivePhotos, !photo.isLivePhoto { return false }
        if query.onlyEdited, !photo.hasEdits { return false }
        if let personAssets, !personAssets.contains(photo.id) { return false }
        return true
    }

    private func snippet(_ document: SearchDocument) -> String {
        let parts = [document.labels, document.ocr, document.place, document.keywords]
            .filter { !$0.isEmpty }
        return String(parts.prefix(2).joined(separator: " · ").prefix(90))
    }
}
