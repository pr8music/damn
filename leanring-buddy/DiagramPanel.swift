//
//  DiagramPanel.swift
//  leanring-buddy
//
//  Lets Clicky open a floating diagram window next to your work: flows,
//  architectures, timelines, charts, animated explainers and 3D scenes.
//
//  How it works:
//    1. The main reply contains a tag like [DIAGRAM:3d cutaway of the earth ...]
//       and Clicky keeps talking right away.
//    2. In the background, a second Gemini request (the "diagram artist") writes
//       the diagram as a small piece of self-contained HTML/SVG/CSS.
//    3. That HTML is shown in a locked-down web view inside a floating window.
//       The page cannot reach the internet (a content security policy blocks
//       every network request) and can't see your screen, files or key.
//
//  3D options:
//    - CSS 3D that you can drag to rotate (built in, no setup).
//    - Real WebGL 3D with three.js, if you add one optional file (see below).
//
//  Optional three.js: save https://cdnjs.cloudflare.com/ajax/libs/three.js/r128/three.min.js as
//      ~/Library/Application Support/Clicky/three.min.js
//  then restart Clicky. Without it, Clicky still draws 3D using CSS 3D and SVG.
//

import AppKit
import WebKit

// MARK: - Instructions for the diagram artist

enum DiagramPrompt {

    /// Loaded once per launch: the optional three.js file, if you added it.
    static let cachedThreeScript: String? = loadThreeScript()

    static var threeJSAvailable: Bool {
        cachedThreeScript != nil
    }

    private static func loadThreeScript() -> String? {
        var candidateURLs: [URL] = []
        if let bundled = Bundle.main.url(forResource: "three.min", withExtension: "js") {
            candidateURLs.append(bundled)
        }
        if let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidateURLs.append(supportDirectory.appendingPathComponent("Clicky/three.min.js"))
        }
        for url in candidateURLs {
            if let script = try? String(contentsOf: url, encoding: .utf8), script.count > 10_000 {
                print("📐 three.js found at \(url.path)")
                return script
            }
        }
        return nil
    }

    static func system(threeJSAvailable: Bool) -> String {
        let basePrompt = """
        you are a precise information designer for a small floating window, about 760 by 560 pixels, with a dark background. you get a request describing what to draw. first reason privately about the entities, relationships, direction, order, and visual type. then reply with ONLY an html fragment: no markdown fences, no explanation, and no html, head, or body tags. it is placed inside a page that already has a dark theme, so never set a page background.

        hard rules:
        - everything must be self-contained: inline svg, css in a style tag, and optional inline script. never use external files, images, fonts, links, network requests, or cdn urls. they are all blocked.
        - colors: use these css variables so everything matches: var(--accent) blue, var(--green), var(--amber), var(--red), var(--violet), var(--text), var(--muted), var(--line), var(--panel), var(--bg). text must be at least 13px with strong contrast on dark. use font-family inherit.
        - start with a short title in an h2, then the diagram, then optionally a one-line caption in var(--muted). Make the title specific, not generic.
        - keep it clean: use a consistent grid, generous padding, aligned shapes, even spacing, and clear visual hierarchy. Keep related items close and unrelated items separated. Use labeled arrows with SVG marker arrowheads. Never let an arrow pass through a node or label. Avoid crossing lines, clipped text, tiny labels, and decorative elements that compete with the explanation. Keep to about twelve nodes at most.
        - use the exact labels and relationships from the request. do not invent facts, values, steps, dependencies, or examples. if the request does not provide numeric data, do not draw numeric axes or pretend to have measurements; use a qualitative diagram instead. if you are unsure about a detail, leave it out.
        - for flows and architectures, arrange the main direction left-to-right or top-to-bottom, number ordered stages only when the order matters, and make arrow direction unambiguous. for comparisons, use equal-width columns with matching rows. for timelines, use a single axis with dates or labels supplied by the request. for charts, show units and a truthful scale only when values were supplied.
        - put labels inside roomy cards where possible. If a label is long, wrap it into two or three lines instead of shrinking the font. Keep every label inside its shape and leave a visible gap around arrows.
        - use a viewBox with a little internal margin and width="100%" so it fits about 720 pixels wide. Prefer a viewBox around 720 by 420 for ordinary diagrams and use the available height rather than packing everything into a thin strip.
        - animation is welcome only when it explains something, like a dot traveling along an arrow or a pulsing node, using css animations or small scripts. keep it subtle, pause or stop it on interaction when practical, and make sure the static end state is fully readable.

        choosing a style:
        - flows, architectures, timelines, comparisons, cycles, hierarchies, charts, and maps: inline svg.
        - 3d that looks 3d but does not need to move: isometric or perspective svg.
        - 3d the user can turn: css 3d. wrap it like this: <div class="scene"><div class="world" data-drag-rotate data-auto-rotate> ...faces... </div></div>. the classes scene and world are already styled (perspective and preserve-3d), and the user can drag to rotate. build faces and layers with absolutely positioned divs using transform: translate3d(...) rotateX(...) rotateY(...). remove data-auto-rotate if slow spinning would be distracting. put labels on elements that face the viewer, and keep every face a solid color with some transparency so shapes stay readable.
        """

        let threePrompt = """

        - real 3d with webgl: three.js release 128 is available as the global THREE. there is no OrbitControls and there are no loaders. create a renderer sized to a container div of about 720 by 420 pixels, append renderer.domElement to it, add an AmbientLight and a DirectionalLight, and call clickyDrag(renderer.domElement, function (dx, dy) { group.rotation.y += dx * 0.01; group.rotation.x += dy * 0.01; }) so the user can drag to rotate. add labels as absolutely positioned html elements over the canvas, but only label surfaces that remain readable from the initial camera angle. use three.js for spheres, solids, molecules, planets, and anything with real depth, and css 3d for simple stacks and boxes. include a small "drag to rotate" hint only when the object is actually draggable.
        """

        return threeJSAvailable ? basePrompt + threePrompt : basePrompt
    }
}

// MARK: - Building the web page

enum DiagramHTML {

    /// Turns the artist's reply into a complete, locked-down page.
    static func page(fromModelOutput modelOutput: String, threeScript: String?) -> String {
        assemble(fragment: normalizedFragment(from: modelOutput), threeScript: threeScript)
    }

    /// A simple page for "drawing..." and error messages.
    static func messagePage(title: String, message: String, showSpinner: Bool) -> String {
        let spinnerHTML = showSpinner ? "<div class='clicky-spinner'></div>" : ""
        let fragment = """
        <style>
        .clicky-message { min-height: calc(100vh - 32px); display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 14px; text-align: center; }
        .clicky-spinner { width: 28px; height: 28px; border-radius: 50%; border: 3px solid var(--line); border-top-color: var(--accent); animation: clickyspin 0.9s linear infinite; }
        @keyframes clickyspin { to { transform: rotate(360deg); } }
        </style>
        <div class="clicky-message">\(spinnerHTML)<div style="font-size:16px">\(escapeHTML(title))</div><div style="font-size:13px;color:var(--muted);max-width:560px">\(escapeHTML(message))</div></div>
        """
        return assemble(fragment: fragment, threeScript: nil)
    }

    static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// True if the model's reply looks like it contains markup at all.
    static func looksLikeMarkup(_ text: String) -> Bool {
        text.contains("<svg") || text.contains("<div") || text.contains("<canvas") || text.contains("<table")
    }

    // MARK: Cleaning the model output

    private static func normalizedFragment(from rawOutput: String) -> String {
        var text = rawOutput.trimmingCharacters(in: .whitespacesAndNewlines)

        // If the model wrapped its answer in a markdown code fence, keep what is inside.
        if let firstFence = text.range(of: "```") {
            var inner = String(text[firstFence.upperBound...])
            if let firstNewline = inner.firstIndex(of: "\n") {
                inner = String(inner[inner.index(after: firstNewline)...])
            }
            if let lastFence = inner.range(of: "```", options: .backwards) {
                inner = String(inner[..<lastFence.lowerBound])
            }
            text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // If the model returned a whole html document, keep its styles and body only.
        let styleBlocks = allMatches(of: #"<style\b[^>]*>.*?</style>"#, in: text)
        var inner: String
        if let bodyInner = firstCapture(of: #"<body\b[^>]*>(.*)</body>"#, in: text) {
            inner = bodyInner
        } else {
            inner = text
        }

        inner = removing(#"<style\b[^>]*>.*?</style>"#, from: inner)
        inner = removing(#"<head\b.*?</head>"#, from: inner)
        inner = removing(#"<!doctype[^>]*>"#, from: inner)
        inner = removing(#"</?(html|body)\b[^>]*>"#, from: inner)
        inner = removing(#"<meta\b[^>]*>"#, from: inner)

        return (styleBlocks + [inner]).joined(separator: "\n")
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
    }

    private static func allMatches(of pattern: String, in text: String) -> [String] {
        guard let expression = regex(pattern) else { return [] }
        let nsText = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: nsText.length))
            .map { nsText.substring(with: $0.range) }
    }

    private static func firstCapture(of pattern: String, in text: String) -> String? {
        guard let expression = regex(pattern) else { return nil }
        let nsText = text as NSString
        guard let match = expression.firstMatch(in: text, range: NSRange(location: 0, length: nsText.length)),
              match.numberOfRanges > 1 else { return nil }
        return nsText.substring(with: match.range(at: 1))
    }

    private static func removing(_ pattern: String, from text: String) -> String {
        guard let expression = regex(pattern) else { return text }
        let nsText = text as NSString
        return expression.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: nsText.length),
            withTemplate: ""
        )
    }

    // MARK: Page assembly

    private static func assemble(fragment: String, threeScript: String?) -> String {
        // Blocks every network request and form post. Inline script and style
        // are allowed so the generated diagram can run and animate.
        let contentSecurityPolicy = "default-src 'none'; img-src data:; style-src 'unsafe-inline'; script-src 'unsafe-inline' 'unsafe-eval'; font-src data:; media-src data:; form-action 'none'; base-uri 'none'"

        var head = """
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <style>\(baseCSS)</style>
        <script>\(dragHelperJavaScript)</script>

        """
        if let threeScript {
            let safeScript = threeScript.replacingOccurrences(of: "</script", with: "<\\/script", options: .caseInsensitive)
            head += "<script>\(safeScript)</script>\n"
        }

        return "<!DOCTYPE html><html><head>\(head)</head><body>\(fragment)<script>\(autoBindJavaScript)</script></body></html>"
    }

    private static let baseCSS = """
    :root { --bg: #0f1318; --panel: #171c23; --line: #2b333d; --text: #e8ecf1; --muted: #9aa5b1; --accent: #3380ff; --green: #34d1a0; --amber: #ffb454; --red: #ff6b81; --violet: #a78bfa; color-scheme: dark; }
    * { box-sizing: border-box; }
    html, body { margin: 0; min-height: 100%; background: var(--bg); color: var(--text); font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; font-size: 14px; }
    body { padding: 16px; }
    h1, h2, h3 { margin: 0 0 12px; font-weight: 650; letter-spacing: -0.01em; }
    h2 { font-size: 19px; }
    svg { display: block; width: 100%; max-width: 100%; height: auto; overflow: visible; }
    svg text { font-family: inherit; fill: var(--text); }
    svg .node { stroke: var(--line); stroke-width: 1.5; }
    svg .label { font-size: 14px; font-weight: 600; }
    svg .caption { font-size: 12px; fill: var(--muted); }
    svg .edge { fill: none; stroke: var(--muted); stroke-width: 2; }
    svg .edge-label { font-size: 12px; fill: var(--muted); }
    svg marker path { fill: var(--muted); }
    .clicky-caption { margin: 10px 2px 0; color: var(--muted); font-size: 13px; line-height: 1.4; }
    .scene { border: 1px solid var(--line); border-radius: 14px; background: linear-gradient(145deg, rgba(51,128,255,.08), rgba(23,28,35,.85)); overflow: hidden; }
    .scene { perspective: 900px; display: flex; align-items: center; justify-content: center; min-height: 420px; user-select: none; }
    .world { position: relative; transform-style: preserve-3d; transform: rotateX(var(--rx, -20deg)) rotateY(var(--ry, 30deg)); }
    """

    /// Defined before the diagram runs so generated scripts can call clickyDrag.
    private static let dragHelperJavaScript = """
    window.clickyDrag = function (element, onDrag) {
      var dragging = false, lastX = 0, lastY = 0;
      element.style.cursor = 'grab';
      element.addEventListener('mousedown', function (event) {
        dragging = true; lastX = event.clientX; lastY = event.clientY; event.preventDefault();
      });
      window.addEventListener('mousemove', function (event) {
        if (!dragging) return;
        onDrag(event.clientX - lastX, event.clientY - lastY);
        lastX = event.clientX; lastY = event.clientY;
      });
      window.addEventListener('mouseup', function () { dragging = false; });
    };
    """

    /// Runs after the diagram is in the page: makes [data-drag-rotate] scenes draggable.
    private static let autoBindJavaScript = """
    (function () {
      var worlds = document.querySelectorAll('[data-drag-rotate]');
      Array.prototype.forEach.call(worlds, function (world) {
        var rx = -20, ry = 30, auto = world.hasAttribute('data-auto-rotate');
        function apply() {
          world.style.setProperty('--rx', rx + 'deg');
          world.style.setProperty('--ry', ry + 'deg');
        }
        apply();
        var target = world.closest('.scene') || world;
        window.clickyDrag(target, function (dx, dy) {
          auto = false;
          ry += dx * 0.5;
          rx -= dy * 0.5;
          rx = Math.max(-89, Math.min(89, rx));
          apply();
        });
        (function tick() {
          if (auto) { ry += 0.25; apply(); }
          requestAnimationFrame(tick);
        })();
      });
    })();
    """
}

// MARK: - The floating window

/// Clicking a window that is not in front should still work, so you can drag
/// to rotate a 3D diagram right away.
final class DiagramWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }
}

@MainActor
final class DiagramPanelController: NSObject, WKNavigationDelegate {

    private var panel: NSPanel?
    private var webView: DiagramWebView?

    private let windowBackgroundColor = NSColor(red: 0.059, green: 0.075, blue: 0.094, alpha: 1)

    /// Shows the window right away with a "drawing..." message.
    func showLoading(title: String) {
        present(
            title: title,
            html: DiagramHTML.messagePage(title: "drawing your diagram", message: title, showSpinner: true)
        )
    }

    /// Replaces the window's contents with the finished diagram.
    func showDiagram(modelOutput: String, title: String) {
        guard DiagramHTML.looksLikeMarkup(modelOutput) else {
            showError("The diagram artist didn't return a drawing. Try asking again, or ask for something simpler.", title: title)
            return
        }
        present(
            title: title,
            html: DiagramHTML.page(fromModelOutput: modelOutput, threeScript: DiagramPrompt.cachedThreeScript)
        )
    }

    func showError(_ message: String, title: String) {
        present(
            title: "couldn't draw that",
            html: DiagramHTML.messagePage(title: "couldn't draw that", message: message, showSpinner: false)
        )
        panel?.title = "clicky · " + Self.shortened(title)
    }

    func close() {
        panel?.orderOut(nil)
    }

    // MARK: - Window

    private func present(title: String, html: String) {
        let (panel, webView) = ensurePanel()
        panel.title = "clicky · " + Self.shortened(title)
        webView.loadHTMLString(html, baseURL: nil)

        if !panel.isVisible {
            position(panel)
        }
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> (NSPanel, DiagramWebView) {
        if let panel, let webView {
            return (panel, webView)
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let webView = DiagramWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.underPageBackgroundColor = windowBackgroundColor

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 580),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.backgroundColor = windowBackgroundColor
        panel.titlebarAppearsTransparent = true
        panel.minSize = NSSize(width: 420, height: 320)
        panel.contentView = webView

        self.panel = panel
        self.webView = webView
        return (panel, webView)
    }

    /// Puts the window on the right side of the screen the mouse is on.
    private func position(_ panel: NSPanel) {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first

        guard let visibleFrame = screen?.visibleFrame else {
            panel.center()
            return
        }

        let width = min(780, visibleFrame.width - 48)
        let height = min(580, visibleFrame.height - 48)
        panel.setContentSize(NSSize(width: width, height: height))

        let frameSize = panel.frame.size
        panel.setFrameOrigin(NSPoint(
            x: visibleFrame.maxX - frameSize.width - 24,
            y: visibleFrame.midY - frameSize.height / 2
        ))
    }

    private static func shortened(_ title: String) -> String {
        title.count > 60 ? String(title.prefix(60)) + "…" : title
    }

    // MARK: - WKNavigationDelegate

    /// The diagram may only ever show its own page. Any attempt to navigate
    /// to a website is cancelled.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        return url.scheme == "about" ? .allow : .cancel
    }
}
