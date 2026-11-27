import SwiftUI
import UIKit

@main
struct PyEditorApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, runner: model.runner)
        }
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var runner: Runner
    @Environment(\.scenePhase) private var scenePhase
    @State private var showSettings = false

    var body: some View {
        let settings = model.settings
        ZStack {
            // 上下の余白やキーボードの周りも、同じ色にする
            settings.color("bg").ignoresSafeArea()
            if runner.fullScreen {
                // 上下の余白も暗くする
                Color.black.opacity(0.6).ignoresSafeArea()
            }
            GeometryReader { proxy in
                workspace(size: proxy.size)
            }
        }
        .foregroundColor(settings.color("fg"))
        .tint(settings.color("func"))
        .preferredColorScheme(settings.isDark ? .dark : .light)
        .sheet(isPresented: $showSettings) {
            SettingsView(model: model)
                .preferredColorScheme(model.settings.isDark ? .dark : .light)
        }
        .onAppear { model.refresh() }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.refresh() } else { model.persist() }
        }
    }

    // 画面全体の配置。ゲーム画面(WebView)は消さずに、場所と大きさだけを変える
    private func workspace(size: CGSize) -> some View {
        let top: CGFloat = 97  // ボタン52 + タブ44 + 線1
        let landscape = size.width >= size.height
        let bodyHeight = max(size.height - top, 1)
        let panelWidth = landscape ? size.width / 2 : size.width
        let panelHeight = landscape ? bodyHeight : bodyHeight / 2
        let panelX = landscape ? size.width - panelWidth : 0
        let panelY = landscape ? top : top + bodyHeight - panelHeight
        let canvasHeight = panelHeight * 0.65
        let editorWidth = runner.showPanel && landscape ? size.width - panelWidth : size.width
        let editorHeight = runner.showPanel && !landscape ? bodyHeight - panelHeight : bodyHeight

        let panelFrame = CGRect(x: panelX, y: panelY, width: panelWidth, height: canvasHeight)
        let fullFrame = CGRect(origin: .zero, size: size)
        let webFrame = runner.fullScreen ? fullFrame : panelFrame
        // 隠すときは、画面の外へ動かす
        let hiddenShift: CGFloat = runner.showPanel || runner.fullScreen ? 0 : size.width * 2

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                toolbar.frame(height: 52)
                TabBar(model: model).frame(height: 44)
                model.settings.color("fg").opacity(0.18).frame(height: 1)
                EditorArea(model: model)
                    .frame(width: editorWidth, height: editorHeight)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(model.settings.color("bg"))

            if runner.showPanel {
                console
                    .frame(width: panelWidth, height: panelHeight - canvasHeight)
                    .position(x: panelX + panelWidth / 2,
                              y: panelY + canvasHeight + (panelHeight - canvasHeight) / 2)
                model.settings.color("fg").opacity(0.18)
                    .frame(width: landscape ? 1 : panelWidth, height: landscape ? panelHeight : 1)
                    .position(x: landscape ? panelX : panelWidth / 2,
                              y: landscape ? panelY + panelHeight / 2 : panelY)
            }

            if runner.fullScreen {
                // 後ろのボタンを押せないようにする
                Color.black.opacity(0.6)
            }

            RunnerView(runner: runner)
                .frame(width: webFrame.width, height: webFrame.height)
                .position(x: webFrame.midX + hiddenShift, y: webFrame.midY)

            if runner.fullScreen {
                Button { runner.stop() } label: {
                    Image(systemName: "stop.fill")
                        .font(.title2)
                        .foregroundColor(model.settings.color("self"))
                        .frame(width: 48, height: 48)
                        .background(Circle().fill(Color.black.opacity(0.6)))
                }
                .position(x: size.width - 32, y: 32)
            }
        }
        .onAppear { runner.setLayout(panel: panelFrame.size, app: size) }
        .onChange(of: [panelFrame.width, panelFrame.height, size.width, size.height]) { v in
            runner.setLayout(panel: CGSize(width: v[0], height: v[1]),
                             app: CGSize(width: v[2], height: v[3]))
        }
    }

    private var toolbar: some View {
        let isPython = model.current.isPython
        return ZStack {
            VStack(spacing: 0) {
                Text(model.current.name).font(.headline).lineLimit(1)
                Text(statusText).font(.caption2)
                    .foregroundColor(model.settings.color("comment"))
            }
            .padding(.horizontal, 230)

            HStack(spacing: 2) {
                icon("doc.badge.plus", "新規") { model.newFile() }
                    .keyboardShortcut("n", modifiers: .command)
                icon("folder", "開く") { model.openFiles() }
                    .keyboardShortcut("o", modifiers: .command)
                icon("folder.badge.gearshape", "作業フォルダ") { model.chooseFolder() }
                icon("square.and.arrow.down", "保存") { model.saveCurrent() }
                    .keyboardShortcut("s", modifiers: .command)
                icon("square.and.arrow.up", "別名で保存") { model.saveCurrent(asNew: true) }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Spacer()
                icon("sidebar.right", "実行画面") { runner.showPanel.toggle() }
                icon("gearshape", "設定") {
                    model.editor.hideCompletions()
                    model.editor.endEditing()
                    showSettings = true
                }
                Button { model.runOrStop() } label: {
                    Image(systemName: runner.running ? "stop.fill" : "play.fill")
                        .font(.title2)
                        .foregroundColor(model.settings.color(runner.running ? "self" : "string"))
                        .frame(width: 48, height: 44)
                }
                .keyboardShortcut("r", modifiers: .command)
                .accessibilityLabel(runner.running ? "停止" : "実行")
                .disabled(!runner.ready || (!runner.running && !isPython))
                .opacity(!runner.ready || (!runner.running && !isPython) ? 0.35 : 1)
            }
            .padding(.horizontal, 8)
        }
    }

    private var statusText: String {
        if runner.failed { return "読み込みに失敗しました" }
        if !runner.ready { return "準備中…" }
        if runner.running { return "実行中" }
        return model.current.isPython ? "準備OK" : "実行できるのは .py だけです"
    }

    private func icon(_ name: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.title3).frame(width: 42, height: 44)
        }
        .accessibilityLabel(label)
    }

    private var console: some View {
        VStack(spacing: 0) {
            model.settings.color("fg").opacity(0.18).frame(height: 1)
            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(runner.output)
                            .font(.system(size: 14, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(10)
                }
                .onChange(of: runner.output) { _ in scroll.scrollTo("end", anchor: .bottom) }
            }
        }
    }
}

struct TabBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.tabs) { tab in
                        item(tab).id(tab.key)
                    }
                }
            }
            .background(Color.black.opacity(0.1))
            .onChange(of: model.activeKey) { key in scroll.scrollTo(key) }
        }
    }

    private func item(_ tab: EditorTab) -> some View {
        let active = tab.key == model.activeKey
        let settings = model.settings
        return HStack(spacing: 0) {
            Button { model.select(tab.key) } label: {
                Text((tab.isDirty ? "● " : "") + tab.name)
                    .font(.subheadline)
                    .lineLimit(1)
                    .padding(.leading, 14)
                    .frame(maxWidth: 220, maxHeight: .infinity)
                    .fixedSize(horizontal: true, vertical: false)
            }
            Button { model.close(tab.key) } label: {
                Image(systemName: "xmark").font(.caption).frame(width: 36, height: 44)
            }
            .accessibilityLabel(tab.name + "を閉じる")
        }
        .buttonStyle(.plain)
        .foregroundColor(settings.color(active ? "fg" : "comment"))
        .background(active ? settings.color("bg") : Color.clear)
        .overlay(alignment: .top) {
            if active { settings.color("func").frame(height: 2) }
        }
        .overlay(alignment: .trailing) { settings.color("fg").opacity(0.18).frame(width: 1) }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                colorSection
                Section("保存") {
                    Toggle("実行するときに元のファイルへ保存する", isOn: $model.settings.saveOnRun)
                    Toggle("入力中も元のファイルへ自動で保存する", isOn: $model.settings.autofile)
                }
                Section("エディタ") {
                    Picker("文字の大きさ", selection: $model.settings.size) {
                        ForEach([12, 14, 16, 18, 20, 22, 24], id: \.self) { Text("\($0)").tag($0) }
                    }
                    Toggle("かっこ・引用符を自動で閉じる", isOn: $model.settings.pair)
                }
                Section("入力補完") {
                    Toggle("入力補完を使う", isOn: $model.settings.complete)
                    Picker("何文字目から候補を出すか", selection: $model.settings.min) {
                        ForEach([1, 2, 3, 4, 5], id: \.self) { Text("\($0)文字目").tag($0) }
                    }
                    Toggle("「.」の直後にも候補を出す", isOn: $model.settings.dot)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }

    private var colorSection: some View {
        Section("色") {
            Picker("テーマ", selection: themeBinding) {
                ForEach(Theme.names, id: \.self) { Text($0).tag($0) }
            }
            ForEach(Theme.editable) { entry in
                ColorPicker(entry.label, selection: colorBinding(entry.id), supportsOpacity: false)
            }
            Button("色をテーマの初期値に戻す") { model.settings.colors = [:] }
        }
    }

    private var themeBinding: Binding<String> {
        Binding(get: { model.settings.theme }, set: { name in
            var next = model.settings
            next.theme = name
            next.colors = [:]
            model.settings = next
        })
    }

    private func colorBinding(_ key: String) -> Binding<Color> {
        Binding(get: { model.settings.color(key) },
                set: { model.settings.colors[key] = UIColor($0).hexString })
    }
}
