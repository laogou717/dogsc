import AppKit
import CoreImage
import RecorderCore
import UniformTypeIdentifiers
import WebKit

/// EDT-069 (trial): DogSC HTML Motion — a web page the AI writes, rendered
/// frame by frame. Frames are a pure function of time: every CSS/Web
/// animation is paused and set to the clip time before each snapshot, and
/// pages that animate in script implement `window.dogsc.seek(t)`.
///
/// Editable fields are declared in the page itself:
///
///     <script type="application/json" id="dogsc-params">
///       { "标题": "Kimi K3.1", "主色": "#C4633F" }
///     </script>
///
/// and used through CSS variables `--标题`/`--主色` (each param becomes
/// `--name` on :root) or `data-param="标题"` on an element (its text). The
/// DogSC inspector shows them; edits re-render immediately.
enum HTMLMotion {
    static func isHTMLMotion(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".dmhtml") || lower.hasSuffix(".html")
    }

    /// Keep a placement's soundtrack portable alongside its HTML asset.
    static func placementSound(at path: String, override: URL?) throws -> VisualClipSound? {
        if let override {
            let portable = ProjectFiles.portable(override.path)
            if !portable.hasPrefix("/") { return VisualClipSound(path: portable) }
            guard let package = ProjectFiles.package else { throw CocoaError(.fileNoSuchFile) }
            let folder = package.appendingPathComponent("Inserted", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let copy = folder.appendingPathComponent("sound-" + UUID().uuidString).appendingPathExtension(override.pathExtension)
            try FileManager.default.copyItem(at: override, to: copy)
            return VisualClipSound(path: ProjectFiles.portable(copy.path))
        }
        guard isHTMLMotion(path),
              let html = try? String(contentsOf: ProjectFiles.url(path), encoding: .utf8),
              let score = try MotionSoundScore.read(in: html) else { return nil }
        guard let package = ProjectFiles.package else { throw CocoaError(.fileNoSuchFile) }
        return try VisualClipSound(path: ProjectFiles.portable(score.file(in: package).path), volume: MotionSoundScore.defaultVolume)
    }

    /// Fields the page declares, in declaration order where possible.
    /// Read once per file version: every frame and every inspector redraw
    /// asks, and reading the page from disk each time cost playback frames.
    static func declaredParams(path: String) -> [(name: String, value: MotionParam)] {
        let modified = (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        if let hit = ParamsCache.shared.get(path, modified) { return hit }
        let value = readDeclaredParams(path: path)
        ParamsCache.shared.set(path, modified, value)
        return value
    }

    private final class ParamsCache: @unchecked Sendable {
        static let shared = ParamsCache()
        private let lock = NSLock()
        private var entries: [String: (Date, [(name: String, value: MotionParam)])] = [:]
        func get(_ path: String, _ modified: Date) -> [(name: String, value: MotionParam)]? {
            lock.lock(); defer { lock.unlock() }
            guard let entry = entries[path], entry.0 == modified else { return nil }
            return entry.1
        }
        func set(_ path: String, _ modified: Date, _ value: [(name: String, value: MotionParam)]) {
            lock.lock(); defer { lock.unlock() }
            entries[path] = (modified, value)
        }
    }

    private static func readDeclaredParams(path: String) -> [(name: String, value: MotionParam)] {
        guard let html = try? String(contentsOfFile: path, encoding: .utf8),
              let json = paramsJSON(in: html),
              let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        // Keep the author's order by reading key positions in the JSON text.
        let keys = object.keys.sorted { (json.range(of: "\"\($0)\"")?.lowerBound ?? json.endIndex)
            < (json.range(of: "\"\($1)\"")?.lowerBound ?? json.endIndex) }
        return keys.compactMap { key in
            switch object[key] {
            case let b as Bool where CFGetTypeID(b as CFTypeRef) == CFBooleanGetTypeID(): (key, .boolean(b))
            case let n as NSNumber: (key, .number(n.doubleValue))
            case let s as String: (key, .string(s))
            default: nil
            }
        }
    }

    static func paramsJSON(in html: String) -> String? {
        guard let tag = html.range(of: "id=\"dogsc-params\""),
              let open = html[tag.upperBound...].range(of: ">"),
              let close = html[open.upperBound...].range(of: "</script>") else { return nil }
        return String(html[open.upperBound..<close.lowerBound])
    }

    /// Duration declared as `<meta name="dogsc-duration" content="3">`.
    static func declaredDuration(path: String) -> Double? {
        guard let html = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return declaredDuration(in: html)
    }

    static func declaredDuration(in html: String) -> Double? {
        guard let tag = html.range(of: "name=\"dogsc-duration\""),
              let content = html[tag.upperBound...].range(of: "content=\""),
              let end = html[content.upperBound...].range(of: "\"") else { return nil }
        guard let seconds = Double(html[content.upperBound..<end.lowerBound]), seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    static func cameraSlot(in html: String) -> MotionCameraSlot? {
        guard let tag = html.range(of: "id=\"dogsc-camera-slot\""),
              let open = html[tag.upperBound...].firstIndex(of: ">"),
              let close = html[open...].range(of: "</script>"),
              let slot = try? JSONDecoder().decode(MotionCameraSlot.self,
                  from: Data(html[html.index(after: open)..<close.lowerBound].utf8)),
              slot.isValid else { return nil }
        return slot
    }

    static func cameraSlot(at path: String) -> MotionCameraSlot? {
        guard isHTMLMotion(path), let html = try? String(contentsOfFile: ProjectFiles.resolve(path), encoding: .utf8) else { return nil }
        return cameraSlot(in: html)
    }

    /// EDT-071: the pixel size a main-track motion is drawn at — the screen
    /// frame it fills (the whole canvas when full screen).
    nonisolated static func insertedPixelSize(_ scene: FrameScene) -> CGSize {
        let rect = scene.screen.finalRect
        let w = rect.width > 2 ? rect.width : scene.canvasSize.width
        let h = rect.height > 2 ? rect.height : scene.canvasSize.height
        return CGSize(width: max(w.rounded(), 2), height: max(h.rounded(), 2))
    }

    /// A main-track motion frame, on the frame grid like overlay motions.
    @MainActor
    static func insertedImage(_ scene: FrameScene, frameRate: Int, pixelSize: CGSize? = nil) async -> CIImage? {
        guard let motion = scene.insertedMotion else { return nil }
        let fps = Double(max(frameRate, 1))
        let time = (motion.localTime * fps + 1e-6).rounded(.down) / fps
        return await image(path: ProjectFiles.resolve(motion.sourcePath), properties: motion.properties, time: time,
                           pixelSize: pixelSize ?? insertedPixelSize(scene), edits: motion.elementEdits)
    }

    @MainActor
    static func image(path: String, properties: [String: AnimationPropertyValue], time: Double, pixelSize: CGSize,
                      edits: [String: MotionElementEdit] = [:]) async -> CIImage? {
        await HTMLMotionRenderer.shared.frame(path: path, properties: properties, time: time, pixelSize: pixelSize, edits: edits)
    }

    /// EDT-073: the page's editable elements at `time`, in viewport CSS px.
    @MainActor
    static func elements(path: String, properties: [String: AnimationPropertyValue], time: Double, canvas: CGSize,
                         edits: [String: MotionElementEdit]) async -> [MotionElement] {
        await HTMLMotionRenderer.shared.elements(path: path, properties: properties, time: time, canvas: canvas, edits: edits)
    }
}

/// EDT-073: one element of an HTML motion the user can pick on the canvas.
struct MotionElement: Identifiable, Equatable {
    /// Stable key: the element's id, its data-param, or its position in the page.
    let id: String
    /// What the user sees in the list: data-name, data-param, id or its text.
    let name: String
    let text: String?
    /// text, image, shape or box — which controls the inspector offers.
    var kind: String = "box"
    /// Current text colour and fill as #RRGGBB, when it has one.
    var color: String? = nil
    var fill: String? = nil
    var fontFamily: String? = nil
    var fontWeight: Int? = nil
    /// The element's box at this moment, including any edit, in viewport px.
    let frame: CGRect
    /// The page's CSS viewport (frames are relative to it).
    let viewport: CGSize
}

/// One export owns its pages; preview and inspector work never shares them.
@MainActor
final class ExportHTMLMotionSession {
    private var renderer: HTMLMotionRenderer?
    private var closed = false
    nonisolated init() {}

    func frame(path: String, properties: [String: AnimationPropertyValue], time: Double,
               pixelSize: CGSize, edits: [String: MotionElementEdit]) async -> CIImage? {
        guard !closed, !Task.isCancelled else { return nil }
        let renderer = self.renderer ?? HTMLMotionRenderer()
        self.renderer = renderer
        return await renderer.frame(path: path, properties: properties, time: time, pixelSize: pixelSize, edits: edits)
    }

    func close() {
        closed = true
        renderer?.close()
        renderer = nil
    }
}

/// One off-screen web view per file (kept warm), driven by explicit seeks.
@MainActor
final class HTMLMotionRenderer: NSObject, WKNavigationDelegate {
    static let shared = HTMLMotionRenderer()

    private final class Page {
        let web: WKWebView
        let window: NSWindow
        var loaded = false
        var waiters: [CheckedContinuation<Void, Never>] = []
        var appliedProperties = ""
        var appliedEdits: String?
        var viewport: CGSize
        var modified: Date
        var busy = false
        var splitApplied = false
        var retired = false
        var queue: [CheckedContinuation<Void, Never>] = []
        init(web: WKWebView, window: NSWindow, viewport: CGSize, modified: Date) {
            self.web = web; self.window = window; self.viewport = viewport; self.modified = modified
        }
    }

    private var pages: [String: Page] = [:]

    private func acquire(_ page: Page) async {
        if page.busy {
            await withCheckedContinuation { page.queue.append($0) }
        } else {
            page.busy = true
        }
    }

    private func release(_ page: Page) {
        if page.queue.isEmpty {
            page.busy = false
        } else {
            // Transfer ownership directly. Clearing busy before the resumed
            // waiter runs lets a newcomer interleave seek and snapshot.
            page.queue.removeFirst().resume()
        }
    }

    private func configureViewport(_ page: Page, size: CGSize) {
        guard page.viewport != size else { return }
        page.viewport = size
        page.window.setContentSize(size)
        page.web.frame = CGRect(origin: .zero, size: size)
        page.appliedProperties = ""
        page.appliedEdits = nil
    }

    private func retire(_ page: Page) {
        page.retired = true
        page.web.navigationDelegate = nil
        page.web.stopLoading()
        page.window.close()
        let waiting = page.waiters + page.queue
        page.waiters = []
        page.queue = []
        waiting.forEach { $0.resume() }
    }

    func close() {
        let retired = Array(pages.values)
        pages.removeAll()
        retired.forEach(retire)
    }

    /// Pages are laid out in CSS pixels on a viewport with the canvas's own
    /// aspect, 1080 CSS px on the short side (1920×1080 for 16:9, 1080×1920
    /// for 9:16), and rasterised at the real output size — so 4K and 5K
    /// renders are drawn sharp, not scaled up.
    nonisolated static func viewport(for canvas: CGSize) -> CGSize {
        let w = max(canvas.width, 2), h = max(canvas.height, 2)
        let scale = 1080 / min(w, h)
        return CGSize(width: (w * scale).rounded(), height: (h * scale).rounded())
    }

    func frame(path: String, properties: [String: AnimationPropertyValue], time: Double, pixelSize: CGSize,
               edits: [String: MotionElementEdit] = [:]) async -> CIImage? {
        guard let page = await page(for: path, viewport: Self.viewport(for: pixelSize)) else { return nil }
        // One frame at a time per page: seek and snapshot must not interleave.
        await acquire(page)
        defer { release(page) }
        guard !Task.isCancelled, !page.retired else { return nil }
        configureViewport(page, size: Self.viewport(for: pixelSize))
        // Every declared field is written each time (the page's own value
        // when the user has not set one), so clearing a field restores it.
        var merged: [String: AnimationPropertyValue] = [:]
        for (name, value) in HTMLMotion.declaredParams(path: path) {
            merged[name] = switch value {
            case let .string(s): s.hasPrefix("#") ? HexColor(s).map { .color($0) } ?? .string(s) : .string(s)
            case let .number(n): .number(n)
            case let .boolean(b): .boolean(b)
            }
        }
        merged.merge(properties) { _, user in user }
        await prepare(page, merged: merged, edits: edits)
        do { _ = try await page.web.callAsyncJavaScript("""
            const ms = t * 1000;
            if (window.dogsc && typeof window.dogsc.seek === 'function') { await window.dogsc.seek(t); }
            for (const a of document.getAnimations()) { a.pause(); a.currentTime = ms; }
            document.body && document.body.offsetHeight;
            return 1;
            """, arguments: ["t": max(time, 0)], contentWorld: .page)
        } catch { return nil }
        let config = WKSnapshotConfiguration()
        config.rect = CGRect(origin: .zero, size: page.viewport)
        // snapshotWidth is in points; WebKit renders at the screen's scale,
        // so ask for exactly the pixels needed (vector text stays sharp).
        let backing = page.window.backingScaleFactor
        config.snapshotWidth = NSNumber(value: Double(max(pixelSize.width, 2) / max(backing, 1)))
        config.afterScreenUpdates = true
        guard let image = try? await page.web.takeSnapshot(configuration: config) else { return nil }
        // NSImage.cgImage may redraw/color-convert the entire snapshot rather
        // than return its backing pixels. Profiling found that conversion
        // consuming most of the main thread during HTML playback. Transfer
        // this one-use image exclusively to a worker; WebKit stays on main.
        let pixels = HTMLMotionSnapshotPixels(image: image)
        guard let ci = await Task.detached(priority: .userInitiated, operation: {
            pixels.image()
        }).value, !Task.isCancelled else { return nil }
        // WebKit rounds the viewport and snapshot to whole pixels independently.
        // Map that raster to the requested rectangle, including its last row.
        let target = CGRect(origin: .zero, size: pixelSize)
        guard ci.extent != target else { return ci }
        guard ci.extent.width > 0, ci.extent.height > 0 else { return nil }
        return ci.clampedToExtent()
            .transformed(by: CGAffineTransform(translationX: -ci.extent.minX, y: -ci.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: target.width / ci.extent.width, y: target.height / ci.extent.height))
            .cropped(to: target)
    }


    /// Writes fields, then element edits, only when they changed.
    private func prepare(_ page: Page, merged: [String: AnimationPropertyValue], edits: [String: MotionElementEdit]) async {
        let props = Self.propertiesScript(merged)
        if props != page.appliedProperties || !page.splitApplied {
            page.splitApplied = true
            page.appliedProperties = props
            page.appliedEdits = nil
            _ = try? await page.web.callAsyncJavaScript(props, contentWorld: .page)
        }
        let editsScript = Self.editsScript(edits)
        if editsScript != page.appliedEdits {
            page.appliedEdits = editsScript
            _ = try? await page.web.callAsyncJavaScript(editsScript, contentWorld: .page)
        }
    }

    func elements(path: String, properties: [String: AnimationPropertyValue], time: Double, canvas: CGSize,
                  edits: [String: MotionElementEdit]) async -> [MotionElement] {
        let viewport = Self.viewport(for: canvas)
        guard let page = await page(for: path, viewport: viewport) else { return [] }
        await acquire(page)
        defer { release(page) }
        guard !Task.isCancelled, !page.retired else { return [] }
        configureViewport(page, size: viewport)
        var merged: [String: AnimationPropertyValue] = [:]
        for (name, value) in HTMLMotion.declaredParams(path: path) {
            merged[name] = switch value {
            case let .string(s): s.hasPrefix("#") ? HexColor(s).map { .color($0) } ?? .string(s) : .string(s)
            case let .number(n): .number(n)
            case let .boolean(b): .boolean(b)
            }
        }
        merged.merge(properties) { _, user in user }
        await prepare(page, merged: merged, edits: edits)
        let raw = try? await page.web.callAsyncJavaScript(Self.elementsScript, arguments: ["t": max(time, 0)], contentWorld: .page)
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let key = item["key"] as? String, let name = item["name"] as? String,
                  let x = (item["x"] as? NSNumber)?.doubleValue, let y = (item["y"] as? NSNumber)?.doubleValue,
                  let w = (item["w"] as? NSNumber)?.doubleValue, let h = (item["h"] as? NSNumber)?.doubleValue else { return nil }
            return MotionElement(id: key, name: name, text: item["text"] as? String,
                                 kind: item["kind"] as? String ?? "box",
                                 color: item["color"] as? String, fill: item["fill"] as? String,
                                 fontFamily: item["fontFamily"] as? String, fontWeight: item["fontWeight"] as? Int,
                                 frame: CGRect(x: x, y: y, width: w, height: h), viewport: viewport)
        }
    }

    /// Applies the user's element edits on top of the page's own animation:
    /// the CSS `translate` property composes with any animated `transform`.
    private static func editsScript(_ edits: [String: MotionElementEdit]) -> String {
        var object: [String: Any] = [:]
        for (key, edit) in edits where !edit.isEmpty {
            var entry: [String: Any] = ["dx": edit.dx, "dy": edit.dy, "hidden": edit.hidden, "scale": edit.scale]
            if let text = edit.text { entry["text"] = text }
            if let color = edit.color { entry["color"] = color }
            if let family = edit.fontFamily { entry["fontFamily"] = family }
            if let weight = edit.fontWeight { entry["fontWeight"] = weight }
            if let fill = edit.fill { entry["fill"] = fill }
            if let radius = edit.radius { entry["radius"] = radius }
            if let width = edit.strokeWidth { entry["strokeWidth"] = width }
            if let stroke = edit.strokeColor { entry["strokeColor"] = stroke }
            if edit.rotation != 0 { entry["rotation"] = edit.rotation }
            if edit.opacity != 1 { entry["opacity"] = edit.opacity }
            if let image = edit.image, let data = try? Data(contentsOf: ProjectFiles.url(image)) {
                // Inlined: the page is loaded from a string and has no file access.
                let type = UTType(filenameExtension: URL(fileURLWithPath: image).pathExtension)?.preferredMIMEType ?? "image/png"
                entry["image"] = "data:\(type);base64," + data.base64EncodedString()
            }
            object[key] = entry
        }
        let json = (try? JSONSerialization.data(withJSONObject: object)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
            \(elementKeyScript)
            const edits = \(json);
            // Restore inline typography exactly, including !important, before
            // applying this revision. Undo/default must recover the page font.
            for (const el of document.querySelectorAll('[data-dogsc-typography]')) {
              const original = JSON.parse(el.getAttribute('data-dogsc-typography'));
              for (const [property, value, priority] of original) {
                if (value) el.style.setProperty(property, value, priority);
                else el.style.removeProperty(property);
              }
              el.removeAttribute('data-dogsc-typography');
            }
            for (const el of document.querySelectorAll('[data-dogsc-bglayer]')) el.remove();
            for (const el of document.querySelectorAll('[data-dogsc-edited]')) {
              el.style.removeProperty('isolation');
              el.style.translate = ''; el.style.visibility = ''; el.style.scale = '';
              el.style.removeProperty('color'); el.style.removeProperty('background-color'); el.style.removeProperty('fill');
              el.style.removeProperty('background-image'); el.style.removeProperty('background-size'); el.style.removeProperty('background');
              el.style.removeProperty('border-color'); el.style.rotate = '';
              for (const p of ['border-radius', 'outline', 'outline-offset', 'opacity', 'stroke', 'stroke-width']) el.style.removeProperty(p);
              el.removeAttribute('data-dogsc-edited');
              if (el.dataset.dogscOriginal !== undefined) { el.textContent = el.dataset.dogscOriginal; delete el.dataset.dogscOriginal; }
              if (el.dataset.dogscSrc !== undefined) { el.setAttribute('src', el.dataset.dogscSrc); delete el.dataset.dogscSrc; }
              if (el.dataset.dogscBg !== undefined) { el.style.backgroundImage = el.dataset.dogscBg; delete el.dataset.dogscBg; }
            }
            const bgEdit = edits['background'];
            const bgEl = dogscBackground();
            if (bgEdit) {
              bgEl.setAttribute('data-dogsc-edited', '');
              if (bgEdit.fill) { bgEl.style.setProperty('background-color', bgEdit.fill, 'important'); }
              if (bgEdit.image) {
                // Its own layer just above the background and below every
                // child, so full-screen gradients or canvases can't cover it.
                const layer = document.createElement('div');
                layer.setAttribute('data-dogsc-bglayer', '');
                layer.style.cssText = 'position:' + (bgEl === document.body ? 'fixed' : 'absolute') + ';inset:0;z-index:-1;pointer-events:none;background:center/cover no-repeat url("' + bgEdit.image + '")';
                if (bgEl !== document.body && getComputedStyle(bgEl).position === 'static') bgEl.style.setProperty('position', 'relative');
                bgEl.style.setProperty('isolation', 'isolate');
                bgEl.append(layer); // appended: index-based element keys stay put
                for (const c of bgEl.children) {
                  if (c === layer) continue;
                  const r = c.getBoundingClientRect(), cs = getComputedStyle(c);
                  if (r.width >= innerWidth * 0.95 && r.height >= innerHeight * 0.95 && (c.tagName === 'CANVAS' || (cs.backgroundImage || 'none') !== 'none')) {
                    c.setAttribute('data-dogsc-edited', ''); c.style.setProperty('visibility', 'hidden');
                  }
                }
              }
              else if (bgEdit.fill) { bgEl.style.setProperty('background-image', 'none', 'important'); }
              if (bgEdit.hidden) { bgEl.style.setProperty('background', 'transparent', 'important'); }
            }
            for (const el of dogscElements()) {
              const e = edits[dogscKey(el)];
              if (!e) continue;
              // Typography has its own reversible style snapshot. A font-only
              // edit must not make the generic reset erase authored colours.
              const fontOnly = !e.dx && !e.dy && !e.hidden && e.scale === 1 &&
                Object.keys(e).every(k => ['dx', 'dy', 'hidden', 'scale', 'fontFamily', 'fontWeight'].includes(k));
              if (!fontOnly) el.setAttribute('data-dogsc-edited', '');
              if (e.dx || e.dy) el.style.translate = e.dx + 'px ' + e.dy + 'px';
              if (e.hidden) el.style.visibility = 'hidden';
              if (e.scale && Math.abs(e.scale - 1) > 0.0001) el.style.scale = String(e.scale);
              if (e.color) el.style.setProperty('color', e.color, 'important');
              if (e.fontFamily || typeof e.fontWeight === 'number') {
                const textNodes = [el, ...el.querySelectorAll('*')].filter(node => node === el ||
                  [...node.childNodes].some(c => c.nodeType === 3 && c.textContent.trim()));
                for (const node of textNodes) {
                  if (!node.hasAttribute('data-dogsc-typography')) {
                    node.setAttribute('data-dogsc-typography', JSON.stringify(['font-family', 'font-weight'].map(p =>
                      [p, node.style.getPropertyValue(p), node.style.getPropertyPriority(p)])));
                  }
                  if (e.fontFamily) node.style.setProperty('font-family', JSON.stringify(e.fontFamily) + ', sans-serif', 'important');
                  if (typeof e.fontWeight === 'number') node.style.setProperty('font-weight', String(e.fontWeight), 'important');
                }
              }
              if (typeof e.rotation === 'number') el.style.rotate = e.rotation + 'deg';
              if (typeof e.opacity === 'number') el.style.setProperty('opacity', String(e.opacity), 'important');
              if (typeof e.radius === 'number') el.style.setProperty('border-radius', e.radius + 'px', 'important');
              if (typeof e.strokeWidth === 'number' || e.strokeColor) {
                const w = typeof e.strokeWidth === 'number' ? e.strokeWidth : 2, c = e.strokeColor || 'currentColor';
                if (el.tagName.toLowerCase() === 'svg') { el.style.setProperty('stroke', c, 'important'); el.style.setProperty('stroke-width', String(w), 'important'); }
                else { el.style.setProperty('outline', w > 0 ? (w + 'px solid ' + c) : 'none', 'important'); el.style.setProperty('outline-offset', (-w) + 'px', 'important'); }
              }
              if (e.fill) {
                const cs = getComputedStyle(el);
                const bgPainted = cs.backgroundColor !== 'rgba(0, 0, 0, 0)' || (cs.backgroundImage || 'none') !== 'none';
                if (el.tagName.toLowerCase() === 'svg') el.style.setProperty('fill', e.fill, 'important');
                else if (!bgPainted && parseFloat(cs.borderTopWidth) + parseFloat(cs.borderLeftWidth) > 0) el.style.setProperty('border-color', e.fill, 'important');
                else el.style.setProperty('background-color', e.fill, 'important');
              }
              if (e.image) {
                if (el.tagName === 'IMG') { el.dataset.dogscSrc = el.getAttribute('src') || ''; el.setAttribute('src', e.image); }
                else { el.dataset.dogscBg = el.style.backgroundImage || ''; el.style.backgroundImage = 'url("' + e.image + '")'; }
              }
              if (typeof e.text === 'string' && !el.querySelector('.dogsc-unit') && el.children.length === 0) {
                el.dataset.dogscOriginal = el.textContent; el.textContent = e.text;
              }
            }
            return 1;
            """
    }

    /// Which elements are pickable and their stable keys. An element with
    /// an id, a data-param or a data-name is one; so is any element that
    /// holds text or is a leaf drawing (svg, img, canvas) directly under the
    /// page's layout. Units of split text are never picked on their own.
    private static let elementKeyScript = """
        function dogscKey(el) {
          if (el.id) return '#' + el.id;
          if (el.dataset.param) return 'param:' + el.dataset.param;
          if (el.dataset.name) return 'name:' + el.dataset.name;
          const path = []; let n = el;
          while (n && n !== document.body) { path.unshift(Array.prototype.indexOf.call(n.parentElement.children, n)); n = n.parentElement; }
          return 'path:' + path.join('.');
        }
        // Anything that is drawn is pickable: text, pictures, shapes and
        // decoration (lines, dots, rings, bars — an empty element painted by
        // a background, border or shadow). Pure layout wrappers are not; nor
        // are split-text units on their own. A full-frame layer is the page
        // background (see dogscBackground), not an element.
        function dogscPaints(el, cs) {
          const bg = cs.backgroundColor, img = cs.backgroundImage || 'none';
          const paintedBg = (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent') || img !== 'none';
          const border = ['Top', 'Right', 'Bottom', 'Left'].some(s => parseFloat(cs['border' + s + 'Width']) > 0
            && cs['border' + s + 'Style'] !== 'none' && cs['border' + s + 'Color'] !== 'rgba(0, 0, 0, 0)');
          return paintedBg || border || (cs.boxShadow && cs.boxShadow !== 'none');
        }
        function dogscElements() {
          const out = [];
          for (const el of document.body.querySelectorAll('*')) {
            if (el.closest('.dogsc-unit') || ['SCRIPT', 'STYLE', 'META', 'BR', 'TEMPLATE'].includes(el.tagName)) continue;
            if (el.closest('svg') && el.tagName.toLowerCase() !== 'svg') continue;
            const cs = getComputedStyle(el);
            if (cs.display === 'none') continue;
            const named = el.id || el.dataset.param || el.dataset.name;
            const ownText = [...el.childNodes].some(c => c.nodeType === 3 && c.textContent.trim()) || el.querySelector(':scope > .dogsc-unit');
            const tag = el.tagName.toLowerCase();
            const drawing = ['svg', 'img', 'canvas', 'video'].includes(tag);
            const r = el.getBoundingClientRect();
            const fullFrame = r.width >= innerWidth * 0.95 && r.height >= innerHeight * 0.95;
            if (fullFrame) continue;
            // A wrapper whose children carry the drawing is not itself a target
            // unless it paints something or is named.
            const leafish = el.children.length === 0 || ownText;
            if (!(named || ownText || drawing || (dogscPaints(el, cs) && (leafish || !el.querySelector('*'))) || (dogscPaints(el, cs) && el.children.length <= 1))) continue;
            out.push(el);
          }
          return out;
        }
        // The page background: the first full-frame layer that paints, or body.
        function dogscBackground() {
          for (const el of [document.body, ...document.body.querySelectorAll(':scope > *, :scope > * > *')]) {
            const r = el.getBoundingClientRect();
            if (r.width >= innerWidth * 0.95 && r.height >= innerHeight * 0.95) {
              const cs = getComputedStyle(el);
              if (cs.backgroundColor !== 'rgba(0, 0, 0, 0)' || (cs.backgroundImage || 'none') !== 'none') return el;
            }
          }
          return document.body;
        }
        """

    private static let elementsScript = """
        \(elementKeyScript)
        const ms = t * 1000;
        if (window.dogsc && typeof window.dogsc.seek === 'function') { await window.dogsc.seek(t); }
        for (const a of document.getAnimations()) { a.pause(); a.currentTime = ms; }
        const bg = dogscBackground(), bgcs = getComputedStyle(bg);
        const bgHex = (() => { const m = (bgcs.backgroundColor || '').match(/\\d+(\\.\\d+)?/g); if (!m || m.length < 3) return null;
          return '#' + m.slice(0, 3).map(v => (+v).toString(16).padStart(2, '0')).join('').toUpperCase(); })();
        const background = { key: 'background', name: '背景', text: null, x: 0, y: 0, w: innerWidth, h: innerHeight,
          kind: 'background', color: null, fill: bgHex };
        return [background].concat(dogscElements().map(el => {
          const r = el.getBoundingClientRect();
          const cs = getComputedStyle(el);
          const tag = el.tagName.toLowerCase();
          const text = el.querySelector('.dogsc-unit') || [...el.childNodes].some(c => c.nodeType === 3 && c.textContent.trim())
            ? el.textContent.trim() : null;
          const shape = (() => {
            if (tag === 'img') return '图片';
            if (tag === 'svg') return '图形';
            const r0 = el.getBoundingClientRect();
            const radiusText = cs.borderTopLeftRadius || '0';
            const radius = radiusText.includes('%') ? parseFloat(radiusText) / 100 * Math.min(r0.width, r0.height) : parseFloat(radiusText);
            const round = radius >= Math.min(r0.width, r0.height) / 2 - 1;
            const thin = Math.min(r0.width, r0.height) <= 8;
            const ringOnly = cs.backgroundColor === 'rgba(0, 0, 0, 0)' && parseFloat(cs.borderTopWidth) > 0;
            if (thin) return '线条';
            if (round && ringOnly) return '圆环';
            if (round) return r0.width < 60 ? '圆点' : '圆形';
            if ((cs.backgroundImage || 'none').includes('url(')) return '图片';
            return '色块';
          })();
          const name = el.dataset.name || el.dataset.param || (el.id && !/^[a-z]{1,3}\\d*$/i.test(el.id) ? el.id : null)
            || (text ? text.slice(0, 18) : shape);
          const image = tag === 'img' || (cs.backgroundImage || 'none').includes('url(');
          const hex = c => { const m = (c || '').match(/\\d+(\\.\\d+)?/g); if (!m || m.length < 3 || (m.length > 3 && +m[3] === 0)) return null;
            return '#' + m.slice(0, 3).map(v => (+v).toString(16).padStart(2, '0')).join('').toUpperCase(); };
          const kind = image ? 'image' : text ? 'text' : (tag === 'svg' ? 'shape' : 'box');
          return { key: dogscKey(el), name, text, x: r.x, y: r.y, w: r.width, h: r.height, kind,
                   color: text ? hex(cs.color) : null,
                   fontFamily: text ? cs.fontFamily : null, fontWeight: text ? parseInt(cs.fontWeight) || 400 : null,
                   fill: tag === 'svg' ? hex(cs.fill) : (hex(cs.backgroundColor) || hex(cs.borderTopColor)) };
        }).filter(e => e.w >= 1 && e.h >= 1 && (e.w > 2 || e.h > 2)));
        """

    private func page(for path: String, viewport: CGSize) async -> Page? {
        let url = URL(fileURLWithPath: path)
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if let page = pages[path], page.modified == modified {
            if !page.loaded { await withCheckedContinuation { page.waiters.append($0) } }
            return page
        }
        if let previous = pages.removeValue(forKey: path) { retire(previous) }
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(WKUserScript(source: "window.__dogscTimelineControlled = true;",
            injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.suppressesIncrementalRendering = true
        let web = WKWebView(frame: CGRect(origin: .zero, size: viewport), configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        web.navigationDelegate = self
        // WebKit only paints views that are in a window; this one is far
        // off screen, transparent and never shown.
        let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: viewport),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderBack(nil)
        let page = Page(web: web, window: window, viewport: viewport, modified: modified)
        pages[path] = page
        // Loaded as an HTML string: WebKit decides the type of a file URL by
        // its extension and would not render `.dmhtml` as a page.
        guard let html = try? String(contentsOf: url, encoding: .utf8) else {
            pages[path] = nil
            window.close()
            return nil
        }
        web.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        // Never wait forever: a page that fails or stalls renders nothing.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.markLoaded(web)
        }
        await withCheckedContinuation { page.waiters.append($0) }
        return page.loaded ? page : nil
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            // Fonts must be ready before the first frame is taken.
            _ = try? await webView.callAsyncJavaScript("await document.fonts.ready; return 1;", contentWorld: .page)
            self.markLoaded(webView)
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.markLoaded(webView) }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in self.markLoaded(webView) }
    }

    private func markLoaded(_ webView: WKWebView) {
        guard let page = pages.values.first(where: { $0.web === webView }), !page.waiters.isEmpty || !page.loaded else { return }
        page.loaded = true
        let waiting = page.waiters
        page.waiters = []
        waiting.forEach { $0.resume() }
    }

    /// Writes each param as a CSS variable and into `[data-param]` elements.
    private static func propertiesScript(_ properties: [String: AnimationPropertyValue]) -> String {
        var pairs: [String: String] = [:]
        for (key, value) in properties {
            pairs[key] = switch value {
            case let .string(s): s
            case let .number(n): n == n.rounded() ? String(Int(n)) : String(n)
            case let .boolean(b): b ? "1" : "0"
            case let .color(hex): "#" + hex.hexString.replacingOccurrences(of: "#", with: "")
            }
        }
        let json = (try? JSONSerialization.data(withJSONObject: pairs)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return "const p = \(json);\n" + HTMLMotionPage.applyPropertiesScript
    }


}

/// A field a motion file declares (DogSC HTML Motion `dogsc-params`).
enum MotionParam: Equatable {
    case string(String)
    case number(Double)
    case boolean(Bool)
}

/// No view or window is used here. Each instance exclusively owns one returned
/// snapshot and is read by one worker only, as required for NSImage threading.
private final class HTMLMotionSnapshotPixels: @unchecked Sendable {
    private let snapshot: NSImage

    init(image: NSImage) { snapshot = image }

    func image() -> CIImage? {
        autoreleasepool {
            // A bitmap representation already has a CGImage. Avoid asking
            // NSImage to redraw it into an ambient window/HDR context.
            let representations = snapshot.representations
            if representations.count == 1,
               let bitmap = representations.first as? NSBitmapImageRep,
               let image = bitmap.cgImage {
                return CIImage(cgImage: image)
            }
            guard let image = snapshot.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
            return CIImage(cgImage: image)
        }
    }
}

/// Every caller renders and inspects motion graphics through here.
enum AnimationFrames {
    struct DeclaredProperty: Identifiable, Equatable {
        enum Kind { case string, number, boolean, color }
        let name: String
        let kind: Kind
        /// The file's own value, shown until the user changes it.
        var defaultValue: AnimationPropertyValue? = nil
        var id: String { name }
    }

    /// Resolves a clip path against the project package for relative paths.
    static func fileURL(for sourcePath: String, projectURL: URL?) -> URL {
        if sourcePath.hasPrefix("/") { return URL(fileURLWithPath: sourcePath) }
        if let projectURL { return projectURL.appendingPathComponent(sourcePath) }
        return ProjectFiles.url(sourcePath)
    }

    /// One frame on the project frame grid. Files of retired formats (Rive,
    /// DogSC Motion JSON) draw nothing.
    @MainActor
    static func image(for scene: FrameAnimationScene, frameRate: Int, pixelSize: CGSize, projectURL: URL?) async -> CIImage? {
        guard HTMLMotion.isHTMLMotion(scene.sourcePath) else { return nil }
        let fps = Double(max(frameRate, 1))
        let time = (scene.localTime * fps + 1e-6).rounded(.down) / fps
        let path = fileURL(for: scene.sourcePath, projectURL: projectURL).path
        return await HTMLMotion.image(path: path, properties: scene.properties, time: time, pixelSize: pixelSize,
                                      edits: scene.elementEdits)
    }

    @MainActor
    static func declaredProperties(sourcePath: String) async -> [DeclaredProperty] {
        guard HTMLMotion.isHTMLMotion(sourcePath) else { return [] }
        return HTMLMotion.declaredParams(path: ProjectFiles.resolve(sourcePath)).map { name, value in
            switch value {
            case let .string(s):
                if s.hasPrefix("#"), let hex = HexColor(s) {
                    .init(name: name, kind: .color, defaultValue: .color(hex))
                } else {
                    .init(name: name, kind: .string, defaultValue: .string(s))
                }
            case let .number(n): .init(name: name, kind: .number, defaultValue: .number(n))
            case let .boolean(b): .init(name: name, kind: .boolean, defaultValue: .boolean(b))
            }
        }
    }
}
