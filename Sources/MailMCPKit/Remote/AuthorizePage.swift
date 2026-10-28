import Foundation

/// The page a browser opens when a remote client connects: which app asks, where approving sends the browser, what it
/// may do, and two ways to say yes (the passcode, or Allow in the menu bar app). One self-contained page: its script
/// carries a nonce, nothing loads from elsewhere, and no other site may frame it.
enum AuthorizePage {
    /// What differs between the servers that share this page.
    enum Wording {
        static let product = "Apple Mail MCP"
        static let full = ("Full access", "Search, read, organize and draft. Sending and big changes still ask on your Mac.")
        static let readOnly = ("Read only", "Search and read. Nothing is moved, drafted or sent.")
        /// An envelope, drawn in the accent colour.
        static let glyph = #"<path d="M4 7.5A2.5 2.5 0 0 1 6.5 5h11A2.5 2.5 0 0 1 20 7.5v9a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5z"/><path d="m5 7 7 5.5L19 7"/>"#
    }

    static func response(_ html: (body: String, nonce: String), status: Int = 200) -> HTTPListener.Response {
        .full(
            status: status,
            headers: [
                "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
                "Content-Security-Policy": "default-src 'none'; script-src 'nonce-\(html.nonce)'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
            ],
            body: Data(html.body.utf8))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    static let style = """
        :root { color-scheme: light dark; --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7;
                --field: #fff; --accent: #0071e3; --accent-soft: rgba(0, 113, 227, .08); --danger: #d70015; --ok: #248a3d;
                --ease-out: cubic-bezier(.23, 1, .32, 1); }
        @media (prefers-color-scheme: dark) {
          :root { --bg: #000; --card: #1c1c1e; --text: #f5f5f7; --muted: #98989d; --line: #3a3a3c; --field: #2c2c2e;
                  --accent: #0a84ff; --accent-soft: rgba(10, 132, 255, .14); --danger: #ff453a; --ok: #30d158; }
        }
        * { box-sizing: border-box; }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--text);
               font: 15px/1.47 system-ui, -apple-system, sans-serif; padding: 16px; -webkit-font-smoothing: antialiased; }
        main { width: 100%; max-width: 400px; background: var(--card); border: 1px solid var(--line); border-radius: 18px; padding: 28px 24px 18px;
               box-shadow: 0 1px 2px rgba(0,0,0,.04), 0 8px 32px rgba(0,0,0,.06); }
        .glyph { width: 44px; height: 44px; border-radius: 11px; display: grid; place-items: center; background: var(--accent-soft); margin-bottom: 14px; }
        .glyph svg { width: 26px; height: 26px; fill: none; stroke: var(--accent); stroke-width: 1.7; stroke-linecap: round; stroke-linejoin: round; }
        .eyebrow { font-size: 12px; font-weight: 600; letter-spacing: .02em; color: var(--muted); margin: 0 0 2px; }
        h1 { font-size: 22px; line-height: 1.2; letter-spacing: -.015em; font-weight: 650; margin: 0 0 6px; }
        p { margin: 0; }
        .muted { color: var(--muted); font-size: 13px; }
        fieldset { border: 0; padding: 0; margin: 20px 0 0; display: grid; gap: 8px; }
        legend, .label { font-size: 12px; font-weight: 600; color: var(--muted); margin-bottom: 6px; padding: 0; }
        .option { display: grid; grid-template-columns: 18px 1fr; gap: 10px; align-items: start; padding: 11px 12px; border: 1px solid var(--line);
                  border-radius: 11px; cursor: pointer; transition: border-color 150ms ease, background-color 150ms ease; }
        .option:has(input:checked) { border-color: var(--accent); background: var(--accent-soft); }
        .option input { margin: 3px 0 0; accent-color: var(--accent); }
        .option b { font-weight: 600; display: block; }
        .option small { color: var(--muted); font-size: 13px; line-height: 1.38; display: block; margin-top: 1px; }
        .approve { margin-top: 22px; }
        .field { display: flex; gap: 8px; }
        input[type=password] { flex: 1; min-width: 0; font: inherit; padding: 10px 12px; border-radius: 10px; border: 1px solid var(--line);
                               background: var(--field); color: inherit; transition: border-color 150ms ease, box-shadow 150ms ease; }
        input[type=password]:focus { outline: none; border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-soft); }
        input[type=password][aria-invalid=true] { border-color: var(--danger); }
        button { font: inherit; font-weight: 600; padding: 10px 16px; border-radius: 10px; border: 1px solid var(--line); background: var(--field);
                 color: inherit; cursor: pointer; display: inline-flex; align-items: center; justify-content: center; gap: 8px;
                 transition: transform 160ms var(--ease-out), background-color 150ms ease, opacity 150ms ease; }
        button:active:not(:disabled) { transform: scale(.97); }
        button:focus-visible, .option:has(input:focus-visible) { outline: 3px solid var(--accent-soft); outline-offset: 1px; }
        button:disabled { opacity: .55; cursor: default; }
        button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
        button.wide { width: 100%; }
        button.quiet { border: 0; background: none; color: var(--muted); font-weight: 500; padding: 8px; }
        @media (hover: hover) and (pointer: fine) {
          button.primary:hover:not(:disabled) { filter: brightness(1.07); }
          button.quiet:hover { color: var(--text); }
        }
        .or { display: flex; align-items: center; gap: 10px; color: var(--muted); font-size: 12px; margin: 14px 0; }
        .or::before, .or::after { content: ""; flex: 1; border-top: 1px solid var(--line); }
        .spinner { width: 14px; height: 14px; border-radius: 50%; border: 2px solid currentColor; border-right-color: transparent;
                   animation: spin 700ms linear infinite; display: none; }
        .busy .spinner { display: inline-block; }
        @keyframes spin { to { transform: rotate(360deg); } }
        #message { margin-top: 10px; font-size: 13px; color: var(--danger); }
        #message:empty { margin: 0; }
        #message.wait { color: var(--muted); }
        footer { margin-top: 10px; text-align: center; }
        .done { text-align: center; padding: 12px 0 8px; }
        .done .check { width: 44px; height: 44px; margin: 0 auto 12px; border-radius: 50%; background: var(--ok); display: grid; place-items: center; }
        .done .check svg { width: 22px; height: 22px; stroke: #fff; stroke-width: 2.6; fill: none; stroke-linecap: round; stroke-linejoin: round; }
        .hidden { display: none !important; }
        @media (prefers-reduced-motion: reduce) {
          button, .option, input { transition: none; }
          button:active:not(:disabled) { transform: none; }
          .spinner { animation-duration: 2s; }
        }
        @media (prefers-contrast: more) { :root { --line: #8e8e93; --muted: #3a3a3c; } }
        """

    static func page(title: String, content: String, script: String = "") -> (body: String, nonce: String) {
        let nonce = RemoteAccess.randomToken()
        let body = """
            <!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(escape(title))</title><style>\(style)</style></head>
            <body><main>\(content)</main>\(script.isEmpty ? "" : "<script nonce=\"\(nonce)\">\(script)</script>")</body></html>
            """
        return (body, nonce)
    }

    static var glyph: String {
        #"<div class="glyph" aria-hidden="true"><svg viewBox="0 0 24 24">\#(Wording.glyph)</svg></div>"#
    }

    static func refused(message: String, service: String) -> (body: String, nonce: String) {
        page(title: "Connect to \(service)", content: """
            \(glyph)<p class="eyebrow">\(escape(Wording.product))</p><h1>Can't connect</h1><p class="muted">\(escape(message))</p>
            """)
    }

    static func consent(service: String, app: String, destination: String, passcode: Bool, mac: Bool, base: String) -> (body: String, nonce: String) {
        let passcodeBlock = passcode ? """
            <label class="label" for="passcode">Passcode</label>
            <div class="field">
              <input id="passcode" type="password" autocomplete="current-password" autofocus aria-describedby="message">
              <button id="allow" class="primary" type="button">Allow</button>
            </div>
            """ : ""
        let macBlock = mac ? """
            \(passcode ? #"<div class="or">or</div>"# : "")
            <button id="mac" type="button" class="wide\(passcode ? "" : " primary")"><span class="spinner" aria-hidden="true"></span><span class="text">Approve on my Mac</span></button>
            """ : ""
        let none = !passcode && !mac
            ? #"<p class="muted">No passcode is set and the menu bar app is not running, so nothing can approve this. Open \#(escape(Wording.product)) on the Mac first.</p>"# : ""
        let content = """
            <section id="ask">
              \(glyph)
              <p class="eyebrow">\(escape(Wording.product))</p>
              <h1>Connect \(escape(app)) to \(escape(service))?</h1>
              <p class="muted">After you approve, you go back to <strong>\(escape(destination))</strong>.</p>
              <fieldset>
                <legend>Access</legend>
                <label class="option"><input type="radio" name="access" value="full" checked><span><b>\(escape(Wording.full.0))</b><small>\(escape(Wording.full.1))</small></span></label>
                <label class="option"><input type="radio" name="access" value="read"><span><b>\(escape(Wording.readOnly.0))</b><small>\(escape(Wording.readOnly.1))</small></span></label>
              </fieldset>
              <div class="approve">\(passcodeBlock)\(macBlock)\(none)</div>
              <p id="message" role="status" aria-live="polite"></p>
              <footer><button id="deny" type="button" class="quiet">Don't allow</button></footer>
            </section>
            <section id="done" class="done hidden" role="status">
              <div class="check" aria-hidden="true"><svg viewBox="0 0 24 24"><path d="m6 12.5 4 4 8-9"/></svg></div>
              <h1>Connected</h1>
              <p class="muted">Going back to \(escape(destination))…</p>
            </section>
            """
        // A keypress meant for the page that opened this one never answers it: clicks count only after a moment,
        // without greying the buttons out.
        let script = """
            const base = \(jsonString(base)); const query = location.search; const $ = id => document.getElementById(id);
            const message = $('message'); let ready = false; let busy = false;
            setTimeout(() => { ready = true; }, 600);
            const readOnly = () => document.querySelector('input[name=access]:checked').value === 'read';
            const controls = () => [...document.querySelectorAll('#ask button, #ask input')];
            function show(text, wait) { message.textContent = text; message.className = wait ? 'wait' : ''; }
            function lock(on) { busy = on; controls().forEach(c => { if (c.id !== 'deny') c.disabled = on; }); }
            async function post(path, body) {
              const response = await fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
              return [response.status, await response.json().catch(() => ({}))];
            }
            function finish(answer, approved) {
              if (!answer.redirect) return false;
              lock(true);
              if (approved) { $('ask').classList.add('hidden'); $('done').classList.remove('hidden'); setTimeout(() => location.href = answer.redirect, 700); }
              else location.href = answer.redirect;
              return true;
            }
            const field = $('passcode'); const allow = $('allow');
            if (allow) allow.addEventListener('click', async () => {
              if (!ready || busy) return;
              if (!field.value) { field.focus(); show('Enter the passcode set in the menu bar app.'); return; }
              lock(true); show('Checking…', true);
              const [, answer] = await post('/approve', { query, approve: true, readOnly: readOnly(), passcode: field.value });
              if (finish(answer, true)) return;
              lock(false); show(answer.error || 'That did not work.'); field.setAttribute('aria-invalid', 'true'); field.select();
            });
            if (field) {
              field.addEventListener('keydown', e => { if (e.key === 'Enter') allow.click(); });
              field.addEventListener('input', () => { field.removeAttribute('aria-invalid'); if (!busy) show(''); });
            }
            const mac = $('mac');
            if (mac) mac.addEventListener('click', async () => {
              if (!ready || busy) return;
              lock(true); mac.classList.add('busy'); mac.querySelector('.text').textContent = 'Waiting for your Mac…';
              show('Answer in the menu bar app on your Mac.', true);
              const reset = (text) => { mac.classList.remove('busy'); mac.querySelector('.text').textContent = 'Approve on my Mac'; lock(false); show(text); };
              const [, answer] = await post('/ask', { query, readOnly: readOnly() });
              if (!answer.ticket) { reset(answer.error || 'That did not work.'); return; }
              for (;;) {
                await new Promise(r => setTimeout(r, 1200));
                const reply = await fetch(base + '/ask/' + answer.ticket).then(r => r.json()).catch(() => ({}));
                if (reply.redirect) { finish(reply, !reply.redirect.includes('error=')); return; }
                if (reply.status !== 'pending') { reset('No answer came from the Mac. Try again.'); return; }
              }
            });
            $('deny').addEventListener('click', async () => {
              if (!ready) return;
              const [, answer] = await post('/approve', { query, approve: false });
              if (!finish(answer, false)) show(answer.error || 'That did not work.');
            });
            """
        return page(title: "Connect to \(service)", content: content, script: script)
    }

    static func jsonString(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text], options: [.withoutEscapingSlashes])) ?? Data("[\"\"]".utf8)
        // `</script>` cannot close the script from inside a string.
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast()).replacingOccurrences(of: "</", with: "<\\/")
    }
}
