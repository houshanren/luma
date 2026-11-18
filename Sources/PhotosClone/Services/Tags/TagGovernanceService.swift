import Foundation

/// 标签治理：只做可解释、可回滚的建议，不自动改库。
///
/// 三类问题：
/// - 重复：只在大小写 / 全半角 / 空格 / 斜杠上不同，实际是同一个词；
/// - 相似：拼写只差一个字符，多半是手误；
/// - 可归入标准标签：端侧标签目录里有同名标准词，统一后语义检索能命中。
enum TagGovernanceService {
    struct Report {
        var issues: [TagIssue] = []
        var scannedTags: Int = 0
        var usedVector: Bool = false
    }

    @MainActor
    static func analyze(store: LibraryStore) -> Report {
        guard !store.isSystemScope, !store.isCloudScope else { return Report() }
        let options = store.keywordOptions
        var report = Report()
        report.scannedTags = options.count

        var counts: [String: Int] = [:]
        for option in options { counts[option.name] = option.count }

        var issues: [TagIssue] = []
        var mergedTags: Set<String> = []
        var groups: [String: [String]] = [:]
        for option in options {
            groups[canonicalForm(option.name).lowercased(), default: []].append(option.name)
        }

        // 1. 重复：同一个匹配键下有多个写法，保留命中最多的一种。
        for (_, raws) in groups {
            if raws.count > 1 {
                let target = raws.max { lhs, rhs in
                    let left = counts[lhs] ?? 0
                    let right = counts[rhs] ?? 0
                    if left == right { return lhs.count > rhs.count }
                    return left < right
                } ?? raws[0]
                for raw in raws where raw != target {
                    mergedTags.insert(raw)
                    issues.append(TagIssue(
                        id: "duplicate|\(raw)|\(target)",
                        kind: .duplicate,
                        tags: [raw, target],
                        count: counts[raw] ?? 0,
                        fix: .merge(from: raw, to: target)
                    ))
                }
            } else if let raw = raws.first {
                let canonical = canonicalForm(raw)
                if canonical != raw {
                    mergedTags.insert(raw)
                    issues.append(TagIssue(
                        id: "duplicate|\(raw)|\(canonical)",
                        kind: .duplicate,
                        tags: [raw, canonical],
                        count: counts[raw] ?? 0,
                        fix: .rename(from: raw, to: canonical)
                    ))
                }
            }
        }

        // 2. 相似：只差一个字符，且不是已经判定为重复的词。
        let candidates = options
            .filter { !mergedTags.contains($0.name) && $0.count >= 2 }
            .map(\.name)
        var nearPairs: Set<String> = []
        for index in candidates.indices {
            let lhs = candidates[index]
            for other in candidates[(index + 1)...] {
                guard abs(lhs.count - other.count) <= 1 else { continue }
                // 中文字符串按 Character 比较，避免把一个字的差异拆成 UTF-8 字节差异。
                guard editDistance(Array(lhs), Array(other)) == 1 else { continue }
                let key = lhs < other ? "\(lhs)|\(other)" : "\(other)|\(lhs)"
                guard nearPairs.insert(key).inserted else { continue }
                let target = (counts[lhs] ?? 0) >= (counts[other] ?? 0) ? lhs : other
                let source = target == lhs ? other : lhs
                issues.append(TagIssue(
                    id: "near|\(source)|\(target)",
                    kind: .nearDuplicate,
                    tags: [source, target],
                    count: counts[source] ?? 0,
                    fix: .merge(from: source, to: target)
                ))
            }
        }

        // 3. 语义相近：装了 SigLIP2 时用文本向量补一层，能发现「猫 / 猫咪」这类拼写无关的同义词。
        //    标签数量很大时跳过，避免打开页面就长时间占用主线程。
        if SigLIPEngine.shared.isAvailable, candidates.count <= 150 {
            report.usedVector = true
            var vectors: [(tag: String, vector: [Float])] = []
            for tag in candidates {
                if let vector = SigLIPEngine.shared.textEmbedding(for: tag) {
                    vectors.append((tag, vector))
                }
            }
            var added = Set(issues.map(\.id))
            var pairCount = 0
            outer: for i in vectors.indices {
                for j in vectors.indices where j > i {
                    guard pairCount < 20 else { break outer }
                    let lhs = vectors[i]
                    let rhs = vectors[j]
                    guard lhs.vector.count == rhs.vector.count,
                          cosine(lhs.vector, rhs.vector) >= 0.94 else { continue }
                    let key = lhs.tag < rhs.tag ? "\(lhs.tag)|\(rhs.tag)" : "\(rhs.tag)|\(lhs.tag)"
                    guard nearPairs.insert(key).inserted else { continue }
                    let target = (counts[lhs.tag] ?? 0) >= (counts[rhs.tag] ?? 0) ? lhs.tag : rhs.tag
                    let source = target == lhs.tag ? rhs.tag : lhs.tag
                    let id = "near|\(source)|\(target)"
                    guard added.insert(id).inserted else { continue }
                    issues.append(TagIssue(
                        id: id,
                        kind: .nearDuplicate,
                        tags: [source, target],
                        count: counts[source] ?? 0,
                        fix: .merge(from: source, to: target)
                    ))
                    pairCount += 1
                }
            }
        }

        // 4. 可归入标准标签：词表能唯一确定一个标准名时才给建议，避免「海边日落」被并进「海边」。
        if let catalog = PhotoTagCatalog.shared {
            for option in options where !mergedTags.contains(option.name) {
                guard catalog.definition(for: option.name) == nil else { continue }
                let hits = catalog.searchTitles(for: option.name)
                guard hits.count == 1, let target = hits.first, target != option.name else { continue }
                issues.append(TagIssue(
                    id: "unmapped|\(option.name)|\(target)",
                    kind: .unmapped,
                    tags: [option.name, target],
                    count: option.count,
                    fix: .rename(from: option.name, to: target)
                ))
            }
        }

        report.issues = issues.sorted {
            if $0.kind != $1.kind { return $0.kind.sortIndex < $1.kind.sortIndex }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.tags.joined() < $1.tags.joined()
        }
        return report
    }

    // MARK: - 归一化

    /// 全半角统一、去首尾空格、折叠连续空格与斜杠，但**保留大小写**：
    /// 大小写只用于判定重复，不作为改写目标，避免把「New York」改成「new york」。
    static func canonicalForm(_ tag: String) -> String {
        var value = tag.precomposedStringWithCompatibilityMapping
        value = value.replacingOccurrences(of: "／", with: "/")
        value = value.replacingOccurrences(of: "　", with: " ")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.contains("//") {
            value = value.replacingOccurrences(of: "//", with: "/")
        }
        value = value.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value
    }

    private static func cosine(_ lhs: [Float], _ rhs: [Float]) -> Float {
        // SigLIP 文本向量已归一化，点积即余弦。
        var dot: Float = 0
        let count = min(lhs.count, rhs.count)
        for index in 0..<count { dot += lhs[index] * rhs[index] }
        return dot
    }

    private static func editDistance(_ lhs: [Character], _ rhs: [Character]) -> Int {
        // 只用于「差一个字符」的判定，长度差大于 1 的调用方已经过滤。
        var previous = Array(0...rhs.count)
        for (i, left) in lhs.enumerated() {
            var current = [i + 1]
            for (j, right) in rhs.enumerated() {
                let cost = left == right ? 0 : 1
                current.append(min(previous[j + 1] + 1, current[j] + 1, previous[j] + cost))
            }
            previous = current
        }
        return previous[rhs.count]
    }
}

private extension TagIssueKind {
    var sortIndex: Int {
        TagIssueKind.allCases.firstIndex(of: self) ?? 0
    }
}
