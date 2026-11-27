import SwiftUI
import UIKit

struct Completion: Identifiable {
    let name: String
    let kind: String
    var id: String { name }
}

// MARK: - エディタと補完の一覧をつなぐ

@MainActor
final class EditorBridge: ObservableObject {
    @Published var completions: [Completion] = []
    @Published var selected = 0
    @Published var caret = CGRect.zero
    var wordLength = 0
    var request = 0
    weak var coordinator: CodeEditor.Coordinator?

    func hideCompletions() {
        request += 1  // 後から届く古い候補は捨てる
        if !completions.isEmpty { completions = [] }
    }

    func accept(_ i: Int) { coordinator?.accept(i) }

    func endEditing() { coordinator?.textView?.resignFirstResponder() }
}

struct EditorArea: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                CodeEditor(model: model,
                           tabKey: model.activeKey,
                           version: model.textVersion,
                           settings: model.settings,
                           isPython: model.current.isPython)
                CompletionList(bridge: model.editor, settings: model.settings, area: proxy.size)
            }
        }
        .clipped()
    }
}

struct CompletionList: View {
    @ObservedObject var bridge: EditorBridge
    let settings: AppSettings
    let area: CGSize

    var body: some View {
        if !bridge.completions.isEmpty {
            let width = min(300, area.width - 8)
            let height = min(CGFloat(bridge.completions.count) * 38, 190)
            let below = bridge.caret.maxY + 4
            // 下に入らないときは、カーソルの上に出す
            let y = below + height > area.height && bridge.caret.minY > height
                ? bridge.caret.minY - height - 4 : below
            let x = max(4, min(bridge.caret.minX, area.width - width - 4))
            list
                .frame(width: width, height: height)
                .background(settings.color("bg"))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(settings.color("fg").opacity(0.25)))
                .shadow(radius: 8)
                .offset(x: x, y: y)
        }
    }

    private var list: some View {
        ScrollViewReader { scroll in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(bridge.completions.enumerated()), id: \.element.id) { i, item in
                        row(i, item).id(i)
                    }
                }
            }
            .onChange(of: bridge.selected) { i in scroll.scrollTo(i) }
        }
    }

    private func row(_ i: Int, _ item: Completion) -> some View {
        Button { bridge.accept(i) } label: {
            HStack {
                Text(item.name).font(.system(size: 15, design: .monospaced)).lineLimit(1)
                Spacer()
                Text(item.kind).font(.caption).foregroundColor(settings.color("comment"))
            }
            .padding(.horizontal, 10)
            .frame(height: 38)
            .background(i == bridge.selected ? settings.color("fg").opacity(0.18) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 行番号つきの入力欄

final class GutterView: UIView {
    weak var textView: CodeTextView?
    var numberColor = UIColor.gray
    var numberFont = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let manager = textView.layoutManager
        let container = textView.textContainer
        let text = textView.textStorage.string as NSString
        let inset = textView.textContainerInset.top
        let offset = textView.contentOffset.y
        let visible = CGRect(x: 0, y: max(offset - inset, 0),
                             width: container.size.width, height: textView.bounds.height)
        let attributes: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: numberColor]

        func put(_ number: Int, _ y: CGFloat) {
            let label = "\(number)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: bounds.width - size.width - 10, y: y + inset - offset + 2),
                       withAttributes: attributes)
        }

        let glyphs = manager.glyphRange(forBoundingRect: visible, in: container)
        var counted = 0   // ここまでの改行を数え終わった
        var line = 1
        manager.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
            let start = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil).location
            while counted < start {
                if text.character(at: counted) == 10 { line += 1 }
                counted += 1
            }
            // 長い行が折り返した部分には、番号を付けない
            if start == 0 || text.character(at: start - 1) == 10 { put(line, fragment.minY) }
        }
        // 最後の空の行
        if text.length == 0 || text.character(at: text.length - 1) == 10 {
            let total = text.components(separatedBy: "\n").count
            let extra = manager.extraLineFragmentRect
            put(total, extra.minY)
        }
    }
}

final class CodeTextView: UITextView {
    let gutter = GutterView()
    var gutterWidth: CGFloat = 48
    var onKey: ((String) -> Void)?
    var hasCompletions: (() -> Bool)?

    func setUp() {
        gutter.textView = self
        gutter.isOpaque = false
        gutter.backgroundColor = .clear
        gutter.isUserInteractionEnabled = false
        addSubview(gutter)
        autocapitalizationType = .none
        autocorrectionType = .no
        spellCheckingType = .no
        smartQuotesType = .no
        smartDashesType = .no
        smartInsertDeleteType = .no
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gutter.frame = CGRect(x: 0, y: contentOffset.y, width: gutterWidth, height: bounds.height)
        gutter.setNeedsDisplay()
    }

    // 候補が出ている間は、矢印キーなどを候補の操作に使う
    override var keyCommands: [UIKeyCommand]? {
        guard hasCompletions?() == true else { return super.keyCommands }
        let keys = [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputEscape]
        return keys.map { key in
            let command = UIKeyCommand(input: key, modifierFlags: [], action: #selector(completionKey(_:)))
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func completionKey(_ command: UIKeyCommand) {
        if let input = command.input { onKey?(input) }
    }
}

// MARK: - Pythonの文字の分け方

enum Syntax {
    static let pattern = ##"(#[^\n]*)|((?:\b[rRbBfFuU]{1,2})?(?:"""[\s\S]*?(?:"""|$)|'''[\s\S]*?(?:'''|$)|"(?:\\.|[^"\\\n])*"?|'(?:\\.|[^'\\\n])*'?))|(\b\d[\w.]*)|([\p{L}_][\p{L}\p{N}_]*)|([+\-*/%=<>!&|^~]+)"##
    static let token = try! NSRegularExpression(pattern: pattern)

    static let keywords: Set<String> = Set("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield match case".split(separator: " ").map(String.init))
    static let builtins: Set<String> = Set("abs all any bool bytes chr dict dir divmod enumerate filter float format getattr hasattr hex input int isinstance iter len list map max min next object open ord pow print range repr reversed round set setattr slice sorted str sum super tuple type zip".split(separator: " ").map(String.init))

    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: .regularExpression) != nil
    }

    // カーソルが文字列の中なら引用符を、コメントの中なら "#" を返す。どちらでもなければ ""
    static func context(_ before: String) -> String {
        let text = before as NSString
        guard let last = token.matches(in: before, range: NSRange(location: 0, length: text.length)).last,
              NSMaxRange(last.range) == text.length else { return "" }
        if last.range(at: 1).location != NSNotFound { return "#" }
        if last.range(at: 2).location == NSNotFound { return "" }
        let whole = text.substring(with: last.range(at: 2))
        let quoted = String(whole.drop { $0.isLetter })
        guard let quote = quoted.first else { return "" }
        let triple = String(repeating: quote, count: 3)
        let mark = quoted.hasPrefix(triple) ? triple : String(quote)
        let closed = quoted.count >= mark.count * 2 && quoted.hasSuffix(mark)
        return closed ? "" : String(quote)
    }

    static func highlight(_ storage: NSTextStorage, settings: AppSettings, font: UIFont, python: Bool) {
        let source = storage.string
        let text = source as NSString
        let all = NSRange(location: 0, length: text.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = (" " as NSString).size(withAttributes: [.font: font]).width * 4
        paragraph.tabStops = []
        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: settings.uiColor("fg"),
                               .paragraphStyle: paragraph], range: all)
        // 非常に長いファイルは、軽くするために色分けしない
        if python && text.length <= 100_000 {
            var colors: [String: UIColor] = [:]
            for key in ["comment", "string", "number", "keyword", "type", "func", "self", "builtin"] {
                colors[key] = settings.uiColor(key)
            }
            var previous = ""
            for match in token.matches(in: source, range: all) {
                var key: String?
                if match.range(at: 1).location != NSNotFound {
                    key = "comment"
                } else if match.range(at: 2).location != NSNotFound {
                    key = "string"
                } else if match.range(at: 3).location != NSNotFound {
                    key = "number"
                } else if match.range(at: 5).location != NSNotFound {
                    key = "builtin"
                } else {
                    let word = text.substring(with: match.range)
                    let end = NSMaxRange(match.range)
                    var next = end
                    while next < text.length && (text.character(at: next) == 32 || text.character(at: next) == 9) {
                        next += 1
                    }
                    let call = next < text.length && text.character(at: next) == 40
                    let afterDot = match.range.location > 0 && text.character(at: match.range.location - 1) == 46
                    if word == "True" || word == "False" || word == "None" { key = "number" }
                    else if keywords.contains(word) { key = "keyword" }
                    else if previous == "class" { key = "type" }
                    else if previous == "def" { key = "func" }
                    else if word == "self" { key = "self" }
                    else if builtins.contains(word) && !afterDot { key = "builtin" }
                    else if call { key = "func" }
                    previous = word
                }
                if let key, let color = colors[key] {
                    storage.addAttribute(.foregroundColor, value: color, range: match.range)
                }
            }
        }
        storage.endEditing()
    }
}

// MARK: - SwiftUIに組みこむ

struct CodeEditor: UIViewRepresentable {
    let model: AppModel
    let tabKey: String
    let version: Int
    let settings: AppSettings
    let isPython: Bool

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeUIView(context: Context) -> CodeTextView {
        let view = CodeTextView(frame: .zero, textContainer: nil)
        // 行番号の位置を調べやすい方式(TextKit 1)に切りかえる
        _ = view.layoutManager
        view.setUp()
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: CodeTextView, context: Context) {
        context.coordinator.update(view, key: tabKey, version: version,
                                   settings: settings, isPython: isPython)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        private let model: AppModel
        private var bridge: EditorBridge { model.editor }
        weak var textView: CodeTextView?

        private var key = ""
        private var version = -1
        private var settings = AppSettings()
        private var isPython = true
        private var applying = false   // プログラムから内容を変えている間は true
        private var typed = false
        private var shownAt = 0         // 候補を出したときのカーソルの位置
        private var positions: [String: (NSRange, CGPoint)] = [:]

        init(model: AppModel) {
            self.model = model
        }

        func attach(_ view: CodeTextView) {
            textView = view
            bridge.coordinator = self
            view.hasCompletions = { [weak self] in !(self?.bridge.completions.isEmpty ?? true) }
            view.onKey = { [weak self] key in self?.completionKey(key) }
        }

        private var font: UIFont {
            UIFont.monospacedSystemFont(ofSize: CGFloat(settings.size), weight: .regular)
        }

        func update(_ view: CodeTextView, key newKey: String, version newVersion: Int,
                    settings newSettings: AppSettings, isPython newPython: Bool) {
            let switched = newKey != key
            let reload = switched || newVersion != version
            let restyle = reload || newSettings != settings || newPython != isPython
            if !restyle { return }
            if switched && !key.isEmpty { positions[key] = (view.selectedRange, view.contentOffset) }
            key = newKey
            version = newVersion
            settings = newSettings
            isPython = newPython

            view.backgroundColor = settings.uiColor("bg")
            view.tintColor = settings.uiColor("func")
            view.keyboardAppearance = settings.isDark ? .dark : .light
            view.gutterWidth = CGFloat(settings.size) * 3
            view.textContainerInset = UIEdgeInsets(top: 8, left: view.gutterWidth, bottom: 8, right: 8)
            view.gutter.numberColor = settings.uiColor("fg").withAlphaComponent(0.4)
            view.gutter.numberFont = UIFont.monospacedSystemFont(ofSize: CGFloat(settings.size) - 2, weight: .regular)

            applying = true
            if reload, let tab = model.tabs.first(where: { $0.key == newKey }) {
                view.text = tab.text
                view.undoManager?.removeAllActions()
                let length = (tab.text as NSString).length
                let saved = positions[newKey]
                let location = min(saved?.0.location ?? 0, length)
                view.selectedRange = NSRange(location: location, length: 0)
                view.setContentOffset(saved?.1 ?? .zero, animated: false)
            }
            restyleText(view)
            applying = false
            view.setNeedsLayout()
            DispatchQueue.main.async { [weak self] in self?.bridge.hideCompletions() }
        }

        private func restyleText(_ view: CodeTextView) {
            let selection = view.selectedRange
            Syntax.highlight(view.textStorage, settings: settings, font: font, python: isPython)
            view.typingAttributes = [.font: font, .foregroundColor: settings.uiColor("fg")]
            view.selectedRange = selection
            view.gutter.setNeedsDisplay()
        }

        // MARK: 文字の入れかえ(「元に戻す」が使える方法)

        private func replace(_ range: NSRange, with text: String, cursor: Int? = nil, length: Int = 0,
                             suggestAfter: Bool = true) {
            guard let view = textView,
                  let start = view.position(from: view.beginningOfDocument, offset: range.location),
                  let end = view.position(from: start, offset: range.length),
                  let target = view.textRange(from: start, to: end) else { return }
            applying = true
            view.replace(target, withText: text)
            if let cursor { view.selectedRange = NSRange(location: cursor, length: length) }
            applying = false
            typed = true
            changed(view)
            if suggestAfter { suggestSoon() }
        }

        private func changed(_ view: CodeTextView) {
            // 日本語の変換中は、色を変えない
            if view.markedTextRange == nil { restyleText(view) }
            model.edited(key, view.text)
            view.setNeedsLayout()
        }

        func textViewDidChange(_ textView: UITextView) {
            guard !applying, let view = textView as? CodeTextView else { return }
            changed(view)
            if typed { suggestSoon() } else { bridge.hideCompletions() }
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            if applying || bridge.completions.isEmpty { return }
            if textView.selectedRange.location != shownAt { bridge.hideCompletions() }
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            bridge.hideCompletions()
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            scrollView.setNeedsLayout()
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            typed = false
            bridge.hideCompletions()
        }

        // MARK: かっこ・引用符・字下げ

        func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange,
                      replacementText input: String) -> Bool {
            typed = input.count <= 1
            if textView.markedTextRange != nil { return true }

            if (input == "\n" || input == "\t") && !bridge.completions.isEmpty {
                accept(bridge.selected)
                return false
            }

            let text = textView.text as NSString
            let pairs: [String: String] = ["(": ")", "[": "]", "{": "}", "\"": "\"", "'": "'"]
            let start = range.location
            let before = text.substring(to: start)
            let end = NSMaxRange(range)
            let next = end < text.length ? text.substring(with: NSRange(location: end, length: 1)) : ""
            let previousBreak = (before as NSString).range(of: "\n", options: .backwards)
            let line = previousBreak.location == NSNotFound
                ? before : (before as NSString).substring(from: previousBreak.location + 1)

            if input == "\t" {
                replace(range, with: "    ", cursor: start + 4)
                return false
            }

            if input == "\n" {
                var indent = String(line.prefix { $0 == " " })
                let open = before.last.map { String($0) } ?? ""
                if settings.pair && ["(", "[", "{"].contains(open) && pairs[open] == next {
                    let first = "\n" + indent + "    "
                    replace(range, with: first + "\n" + indent, cursor: start + (first as NSString).length)
                } else {
                    if line.trimmingCharacters(in: .whitespaces).hasSuffix(":") { indent += "    " }
                    replace(range, with: "\n" + indent, cursor: start + 1 + (indent as NSString).length)
                }
                return false
            }

            // 削除キー
            if input.isEmpty && range.length == 1 && textView.selectedRange.length == 0 {
                let removed = text.substring(with: range)
                if settings.pair && !next.isEmpty && pairs[removed] == next {
                    replace(NSRange(location: start, length: 2), with: "", cursor: start)
                    return false
                }
                let head = text.substring(to: end)
                let headLine = head.components(separatedBy: "\n").last ?? ""
                if !headLine.isEmpty && headLine.allSatisfy({ $0 == " " }) {
                    let count = (headLine.count - 1) % 4 + 1
                    replace(NSRange(location: end - count, length: count), with: "", cursor: end - count)
                    return false
                }
                return true
            }

            if (input as NSString).length != 1 { return true }
            // 曲がった引用符は、まっすぐなものに直す
            let straight = ["\u{2018}": "'", "\u{2019}": "'", "\u{201C}": "\"", "\u{201D}": "\""]
            let ch = straight[input] ?? input
            let curly = ch != input
            let isQuote = ch == "\"" || ch == "'"
            let place = isPython ? Syntax.context(before) : ""

            // すでにある閉じる文字は、飛びこえるだけ
            if settings.pair && range.length == 0 && next == ch
                && ([")", "]", "}"].contains(ch) || (isQuote && place != "#")) {
                applying = true
                textView.selectedRange = NSRange(location: start + 1, length: 0)
                applying = false
                bridge.hideCompletions()
                return false
            }
            if !place.isEmpty {
                if curly && place == ch {
                    replace(range, with: ch, cursor: start + 1)
                    return false
                }
                return true
            }
            if settings.pair, let close = pairs[ch] {
                if range.length > 0 {  // 選んだ文字を囲む
                    let inside = text.substring(with: range)
                    replace(range, with: ch + inside + close, cursor: start + 1, length: range.length)
                    return false
                }
                let free = next.isEmpty || Syntax.matches("^[\\s)\\]},:.]", next)
                if isQuote {
                    if before.hasSuffix(ch + ch) && free {
                        replace(range, with: String(repeating: ch, count: 4), cursor: start + 1)
                        return false
                    }
                    let wordPart = String(line.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "_" }.reversed())
                    let prefixes = ["r", "u", "b", "f", "rb", "br", "rf", "fr"]
                    if free && (wordPart.isEmpty || prefixes.contains(wordPart.lowercased())) {
                        replace(range, with: ch + ch, cursor: start + 1)
                        return false
                    }
                } else if free {
                    replace(range, with: ch + close, cursor: start + 1)
                    return false
                }
            }
            if curly {
                replace(range, with: ch, cursor: start + 1)
                return false
            }
            return true
        }

        // replaceは中で候補を調べないので、ここで予約する
        private func suggestSoon() {
            DispatchQueue.main.async { [weak self] in self?.suggest() }
        }

        // MARK: 入力補完

        private func suggest() {
            guard let view = textView, isPython, settings.complete, view.isFirstResponder,
                  view.markedTextRange == nil, view.selectedRange.length == 0 else {
                bridge.hideCompletions()
                return
            }
            let text = view.text as NSString
            let position = view.selectedRange.location
            let before = text.substring(to: position)
            let lastLine = before.components(separatedBy: "\n").last ?? ""

            let finder = try! NSRegularExpression(
                pattern: #"(?:([\p{L}_][\p{L}\p{N}_]*(?:\.[\p{L}_][\p{L}\p{N}_]*)*)\.)?([\p{L}_][\p{L}\p{N}_]*)?$"#)
            let lineText = lastLine as NSString
            var base = ""
            var prefix = ""
            if let m = finder.firstMatch(in: lastLine, range: NSRange(location: 0, length: lineText.length)) {
                if m.range(at: 1).location != NSNotFound { base = lineText.substring(with: m.range(at: 1)) }
                if m.range(at: 2).location != NSNotFound { prefix = lineText.substring(with: m.range(at: 2)) }
            }
            let enough = !base.isEmpty && prefix.isEmpty ? settings.dot : prefix.count >= settings.min
            let next = position < text.length ? text.substring(with: NSRange(location: position, length: 1)) : ""
            let orphanDot = base.isEmpty && String(lastLine.dropLast(prefix.count)).hasSuffix(".")
            if !enough || (base.isEmpty && prefix.isEmpty) || orphanDot
                || Syntax.matches("^[\\p{L}\\p{N}_]", next) || !Syntax.context(before).isEmpty {
                bridge.hideCompletions()
                return
            }

            bridge.request += 1
            let request = bridge.request
            let source: String = view.text
            model.runner.complete(source: source, base: base, prefix: prefix) { [weak self] items in
                guard let self, let view = self.textView, request == self.bridge.request,
                      view.text == source, view.selectedRange.location == position,
                      let cursor = view.selectedTextRange?.start else { return }
                let rect = view.caretRect(for: cursor)
                self.bridge.caret = rect.offsetBy(dx: 0, dy: -view.contentOffset.y)
                self.bridge.wordLength = (prefix as NSString).length
                self.bridge.selected = 0
                self.shownAt = position
                self.bridge.completions = items
            }
        }

        private func completionKey(_ input: String) {
            let count = bridge.completions.count
            if count == 0 { return }
            if input == UIKeyCommand.inputEscape {
                bridge.hideCompletions()
            } else {
                let step = input == UIKeyCommand.inputDownArrow ? 1 : -1
                bridge.selected = (bridge.selected + step + count) % count
            }
        }

        func accept(_ i: Int) {
            guard let view = textView, bridge.completions.indices.contains(i) else { return }
            let name = bridge.completions[i].name
            let end = view.selectedRange.location
            let start = max(end - bridge.wordLength, 0)
            bridge.hideCompletions()
            replace(NSRange(location: start, length: end - start), with: name,
                    cursor: start + (name as NSString).length, suggestAfter: false)
            typed = false
        }
    }
}
