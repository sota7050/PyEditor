import SwiftUI
import WebKit

// Pythonの実行とゲーム画面。ここだけはWeb表示の部品(WKWebView)を使う
@MainActor
final class Runner: NSObject, ObservableObject, WKScriptMessageHandler, WKUIDelegate, WKNavigationDelegate {
    @Published var ready = false
    @Published var failed = false
    @Published var running = false
    @Published var fullScreen = false
    @Published var showPanel = false
    @Published var output = ""

    let webView: WKWebView
    private var panelSize = CGSize(width: 400, height: 400)
    private var appSize = CGSize(width: 1180, height: 776)

    override init() {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(LocalFiles(), forURLScheme: "app")
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: config)
        super.init()
        webView.configuration.userContentController.add(self, name: "runner")
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        load()
    }

    private func load() {
        webView.load(URLRequest(url: URL(string: "app://local/runner.html")!))
    }

    private func script(_ body: String, _ arguments: [String: Any] = [:]) {
        webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page, completionHandler: nil)
    }

    func setLayout(panel: CGSize, app: CGSize) {
        panelSize = panel
        appSize = app
        sendLayout()
    }

    private func sendLayout() {
        script("if (window.setLayout) window.setLayout(pw, ph, aw, ah);",
               ["pw": Double(panelSize.width), "ph": Double(panelSize.height),
                "aw": Double(appSize.width), "ah": Double(appSize.height)])
    }

    func run(_ source: String) {
        output = ""
        showPanel = true
        running = true
        sendLayout()
        webView.becomeFirstResponder()
        // 終わるのを待たずに始める(終わると "done" が届く)
        script("window.runCode(source); return null;", ["source": source])
    }

    func stop() {
        script("window.stopCode(); return null;")
    }

    func complete(source: String, base: String, prefix: String,
                  done: @escaping ([Completion]) -> Void) {
        guard ready else { return }
        webView.callAsyncJavaScript(
            "return window.completeCode(source, base, prefix);",
            arguments: ["source": source, "base": base, "prefix": prefix],
            in: nil, in: .page
        ) { result in
            guard case .success(let value) = result,
                  let json = value as? String,
                  let list = try? JSONDecoder().decode([[String]].self, from: Data(json.utf8))
            else { return }
            done(list.compactMap { $0.count == 2 ? Completion(name: $0[0], kind: $0[1]) : nil })
        }
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let type = body["type"] as? String else { return }
        let value = body["value"] as? String ?? ""
        switch type {
        case "loaded":
            sendLayout()
        case "ready":
            ready = true
        case "failed":
            failed = true
            showPanel = true
        case "out":
            output = String((output + value).suffix(20000))
        case "screen":
            showPanel = true
            fullScreen = value == "full"
        case "done":
            running = false
            fullScreen = false
        default:
            break
        }
    }

    // 重すぎてWeb部分が止まったときは、読み込み直す
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        ready = false
        running = false
        fullScreen = false
        output += "実行する部分が止まったため、読み込み直します。\n"
        load()
    }

    // お知らせの画面
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        guard let top = Dialog.topController() else { completionHandler(); return }
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        top.present(alert, animated: true)
    }

    // 入力の画面(Pythonの input() 用)
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        guard let top = Dialog.topController() else { completionHandler(nil); return }
        let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
            completionHandler(alert?.textFields?.first?.text)
        })
        top.present(alert, animated: true)
    }
}

struct RunnerView: UIViewRepresentable {
    let runner: Runner
    func makeUIView(context: Context) -> WKWebView { runner.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
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

