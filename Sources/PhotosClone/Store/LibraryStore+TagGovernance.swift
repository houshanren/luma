import Foundation

/// 标签治理的落库入口：合并 / 统一 / 删除，全部走既有的内存状态 + 撤销栈。
extension LibraryStore {
    /// 标签治理只对拾光本地图库生效：系统图库与网盘的关键词是补充元数据，不在这里改写。
    var supportsTagGovernance: Bool {
        !isReadOnlyScope
    }

    func applyTagFix(_ issue: TagIssue) {
        switch issue.fix {
        case .merge(let from, let to):
            replaceKeyword(from, with: to, actionTitle: "合并标签")
        case .rename(let from, let to):
            replaceKeyword(from, with: to, actionTitle: "统一标签")
        case .delete(let tag):
            deleteKeyword(tag)
        }
    }

    /// 把 `old` 全部替换成 `new`，同一张照片上去重；保留用户其他关键词顺序。
    private func replaceKeyword(_ old: String, with new: String, actionTitle: String) {
        guard supportsTagGovernance else {
            showToast("标签治理只支持拾光本地图库")
            return
        }
        let trimmed = new.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, old != trimmed else { return }
        let affected = Set(photos.filter { ($0.keywords ?? []).contains(old) }.map(\.id))
        guard !affected.isEmpty else {
            showToast("没有照片使用「\(old)」")
            return
        }
        let before = photoSnapshot(affected)
        for index in photos.indices where affected.contains(photos[index].id) {
            guard var list = photos[index].keywords else { continue }
            list.removeAll { $0 == old }
            if !list.contains(trimmed) { list.append(trimmed) }
            photos[index].keywords = list.isEmpty ? nil : list
        }
        save()
        recordUndo(actionTitle, beforePhotos: before)
        showToast("\(actionTitle)：「\(old)」→「\(trimmed)」（\(affected.count) 张）")
    }
}
