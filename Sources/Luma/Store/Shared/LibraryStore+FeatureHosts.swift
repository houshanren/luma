import Foundation

/// 功能模块的宿主适配：功能 target 只声明自己需要的能力，由 `LibraryStore` 在这里实现。
extension LibraryStore: MemoryHost {
    var memoryJobPath: String {
        (LibraryPaths.containerLibraryURL ?? LibraryPaths.root).standardizedFileURL.path
    }
}
