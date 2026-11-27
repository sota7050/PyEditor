import SwiftUI
import WebKit
import UIKit
import UniformTypeIdentifiers

@main
struct PyEditorApp: App {
    var body: some Scene {
        WindowGroup {
            // 画面の端まで背景を広げる(キーボードをよける処理は下のUIKit側で行う)
            EditorView().ignoresSafeArea()
        }
    }
}

struct EditorView: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> EditorController { EditorController() }
    func updateUIViewController(_ controller: EditorController, context: Context) {}
}

// アプリ内のファイルを app://local/... としてWeb画面に渡す
final class LocalFiles: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, let root = Bundle.main.resourceURL else { return }
        let file = root.appendingPathComponent("www" + url.path)
        guard let data = try? Data(contentsOf: file) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript",
                     "mjs": "text/javascript", "wasm": "application/wasm",
                     "json": "application/json"]
        let headers = ["Content-Type": types[file.pathExtension] ?? "application/octet-stream",
                       "Content-Length": String(data.count),
                       "Access-Control-Allow-Origin": "*"]
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}

final class EditorController: UIViewController, WKScriptMessageHandler, WKUIDelegate {
    private var webView: WKWebView!
    private let files = FileBridge()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = color(UserDefaults.standard.string(forKey: "background") ?? "#282c34")
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFiles(), forURLScheme: "app")

        // 保存してある内容をWeb画面に渡す
        let values = [("nativeCode", "code"), ("nativeSettings", "settings"),
                      ("nativeWorkspace", "workspace")]
        for (name, key) in values {
            if let value = UserDefaults.standard.string(forKey: key),
               let json = try? JSONEncoder().encode(value),
               let text = String(data: json, encoding: .utf8) {
                config.userContentController.addUserScript(WKUserScript(
                    source: "window.\(name) = \(text);",
                    injectionTime: .atDocumentStart, forMainFrameOnly: true))
            }
        }
        config.userContentController.add(self, name: "settings")
        config.userContentController.add(self, name: "appearance")
        config.userContentController.add(self, name: "state")
        files.presenter = self
        config.userContentController.addScriptMessageHandler(files, contentWorld: .page, name: "files")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        // 文字やボタンは、時計などと重ならない範囲に置く
        let safe = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: safe.topAnchor),
            // キーボードや下のバーが出たときは、その上まで
            webView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: safe.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: safe.trailingAnchor)
        ])
        webView.load(URLRequest(url: URL(string: "app://local/index.html")!))
    }

    private var isDark = true

    // "#rrggbb" を色に変える
    private func color(_ hex: String) -> UIColor {
        let n = UInt32(hex.dropFirst(), radix: 16) ?? 0x282c34
        return UIColor(red: CGFloat((n >> 16) & 255) / 255,
                       green: CGFloat((n >> 8) & 255) / 255,
                       blue: CGFloat(n & 255) / 255, alpha: 1)
    }

    private func applyStyle() {
        // 時計などの文字の色を、背景に合わせる
        view.window?.overrideUserInterfaceStyle = isDark ? .dark : .light
        view.window?.backgroundColor = view.backgroundColor
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        applyStyle()
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let code = message.body as? String else { return }
        if message.name == "settings" {
            UserDefaults.standard.set(code, forKey: "settings")
        } else if message.name == "appearance" {
            guard let data = code.data(using: .utf8),
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bg = value["bg"] as? String else { return }
            UserDefaults.standard.set(bg, forKey: "background")
            view.backgroundColor = color(bg)
            isDark = value["dark"] as? Bool ?? true
            applyStyle()
        } else if message.name == "state" {
            UserDefaults.standard.set(code, forKey: "workspace")
        }
    }

    // お知らせの画面
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    // 確認の画面(これがないと「開く」が動かない)
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    // 入力の画面(Pythonの input() 用)
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
            completionHandler(alert.textFields?.first?.text)
        })
        present(alert, animated: true)
    }
}

// 元のファイルを直接読み書きする
@MainActor
final class FileBridge: NSObject, WKScriptMessageHandlerWithReply, UIDocumentPickerDelegate {
    weak var presenter: UIViewController?
    private var waiting: CheckedContinuation<[URL], Never>?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return (nil, "不明な命令です") }
        let id = body["id"] as? String ?? ""
        do {
            switch action {
            case "open":
                let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: false)
                picker.allowsMultipleSelection = true
                var result: [[String: Any]] = []
                for url in await pick(picker) {
                    do {
                        let text = try withAccess(url) { try read(url) }
                        result.append(["id": try remember(url), "name": url.lastPathComponent, "text": text])
                    } catch {
                        result.append(["name": url.lastPathComponent, "error": error.localizedDescription])
                    }
                }
                return (result, nil)
            case "saveAs":
                guard let name = body["name"] as? String, let text = body["text"] as? String else {
                    return (nil, "保存する内容がありません")
                }
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let temp = folder.appendingPathComponent(name)
                try Data(text.utf8).write(to: temp)
                // コピーではなく移動して、移動先をそのまま編集する
                let picker = UIDocumentPickerViewController(forExporting: [temp], asCopy: false)
                guard let url = await pick(picker).first else { return (["cancel": true], nil) }
                let newID = try remember(url)
                return (["id": newID, "name": url.lastPathComponent], nil)
            case "read":
                let url = try find(id)
                let text = try withAccess(url) { try read(url) }
                return (["id": id, "name": url.lastPathComponent, "text": text], nil)
            case "write":
                guard let text = body["text"] as? String else { return (nil, "保存する内容がありません") }
                let url = try find(id)
                let force = body["force"] as? Bool ?? false
                let expected = body["expected"] as? String ?? ""
                let conflict = try withAccess(url) { () throws -> Bool in
                    // 別の場所で変えられていたら、勝手に上書きしない
                    if !force {
                        let now = try read(url)
                        if now != expected { return true }
                    }
                    try write(text, to: url)
                    return false
                }
                if conflict { return (["conflict": true], nil) }
                return (["name": url.lastPathComponent], nil)
            case "close":
                var all = bookmarks
                all[id] = nil
                bookmarks = all
                return (["ok": true], nil)
            default:
                return (nil, "不明な命令です")
            }
        } catch {
            return (nil, error.localizedDescription)
        }
    }

    private func pick(_ picker: UIDocumentPickerViewController) async -> [URL] {
        guard waiting == nil, let presenter, presenter.presentedViewController == nil else { return [] }
        return await withCheckedContinuation { continuation in
            waiting = continuation
            picker.delegate = self
            presenter.present(picker, animated: true)
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

    private func write(_ text: String, to url: URL) throws {
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
        var all = bookmarks
        let old = all.keys.first { key in
            (try? find(key))?.standardizedFileURL.path == url.standardizedFileURL.path
        }
        let id = old ?? UUID().uuidString
        all = bookmarks
        all[id] = try withAccess(url) { try url.bookmarkData() }
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
