import SwiftUI
import WebKit
import UIKit

@main
struct PyEditorApp: App {
    var body: some Scene {
        WindowGroup { EditorView() }
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFiles(), forURLScheme: "app")

        // 前回のコードをWeb画面に渡す
        if let code = UserDefaults.standard.string(forKey: "code"),
           let json = try? JSONEncoder().encode(code),
           let text = String(data: json, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(
                source: "window.nativeCode = \(text);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController.add(self, name: "autosave")
        config.userContentController.add(self, name: "exportFile")

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.uiDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)
        webView.load(URLRequest(url: URL(string: "app://local/index.html")!))
    }

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let code = message.body as? String else { return }
        if message.name == "autosave" {
            UserDefaults.standard.set(code, forKey: "code")
        } else {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("main.py")
            do {
                try code.write(to: file, atomically: true, encoding: .utf8)
                present(UIDocumentPickerViewController(forExporting: [file], asCopy: true),
                        animated: true)
            } catch {
                print(error)
            }
        }
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
