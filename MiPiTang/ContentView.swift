import SwiftUI
import UIKit
import WebKit
import CryptoKit

// MARK: - 网页开关偏好（震动 / 自动更新）

/// 网页里的开关状态，网页那边会 postMessage 过来；未写入过 → 默认 true
enum Prefs {
    static let vibrateKey = "UserVibrateEnabled"
    static let autoUpdateKey = "UserAutoUpdateEnabled"

    /// UserDefaults.bool 在键不存在时返回 false，这里改用 object 判空 → 缺省为 true
    static func flag(_ key: String) -> Bool {
        let d = UserDefaults.standard
        guard d.object(forKey: key) != nil else { return true }
        return d.bool(forKey: key)
    }

    static func setFlag(_ key: String, _ value: Bool) {
        UserDefaults.standard.set(value, forKey: key)
    }
}

// MARK: - 触觉反馈（震动）

/// 三种力度：light 普通 / medium 重要 / heavy 警报
enum Haptics {
    private static let lightGen = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGen = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGen = UIImpactFeedbackGenerator(style: .heavy)
    private static let selectGen = UISelectionFeedbackGenerator()
    private static var lastAt: TimeInterval = 0

    static func prepare() {
        lightGen.prepare()
        mediumGen.prepare()
        heavyGen.prepare()
        selectGen.prepare()
    }

    static func play(_ type: String) {
        // 网页里关了震动：原生侧也拦（双保险）
        guard Prefs.flag(Prefs.vibrateKey) else { return }
        // 限流：70ms 内重复触发只算一次，避免连点狂震
        let now = Date().timeIntervalSince1970
        // heavy 是重要事件，即使紧跟按钮轻震也要放行
        if type != "heavy" && now - lastAt < 0.07 { return }
        lastAt = now

        switch type {
        case "heavy":
            heavyGen.impactOccurred()
            heavyGen.prepare()
        case "medium":
            mediumGen.impactOccurred()
            mediumGen.prepare()
        case "selection":
            selectGen.selectionChanged()
            selectGen.prepare()
        default:
            lightGen.impactOccurred()
            lightGen.prepare()
        }
    }
}

/// 网页 JS → 原生 的震动通道
final class HapticBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "haptic", let type = message.body as? String else { return }
        Haptics.play(type)
    }
}

/// 网页 JS → 原生 的开关通道：{ vibrate: Bool, autoUpdate: Bool }
final class SettingsBridge: NSObject, WKScriptMessageHandler {
    /// 用来触发「检查更新」；设为 weak，Coordinator 强持有本对象
    weak var coordinator: WebView.Coordinator?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "settings", let payload = SettingsBridge.dict(from: message.body) else { return }

        // 网页「设置 → 检查更新」按钮：立刻问云端
        if SettingsBridge.boolValue(payload["checkUpdate"]) == true {
            coordinator?.manualCheck()
            return
        }

        // 只写过来的字段；没传的字段不动（避免一个开关把另一个覆盖成默认值）
        if let v = SettingsBridge.boolValue(payload["vibrate"]) {
            Prefs.setFlag(Prefs.vibrateKey, v)
        }
        if let a = SettingsBridge.boolValue(payload["autoUpdate"]) {
            Prefs.setFlag(Prefs.autoUpdateKey, a)
        }
    }

    /// 兼容两种传法：直接传对象，或传 JSON 字符串
    private static func dict(from body: Any) -> [String: Any]? {
        if let d = body as? [String: Any] { return d }
        guard let s = body as? String,
              let data = s.data(using: .utf8),
              let d = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return d
    }

    /// JS 的 true/false 会桥接成 NSNumber，as? Bool 不一定成功，补一层
    private static func boolValue(_ v: Any?) -> Bool? {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        return nil
    }
}

// MARK: - 网页 ↔ 原生 状态桥

/// 让 SwiftUI 层能操作网页里的中英文切换按钮
final class WebBridge: ObservableObject {
    @Published var showNativeLang = false
    @Published var langText = "🌐"

    weak var webView: WKWebView?

    /// 是否支持原生液态玻璃（iOS 26+）
    static var nativeGlassSupported: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// 页面加载后检查网页里有没有可见的 #langBtn（没有就不显示原生按钮）
    func probeLangButton() {
        guard let wv = webView else { return }
        let js = """
        (function(){
          var b = document.getElementById('langBtn');
          if (!b) { return 'none'; }
          if (window.getComputedStyle(b).display === 'none') { return 'none'; }
          return 'ok|' + (b.textContent || '').trim();
        })();
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self, let s = result as? String else { return }
            guard s.hasPrefix("ok|") else { return }
            let text = String(s.dropFirst(3)).trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { self.langText = text }
            guard WebBridge.nativeGlassSupported else { return }   // 老系统不动网页那颗
            self.showNativeLang = true
            // 网页那颗隐藏掉，避免双按钮
            wv.evaluateJavaScript("var b=document.getElementById('langBtn'); if(b){ b.style.display='none'; }",
                                  completionHandler: nil)
        }
    }

    /// 点原生按钮 → 触发网页里的切换逻辑 → 同步按钮上的旗子
    func toggleLang() {
        guard let wv = webView else { return }
        let js = """
        (function(){
          var b = document.getElementById('langBtn');
          if (!b) { return ''; }
          b.click();
          return (b.textContent || '').trim();
        })();
        """
        wv.evaluateJavaScript(js) { [weak self] result, _ in
            guard let self = self else { return }
            if let s = result as? String, !s.isEmpty { self.langText = s }
            // 有的页面点完才改文字，稍后再取一次
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                let js2 = "(function(){var b=document.getElementById('langBtn'); return b ? (b.textContent||'').trim() : '';})();"
                wv.evaluateJavaScript(js2) { r2, _ in
                    if let s2 = r2 as? String, !s2.isEmpty { self.langText = s2 }
                }
            }
        }
    }
}

// MARK: - 原生液态玻璃按钮（iOS 26 / Xcode 26）

/// 真·Liquid Glass：调用系统 glassEffect。老系统/老编译器自动走下面的兜底样式。
@available(iOS 26.0, *)
struct LangGlassButton: View {
    let text: String
    let action: () -> Void

    var body: some View {
        #if compiler(>=6.2)
        Button(action: action) {
            Text(text)
                .font(.system(size: 20))
                .frame(width: 24, height: 24)
                .padding(10)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        #else
        Button(action: action) {
            Text(text)
                .font(.system(size: 20))
                .frame(width: 24, height: 24)
                .padding(10)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 1))
        }
        .buttonStyle(.plain)
        #endif
    }
}

// MARK: - 本地网页存储（热更新落地目录）

/// 热更新后的网页放在沙盒 Documents/web/index.html；
/// 没有就用 App 包里的 web/index.html（旧版兜底）。
enum HTMLStore {
    /// Documents/web
    static var webDir: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("web", isDirectory: true)
    }

    /// Documents/web/index.html
    static var sandboxIndex: URL {
        return webDir.appendingPathComponent("index.html", isDirectory: false)
    }

    /// 沙盒里是否已有热更新过的网页
    static var hasSandboxVersion: Bool {
        return FileManager.default.fileExists(atPath: sandboxIndex.path)
    }

    /// 包内旧版网页
    static var bundledIndex: URL? {
        return Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "web")
    }

    /// 包内 web 目录（folder reference，内含 index.html 及 js/wasm 等全部资源）
    static var bundledWebDir: URL? {
        return Bundle.main.resourceURL?.appendingPathComponent("web", isDirectory: true)
    }

    /// 首次启动把包内 web 整目录搬到 Documents/web；
    /// 已存在的 index.html 跳过（交给热更新管线），其余资源缺失则补齐
    static func seedIfNeeded() {
        let fm = FileManager.default
        guard let src = bundledWebDir,
              let items = try? fm.contentsOfDirectory(at: src, includingPropertiesForKeys: nil)
        else { return }
        try? fm.createDirectory(at: webDir, withIntermediateDirectories: true)
        for item in items {
            let dst = webDir.appendingPathComponent(item.lastPathComponent)
            // 热更新只覆写 index.html，别把沙盒里的新版网页盖回包内旧版
            if item.lastPathComponent == "index.html",
               fm.fileExists(atPath: dst.path) { continue }
            if fm.fileExists(atPath: dst.path) { continue }
            try? fm.copyItem(at: item, to: dst)
        }
    }
}

// MARK: - 根视图

struct ContentView: View {
    @StateObject private var bridge = WebBridge()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            WebView(bridge: bridge)
                .ignoresSafeArea()

            if bridge.showNativeLang {
                if #available(iOS 26.0, *) {
                    LangGlassButton(text: bridge.langText) {
                        bridge.toggleLang()   // 语言切换不震
                    }
                    .padding(.top, 12)
                    .padding(.trailing, 12)
                }
            }
        }
    }
}

// MARK: - WKWebView

/// 用 WKWebView 加载本地 index.html：优先沙盒热更新版，其次包内旧版
struct WebView: UIViewRepresentable {

    @ObservedObject var bridge: WebBridge

    // v0.47：不再全局拦截按钮点击。震动只在网页 triggerVibrate() 里显式调用，
    // 这里只保留 haptic 消息通道（config 里已注册），无需注入脚本。

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        // 多文件网页（wasm / Worker / 模型文件）要从 file:// 读，默认会被 WKWebView 拦死
        config.preferences.setValue(true, forKey: "allowFileAccessFromFileURLs")
        config.setValue(true, forKey: "allowUniversalAccessFromFileURLs")

        // 震动桥接（在 load 之前挂好，网页里才能 postMessage）
        config.userContentController.add(context.coordinator.haptic, name: "haptic")
        // 网页开关桥接（震动 / 自动更新）
        config.userContentController.add(context.coordinator.settings, name: "settings")

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.bridge = bridge
        bridge.webView = webView
        webView.scrollView.bounces = false
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.isOpaque = false
        webView.backgroundColor = UIColor(red: 1.0, green: 0.91, blue: 0.87, alpha: 1.0)
        webView.allowsBackForwardNavigationGestures = false

        // 1) 沙盒里下载过新版本 → 加载它（读权限给整个 web 目录，页面内相对资源也能读）
        // 2) 否则降级到 App 包内旧版
        // 多文件网页（js/wasm/模型等）要先铺到 Documents/web，否则相对路径全 404
        HTMLStore.seedIfNeeded()

        if HTMLStore.hasSandboxVersion {
            webView.loadFileURL(HTMLStore.sandboxIndex, allowingReadAccessTo: HTMLStore.webDir)
        } else if let url = HTMLStore.bundledIndex {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// 视图销毁时拆掉消息通道，避免 userContentController 长期强持有 handler
    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        uiView.stopLoading()
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "haptic")
        uiView.configuration.userContentController.removeScriptMessageHandler(forName: "settings")
        uiView.navigationDelegate = nil
        coordinator.webView = nil
        coordinator.bridge?.webView = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate {

        weak var webView: WKWebView?
        weak var bridge: WebBridge?
        let haptic = HapticBridge()
        let settings = SettingsBridge()

        /// 公告地址（v1.3：优先 Cloudflare Worker，失败自动换 GitHub 直连）
        private let noticeURLs = [
            "https://broadcast.us.ci/notice",
            "https://raw.githubusercontent.com/htpxfcqkgm-hub/mipitang-assets/main/version.json"
        ]

        // MARK: - 前台回切监听

        private var foregroundToken: NSObjectProtocol?

        override init() {
            super.init()
            settings.coordinator = self
            // 从后台切回前台也查一次（有节流，不会反复拉）
            foregroundToken = NotificationCenter.default.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.checkForUpdates(reason: "前台")
            }
        }

        deinit {
            if let token = foregroundToken {
                NotificationCenter.default.removeObserver(token)
            }
        }

        // MARK: - 热更新白名单

        /// 参与热更新的 App 名称（改名后这里要同步，否则热更新静默失效）
        private static let hotUpdateNames: Set<String> = ["米皮糖小摊", "米皮糖管理"]

        /// 参与热更新的包名（批量脚本生成的包名是 com.mipitang.a+md5，不会撞）
        private static let hotUpdateBundleIDs: Set<String> = [
            "com.mipitang.stall",
            "dev.pages.bigsaucyschicken.SAM5AX8YV9",
            // 正式「米皮糖小摊」包：批量脚本按 md5(名字) 生成，重打不变，故存档不丢
            "com.mipitang.aee68d592"
        ]

        /// 只有主 App 参与热更新；批量导出的其它 App 永远用包内网页
        private static var hotUpdateEnabled: Bool {
            let info = Bundle.main.infoDictionary ?? [:]
            let name = (info["CFBundleDisplayName"] as? String)
                ?? (info["CFBundleName"] as? String) ?? ""
            let bid = Bundle.main.bundleIdentifier ?? ""

            // 1) 包名命中白名单：直接放行（主 App 改包名也认）
            if hotUpdateBundleIDs.contains(bid) { return true }
            // 2) 批量导出的包名（严格等于 com.mipitang.a + 8 位 md5）：永不热更新，
            //    防止 html 的 <title> 刚好叫「米皮糖小摊」而把自己覆盖成主摊网页。
            //    注意：必须精确匹配，自签工具若给正式包加后缀（如 .sign），不能被误拦
            if bid.range(of: #"^com\.mipitang\.a[0-9a-fA-F]{8}$"#,
                         options: .regularExpression) != nil { return false }
            // 3) 剩下的才看显示名称
            return hotUpdateNames.contains(name)
        }

        /// 网页里的外部链接（如「反馈」表单）交给系统 Safari 打开
        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if let url = navigationAction.request.url,
               let scheme = url.scheme?.lowercased(),
               scheme == "http" || scheme == "https" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }

        /// 页面加载完成：拉公告 + 静默查热更新
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            self.webView = webView
            self.bridge?.webView = webView
            Haptics.prepare()   // 预热震动器，第一次点击不延迟
            fetchCloudNotice()
            checkForUpdates(reason: "启动")   // 后台静默，不阻塞界面
            // 找网页里的中英文按钮，找到就换成原生液态玻璃
            self.bridge?.probeLangButton()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                if self?.bridge?.showNativeLang == false { self?.bridge?.probeLangButton() }
            }
        }

        // MARK: - 原生拉取 + JS 注入（绕开 WKWebView 跨域限制）

        func fetchCloudNotice() {
            let ts = Int(Date().timeIntervalSince1970)
            let urls = noticeURLs.map { "\($0)?t=\(ts)" }
            tryFetch(urls, attempt: 0)
        }

        private func tryFetch(_ urls: [String], attempt: Int) {
            guard attempt < urls.count, let url = URL(string: urls[attempt]) else { return }

            var request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 12)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue("application/json", forHTTPHeaderField: "Accept")

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error == nil, status == 200, let data = data, !data.isEmpty,
                   let json = String(data: data, encoding: .utf8) {
                    let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
                        DispatchQueue.main.async { self.inject(trimmed) }
                        return
                    }
                }

                // 本次失败：换下一个地址重试
                self.tryFetch(urls, attempt: attempt + 1)
            }.resume()
        }

        private func inject(_ json: String) {
            guard let webView = webView else { return }
            // 1) 先把数据挂到全局变量 + 广播事件（处理函数没就绪时网页也能自己取）
            // 2) 再直接调用 __mptApplyCloud 弹公告
            let js = """
            (function(){
              try {
                window.__MPT_CLOUD = \(json);
                window.dispatchEvent(new Event('mpt-cloud'));
              } catch (e) {}
              if (typeof window.__mptApplyCloud !== 'function') { return 'no-handler'; }
              try { window.__mptApplyCloud(\(json)); return 'ok'; } catch (e) { return 'error:' + e; }
            })();
            """
            webView.evaluateJavaScript(js) { result, error in
                if let error = error {
                    print("注入公告 JS 失败: \(error)")
                } else if let result = result {
                    print("公告注入结果: \(result)")
                }
            }
        }

        // MARK: - 热更新：云端哈希比对 → 变了才整包下载

        /// Worker 极简指纹接口（返回 {"success":true,"hash":"<sha256>"}，几十字节）
        /// 主接口（JSON）
        private let hashURL = "https://broadcast.us.ci/htmlhash"
        /// 备用接口（纯文本 64 位 sha256）
        private let hashTextURL = "https://broadcast.us.ci/hash.txt"

        /// 整包网页地址（只在哈希不一致时才请求）
        private let htmlURL = "https://mipitang-stall.pages.dev/index.html"

        /// 指纹键（键名沿用 LocalHTMLETag）：存 "sha256:xxxx"，哪个网页的哈希就算哪个
        private static let etagKey = "LocalHTMLETag"

        /// 前台回切检查节流（秒）
        private static let foregroundThrottle: TimeInterval = 300

        /// 每次启动最多无感重载 2 次，防止服务器指纹抖动导致死循环
        private var reloadBudget = 2

        private var isChecking = false
        private var didFirstCheck = false
        private var lastCheckAt: TimeInterval = 0
        /// 网页点了「检查更新」：结果要回传到设置页显示
        private var manualMode = false

        /// 入口：启动 / 前台回切时调用，全程后台线程
        func checkForUpdates(reason: String = "启动") {
            // 非主 App 直接跳过，连请求都不发
            guard Coordinator.hotUpdateEnabled else { return }
            // 用户在网页里关了「自动更新」：不发任何 htmlhash 请求
            guard Prefs.flag(Prefs.autoUpdateKey) else { return }
            guard !isChecking else { return }

            let now = Date().timeIntervalSince1970
            if didFirstCheck && now - lastCheckAt < Coordinator.foregroundThrottle { return }
            isChecking = true
            didFirstCheck = true
            lastCheckAt = now

            DispatchQueue.global(qos: .utility).async { [weak self] in
                self?.verifyRemoteHash()
            }
        }

        /// 网页「设置 → 检查更新」：无视自动更新开关与前台节流，白名单照旧
        func manualCheck() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard Coordinator.hotUpdateEnabled else {
                    // 诊断用：把实际包名 / 显示名吐到网页，方便一眼定位白名单为何没命中
                    let bid = Bundle.main.bundleIdentifier ?? "nil"
                    let info = Bundle.main.infoDictionary ?? [:]
                    let nm = (info["CFBundleDisplayName"] as? String)
                        ?? (info["CFBundleName"] as? String) ?? "nil"
                    self.notifyPage("unsupported", "不支持热更新（包名 \(bid) / 名称 \(nm)）")
                    return
                }
                guard !self.isChecking else {
                    self.notifyPage("busy", "正在检查，请稍候")
                    return
                }
                self.manualMode = true
                self.isChecking = true
                self.didFirstCheck = true
                self.lastCheckAt = Date().timeIntervalSince1970
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    self?.verifyRemoteHash()
                }
            }
        }

        /// 只有手动检查才回传，自动检查保持全静默
        private func notifyPageIfManual(_ status: String, _ msg: String) {
            guard manualMode else { return }
            notifyPage(status, msg)
        }

        /// 把结果写回网页设置页（window.__nativeUpdateResult）
        private func notifyPage(_ status: String, _ msg: String) {
            manualMode = false
            let esc = msg.replacingOccurrences(of: "\\", with: "\\\\")
                           .replacingOccurrences(of: "'", with: "\\'")
                           .replacingOccurrences(of: "\n", with: " ")
            let js = "window.__nativeUpdateResult && window.__nativeUpdateResult('\(status)','\(esc)')"
            DispatchQueue.main.async { [weak self] in
                self?.webView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }

        /// 第一步（0 流量）：问 Worker 要云端网页的 sha256，跟本地当前网页比
        private func verifyRemoteHash() {
            // 主通道：JSON 接口（5s）
            fetchRemoteHash(from: hashURL, isJSON: true) { [weak self] hash in
                guard let self = self else { return }
                if let hash = hash {
                    self.handleRemoteHash(hash)
                    return
                }
                // 兑底通道：主接口非 200 / JSON 脏 / 超时 → 纯文本
                self.fetchRemoteHash(from: self.hashTextURL, isJSON: false) { [weak self] fallback in
                    guard let self = self else { return }
                    guard let fallback = fallback else {
                        print("[热更新] 哈希接口全挂，静默跳过")
                        self.notifyPageIfManual("failed", "检查失败，请确认网络后重试")
                        self.finishCheck()
                        return
                    }
                    print("[热更新] 主接口不可用，已降级到 hash.txt")
                    self.handleRemoteHash(fallback)
                }
            }
        }

        /// 拉单个云端指纹：timeout 5s；非 200 / 非 64hex / JSON 解析失败 → nil
        private func fetchRemoteHash(from base: String, isJSON: Bool, completion: @escaping (String?) -> Void) {
            let ts = Int(Date().timeIntervalSince1970)
            // ?t= 防 CDN 返回旧哈希
            guard let url = URL(string: "\(base)?t=\(ts)") else {
                completion(nil)
                return
            }

            var request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 5)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            request.setValue(isJSON ? "application/json" : "text/plain", forHTTPHeaderField: "Accept")

            URLSession.shared.dataTask(with: request) { data, response, error in
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, status == 200, let data = data, !data.isEmpty else {
                    completion(nil)
                    return
                }

                var candidate: String?
                if isJSON {
                    if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                       (obj["success"] as? Bool) ?? true,
                       let h = obj["hash"] as? String {
                        candidate = h
                    }
                } else {
                    // 纯文本：trim 换行与首尾空白
                    candidate = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }

                guard let h = candidate?.lowercased(), Coordinator.isSHA256(h) else {
                    completion(nil)
                    return
                }
                completion(h)
            }.resume()
        }

        /// 比对：一致 → 0 流量结束；不一致 → 整包下载
        private func handleRemoteHash(_ remoteHash: String) {
            guard let localHash = Coordinator.localBodyHash() else {
                // 本地网页读不出来（损坏）：直接整包重下
                downloadHTML(remoteHash: remoteHash)
                return
            }

            if localHash == remoteHash {
                notifyPageIfManual("latest", "已是最新版本")
                finishCheck()   // 云端没更新：到此结束，0 流量
                return
            }

            downloadHTML(remoteHash: remoteHash)
        }

        /// 第二步（仅哈希不一致时）：整包下载 → 原子落盘 → 主线程无感重载
        private func downloadHTML(remoteHash: String) {
            let ts = Int(Date().timeIntervalSince1970)
            guard let url = URL(string: "\(htmlURL)?t=\(ts)") else {
                finishCheck()
                return
            }

            var request = URLRequest(url: url,
                                     cachePolicy: .reloadIgnoringLocalCacheData,
                                     timeoutInterval: 10)
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")

            URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
                guard let self = self else { return }
                defer { self.finishCheck() }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard error == nil, status == 200, let data = data, data.count > 500,
                      let text = String(data: data, encoding: .utf8) else { return }

                // 防呆：下到的必须是网页，不能是错误页 / JSON / 半截数据
                let lower = text.lowercased()
                guard lower.contains("<html") || lower.contains("<!doctype") else { return }

                let hash = Coordinator.sha256Hex(data)

                // 下到的内容跟当前在用的网页一样 → 不落盘（CDN 可能还是旧的）
                if Coordinator.localBodyHash() == hash {
                    UserDefaults.standard.set("sha256:\(hash)", forKey: Coordinator.etagKey)
                    return
                }

                do {
                    try FileManager.default.createDirectory(at: HTMLStore.webDir,
                                                            withIntermediateDirectories: true)
                    // .atomic：先写临时文件再改名，不会读到写了一半的网页
                    try data.write(to: HTMLStore.sandboxIndex, options: .atomic)
                } catch {
                    return   // 空间不足 / 权限异常：静默放弃，玩家继续用旧网页
                }

                UserDefaults.standard.set("sha256:\(hash)", forKey: Coordinator.etagKey)

                if hash != remoteHash {
                    // CDN 还没刷到新文件：已落盘但不重载，下次回前台再比一次
                    print("热更新：CDN 内容与云端哈希不一致，本次不重载")
                    notifyPageIfManual("pending", "已下载新版，下次启动生效")
                    return
                }

                print("检测到网页更新，已无感替换")
                let manual = manualMode
                notifyPageIfManual("updated", "已更新，正在刷新…")
                // 手动检查留给提示 1 秒，自动检查立刻刷新
                DispatchQueue.main.asyncAfter(deadline: .now() + (manual ? 1.0 : 0)) {
                    self.reloadAfterUpdate()
                }
            }.resume()
        }

        /// 第三步：主线程重载沙盒里的新网页（在后台或正在加载就跳过，留给下次启动）
        private func reloadAfterUpdate() {
            guard let webView = webView else { return }
            guard UIApplication.shared.applicationState == .active else { return }
            guard !webView.isLoading else { return }
            guard reloadBudget > 0 else { return }
            reloadBudget -= 1
            webView.loadFileURL(HTMLStore.sandboxIndex, allowingReadAccessTo: HTMLStore.webDir)
        }

        /// 收尾：解锁 isChecking（放主线程，避免和 checkForUpdates 抢标志位）
        private func finishCheck() {
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                // 手动检查走到这里还没回过话（下载失败 / 格式不对等）→ 统一报一次
                if self.manualMode { self.notifyPage("failed", "检查未完成，请稍后重试") }
                self.isChecking = false
            }
        }

        // MARK: - 指纹工具

        /// 是否是合法的 sha256 十六进制串（防 Worker 返回脏数据）
        private static func isSHA256(_ s: String) -> Bool {
            guard s.count == 64 else { return false }
            let hex = CharacterSet(charactersIn: "0123456789abcdef")
            return s.unicodeScalars.allSatisfy { hex.contains($0) }
        }

        /// 当前真正在用的网页（沙盒优先，退回包内）的内容哈希
        private static func localBodyHash() -> String? {
            let target: URL?
            if HTMLStore.hasSandboxVersion {
                target = HTMLStore.sandboxIndex
            } else {
                target = HTMLStore.bundledIndex
            }
            guard let url = target, let data = try? Data(contentsOf: url) else { return nil }
            return sha256Hex(data)
        }

        private static func sha256Hex(_ data: Data) -> String {
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}
