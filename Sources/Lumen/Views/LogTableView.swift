import SwiftUI
import WebKit

/// 本地 HTML 日志页使用 WebKit 原生文字选择，支持跨列、跨记录拖选。
struct LogTableView: NSViewRepresentable {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var scheme

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(context.coordinator, name: "logs")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = context.coordinator
        context.coordinator.web = web
        web.loadHTMLString(LogWebDocument.html, baseURL: nil)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        let coordinator = context.coordinator
        coordinator.payload = [
            "rows": model.rows.map { record in
                ["id": String(record.id), "clock": record.clock, "level": record.level.title,
                 "process": record.category.isEmpty ? record.process : record.category,
                 "message": record.message, "raw": record.raw]
            },
            "hidden": Array(model.hiddenColumns), "font": model.fontSize,
            "dark": scheme == .dark, "search": model.searchText,
            "follow": model.autoScroll && model.viewingLive,
            "target": model.scrollTarget.map(String.init) ?? "",
            // 用户主动切换会话、筛选和分页时结束旧选区；流式续写不改变该标识。
            "context": "\(model.selectedSessionID ?? "")|\(model.pageOffset)|\(model.searchText)|\(model.filter)",
            "version": model.tableVersion
        ]
        coordinator.render()
    }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "logs")
        web.navigationDelegate = nil
    }

    @MainActor final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let model: AppModel
        weak var web: WKWebView?
        var payload: [String: Any] = [:]
        var ready = false
        init(model: AppModel) { self.model = model }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true; render()
            NSLog("[Lumen] HTML 日志视图已就绪")
        }

        /// 通过结构化参数传入日志，正文只写 textContent，不能作为 HTML 或脚本执行。
        func render() {
            guard ready, let web else { return }
            web.callAsyncJavaScript("window.lumen.update(payload)", arguments: ["payload": payload], in: nil, in: .page) { result in
                if case .failure(let error) = result { NSLog("[Lumen] 日志页面更新失败：%@", error.localizedDescription) }
            }
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            switch kind {
            case "pause": model.autoScroll = false
            case "copyRows": model.copySelection()
            case "selection":
                guard let values = body["rows"] as? [[String: String]] else { return }
                // 使用浏览器实际显示的正文快照，流式续写不能改变整条日志复制内容。
                let byID = Dictionary(uniqueKeysWithValues: model.rows.map { (String($0.id), $0) })
                let selected = values.compactMap { value -> LogRecord? in
                    guard let id = value["id"], var record = byID[id] else { return nil }
                    record.raw = value["raw"] ?? record.raw
                    return record
                }
                model.selectRecords(Set(selected.map(\.id)), displayedRecords: selected)
            default: break
            }
        }

        /// 日志中的地址、拖入内容和新窗口均不能将本地日志页导航到外部站点。
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
    }
}
