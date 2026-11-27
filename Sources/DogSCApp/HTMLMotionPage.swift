import Foundation

/// Self-contained HTML shared by browser playback and the timeline renderer.
enum HTMLMotionPage {
    private static let previewTag = "<script id=\"dogsc-browser-preview\">"

    /// Ignore our own player when checking content identity or accepting a read/modify/write revision.
    static func authoredPage(_ html: String) -> String {
        var source = html
        if let start = source.range(of: previewTag, options: .backwards),
           let end = source.range(of: "</script>", range: start.upperBound..<source.endIndex) {
            source.removeSubrange(start.lowerBound..<end.upperBound)
        }
        return source.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func standalonePage(_ html: String) -> String {
        guard html.localizedCaseInsensitiveContains("<script") || html.contains("data-split") ||
                html.contains("data-param") else { return html }
        let score = try? MotionSoundScore.read(in: html)
        let player = """
        \(previewTag)
        (() => {
          if (window.__dogscTimelineControlled) return;
          function prepare(p) {
            \(applyPropertiesScript)
          }
          function start() {
            let defaults = {};
            try { defaults = JSON.parse(document.getElementById('dogsc-params')?.textContent || '{}'); } catch {}
            prepare(Object.fromEntries(Object.entries(defaults).map(([key, value]) => [key, String(value)])));
            if (typeof window.dogsc?.seek !== 'function' && !document.getElementById('dogsc-sound')) return;
            const seconds = Number(document.querySelector('meta[name="dogsc-duration"]')?.content);
            const duration = Number.isFinite(seconds) && seconds > 0 ? seconds : 3;
            let origin;
            let audioTime = () => null;
            \(score.map(browserSoundPlayer) ?? "")
            async function frame(now) {
              origin ??= now;
              const t = audioTime() ?? (((now - origin) / 1000) % duration);
              await window.dogsc?.seek?.(t);
              for (const animation of document.getAnimations()) {
                animation.pause();
                animation.currentTime = t * 1000;
              }
              requestAnimationFrame(frame);
            }
            requestAnimationFrame(frame);
          }
          if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, {once: true});
          else start();
        })();
        </script>
        """
        var page = html
        let end = page.range(of: "</body>", options: [.caseInsensitive, .backwards])?.lowerBound ?? page.endIndex
        page.insert(contentsOf: player, at: end)
        return page
    }

    private static func browserSoundPlayer(_ score: MotionSoundScore) -> String {
        let needsLegacyVoices = score.cues.contains { score.customSamples[$0.type] == nil }
        return """
        const cues = JSON.parse(document.getElementById('dogsc-sound').textContent)
          .filter(c => c.at < duration).sort((a, b) => a.at - b.at);
        if (cues.length && window.AudioContext) {
          const button = document.createElement('button');
          button.textContent = '开启试听';
          button.setAttribute('aria-pressed', 'false');
          button.style.cssText = 'position:fixed;right:14px;bottom:14px;z-index:2147483647;padding:7px 12px;border:1px solid #9998;border-radius:16px;background:#222;color:white;font:13px system-ui;cursor:pointer';
          document.body.append(button);
          let context;
          button.onclick = async () => {
            button.disabled = true;
            try {
              if (context) {
                origin = performance.now() - audioTime() * 1000;
                audioTime = () => null;
                await context.close();
                context = null;
              } else {
                context = new AudioContext();
                await context.resume();
                const buffers = {};
                for (const [name, encoded] of Object.entries(\(needsLegacyVoices ? MotionSoundScore.browserBank : "{}"))) {
                  const bytes = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
                  const pcm = new DataView(bytes.buffer);
                  const buffer = context.createBuffer(1, bytes.length / 2, \(MotionSoundScore.rate));
                  const channel = buffer.getChannelData(0);
                  for (let i = 0; i < channel.length; i++) channel[i] = pcm.getInt16(2 * i, true) / 32768;
                  buffers[name] = buffer;
                }
                const bank = JSON.parse(document.getElementById('dogsc-samples')?.textContent || '{}');
                for (const name of new Set(cues.map(c => c.type))) {
                  if (!bank[name]) continue;
                  const bytes = Uint8Array.from(atob(bank[name].split(',')[1]), c => c.charCodeAt(0));
                  buffers[name] = await context.decodeAudioData(bytes.buffer);
                }
                const epoch = context.currentTime + 0.04;
                let cycle = 0, index = 0;
                audioTime = () => {
                  const now = context.currentTime;
                  const elapsed = Math.max(0, now - epoch);
                  const currentCycle = Math.floor(elapsed / duration);
                  if (cycle < currentCycle) { cycle = currentCycle; index = 0; }
                  while (true) {
                    const cue = cues[index];
                    const start = epoch + cycle * duration + cue.at;
                    if (start > now + 0.16) break;
                    const offset = Math.max(0, now - start);
                    const length = Math.min(buffers[cue.type].duration, duration - cue.at) - offset;
                    if (length > 0) {
                      const source = context.createBufferSource();
                      source.buffer = buffers[cue.type];
                      const gain = context.createGain();
                      gain.gain.value = cue.volume * \(MotionSoundScore.defaultVolume);
                      source.connect(gain).connect(context.destination);
                      source.start(Math.max(start, now), offset, length);
                    }
                    if (++index === cues.length) { index = 0; cycle++; }
                  }
                  return elapsed % duration;
                };
                audioTime();
              }
              button.textContent = context ? '关闭试听' : '开启试听';
              button.setAttribute('aria-pressed', String(Boolean(context)));
            } finally { button.disabled = false; }
          };
        }
        """
    }

    /// Shared by the timeline and the standalone browser preview with the page's default fields.
    static let applyPropertiesScript = """
            // A field wins over the page's own declaration wherever the page
            // put it (:root, body, a wrapper): one !important rule for all.
            let fieldStyle = document.getElementById('dogsc-fields');
            if (!fieldStyle) { fieldStyle = document.createElement('style'); fieldStyle.id = 'dogsc-fields'; document.head.appendChild(fieldStyle); }
            const decls = Object.entries(p).map(([k, v]) => '--' + CSS.escape(k) + ':' + String(v).replace(/[;{}<>]/g, '') + ' !important').join(';');
            fieldStyle.textContent = '*, *::before, *::after, :root {' + decls + '}';
            for (const [k, v] of Object.entries(p)) {
              document.documentElement.style.setProperty('--' + k, v);
              document.querySelectorAll('[data-param="' + k + '"]').forEach(e => { e.textContent = v; e.removeAttribute('data-split-done'); });
            }
            // data-split="chars|words": DogSC wraps each letter (or word) in a
            // span with --i (its index) and --n (the count), after every text
            // change, so per-letter CSS keeps working when the user edits it.
            // WebKit clips an animating unit's blur and shadow to the unit's
            // own box (visible as hard tiles mid-animation); a padding that a
            // negative margin cancels gives them room without moving a glyph.
            if (!document.getElementById('dogsc-split-style')) {
              const style = document.createElement('style');
              style.id = 'dogsc-split-style';
              style.textContent = '.dogsc-unit{padding:.4em;margin:-.4em}';
              document.head.prepend(style);
            }
            document.querySelectorAll('[data-split]').forEach(e => {
              if (e.hasAttribute('data-split-done')) return;
              const text = e.textContent;
              const parts = e.dataset.split === 'words' ? text.split(/(\\s+)/) : [...text];
              e.textContent = '';
              let i = 0;
              const units = parts.filter(t => t.trim() !== '').length;
              for (const part of parts) {
                if (part.trim() === '') { e.appendChild(document.createTextNode(part)); continue; }
                const span = document.createElement('span');
                span.textContent = part;
                span.className = 'dogsc-unit';
                span.style.setProperty('--i', i++);
                span.style.setProperty('--n', units);
                e.appendChild(span);
              }
              e.setAttribute('data-split-done', '');
            });
            if (window.dogsc && typeof window.dogsc.params === 'function') { window.dogsc.params(p); }
            return 1;
            """
}
