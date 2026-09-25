import AppKit
import WebKit

/// Breaks retain cycles between `WKUserContentController` and its message handler.
final class ScriptMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

extension NSColor {
    /// Stable hex for CSS, even when the color comes from SwiftUI bridging.
    var reliableHexString: String {
        let rgb = usingColorSpace(.deviceRGB)
            ?? usingColorSpace(.sRGB)
            ?? self
        var r: CGFloat = 1
        var g: CGFloat = 1
        var b: CGFloat = 0.6
        var a: CGFloat = 1
        rgb.getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(
            format: "#%02x%02x%02x",
            Int((r * 255).rounded()),
            Int((g * 255).rounded()),
            Int((b * 255).rounded())
        )
    }
}
