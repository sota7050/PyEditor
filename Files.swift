import UIKit
import UniformTypeIdentifiers

struct OpenedFile {
    let id: String
    let name: String
    let text: String
}

// 元のファイルを直接読み書きする
@MainActor
final class FileStore: NSObject, UIDocumentPickerDelegate {
    private var waiting: CheckedContinuation<[URL], Never>?

    func open() async -> [Result<OpenedFile, Error>] {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
        picker.allowsMultipleSelection = true
        var results: [Result<OpenedFile, Error>] = []
        for url in await pick(picker) {
            results.append(Result {
                let text = try withAccess(url) { try read(url) }
                return OpenedFile(id: try remember(url), name: url.lastPathComponent, text: text)
            })
        }
        return results
    }

    // 保存場所を選ぶ。キャンセルしたときは nil
    func saveAs(name: String, text: String) async throws -> OpenedFile? {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let temp = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: temp)
        // コピーではなく移動して、移動先をそのまま編集する
        let picker = UIDocumentPickerViewController(forExporting: [temp], asCopy: false)
        guard let url = await pick(picker).first else { return nil }
        return OpenedFile(id: try remember(url), name: url.lastPathComponent, text: text)
    }

    func load(_ id: String) throws -> OpenedFile {
        let url = try find(id)
        let text = try withAccess(url) { try read(url) }
        return OpenedFile(id: id, name: url.lastPathComponent, text: text)
    }

    // 別の場所で変えられていて、上書きしなかったときは false
    func write(_ id: String, text: String, expected: String, force: Bool) throws -> Bool {
        let url = try find(id)
        return try withAccess(url) { () throws -> Bool in
            if !force {
                let now = try read(url)
                // 文字の中身を1つずつ比べる
                if !now.utf8.elementsEqual(expected.utf8) { return false }
            }
            try replace(url, with: text)
            return true
        }
    }

    func forget(_ id: String) {
        var all = bookmarks
        all[id] = nil
        bookmarks = all
    }

    private func pick(_ picker: UIDocumentPickerViewController) async -> [URL] {
        guard waiting == nil, let top = Dialog.topController() else { return [] }
        return await withCheckedContinuation { continuation in
            waiting = continuation
            picker.delegate = self
            top.present(picker, animated: true)
        }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        waiting?.resume(returning: urls)
        waiting = nil
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        waiting?.resume(returning: [])
        waiting = nil
    }

    // 選んだファイルを使う許可を得てから、作業する
    private func withAccess<T>(_ url: URL, _ work: () throws -> T) rethrows -> T {
        let allowed = url.startAccessingSecurityScopedResource()
        defer { if allowed { url.stopAccessingSecurityScopedResource() } }
        return try work()
    }

    private func read(_ url: URL) throws -> String {
        var coordinationError: NSError?
        var result: Result<String, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result {
                let data = try Data(contentsOf: target)
                // 大きすぎるファイルや、文字ではないファイルは開かない
                if data.count > 1_000_000 { throw CocoaError(.fileReadTooLarge) }
                if data.contains(0) { throw CocoaError(.fileReadCorruptFile) }
                guard let text = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadInapplicableStringEncoding)
                }
                return text
            }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private func replace(_ url: URL, with text: String) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            result = Result { try Data(text.utf8).write(to: target) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
    }

    // アプリを開き直しても同じファイルを使えるように、場所の情報を覚える
    private var bookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: "bookmarks") as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "bookmarks") }
    }

    private func remember(_ url: URL) throws -> String {
        let old = bookmarks.keys.first { key in
            (try? find(key))?.standardizedFileURL.path == url.standardizedFileURL.path
        }
        let id = old ?? UUID().uuidString
        let data = try withAccess(url) { try url.bookmarkData() }
        var all = bookmarks
        all[id] = data
        bookmarks = all
        return id
    }

    private func find(_ id: String) throws -> URL {
        guard let data = bookmarks[id] else { throw CocoaError(.fileNoSuchFile) }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale)
        if stale, let fresh = try? withAccess(url, { try url.bookmarkData() }) {
            var all = bookmarks
            all[id] = fresh
            bookmarks = all
        }
        return url
    }
}
