import Foundation

/// The page a browser opens when a remote client connects: which app asks, where approving sends the browser, and two
/// ways to say yes (the passcode, or Allow in the menu bar app). One self-contained page: its script carries a nonce,
/// nothing loads from elsewhere, and no other site may frame it.
enum AuthorizePage {
    static func response(_ html: (body: String, nonce: String), status: Int = 200) -> HTTPListener.Response {
        .full(
            status: status,
            headers: [
                "Content-Type": "text/html; charset=utf-8", "Cache-Control": "no-store", "Referrer-Policy": "no-referrer",
                "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY",
                "Content-Security-Policy": "default-src 'none'; script-src 'nonce-\(html.nonce)'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'",
            ],
            body: Data(html.body.utf8))
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "'", with: "&#39;")
    }

    static let style = """
        :root { color-scheme: light dark; --bg: #f5f5f7; --card: #fff; --text: #1d1d1f; --muted: #6e6e73; --line: #d2d2d7; --accent: #0071e3; --danger: #d70015; }
        @media (prefers-color-scheme: dark) { :root { --bg: #000; --card: #1c1c1e; --text: #f5f5f7; --muted: #98989d; --line: #38383a; --accent: #0a84ff; --danger: #ff453a; } }
        * { box-sizing: border-box; }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; background: var(--bg); color: var(--text);
               font: 15px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Helvetica Neue", sans-serif; padding: 16px; }
        main { width: 100%; max-width: 420px; background: var(--card); border: 1px solid var(--line); border-radius: 14px; padding: 24px; }
        h1 { font-size: 19px; margin: 0 0 4px; }
        p { margin: 8px 0; }
        .muted { color: var(--muted); font-size: 13px; }
        hr { border: 0; border-top: 1px solid var(--line); margin: 18px 0; }
        label { display: flex; gap: 8px; align-items: center; margin: 10px 0; }
        input[type=password] { width: 100%; font: inherit; padding: 9px 11px; border-radius: 8px; border: 1px solid var(--line); background: transparent; color: inherit; }
        .row { display: flex; gap: 8px; margin-top: 12px; }
        button { flex: 1; font: inherit; font-weight: 600; padding: 9px 12px; border-radius: 8px; border: 1px solid var(--line); background: transparent; color: inherit; cursor: pointer; }
        button.primary { background: var(--accent); border-color: var(--accent); color: #fff; }
        button:disabled { opacity: .5; cursor: default; }
        #message { min-height: 20px; color: var(--danger); font-size: 13px; }
        #message.wait { color: var(--muted); }
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

    static func refused(message: String, service: String) -> (body: String, nonce: String) {
        page(title: "Connect to \(service)", content: "<h1>Can't connect</h1><p>\(escape(message))</p>")
    }

    static func consent(service: String, app: String, destination: String, passcode: Bool, mac: Bool, base: String) -> (body: String, nonce: String) {
        let passcodeBlock = passcode ? """
            <label for="passcode" class="muted">Passcode (set in the menu bar app's Settings)</label>
            <input id="passcode" type="password" autocomplete="current-password">
            <div class="row"><button id="allow" class="primary" disabled>Allow</button></div>
            """ : ""
        let macBlock = mac ? """
            <div class="row"><button id="mac"\(passcode ? "" : " class=\"primary\"")>Approve on my Mac</button></div>
            """ : ""
        let none = !passcode && !mac
            ? "<p>No passcode is set and the menu bar app is not running, so nothing can approve this. Open Apple Mail MCP on the Mac first.</p>" : ""
        let content = """
            <h1>Connect \(escape(app)) to \(escape(service))?</h1>
            <p class="muted">Approving sends you back to <strong>\(escape(destination))</strong>.</p>
            <hr>
            <label><input id="readonly" type="checkbox"> Read only: no moving, drafting or sending</label>
            <p class="muted">Otherwise it may do what Claude on this Mac may do. Sending and big changes still ask in the menu bar app.</p>
            <hr>
            \(passcodeBlock)\(macBlock)\(none)
            <div class="row"><button id="deny">Deny</button></div>
            <p id="message" role="status"></p>
            """
        // Allow and Deny wait a moment, so a keypress meant for the page that opened this one never answers it.
        let script = """
            const base = \(jsonString(base)); const query = location.search; const message = document.getElementById('message');
            const buttons = [...document.querySelectorAll('button')];
            buttons.forEach(b => b.disabled = true); setTimeout(() => buttons.forEach(b => b.disabled = false), 700);
            const readOnly = () => document.getElementById('readonly').checked;
            function show(text, wait) { message.textContent = text; message.className = wait ? 'wait' : ''; }
            async function post(path, body) {
              const response = await fetch(base + path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
              return [response.status, await response.json().catch(() => ({}))];
            }
            function finish(answer) { if (answer.redirect) { buttons.forEach(b => b.disabled = true); location.href = answer.redirect; return true; } return false; }
            const allow = document.getElementById('allow');
            if (allow) allow.addEventListener('click', async () => {
              allow.disabled = true; show('Checking…', true);
              const [, answer] = await post('/approve', { query, approve: true, readOnly: readOnly(), passcode: document.getElementById('passcode').value });
              if (!finish(answer)) { show(answer.error || 'That did not work.'); allow.disabled = false; }
            });
            const passcodeField = document.getElementById('passcode');
            if (passcodeField) passcodeField.addEventListener('keydown', e => { if (e.key === 'Enter' && !allow.disabled) allow.click(); });
            const mac = document.getElementById('mac');
            if (mac) mac.addEventListener('click', async () => {
              mac.disabled = true; show('Waiting for your answer in the menu bar app on your Mac…', true);
              const [, answer] = await post('/ask', { query, readOnly: readOnly() });
              if (!answer.ticket) { show(answer.error || 'That did not work.'); mac.disabled = false; return; }
              for (;;) {
                await new Promise(r => setTimeout(r, 1500));
                const reply = await fetch(base + '/ask/' + answer.ticket).then(r => r.json()).catch(() => ({}));
                if (finish(reply)) return;
                if (reply.status !== 'pending') { show('No answer came from the Mac. Try again.'); mac.disabled = false; return; }
              }
            });
            document.getElementById('deny').addEventListener('click', async () => {
              const [, answer] = await post('/approve', { query, approve: false });
              if (!finish(answer)) show(answer.error || 'That did not work.');
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
