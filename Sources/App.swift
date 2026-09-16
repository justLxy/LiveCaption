import AppKit
import SwiftUI
import Carbon

final class SubtitlePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

// 统一的控制按钮样式
struct ControlButton: View {
    let icon: String
    let help: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .help(help)
    }
}

struct SubtitleView: View {
    @ObservedObject var model:AppModel
    private var hovering: Bool { model.hovering }
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            // 控制栏 - 仅悬停时显示
            if hovering {
                HStack(spacing:0) {
                    // 左侧：状态和音频来源
                    HStack(spacing:8) {
                        Circle()
                            .fill(model.running ? Color.mint : Color.gray.opacity(0.5))
                            .frame(width:7,height:7)
                            .help(model.status)

                        Picker("音频来源",selection:Binding(get:{ model.source },set:{ model.selectSource($0) })) {
                            Text("系统音频").tag("system")
                            Text("麦克风").tag("microphone")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(width:110)
                        .disabled(model.busy || model.switchingSource)
                        .help("切换音频来源")
                    }

                    // 中间：可拖动的弹性空间
                    Rectangle()
                        .fill(.clear)
                        .frame(maxWidth:.infinity)
                        .frame(height:28)
                        .overlay(WindowDragRegion())

                    // 右侧：操作按钮
                    HStack(spacing:6) {
                        ControlButton(icon: model.running || model.busy ? "stop.fill" : "play.fill",
                                    help: "开始 / 停止",
                                    disabled: model.switchingSource) {
                            model.toggle()
                        }

                        ControlButton(icon: "slider.horizontal.3", help: "字幕设置") {
                            model.showSettings?()
                        }

                        ControlButton(icon: "minus.circle.fill", help: "隐藏窗口 · ⌥⌘S 恢复") {
                            model.hideWindow?()
                        }

                        ControlButton(icon: "xmark.circle.fill", help: "退出 LumaCaption") {
                            model.quitApp?()
                        }
                    }
                }
                .frame(height:28)
                .foregroundStyle(.white.opacity(0.72))
                .transition(.move(edge:.top).combined(with:.opacity))
            }
            if hovering && (model.busy || model.switchingSource || (!model.running && !model.status.hasPrefix("就绪") && !model.status.hasPrefix("已停止"))) {
                Text(model.switchingSource ? "正在切换音频来源…" : model.status).font(.system(size:11)).foregroundStyle(.white.opacity(0.6)).fixedSize(horizontal:false,vertical:true)
                    .transition(.opacity)
            }
            if hovering && model.displayMode == "history" {
                HStack {
                    Text("长段记录 · \(model.history.entries.count) 段").foregroundStyle(.secondary)
                    Spacer()
                    Button(model.followLatest ? "跟随最新 ✓" : "回到最新 ↓") { model.followLatest.toggle() }.buttonStyle(.plain).foregroundStyle(.mint)
                }.font(.system(size:11))
                    .transition(.opacity)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:18) {
                        if model.displayMode == "history" && !model.history.entries.isEmpty {
                            ForEach(model.history.entries) { entry in
                                VStack(alignment:.leading,spacing:8) {
                                    if model.showEnglish { Text(entry.english).font(.system(size:model.englishFontSize)).foregroundStyle(.white.opacity(0.72)).textSelection(.enabled) }
                                    if model.showChinese { Text(entry.chinese ?? "翻译中…").font(.system(size:model.fontSize,weight:.medium)).foregroundStyle(.white.opacity(entry.chinese == nil ? 0.4 : 1)).lineSpacing(5).textSelection(.enabled) }
                                }.frame(maxWidth:.infinity,alignment:.leading).id(entry.id)
                            }
                        } else {
                            if model.showEnglish && !model.english.isEmpty { Text(model.english).font(.system(size:model.englishFontSize)).foregroundStyle(.white.opacity(0.72)).textSelection(.enabled) }
                            if model.showChinese && !model.chinese.isEmpty { Text(model.chinese).font(.system(size:model.fontSize,weight:.medium)).foregroundStyle(.white).lineSpacing(5).textSelection(.enabled) }
                        }
                        if model.showEnglish && !model.partial.isEmpty {
                            Text("· " + model.partial).font(.system(size:model.englishFontSize)).foregroundStyle(.white.opacity(0.52))
                        }
                        Color.clear.frame(height:1).id("latest")
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                .background(ReadingScrollMonitor { if model.displayMode == "history" { model.followLatest = false } })
                .onChange(of:model.history.entries) { _, _ in if model.followLatest { proxy.scrollTo("latest",anchor:.bottom) } }
                .onChange(of:model.partial) { _, _ in if model.followLatest { proxy.scrollTo("latest",anchor:.bottom) } }
                .onChange(of:model.followLatest) { _, follow in if follow { proxy.scrollTo("latest",anchor:.bottom) } }
                .onChange(of:model.displayMode) { _, _ in if model.followLatest { proxy.scrollTo("latest",anchor:.bottom) } }
            }
            if hovering {
                HStack {
                    Text(model.clickThrough ? "点击穿透 · 菜单栏可关闭" : "⌥⌘S 显示 / 隐藏")
                    Spacer()
                    Text(model.latency)
                }.font(.system(size:10)).foregroundStyle(.white.opacity(0.36))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration:0.2), value: hovering)
        .padding(.horizontal,24).padding(.vertical,17)
        .background(RoundedRectangle(cornerRadius:18).fill(Color(red:0.035,green:0.045,blue:0.06).opacity(model.opacity)))
        .overlay(RoundedRectangle(cornerRadius:18).strokeBorder(.white.opacity(model.opacity == 0 ? 0 : 0.10),lineWidth:1))
        .onHover { model.hovering = $0 }
        .preferredColorScheme(.dark)
    }
}

struct FontSizeControl: View {
    let title:String
    @Binding var size:Double
    var body: some View {
        HStack {
            Text(title).frame(width:70,alignment:.leading)
            Slider(value:$size,in:8...72,step:1).accessibilityLabel(title)
            Text("\(Int(size.rounded())) pt").monospacedDigit().frame(width:48)
            Stepper(title,value:$size,in:8...72,step:1).labelsHidden()
        }
    }
}

struct PreferencesView: View {
    @ObservedObject var model:AppModel
    var body: some View {
        ScrollView {
        VStack(alignment:.leading,spacing:20) {
            HStack { VStack(alignment:.leading,spacing:5) { Text("LumaCaption").font(.system(size:25,weight:.semibold)); Text("本地英中字幕 · Apple Silicon").foregroundStyle(.secondary) }; Spacer(); Image(systemName:"captions.bubble").font(.system(size:32)).foregroundStyle(.mint) }
            Form {
                Picker("显示模式",selection:$model.displayMode) { Text("单句字幕").tag("single"); Text("长段转录与翻译").tag("history") }
                if model.displayMode == "history" {
                    Picker("窗口保留记录",selection:$model.historyLimit) { Text("50 段").tag(50); Text("100 段").tag(100); Text("300 段").tag(300); Text("1000 段").tag(1000) }
                    Text("上滚暂停跟随，可回看英中记录；完整 transcript 始终保存。").font(.caption).foregroundStyle(.secondary)
                }
                Text("识别模型：Nemotron English · 0.6B").font(.caption).foregroundStyle(.secondary)
                Picker("音频来源",selection:Binding(get:{ model.source },set:{ model.selectSource($0) })) { Text("麦克风").tag("microphone"); Text("Mac 系统音频").tag("system") }.disabled(model.busy || model.switchingSource)
                HStack { Text("背景不透明度"); Slider(value:$model.opacity,in:0...1); Text("\(Int(model.opacity*100))%").monospacedDigit().frame(width:40) }
                FontSizeControl(title:"中文字号",size:$model.fontSize)
                FontSizeControl(title:"英文字号",size:$model.englishFontSize)
                Toggle("显示英文（包含即时 partial）",isOn:$model.showEnglish)
                Toggle("显示简体中文",isOn:$model.showChinese)
                Toggle("始终置顶",isOn:$model.onTop)
                Toggle("点击穿透（从菜单栏关闭）",isOn:$model.clickThrough)
            }
            Divider()
            VStack(alignment:.leading,spacing:8) {
                Text("课程术语表").font(.headline)
                Text("每行：English = 中文。仅匹配当前英文的术语会发送给本地翻译模型。").font(.caption).foregroundStyle(.secondary)
                TextEditor(text:$model.glossary).font(.system(size:13,design:.monospaced)).frame(height:120).scrollContentBackground(.hidden).padding(8).background(.quaternary,in:RoundedRectangle(cornerRadius:8))
            }
            HStack {
                Button("打开双语记录") { model.openTranscripts() }
                Button("测试示例音频") { model.start(sampleSeconds:24) }.disabled(model.running || model.busy)
                Spacer()
                Button(model.running || model.busy ? "停止" : "开始字幕") { model.toggle() }.buttonStyle(.borderedProminent).tint(.mint)
            }
            Text("⌥⌘S  隐藏 / 显示悬浮窗。拖动顶部左侧横条移动，拖动边缘缩放。系统音频开始时请选择屏幕并确认共享；仅处理音频，不保存画面。").font(.caption).foregroundStyle(.secondary)
        }.padding(26)
        }.frame(width:560,height: min(760, (NSScreen.main?.visibleFrame.height ?? 850)-100)).preferredColorScheme(.dark)
    }
}

@MainActor
final class AppDelegate:NSObject,NSApplicationDelegate,NSWindowDelegate {
    let model = AppModel()
    var panel:SubtitlePanel!
    var settings:NSWindow?
    var item:NSStatusItem!
    var hotKey:EventHotKeyRef?
    var handler:EventHandlerRef?
    var terminationSignals:[DispatchSourceSignal] = []
    func applicationDidFinishLaunching(_ notification:Notification) {
        NSApp.setActivationPolicy(.accessory)
        panel = SubtitlePanel(contentRect:NSRect(x:160,y:120,width:800,height:238),styleMask:[.borderless,.resizable,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.acceptsMouseMovedEvents = true; panel.isMovableByWindowBackground = false; panel.hidesOnDeactivate = false; panel.isFloatingPanel = true
        panel.level = .floating; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.minSize = NSSize(width:360,height:165); panel.delegate = self
        panel.contentView = NSHostingView(rootView:SubtitleView(model:model))
        if !panel.setFrameUsingName("LumaCaption.Subtitles") { panel.center(); if let screen = panel.screen { var f = panel.frame; f.origin.y = screen.visibleFrame.minY+70; panel.setFrame(f,display:false) } }
        if !NSScreen.screens.contains(where:{$0.visibleFrame.intersects(panel.frame)}) { panel.center() }
        panel.setFrameAutosaveName("LumaCaption.Subtitles")
        model.windowChange = { [weak self] in self?.updatePanel() }
        model.showSettings = { [weak self] in self?.openSettings() }
        model.hideWindow = { [weak self] in self?.panel.orderOut(nil) }
        model.quitApp = { [weak self] in self?.quit() }
        updatePanel()
        if !CommandLine.arguments.contains("--headless") { panel.orderFrontRegardless() }
        item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName:"captions.bubble",accessibilityDescription:"LumaCaption")
        let menu = NSMenu()
        add(menu,"显示 / 隐藏字幕  ⌥⌘S",#selector(togglePanel))
        add(menu,"开始 / 停止字幕",#selector(toggleRecording))
        add(menu,"设置与术语表…",#selector(openSettings))
        add(menu,"切换点击穿透",#selector(toggleThrough))
        add(menu,"打开双语记录",#selector(openTranscripts))
        menu.addItem(.separator()); add(menu,"退出 LumaCaption",#selector(quit),key:"q")
        item.menu = menu
        if CommandLine.arguments.contains("--headless") { NSStatusBar.system.removeStatusItem(item) }
        let appMenu = NSMenu(); let root = NSMenuItem(); appMenu.addItem(root)
        let submenu = NSMenu(); root.submenu = submenu
        add(submenu,"设置…",#selector(openSettings),key:",")
        add(submenu,"退出 LumaCaption",#selector(quit),key:"q")
        NSApp.mainMenu = appMenu
        var spec = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,_,userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in delegate.togglePanel() }; return noErr
        },1,&spec,Unmanaged.passUnretained(self).toOpaque(),&handler)
        let result = CommandLine.arguments.contains("--headless") ? noErr : RegisterEventHotKey(UInt32(kVK_ANSI_S),UInt32(cmdKey | optionKey),EventHotKeyID(signature:0x4C554D41,id:1),GetApplicationEventTarget(),0,&hotKey)
        if result != noErr { model.status = "全局快捷键注册失败，请使用菜单栏显示字幕" }
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal:sig,queue:.main)
            source.setEventHandler { [weak self] in self?.quit() }; source.resume(); terminationSignals.append(source)
        }
        let args = CommandLine.arguments
        if let index = args.firstIndex(of:"--sample-seconds"),args.count > index+1,let seconds = Double(args[index+1]) { model.start(sampleSeconds:seconds) }
    }
    func add(_ menu:NSMenu,_ title:String,_ action:Selector,key:String = "") { let entry = NSMenuItem(title:title,action:action,keyEquivalent:key);entry.target = self;menu.addItem(entry) }
    func updatePanel() { panel.ignoresMouseEvents = model.clickThrough; panel.level = model.onTop ? .floating : .normal
        if model.displayMode == "history", panel.frame.height < 420 {
            var frame = panel.frame; frame.size.height = 420
            if let screen = panel.screen { frame.origin.y = min(frame.origin.y,screen.visibleFrame.maxY-frame.height) }
            panel.setFrame(frame,display:true)
        }
    }
    @objc func togglePanel() { if panel.isVisible { panel.orderOut(nil) } else { panel.orderFrontRegardless() } }
    @objc func toggleRecording() { model.toggle() }
    @objc func toggleThrough() { model.clickThrough.toggle() }
    @objc func openTranscripts() { model.openTranscripts() }
    @objc func openSettings() {
        if settings == nil { settings = NSWindow(contentRect:NSRect(x:0,y:0,width:572,height:660),styleMask:[.titled,.closable],backing:.buffered,defer:false);settings!.title = "LumaCaption 设置";settings!.isReleasedWhenClosed = false; settings!.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+1); settings!.contentView = NSHostingView(rootView:PreferencesView(model:model));settings!.center() }
        settings!.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func quit() { Task { await model.stop(); NSApp.terminate(nil) } }
    func applicationWillTerminate(_ notification:Notification) { model.shutdown(); if let hotKey { UnregisterEventHotKey(hotKey) }; if let handler { RemoveEventHandler(handler) } }
    func windowDidMove(_ notification:Notification) { panel.saveFrame(usingName:"LumaCaption.Subtitles") }
    func windowDidResize(_ notification:Notification) { panel.saveFrame(usingName:"LumaCaption.Subtitles") }
}

@main
struct LumaCaptionMain {
    @MainActor static func main() { let app = NSApplication.shared; let delegate = AppDelegate();app.delegate = delegate;withExtendedLifetime(delegate) { app.run() } }
}
