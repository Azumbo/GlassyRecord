import SwiftUI
import UIKit
import WebKit

/// Встроенный браузер для демо-записей: тапы видны, Face Cam остаётся в системном PiP.
struct DemoBrowserView: View {
    @EnvironmentObject private var settingsStore: SettingsStore
    var onClose: () -> Void

    @StateObject private var model = DemoBrowserModel()
    @State private var addressText = ""
    @State private var touchIndicators: [DemoTouchIndicator] = []
    @State private var lastTouchPoint: CGPoint?

    private let presets: [(title: String, url: String)] = DemoBrowserPresets.localized

    var body: some View {
        VStack(spacing: 0) {
            topBar
            addressBar
            presetRow
            ZStack {
                DemoWebView(model: model)
                TouchPassthroughRepresentable { point in
                    addTouchIndicator(at: point)
                }
                touchLayer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(GlassyTheme.backgroundSecondary.ignoresSafeArea())
        .onAppear {
            if model.url == nil {
                model.load(DemoBrowserPresets.defaultHomeURL)
            }
            addressText = model.url?.absoluteString ?? ""
            UsageTracker.shared.track(.demoBrowserOpened)
        }
        .onChange(of: model.url) { url in
            if let url {
                addressText = url.absoluteString
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                onClose()
            } label: {
                Label(L10n.t("demo.back"), systemImage: "chevron.left")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.plain)

            Spacer()

            Text(L10n.t("demo.title"))
                .font(.headline)

            Spacer()

            HStack(spacing: 16) {
                Button {
                    model.goBack()
                } label: {
                    Image(systemName: "chevron.backward")
                }
                .disabled(!model.canGoBack)

                Button {
                    model.goForward()
                } label: {
                    Image(systemName: "chevron.forward")
                }
                .disabled(!model.canGoForward)

                Button {
                    model.reload()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .font(.body.weight(.medium))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var addressBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "globe")
                .foregroundStyle(GlassyTheme.labelSecondary)
            TextField(L10n.t("demo.address"), text: $addressText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit { submitAddress() }
            Button(L10n.t("demo.go")) { submitAddress() }
                .font(.subheadline.weight(.semibold))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GlassyTheme.fillSecondary)
    }

    private var presetRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(presets, id: \.title) { preset in
                    Button(preset.title) {
                        model.load(preset.url)
                        addressText = preset.url
                        UsageTracker.shared.track(.demoPresetOpened, params: ["site": preset.title])
                    }
                    .buttonStyle(SelectableCapsuleStyle(isSelected: false))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private var touchLayer: some View {
        GeometryReader { _ in
            ForEach(touchIndicators) { indicator in
                Circle()
                    .fill(indicator.color.opacity(indicator.opacity))
                    .frame(width: indicator.size, height: indicator.size)
                    .position(indicator.position)
            }
        }
        .allowsHitTesting(false)
    }

    private func submitAddress() {
        model.load(addressText)
    }

    private func addTouchIndicator(at point: CGPoint) {
        guard settingsStore.settings.touchIndicatorEnabled else { return }

        if let last = lastTouchPoint {
            let dx = point.x - last.x
            let dy = point.y - last.y
            guard (dx * dx + dy * dy) >= 400 else { return }
        }
        lastTouchPoint = point

        let indicator = DemoTouchIndicator(
            position: point,
            color: Color(hex: settingsStore.settings.touchIndicatorColorHex) ?? .red,
            size: settingsStore.settings.touchIndicatorSize,
            opacity: settingsStore.settings.touchIndicatorOpacity
        )
        touchIndicators.append(indicator)
        UsageTracker.shared.track(.touchIndicatorShown)
        Task {
            try? await Task.sleep(for: .seconds(0.55))
            touchIndicators.removeAll { $0.id == indicator.id }
        }
    }
}

// MARK: - Model

@MainActor
final class DemoBrowserModel: ObservableObject {
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var isLoading = false
    @Published var pageTitle = ""

    weak var webView: WKWebView?

    func load(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let withScheme: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            withScheme = trimmed
        } else if trimmed.contains(".") && !trimmed.contains(" ") {
            withScheme = "https://\(trimmed)"
        } else {
            let query = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
            withScheme = "https://www.google.com/search?q=\(query)"
        }

        guard let url = URL(string: withScheme) else { return }
        self.url = url
        webView?.load(URLRequest(url: url))
    }

    func goBack() { webView?.goBack() }
    func goForward() { webView?.goForward() }
    func reload() { webView?.reload() }

    func syncNavigationState(from webView: WKWebView) {
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        isLoading = webView.isLoading
        pageTitle = webView.title ?? ""
        url = webView.url
    }
}

struct DemoTouchIndicator: Identifiable {
    let id = UUID()
    let position: CGPoint
    let color: Color
    let size: CGFloat
    let opacity: Double
}

// MARK: - WebView

struct DemoWebView: UIViewRepresentable {
    @ObservedObject var model: DemoBrowserModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .automatic
        model.webView = webView
        if let url = model.url {
            webView.load(URLRequest(url: url))
        }
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        model.webView = uiView
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let model: DemoBrowserModel

        init(model: DemoBrowserModel) {
            self.model = model
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            Task { @MainActor in model.syncNavigationState(from: webView) }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            Task { @MainActor in model.syncNavigationState(from: webView) }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            Task { @MainActor in model.syncNavigationState(from: webView) }
        }
    }
}

// MARK: - Touch passthrough

struct TouchPassthroughRepresentable: UIViewRepresentable {
    var onTouch: (CGPoint) -> Void

    func makeUIView(context: Context) -> TouchPassthroughUIView {
        let view = TouchPassthroughUIView()
        view.onTouch = onTouch
        view.backgroundColor = .clear
        view.isOpaque = false
        return view
    }

    func updateUIView(_ uiView: TouchPassthroughUIView, context: Context) {
        uiView.onTouch = onTouch
    }
}

final class TouchPassthroughUIView: UIView {
    var onTouch: ((CGPoint) -> Void)?

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if let event {
            for touch in event.allTouches ?? [] {
                switch touch.phase {
                case .began, .moved:
                    onTouch?(touch.location(in: self))
                default:
                    break
                }
            }
        }
        // Пропускаем касание в WKWebView под оверлеем.
        return nil
    }
}

/// Стартовые сайты демо-браузера с учётом языка системы.
enum DemoBrowserPresets {
    static var languageCode: String {
        Locale.current.language.languageCode?.identifier ?? "en"
    }

    static var defaultHomeURL: String {
        "https://www.google.com/search?hl=\(languageCode)"
    }

    static var localized: [(title: String, url: String)] {
        let lang = languageCode
        let wikiHost: String
        switch lang {
        case "zh": wikiHost = "zh.m.wikipedia.org"
        default: wikiHost = "\(lang).m.wikipedia.org"
        }
        return [
            ("Google", "https://www.google.com/?hl=\(lang)"),
            ("YouTube", "https://m.youtube.com/?hl=\(lang)&gl=\(regionCode)"),
            ("Wikipedia", "https://\(wikiHost)"),
            ("Apple", appleURL)
        ]
    }

    private static var regionCode: String {
        Locale.current.region?.identifier ?? "US"
    }

    private static var appleURL: String {
        let lang = languageCode
        if lang == "en" { return "https://www.apple.com" }
        return "https://www.apple.com/\(lang)/"
    }
}
