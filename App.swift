import SwiftUI
import WebKit
import UIKit

@main
struct PyEditorApp: App {
    var body: some Scene {
        WindowGroup {
            // 画面の端まで背景を広げる(キーボードはよける)
            EditorView().ignoresSafeArea(.container, edges: .all)
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

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = color(UserDefaults.standard.string(forKey: "background") ?? "#282c34")
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
        if let settings = UserDefaults.standard.string(forKey: "settings"),
           let json = try? JSONEncoder().encode(settings),
           let text = String(data: json, encoding: .utf8) {
            config.userContentController.addUserScript(WKUserScript(
                source: "window.nativeSettings = \(text);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        config.userContentController.add(self, name: "settings")
        config.userContentController.add(self, name: "appearance")
        config.userContentController.add(self, name: "autosave")
        config.userContentController.add(self, name: "exportFile")

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
            webView.bottomAnchor.constraint(equalTo: safe.bottomAnchor),
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
        } else if message.name == "autosave" {
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
