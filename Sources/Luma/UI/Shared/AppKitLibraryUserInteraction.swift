import AppKit

/// AppKit 实现：只在视图层注入，Store 只依赖 `LibraryUserInteraction` 协议。
struct AppKitLibraryUserInteraction: LibraryUserInteraction {
    func chooseURLs(_ request: LibraryOpenPanelRequest) -> [URL] {
        let panel = NSOpenPanel()
        panel.canChooseFiles = request.canChooseFiles
        panel.canChooseDirectories = request.canChooseDirectories
        panel.allowsMultipleSelection = request.allowsMultipleSelection
        panel.canCreateDirectories = request.canCreateDirectories
        panel.treatsFilePackagesAsDirectories = request.treatsFilePackagesAsDirectories
        if let message = request.message { panel.message = message }
        if let prompt = request.prompt { panel.prompt = prompt }
        if !request.allowedContentTypes.isEmpty {
            panel.allowedContentTypes = request.allowedContentTypes
        }
        if let directoryURL = request.directoryURL {
            panel.directoryURL = directoryURL
        }
        return panel.runModal() == .OK ? panel.urls : []
    }

    func chooseSaveURL(_ request: LibrarySavePanelRequest) -> URL? {
        let panel = NSSavePanel()
        if let title = request.title { panel.title = title }
        if let message = request.message { panel.message = message }
        if let prompt = request.prompt { panel.prompt = prompt }
        panel.nameFieldStringValue = request.nameFieldStringValue
        panel.canCreateDirectories = request.canCreateDirectories
        if let isExtensionHidden = request.isExtensionHidden {
            panel.isExtensionHidden = isExtensionHidden
        }
        if let directoryURL = request.directoryURL {
            panel.directoryURL = directoryURL
        }
        return panel.runModal() == .OK ? panel.url : nil
    }

    func presentAlert(_ request: LibraryAlertRequest) -> Int? {
        let alert = NSAlert()
        alert.messageText = request.title
        alert.informativeText = request.message
        alert.alertStyle = request.style == .warning ? .warning : .informational
        for button in request.buttons {
            alert.addButton(withTitle: button)
        }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        return request.buttons.indices.contains(index) ? index : nil
    }
}
