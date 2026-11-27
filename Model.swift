import SwiftUI
import UIKit

// MARK: - 色と設定

enum Theme {
    static let names = ["One Dark Pro Flat", "ライト", "Monokai風", "ブラック"]

    static let all: [String: [String: String]] = [
        "One Dark Pro Flat": ["bg": "#282c34", "fg": "#abb2bf", "keyword": "#c678dd", "string": "#98c379",
                              "number": "#d19a66", "func": "#61afef", "builtin": "#56b6c2",
                              "comment": "#7f848e", "type": "#e5c07b", "self": "#e06c75"],
        "ライト": ["bg": "#fafafa", "fg": "#383a42", "keyword": "#a626a4", "string": "#3d7f3c",
                 "number": "#986801", "func": "#2f66d0", "builtin": "#0b7285",
                 "comment": "#808189", "type": "#a36f00", "self": "#ca3e35"],
        "Monokai風": ["bg": "#272822", "fg": "#f8f8f2", "keyword": "#f92672", "string": "#e6db74",
                     "number": "#ae81ff", "func": "#a6e22e", "builtin": "#66d9ef",
                     "comment": "#8f8a73", "type": "#66d9ef", "self": "#fd971f"],
        "ブラック": ["bg": "#000000", "fg": "#d4d4d4", "keyword": "#c586c0", "string": "#ce9178",
                  "number": "#b5cea8", "func": "#4fc1ff", "builtin": "#4ec9b0",
                  "comment": "#6a9955", "type": "#dcdcaa", "self": "#f44747"]
    ]

    struct Item: Identifiable {
        let id: String
        let label: String
    }

    static let editable: [Item] = [
        Item(id: "bg", label: "背景"), Item(id: "fg", label: "ふつうの文字"),
        Item(id: "keyword", label: "キーワード（if など）"), Item(id: "string", label: "文字列"),
        Item(id: "number", label: "数字"), Item(id: "func", label: "関数・ボタン"),
        Item(id: "builtin", label: "組み込み・記号"), Item(id: "comment", label: "コメント")
    ]
}

struct AppSettings: Codable, Equatable {
    var theme = "One Dark Pro Flat"
    var colors: [String: String] = [:]
    var size = 16
    var autofile = false
    var saveOnRun = true
    var pair = true
    var complete = true
    var min = 1
    var dot = true

    init() {}

    // 前の版の設定に足りない項目があっても読めるようにする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        theme = (try? c.decode(String.self, forKey: .theme)) ?? theme
        colors = (try? c.decode([String: String].self, forKey: .colors)) ?? colors
        size = (try? c.decode(Int.self, forKey: .size)) ?? size
        autofile = (try? c.decode(Bool.self, forKey: .autofile)) ?? autofile
        saveOnRun = (try? c.decode(Bool.self, forKey: .saveOnRun)) ?? saveOnRun
        pair = (try? c.decode(Bool.self, forKey: .pair)) ?? pair
        complete = (try? c.decode(Bool.self, forKey: .complete)) ?? complete
        min = (try? c.decode(Int.self, forKey: .min)) ?? min
        dot = (try? c.decode(Bool.self, forKey: .dot)) ?? dot
    }

    func hex(_ key: String) -> String {
        colors[key] ?? Theme.all[theme]?[key] ?? Theme.all["One Dark Pro Flat"]?[key] ?? "#808080"
    }

    func uiColor(_ key: String) -> UIColor { UIColor(hexString: hex(key)) }

    func color(_ key: String) -> Color { Color(uiColor: uiColor(key)) }

    var isDark: Bool {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor("bg").getRed(&r, green: &g, blue: &b, alpha: &a)
        return r * 0.299 + g * 0.587 + b * 0.114 < 0.55
    }
}

extension UIColor {
    convenience init(hexString: String) {
        let n = UInt32(hexString.dropFirst(), radix: 16) ?? 0x808080
        self.init(red: CGFloat((n >> 16) & 255) / 255,
                  green: CGFloat((n >> 8) & 255) / 255,
                  blue: CGFloat(n & 255) / 255, alpha: 1)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        getRed(&r, green: &g, blue: &b, alpha: &a)
        func byte(_ v: CGFloat) -> Int { Int((Swift.min(Swift.max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
    }
}

// MARK: - タブ

struct EditorTab: Codable, Identifiable {
    var key = UUID().uuidString
    var name: String
    var text: String
    var fileId: String? = nil   // 元のファイルを覚えておく番号
    var disk: String? = nil     // 最後に読み書きした、ファイルそのままの内容
    var saved: String = ""

    var id: String { key }
    var isDirty: Bool { text != saved }
    var isPython: Bool { name.lowercased().hasSuffix(".py") }

    static func clean(_ text: String) -> String {
        var t = text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        if t.hasPrefix("\u{FEFF}") { t.removeFirst() }
        return t
    }

    // 元のファイルの改行の形に合わせる
    func diskText(_ value: String) -> String {
        // "\r\n" は1文字として扱われるので、unicodeScalarsで調べる
        let windows = disk?.unicodeScalars.contains("\r") ?? false
        return windows ? value.replacingOccurrences(of: "\n", with: "\r\n") : value
    }
}

private struct SavedWorkspace: Codable {
    var tabs: [EditorTab]
    var active: String
}

let sampleCode = """
import pygame

pygame.init()
screen = pygame.display.set_mode((400, 300))
clock = pygame.time.Clock()
x, y = 200, 150

running = True
while running:
    for event in pygame.event.get():
        if event.type == pygame.QUIT:
            running = False
        if event.type == pygame.MOUSEBUTTONDOWN:
            x, y = event.pos

    screen.fill((30, 30, 60))
    pygame.draw.circle(screen, (255, 200, 0), (x, y), 30)
    pygame.display.flip()
    clock.tick(60)

"""

// MARK: - アプリの状態

@MainActor
final class AppModel: ObservableObject {
    @Published var tabs: [EditorTab] = []
    @Published var activeKey = ""
    @Published var textVersion = 0   // 外から内容を変えたときに増やす
    @Published var settings = AppSettings() {
        didSet { saveSettings() }
    }

    let runner = Runner()
    let editor = EditorBridge()
    private let files = FileStore()

    private var saving: Set<String> = []
    private var saveAgain: Set<String> = []
    private var paused: Set<String> = []
    private var autoTasks: [String: Task<Void, Never>] = [:]
    private var persistTask: Task<Void, Never>?
    private var busyDialog = false

    var current: EditorTab {
        tabs.first { $0.key == activeKey } ?? tabs[0]
    }

    init() {
        let store = UserDefaults.standard
        if let data = store.string(forKey: "settings")?.data(using: .utf8),
           let value = try? JSONDecoder().decode(AppSettings.self, from: data) {
            settings = value
        }
        if let data = store.string(forKey: "workspace")?.data(using: .utf8),
           let value = try? JSONDecoder().decode(SavedWorkspace.self, from: data),
           !value.tabs.isEmpty {
            tabs = value.tabs
            activeKey = tabs.contains { $0.key == value.active } ? value.active : tabs[0].key
        } else {
            let code = store.string(forKey: "code") ?? sampleCode
            let tab = EditorTab(name: "main.py", text: code)
            tabs = [tab]
            activeKey = tab.key
        }
    }

    private func index(_ key: String) -> Int? {
        tabs.firstIndex { $0.key == key }
    }

    private func saveSettings() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "settings")
        }
    }

    func persist() {
        persistTask?.cancel()
        let value = SavedWorkspace(tabs: tabs, active: activeKey)
        if let data = try? JSONEncoder().encode(value) {
            UserDefaults.standard.set(String(data: data, encoding: .utf8), forKey: "workspace")
        }
    }

    private func persistSoon() {
        persistTask?.cancel()
        persistTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { persist() }
        }
    }

    // エディタで文字が変わったとき
    func edited(_ key: String, _ text: String) {
        guard let i = index(key), tabs[i].text != text else { return }
        tabs[i].text = text
        persistSoon()
        scheduleAutoSave(key)
    }

    func select(_ key: String) {
        editor.hideCompletions()
        activeKey = key
        persist()
    }

    private func add(_ tab: EditorTab) {
        tabs.append(tab)
        select(tab.key)
    }

    func newFile() {
        guard !busyDialog else { return }
        busyDialog = true
        Task {
            defer { busyDialog = false }
            guard let input = await Dialog.prompt("新しいファイルの名前（例：game.py）", value: "untitled.py")
            else { return }
            let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty { return }
            if name.contains("/") || name.contains(":") {
                await Dialog.notify("名前に / や : は使えません。")
                return
            }
            add(EditorTab(name: name, text: ""))
        }
    }

    func close(_ key: String) {
        Task {
            guard let first = index(key) else { return }
            if tabs[first].isDirty {
                let ok = await Dialog.ask("「\(tabs[first].name)」の変更はファイルに保存されていません。保存せずに閉じますか？")
                if !ok { return }
            }
            guard let i = index(key) else { return }
            autoTasks[key]?.cancel()
            if let fileId = tabs[i].fileId { files.forget(fileId) }
            tabs.remove(at: i)
            if tabs.isEmpty { tabs.append(EditorTab(name: "untitled.py", text: "")) }
            if activeKey == key { select(tabs[min(i, tabs.count - 1)].key) }
            persist()
        }
    }

    func openFiles() {
        Task {
            for result in await files.open() {
                switch result {
                case .failure(let error):
                    await Dialog.notify("ファイルを開けませんでした。\n" + error.localizedDescription)
                case .success(let file):
                    if let i = tabs.firstIndex(where: { $0.fileId == file.id }) {
                        if !tabs[i].isDirty { apply(file, at: i) }
                        select(tabs[i].key)
                    } else {
                        let text = EditorTab.clean(file.text)
                        add(EditorTab(name: file.name, text: text, fileId: file.id,
                                      disk: file.text, saved: text))
                    }
                }
            }
            persist()
        }
    }

    private func apply(_ file: OpenedFile, at i: Int) {
        let text = EditorTab.clean(file.text)
        let changed = tabs[i].text != text
        tabs[i].name = file.name
        tabs[i].disk = file.text
        tabs[i].text = text
        tabs[i].saved = text
        if changed && tabs[i].key == activeKey { textVersion += 1 }
    }

    // ほかのアプリで変えた内容を読み直す(未保存のタブは変えない)
    func refresh() {
        for i in tabs.indices {
            guard let fileId = tabs[i].fileId, !tabs[i].isDirty, !saving.contains(tabs[i].key),
                  let file = try? files.load(fileId), file.text != tabs[i].disk else { continue }
            apply(file, at: i)
        }
        persist()
    }

    func saveCurrent(asNew: Bool = false) {
        let key = activeKey
        Task { await save(key, asNew: asNew) }
    }

    private func save(_ key: String, asNew: Bool = false, automatic: Bool = false) async {
        if saving.contains(key) {
            if automatic { saveAgain.insert(key) }
            return
        }
        guard let start = index(key) else { return }
        saving.insert(key)
        autoTasks[key]?.cancel()
        let tab = tabs[start]
        let text = tab.text
        let data = tab.diskText(text)
        var retryAsNew = false

        do {
            if let fileId = tab.fileId, !asNew {
                var done = try files.write(fileId, text: data, expected: tab.disk ?? "", force: false)
                if !done {
                    if await Dialog.ask("「\(tab.name)」は、ほかの場所で変更されています。今の内容で上書きしますか？") {
                        done = try files.write(fileId, text: data, expected: "", force: true)
                    } else {
                        paused.insert(key)
                    }
                }
                if done, let i = index(key) {
                    tabs[i].disk = data
                    tabs[i].saved = text
                    paused.remove(key)
                }
            } else if let file = try await files.saveAs(name: tab.name, text: data) {
                // 同じファイルを開いていた別のタブは、つながりを外す
                for j in tabs.indices where tabs[j].key != key && tabs[j].fileId == file.id {
                    tabs[j].fileId = nil
                    tabs[j].disk = nil
                    tabs[j].saved = ""
                }
                if let i = index(key) {
                    if let old = tabs[i].fileId, old != file.id { files.forget(old) }
                    tabs[i].fileId = file.id
                    tabs[i].name = file.name
                    tabs[i].disk = data
                    tabs[i].saved = text
                    paused.remove(key)
                }
            }
        } catch {
            paused.insert(key)
            if !asNew && tab.fileId != nil {
                retryAsNew = await Dialog.ask("「\(tab.name)」を保存できませんでした。\n\(error.localizedDescription)\n別の場所に保存しますか？")
            } else {
                await Dialog.notify("保存できませんでした。内容はタブに残っています。\n" + error.localizedDescription)
            }
        }

        saving.remove(key)
        persist()
        if retryAsNew {
            await save(key, asNew: true)
            return
        }
        let again = saveAgain.remove(key) != nil
        if again, !paused.contains(key), let i = index(key), tabs[i].isDirty {
            await save(key, automatic: true)
        } else if let i = index(key), tabs[i].text != text {
            scheduleAutoSave(key)
        }
    }

    private func scheduleAutoSave(_ key: String) {
        autoTasks[key]?.cancel()
        guard settings.autofile, !paused.contains(key),
              let i = index(key), tabs[i].fileId != nil else { return }
        autoTasks[key] = Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled || !settings.autofile { return }
            guard let j = index(key), tabs[j].isDirty, !paused.contains(key) else { return }
            // この待ち時間の作業を取り消さないように、別の作業として保存する
            Task { await save(key, automatic: true) }
        }
    }

    func runOrStop() {
        if runner.running {
            runner.stop()
            return
        }
        let tab = current
        guard runner.ready, tab.isPython else { return }
        editor.hideCompletions()
        editor.endEditing()
        // 元のファイルがあるタブだけ保存する(新しいファイルは保存場所が未定)
        if settings.saveOnRun && tab.fileId != nil && tab.isDirty {
            Task { await save(tab.key, automatic: true) }
        }
        runner.run(tab.text)
    }
}

// MARK: - お知らせや確認の画面

@MainActor
enum Dialog {
    static func topController() -> UIViewController? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
        var top = (windows.first { $0.isKeyWindow } ?? windows.first)?.rootViewController
        while let next = top?.presentedViewController, !next.isBeingDismissed {
            top = next
        }
        return top
    }

    // 画面が閉じ終わるのを待つ
    private static func pause() async {
        try? await Task.sleep(nanoseconds: 450_000_000)
    }

    static func notify(_ message: String) async {
        guard let top = topController() else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume() })
            top.present(alert, animated: true)
        }
        await pause()
    }

    static func ask(_ message: String) async -> Bool {
        guard let top = topController() else { return false }
        let answer = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in done.resume(returning: false) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in done.resume(returning: true) })
            top.present(alert, animated: true)
        }
        await pause()
        return answer
    }

    static func prompt(_ message: String, value: String) async -> String? {
        guard let top = topController() else { return nil }
        let answer = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
            alert.addTextField {
                $0.text = value
                $0.autocapitalizationType = .none
                $0.autocorrectionType = .no
            }
            alert.addAction(UIAlertAction(title: "キャンセル", style: .cancel) { _ in done.resume(returning: nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in
                done.resume(returning: alert?.textFields?.first?.text)
            })
            top.present(alert, animated: true)
        }
        await pause()
        return answer
    }
}
