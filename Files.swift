import UIKit
import UniformTypeIdentifiers

// 実行するときに渡す、作業フォルダーの中身
struct Project {
    let root: URL
    let script: String          // フォルダーから見た、プログラムの場所
    var originals: [String: Data]
    let folders: [String]

    var message: [String: Any] {
        ["script": script, "dirs": folders,
         "files": originals.map { [$0.key, $0.value.base64EncodedString()] }]
    }
}

struct ProjectError: LocalizedError {
    let errorDescription: String?
}

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

    // MARK: 作業フォルダー

    // 選んだフォルダーを覚える。キャンセルしたときは nil
    func chooseFolder() async throws -> String? {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        guard let url = await pick(picker).first else { return nil }
        let data = try withAccess(url) { try url.bookmarkData() }
        var all = folderBookmarks
        all[url.resolvingSymlinksInPath().path] = data
        folderBookmarks = all
        return url.lastPathComponent
    }

    private var folderBookmarks: [String: Data] {
        get { UserDefaults.standard.dictionary(forKey: "folders") as? [String: Data] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "folders") }
    }

    private func parts(_ url: URL) -> [String] {
        url.resolvingSymlinksInPath().pathComponents
    }

    // ファイルが入っている作業フォルダーを探して、中身を読む。なければ nil
    func project(for fileId: String) throws -> Project? {
        let file = try find(fileId)
        let fileParts = withAccess(file) { parts(file) }
        var best: (url: URL, count: Int)?
        for data in folderBookmarks.values {
            var stale = false
            guard let root = try? URL(resolvingBookmarkData: data, bookmarkDataIsStale: &stale) else { continue }
            let rootParts = withAccess(root) { parts(root) }
            if fileParts.count > rootParts.count && Array(fileParts.prefix(rootParts.count)) == rootParts
                && rootParts.count > (best?.count ?? 0) {
                best = (root, rootParts.count)
            }
        }
        guard let found = best else { return nil }
        let script = fileParts.dropFirst(found.count).joined(separator: "/")
        return try withAccess(found.url) { try scan(found.url, script: script) }
    }

    private func scan(_ root: URL, script: String) throws -> Project {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                         options: [.skipsHiddenFiles]) else {
            throw ProjectError(errorDescription: "作業フォルダーを読めませんでした。")
        }
        let tooBig = ProjectError(errorDescription: "作業フォルダーが大きすぎます(500個・合計30MBまで)。必要なファイルだけを入れたフォルダーを選んでください。")
        let rootCount = parts(root).count
        var files: [String: Data] = [:]
        var folders: [String] = []
        var total = 0
        var count = 0
        for case let item as URL in items {
            if item.lastPathComponent == "__pycache__" {
                items.skipDescendants()
                continue
            }
            count += 1
            if count > 500 { throw tooBig }
            let info = try item.resourceValues(forKeys: Set(keys))
            let path = parts(item).dropFirst(rootCount).joined(separator: "/")
            if info.isDirectory == true {
                folders.append(path)
            } else if info.isRegularFile == true {
                total += info.fileSize ?? 0
                if total > 30_000_000 { throw tooBig }
                files[path] = try readData(item)
            }
        }
        return Project(root: root, script: script, originals: files, folders: folders)
    }

    // プログラムが作った・書きかえたファイルを、iPadのフォルダーに書く
    // 戻り値は、画面に出すお知らせ
    func writeBack(_ changes: [[String]], to project: inout Project) -> [String] {
        var notes: [String] = []
        withAccess(project.root) {
            for change in changes where change.count == 2 {
                let path = change[0]
                let names = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
                // フォルダーの外には書かない
                if names.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) { continue }
                guard let data = Data(base64Encoded: change[1]) else { continue }
                let target = names.reduce(project.root) { $0.appendingPathComponent($1) }
                do {
                    let real = parts(target.deletingLastPathComponent())
                    let rootParts = parts(project.root)
                    if Array(real.prefix(rootParts.count)) != rootParts { continue }
                    if FileManager.default.fileExists(atPath: target.path) {
                        // 実行中にほかの場所で変わったファイルは、上書きしない
                        let now = try readData(target)
                        if now != project.originals[path] && now != data {
                            notes.append("「\(path)」はほかの場所で変わっていたので、上書きしませんでした。")
                            continue
                        }
                    } else {
                        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                                withIntermediateDirectories: true)
                    }
                    try writeData(data, to: target)
                    project.originals[path] = data
                } catch {
                    notes.append("「\(path)」を保存できませんでした: \(error.localizedDescription)")
                }
            }
        }
        return notes
    }

    private func readData(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { target in
            result = Result { try Data(contentsOf: target) }
        }
        if let coordinationError { throw coordinationError }
        return try result.get()
    }

    private func writeData(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(CocoaError(.fileWriteUnknown))
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { target in
            result = Result { try data.write(to: target) }
        }
        if let coordinationError { throw coordinationError }
        try result.get()
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
