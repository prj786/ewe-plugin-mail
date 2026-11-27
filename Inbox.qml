pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs

// Inbox — THE inbox model of the ewe.mail plugin, read by the bar envelope,
// the Inbox page and the `mail` IPC target. Two sources, one shape:
//   · any IMAP account — the core `ewe-mail` CLI (account in ewe.conf
//     [accounts.mail], password in the keyring). Was the shell's Mail.qml.
//   · Gmail — through the user's own Google client; the access token comes
//     from the core `ewe-auth token` broker (RFC-002), the refresh token
//     never leaves the keyring. Was the Gmail half of the shell's Google.qml
//     (unread badge, History-API cursor for genuinely NEW mail, the list,
//     the notifications); OAuth, Calendar, Drive and settings sync stay core.
// IMAP wins `source` when it is configured; with Gmail signed in as well,
// the count and the rows are both inboxes together (every IMAP account:
// `ewe-mail unseen --all`). New-mail notifications fire once per message id,
// persisted so a restart never re-notifies; the toggle is shared.
// With ewe Mail installed (`ewe-mail-app`), a row, a notification and the
// head button open it, at the message — else the browser / mailto: as before.
// Rule 2: nothing secret is ever written — the state files hold ids, flags,
// counts and the latest rows; tokens live in memory only.
QtObject {
    id: ml

    // the core CLIs, called the way the shell calls them: ~/.config/quickshell
    // is a symlink into the payload, so `../../bin` is the payload's bin/
    readonly property string eweMail: Quickshell.env("HOME") + "/.config/quickshell/../../bin/ewe-mail"
    readonly property string eweAuth: Quickshell.env("HOME") + "/.config/quickshell/../../bin/ewe-auth"

    // ── ewe Mail, the app: installed or not (asked at start and when the
    // Inbox page opens — a pacman -S between two looks is seen) ──
    property bool hasApp: false
    function probeApp() { _appProbe.running = false; _appProbe.running = true }
    property Process _appProbe: Process {
        running: true
        command: ["sh", "-c", "command -v ewe-mail-app >/dev/null 2>&1 && echo yes || echo no"]
        stdout: StdioCollector { onStreamFinished: ml.hasApp = this.text.trim() === "yes" }
    }

    // ── IMAP account (from ewe-mail status) ──
    property bool probed: false
    property bool imapConfigured: false
    property string imapHost: ""
    property string imapUser: ""
    property string imapEmail: ""         // the first account's address (ewe-mail 0.51+), else the user when it is one
    property string _imapFirst: ""        // the first account's id: its rows keep the plain-id notified keys
    property bool imapKeyring: true      // the password is in the keyring
    property int imapUnread: 0
    property var imapList: []
    property string imapState: ""        // "" | "offline" | "auth"
    property string imapError: ""
    property double imapLastFetch: 0

    // ── Gmail session (from ewe-auth status / token) ──
    property bool gmailProbed: false
    property bool gmailConfigured: false // the broker has a client file
    property bool gmailSignedIn: false
    property string gmailEmail: ""       // the signed-in address: Gmail rows' account is google:<it>
    property string busy: ""             // "" | "token"

    // ── the one shape the widgets read ──
    readonly property string source: imapConfigured ? "imap" : (gmailSignedIn ? "gmail" : "")
    readonly property bool available: source !== ""
    readonly property string title: source === "imap" ? imapUser : source === "gmail" ? "Gmail" : "Mail"
    // both set up: one inbox — the counts add up, the rows interleave by date
    readonly property bool both: imapConfigured && gmailSignedIn
    readonly property int unread: both ? imapUnread + mailUnread : source === "imap" ? imapUnread : source === "gmail" ? mailUnread : 0
    readonly property var list: both ? ml._merge(imapList, mailList) : source === "imap" ? imapList : source === "gmail" ? mailList : []
    readonly property string state: source === "imap" ? imapState : source === "gmail" ? mailState : ""
    readonly property string error: source === "imap" ? imapError : source === "gmail" ? mailError : ""
    readonly property bool needsReconnect: gmailSignedIn && mailState === "scope"
    // Notifications for new mail: the plugin's `notify` setting (manifest;
    // Komble → Plugins → Mail → Options), also flipped by the bell on the
    // Inbox page and `mail setNotify` — those write the setting through
    // Shell.setSetting, so there is one value, not a second copy in a state
    // file. applyNotify is what the setting arriving (Service.qml) calls.
    property bool notify: true
    function applyNotify(v) {
        v = !!v
        if (ml.notify === v) return
        ml.notify = v; ml._saveState()
        if (ml.gmailConfigured) ml.setMailNotify(v)
    }
    function setNotify(v) {
        ml.applyNotify(v)
        if (typeof Shell.setSetting === "function") Shell.setSetting("ewe.mail", "notify", !!v)
    }
    // 1.0 kept the toggle in mail-state.json: an "off" there is carried into
    // the setting once (notifyCarried), then the setting is the only truth
    property bool _notifyCarried: false
    // a Gmail re-consent happens in the account app (ewe-sync owns Google
    // sign-in since RFC-005/006; the shell's `google signIn` is not ours to call)
    function reconnect() {
        if (!ml.gmailSignedIn) return
        // straight to its Google page (a running ewe Sync takes the link)
        Quickshell.execDetached(["ewe-sync", "--pane", "google"])
    }
    function fetch() {
        if (ml.imapConfigured) ml.fetchImap()
        if (ml.gmailSignedIn) ml.fetchMail()
    }
    // one row of the list: ewe Mail at that message, else what 1.2 did
    function openRow(r) {
        if (!r) return
        var acct = ml._rowAccount(r)
        if (ml.hasApp && acct !== "") {
            Quickshell.execDetached(["ewe-mail-app", "--open", acct, "INBOX", String(r.id)])
            return
        }
        if (r.source === "gmail" || (!r.source && ml.source === "gmail")) ml.openMail(r.id)
        else Quickshell.execDetached(["xdg-open", "mailto:"])
    }
    function open(id) {
        var rows = ml.list
        for (var i = 0; i < rows.length; i++)
            if (String(rows[i].id) === String(id)) { ml.openRow(rows[i]); return }
        if (source === "gmail") ml.openMail(id)
        else Quickshell.execDetached(["xdg-open", "mailto:"])
    }
    function openInbox() {
        if (ml.hasApp) {
            if (!Shell.launch("io.github.prj786.ewe-mail")) Quickshell.execDetached(["ewe-mail-app"])
            return
        }
        if (source === "gmail") Quickshell.execDetached(["xdg-open", "https://mail.google.com/mail/u/0/"])
        else Quickshell.execDetached(["xdg-open", "mailto:"])
    }
    readonly property string inboxLabel: ml.hasApp ? "Open ewe Mail" : source === "gmail" ? "Open Gmail" : "Open mail"
    readonly property string hint: "Add a mail account or connect Google in ewe Sync to see mail here."

    // the `mail status` snapshot — byte-compatible with the shell's: ewe-settings reads it
    function statusJson() {
        return JSON.stringify({
            probed: ml.probed, source: ml.source, available: ml.available, title: ml.title,
            imapConfigured: ml.imapConfigured, imapHost: ml.imapHost, imapUser: ml.imapUser, imapKeyring: ml.imapKeyring,
            unread: ml.unread, state: ml.state, error: ml.error, notify: ml.notify, needsReconnect: ml.needsReconnect
        })
    }
    // `mail refresh`: re-read both accounts, then fetch
    function refresh() { ml.probe(); ml.probeGmail(); ml.probeApp(); ml.fetch() }

    // both inboxes as one list, newest first
    function _merge(a, b) {
        return (a || []).concat(b || []).sort(function (x, y) { return (y.date || 0) - (x.date || 0) })
    }
    function _imapAccount() { return "imap:" + String(ml.imapEmail || ml.imapUser).toLowerCase() }
    // rows restored from a 1.2 state file carry no account: the source says it
    function _rowAccount(r) {
        if (r.account) return String(r.account)
        var gmail = r.source === "gmail" || (!r.source && ml.source === "gmail")
        if (gmail) return ml.gmailEmail ? "google:" + ml.gmailEmail.toLowerCase() : ""
        return ml.imapConfigured ? (ml._imapFirst || ml._imapAccount()) : ""
    }
    // a new message: with ewe Mail, clicking the notification opens it there
    // (notify-send waits for the click; an hour later it lets go). The text
    // goes as arguments, never into the script, and the body is escaped for
    // the shell's markup-reading notification server.
    function _toast(app, title, body, row) {
        var acct = row ? ml._rowAccount(row) : ""
        if (ml.hasApp && acct !== "" && row.id) {
            var esc = String(body || "").replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
            Quickshell.execDetached(["sh", "-c",
                'a=$(timeout 3600 notify-send -a "ewe Mail" -i io.github.prj786.ewe-mail -A default=Open -- "$1" "$2" 2>/dev/null); '
                + '[ "$a" = default ] && exec ewe-mail-app --open "$3" INBOX "$4"',
                "ewe-mail-notify", String(title || "New mail"), esc, acct, String(row.id)])
            return
        }
        Quickshell.execDetached(["notify-send", "-a", app, "-i", "mail-unread", title, body])
    }

    // ══ IMAP ══════════════════════════════════════════════════════════════════
    function probe() { _statusProc.running = false; _statusProc.running = true }
    property Process _statusProc: Process {
        running: true
        command: ["python3", ml.eweMail, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                var was = ml.imapConfigured
                try {
                    var j = JSON.parse(this.text)
                    ml.imapConfigured = !!j.configured
                    ml.imapHost = String(j.host || ""); ml.imapUser = String(j.user || "")
                    ml.imapEmail = String(j.email || (String(j.user || "").indexOf("@") > 0 ? j.user : ""))
                    ml.imapKeyring = j.keyring !== false
                } catch (e) { ml.imapConfigured = false }
                ml.probed = true
                if (ml.imapConfigured && !was) ml.fetchImap()
                if (!ml.imapConfigured && was) { ml.imapUnread = 0; ml.imapList = []; ml.imapState = ""; ml.imapError = "" }
            }
        }
    }
    // the account record lives in the one file: re-probe when it changes
    property FileView _confWatch: FileView {
        path: Quickshell.env("HOME") + "/.config/ewe/ewe.conf"
        watchChanges: true
        printErrors: false
        onFileChanged: ml._reprobe.restart()
    }
    property Timer _reprobe: Timer { interval: 1500; onTriggered: ml.probe() }

    property bool _fetching: false
    function fetchImap() {
        if (!ml.imapConfigured || ml._fetching) return
        ml._fetching = true
        _unseenProc.running = false; _unseenProc.running = true
    }
    property Process _unseenProc: Process {
        // --all: every account, each row with its `account` (an older
        // ewe-mail ignores the flag and answers for its one account)
        command: ["python3", ml.eweMail, "unseen", "--all", "--limit", "10"]
        stdout: StdioCollector {
            onStreamFinished: {
                ml._fetching = false
                try {
                    var j = JSON.parse(this.text)
                    if (j.ok) {
                        ml.imapState = ""; ml.imapError = ""
                        ml.imapUnread = j.unread || 0
                        ml._imapFirst = (j.accounts && j.accounts.length && j.accounts[0].id) ? String(j.accounts[0].id) : ml._imapAccount()
                        var rows = j.list || []
                        for (var r = 0; r < rows.length; r++) {
                            rows[r].source = "imap"
                            if (!rows[r].account) rows[r].account = ml._imapFirst
                        }
                        ml.imapList = rows
                        // judge "first fetch ever" BEFORE the stamp moves — stamped
                        // first, it never was the first fetch and every already-unread
                        // message toasted on a fresh account (2026-09-20)
                        var first = Object.keys(ml._notified).length === 0 && ml.imapLastFetch === 0
                        ml.imapLastFetch = Date.now()
                        ml._notifyNew(ml.imapList, first)
                        ml._saveState()
                    } else if (j.error === "auth-failed" || j.error === "no-password") {
                        ml.imapState = "auth"; ml.imapError = "The mail server rejected the login — sign in to the mail account again on ewe Sync's Mail page."
                    } else if (j.error === "not-configured") {
                        ml.imapConfigured = false
                    } else {
                        ml.imapState = "offline"
                    }
                } catch (e) { ml.imapState = "offline" }
            }
        }
    }
    // new-mail toasts: once per message id, at most five named per fetch
    readonly property int notifyBurst: 5
    property var _notified: ({})
    property bool _stateLoaded: false
    // the pre-plugin path, so an upgrade keeps the notified-set (no re-notify storm)
    readonly property string statePath: Quickshell.env("HOME") + "/.config/quickshell/mail-state.json"
    property Process _stateLoad: Process {
        running: true
        command: ["sh", "-c", "cat \"$HOME/.config/quickshell/mail-state.json\" 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(this.text)
                    if (j.notified && typeof j.notified === "object") ml._notified = j.notified
                    ml._notifyCarried = !!j.notifyCarried
                    if (j.notify === false && !ml._notifyCarried) ml.setNotify(false)
                    ml._notifyCarried = true
                    if (ml.imapLastFetch === 0) {
                        if (j.unread !== undefined) ml.imapUnread = j.unread
                        if (Array.isArray(j.list)) ml.imapList = j.list
                    }
                } catch (e) {}
                ml._stateLoaded = true
            }
        }
    }
    // an atomic write (tmp + mv) through one sh — the shell's own files are
    // written the same way; a plugin has no HyprMon, so the helper lives here
    function _atomicWrite(proc, path, content) {
        proc.command = ["sh", "-c",
            'mkdir -p "$(dirname "$1")" && cat > "$1.tmp" <<\'EWE_MAIL_EOF_7f3a\'\n' + content + '\nEWE_MAIL_EOF_7f3a\nmv "$1.tmp" "$1"',
            "ewe-mail", path]
        proc.running = false; proc.running = true
    }
    property Process _stateWriter: Process {}
    property Timer _saveT: Timer {
        interval: 200
        onTriggered: ml._atomicWrite(ml._stateWriter, ml.statePath, JSON.stringify({
            notified: ml._notified, notify: ml.notify, notifyCarried: ml._notifyCarried,
            unread: ml.imapUnread, list: ml.imapList.slice(0, 15)
        }))
    }
    function _saveState() {
        var cut = Date.now() - 7 * 86400000
        for (var k in ml._notified) if (ml._notified[k] < cut) delete ml._notified[k]
        ml._saveT.restart()
    }
    function _notifyNew(rows, first) {
        if (!ml._stateLoaded) return
        // first fetch ever: everything currently unseen is "seen" — no storm
        var fresh = []
        for (var i = 0; i < rows.length; i++) {
            var id = String(rows[i].id || "")
            if (id === "") continue
            // a UID is only unique inside its account: other accounts' rows are
            // keyed account/uid; the first keeps the plain uid 1.2 stored
            var acct = String(rows[i].account || "")
            var key = (acct !== "" && acct !== ml._imapFirst) ? acct + "/" + id : id
            if (ml._notified[key]) continue
            ml._notified[key] = Date.now()
            if (!first) fresh.push(rows[i])
        }
        if (!ml.notify || fresh.length === 0) return
        for (var f = 0; f < Math.min(fresh.length, ml.notifyBurst); f++)
            ml._toast("Mail", fresh[f].from || "New mail", fresh[f].subject || "", fresh[f])
        if (fresh.length > ml.notifyBurst)
            Quickshell.execDetached(["notify-send", "-a", "Mail", "-i", "mail-unread", "New mail", (fresh.length - ml.notifyBurst) + " more new messages in your inbox."])
    }

    // back off on battery: each poll wakes the radio
    property Timer _poll: Timer {
        interval: (Shell.lowPower ? 5 : 2) * 60 * 1000
        running: ml.imapConfigured; repeat: true
        onTriggered: ml.fetchImap()
    }

    // ══ Gmail session: who is signed in, and a token when one is needed ═══════
    // `ewe-auth status` says whether a Google client is configured and a
    // refresh token is stored; `ewe-auth token --json` hands out a short-lived
    // access token (runtime-cached by the broker, refreshed under a lock).
    function probeGmail() { _authStatus.running = false; _authStatus.running = true }
    property Process _authStatus: Process {
        running: true
        command: ["python3", ml.eweAuth, "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                var was = ml.gmailSignedIn
                try {
                    var j = JSON.parse(this.text)
                    ml.gmailConfigured = !!j.configured
                    ml.gmailSignedIn = !!j.signed_in
                    ml.gmailEmail = String((j.profile && j.profile.email) || "")
                } catch (e) { /* the broker always prints JSON; treat garbage (or no broker) as signed-out */
                    ml.gmailConfigured = false; ml.gmailSignedIn = false
                }
                ml.gmailProbed = true
                if (ml.gmailSignedIn && !was) ml.fetchMail()          // the session is ready
                if (!ml.gmailSignedIn && was) ml._gmailClosed()
                // right after boot the first probe can race gnome-keyring coming
                // up and report signed-out even though a refresh token is stored
                // — re-probe with backoff instead of staying signed-out forever
                if (!ml.gmailSignedIn && ml.gmailConfigured && ml._probeRetries < 3) {
                    ml._probeRetries++
                    ml._probeRetry.interval = 5000 * ml._probeRetries
                    ml._probeRetry.restart()
                }
            }
        }
    }
    property int _probeRetries: 0
    property Timer _probeRetry: Timer { onTriggered: { if (!ml.gmailSignedIn) ml.probeGmail() } }
    // a sign-in or sign-out in the account app writes or removes this
    // non-secret record (client id + email) — re-probe when it moves
    property FileView _authWatch: FileView {
        path: Quickshell.env("HOME") + "/.config/ewe/auth.json"
        watchChanges: true
        printErrors: false
        onFileChanged: ml._authReprobe.restart()
    }
    property Timer _authReprobe: Timer { interval: 1500; onTriggered: { ml._probeRetries = 0; ml.probeGmail() } }
    function _gmailClosed() {
        ml._accessToken = ""; ml._expiresAt = 0
        ml.mailUnread = 0; ml.mailList = []; ml.mailState = ""; ml.mailError = ""
        ml._mailHistoryId = ""; ml._mailIds = []; ml._saveMailState()
    }

    // access-token cache — memory only, never persisted
    property string _accessToken: ""
    property double _expiresAt: 0
    property var _tokenWaiters: []
    // After a failed refresh, hold off for 5 min instead of asking the broker
    // again on every poll: a dead OAuth client produced 17 "token refresh
    // failed: deleted_client" in 12 minutes (2026-09-10). Cleared by a
    // successful refresh and by the wake path.
    property double _refreshFailedAt: 0
    function ensureToken(cb) {
        if (ml._accessToken !== "" && Date.now() < ml._expiresAt - 60000) { cb(ml._accessToken); return }
        if (ml._refreshFailedAt > 0 && Date.now() - ml._refreshFailedAt < 5 * 60 * 1000) { cb(""); return }
        ml._tokenWaiters.push(cb)
        if (ml.busy !== "token") {
            ml.busy = "token"
            _tokenProc.running = false; _tokenProc.running = true
        }
    }
    property Process _tokenProc: Process {
        command: ["python3", ml.eweAuth, "token", "--json"]
        stdout: StdioCollector {
            onStreamFinished: {
                if (ml.busy === "token") ml.busy = ""
                var tok = ""
                try {
                    var j = JSON.parse(this.text)
                    if (j.ok) {
                        ml._accessToken = j.access_token
                        ml._expiresAt = j.expires_at * 1000
                        tok = j.access_token
                        ml._refreshFailedAt = 0
                    } else if (j.error === "signed-out" || j.error === "not-configured") {
                        // refresh token revoked, the client gone, or no client —
                        // the broker has already cleared its side; drop ours
                        var was = ml.gmailSignedIn
                        ml.gmailSignedIn = false
                        if (was) { ml._gmailClosed(); Log.warn("ewe.mail", "Gmail signed out:", j.reason || j.error) }
                    } else {
                        ml._refreshFailedAt = Date.now()
                        Log.warn("ewe.mail", "token refresh failed:", j.error)
                    }
                } catch (e) {
                    ml._refreshFailedAt = Date.now()
                    Log.error("ewe.mail", "ewe-auth token returned unparseable output")
                }
                var ws = ml._tokenWaiters
                ml._tokenWaiters = []
                for (var i = 0; i < ws.length; i++) ws[i](tok)   // "" → the api() call reports not-authorized
            }
        }
    }

    // ══ Gmail — INBOX unread badge, new-mail notifications and the list ═══════
    // Read-only scope. The History API cursor detects genuinely NEW arrivals
    // (no notification storm for pre-existing unread mail); the cursor and a
    // bounded notified-set persist so restarts never re-notify.
    property int mailUnread: 0
    property var mailList: []            // [{id, from, subject, snippet, date, unread}]
    property string mailState: ""        // "" | "offline" | "scope" (re-consent needed) | "api" (API disabled)
    property string mailError: ""
    property bool mailNotify: true       // desktop notifications for new mail
    property double mailLastFetch: 0
    property string _mailHistoryId: ""
    property var _mailNotified: ({})     // messageId -> epoch-ms (bounded, persisted)
    property var _mailIds: []            // current unread id set (change detector)
    // the pre-plugin path: the History cursor and the notified-set survive the upgrade
    readonly property string mailStatePath: Quickshell.env("HOME") + "/.config/quickshell/google-mail.json"

    property Process _mailWriter: Process {}
    // _saveMailState fires from several callbacks that can land in the same tick
    // (history → baseline → list refresh); coalesce the burst into one write
    property Timer _mailSaveT: Timer {
        interval: 200
        onTriggered: ml._atomicWrite(ml._mailWriter, ml.mailStatePath, JSON.stringify({
            historyId: ml._mailHistoryId, notified: ml._mailNotified,
            notify: ml.mailNotify, unread: ml.mailUnread, list: ml.mailList.slice(0, 15)
        }))
    }
    function _saveMailState() {
        var cut = Date.now() - 7 * 86400000
        for (var k in ml._mailNotified) if (ml._mailNotified[k] < cut) delete ml._mailNotified[k]
        ml._mailSaveT.restart()
    }
    property Process _mailLoad: Process {
        running: true
        command: ["sh", "-c", "cat \"$HOME/.config/quickshell/google-mail.json\" 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    var j = JSON.parse(this.text)
                    if (j.historyId) ml._mailHistoryId = String(j.historyId)
                    if (j.notified && typeof j.notified === "object") ml._mailNotified = j.notified
                    if (j.notify !== undefined) ml.mailNotify = !!j.notify
                    if (ml.mailLastFetch === 0) {
                        if (j.unread !== undefined) ml.mailUnread = j.unread
                        if (Array.isArray(j.list)) ml.mailList = j.list
                    }
                } catch (e) {}
            }
        }
    }
    function setMailNotify(v) { ml.mailNotify = v; ml._saveMailState() }

    function fetchMail() {
        if (!ml.gmailSignedIn) return
        ml.api("GET", "https://gmail.googleapis.com/gmail/v1/users/me/labels/INBOX", null, function (st, j, err) {
            if (st === 200 && j) {
                ml.mailState = ""; ml.mailError = ""
                ml.mailUnread = j.messagesUnread || 0
                ml.mailLastFetch = Date.now()
                ml._mailHistory()
            } else if (st === 403 || st === 401) {
                var m = (j && j.error && j.error.message) ? String(j.error.message) : ""
                if (m.indexOf("disabled") >= 0 || m.indexOf("has not been used") >= 0) {
                    ml.mailState = "api"
                    ml.mailError = "Enable the Gmail API for your project in the Google Cloud console, then retry."
                } else {
                    ml.mailState = "scope"   // token predates the gmail scope
                    ml.mailError = "Gmail needs a new permission — reconnect your Google account."
                }
            } else if (err === "offline" || st === 0) {
                ml.mailState = "offline"
            }
        })
    }
    // How many new-mail toasts a single history walk may fire before it stops
    // naming them individually. A multi-hour suspend can surface dozens at once.
    readonly property int mailNotifyBurst: 5

    property var _mailFresh: ({})        // message ids gathered across history pages

    function _mailHistory() {
        if (ml._mailHistoryId === "") { ml._mailBaseline(); return }
        ml._mailFresh = {}
        ml._mailHistoryPage("", 0)
    }
    // history.list pages at ~100 records. Reading only the first page while still
    // advancing the cursor to j.historyId (which is the mailbox's CURRENT id, not
    // the last id on the page) silently dropped every arrival past page one and
    // left the cursor looking healthy — so walk the pages before committing.
    function _mailHistoryPage(pageToken, depth) {
        var url = "https://gmail.googleapis.com/gmail/v1/users/me/history?historyTypes=messageAdded&labelId=INBOX&startHistoryId="
                + ml._mailHistoryId
        if (pageToken !== "") url += "&pageToken=" + encodeURIComponent(pageToken)
        ml.api("GET", url, null, function (st, j, err) {
            if (st === 404) { ml._mailFresh = {}; ml._mailBaseline(); return }   // cursor aged out — reconcile silently
            if (st !== 200 || !j) { ml._mailFresh = {}; ml._refreshMailList(); return }
            var hs = j.history || []
            for (var h = 0; h < hs.length; h++)
                for (var a = 0; a < (hs[h].messagesAdded || []).length; a++) {
                    var msg = hs[h].messagesAdded[a].message
                    if (msg && msg.id && !ml._mailNotified[msg.id]) ml._mailFresh[msg.id] = true
                }
            if (j.nextPageToken) {
                if (depth < 20) { ml._mailHistoryPage(String(j.nextPageToken), depth + 1); return }
                // gap too large to walk — rebaseline rather than advance the cursor
                // past pages we never read
                Log.warn("ewe.mail", "gmail history gap over", depth, "pages — rebaselining")
                ml._mailFresh = {}
                ml._mailBaseline()
                return
            }
            if (j.historyId) ml._mailHistoryId = String(j.historyId)
            var ids = Object.keys(ml._mailFresh)
            ml._mailFresh = {}
            if (ids.length > 0) Log.info("ewe.mail", "gmail:", ids.length, "new message(s) since the cursor")
            for (var i = 0; i < ids.length; i++) {
                ml._mailNotified[ids[i]] = Date.now()
                if (ml.mailNotify && i < ml.mailNotifyBurst) ml._notifyMail(ids[i])
            }
            // one summary instead of a toast storm for the rest
            if (ml.mailNotify && ids.length > ml.mailNotifyBurst)
                Quickshell.execDetached(["notify-send", "-a", "Gmail", "-i", "mail-unread",
                    "New mail", (ids.length - ml.mailNotifyBurst) + " more new messages in your inbox."])
            ml._saveMailState()
            ml._refreshMailList()
        })
    }
    // (re)baseline the history cursor; everything currently unread is "seen"
    function _mailBaseline() {
        ml.api("GET", "https://gmail.googleapis.com/gmail/v1/users/me/profile", null, function (st, j, err) {
            if (st === 200 && j && j.historyId) ml._mailHistoryId = String(j.historyId)
            ml.api("GET", "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=" + encodeURIComponent("is:unread in:inbox") + "&maxResults=15",
                    null, function (st2, j2, err2) {
                var ms = (st2 === 200 && j2 && j2.messages) ? j2.messages : []
                for (var i = 0; i < ms.length; i++) ml._mailNotified[ms[i].id] = Date.now()
                ml._saveMailState()
                ml._refreshMailList()
            })
        })
    }
    function _refreshMailList() {
        ml.api("GET", "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=" + encodeURIComponent("in:inbox") + "&maxResults=10",
                null, function (st, j, err) {
            if (st !== 200 || !j) return
            var ms = j.messages || []
            var ids = ms.map(function (m) { return m.id })
            if (JSON.stringify(ids) === JSON.stringify(ml._mailIds) && ml.mailList.length > 0) return
            ml._mailIds = ids
            if (ids.length === 0) { ml.mailList = []; ml._saveMailState(); return }
            var out = [], pending = ids.length
            for (var i = 0; i < ids.length; i++) ml._mailMeta(ids[i], function (row) {
                if (row) out.push(row)
                if (--pending === 0) {
                    out.sort(function (a, b) { return b.date - a.date })
                    ml.mailList = out
                    ml._saveMailState()
                }
            })
        })
    }
    function _mailMeta(id, cb) {
        ml.api("GET", "https://gmail.googleapis.com/gmail/v1/users/me/messages/" + id
                + "?format=metadata&metadataHeaders=From&metadataHeaders=Subject&metadataHeaders=Date", null, function (st, j, err) {
            if (st !== 200 || !j) { cb(null); return }
            var from = "", subject = ""
            var hs = (j.payload && j.payload.headers) ? j.payload.headers : []
            for (var i = 0; i < hs.length; i++) {
                if (hs[i].name === "From") from = hs[i].value
                else if (hs[i].name === "Subject") subject = hs[i].value
            }
            var nice = from.replace(/\s*<[^>]*>/, "").replace(/^"|"$/g, "").trim() || from
            cb({
                id: j.id, from: nice, subject: subject || "(no subject)",
                snippet: j.snippet || "", date: Number(j.internalDate || 0),
                unread: (j.labelIds || []).indexOf("UNREAD") >= 0,
                source: "gmail", account: ml.gmailEmail ? "google:" + ml.gmailEmail.toLowerCase() : ""
            })
        })
    }
    function _notifyMail(id) {
        ml._mailMeta(id, function (row) {
            if (!row) return
            ml._toast("Gmail", row.from || "New mail", (row.subject || "") + (row.snippet ? "\n" + row.snippet : ""), row)
        })
    }
    function openMail(id) {
        Quickshell.execDetached(["xdg-open", "https://mail.google.com/mail/u/0/#inbox/" + id])
    }

    // back off on battery: each poll is an HTTPS round-trip that wakes the Wi-Fi
    // radio out of power-save, 720 times a day at the 2-minute cadence
    property Timer _mailPoll: Timer {
        interval: (Shell.lowPower ? 5 : 2) * 60 * 1000
        running: ml.gmailSignedIn; repeat: true   // the status probe does the first fetch
        onTriggered: ml.fetchMail()
    }

    // ══ shared hooks ══════════════════════════════════════════════════════════
    // Quick settings opening refreshes a stale inbox (>1 min); signed-out but
    // configured Google re-checks the keyring (the boot probe may have raced it)
    property Connections _qsHook: Connections {
        target: Shell
        function onQuickSettingsOpenChanged() {
            if (!Shell.quickSettingsOpen) return
            if (ml.imapConfigured && Date.now() - ml.imapLastFetch > 60 * 1000) ml.fetchImap()
            if (ml.gmailSignedIn && Date.now() - ml.mailLastFetch > 60 * 1000) ml.fetchMail()
            else if (!ml.gmailSignedIn && ml.gmailConfigured && ml.busy === "") ml.probeGmail()
        }
    }
    // Shell.resumed (the wake sequence's network step): refetch IMAP; every
    // Gmail access token minted before the suspend is stale — drop it and
    // refresh once up front instead of letting the next poll fail a request
    function refreshAfterResume() {
        if (ml.imapConfigured) ml.fetchImap()
        ml._accessToken = ""
        ml._expiresAt = 0
        ml._refreshFailedAt = 0
        if (!ml.gmailConfigured) return
        if (!ml.gmailSignedIn) {
            // a keyring that was locked at login leaves the shell believing it is
            // signed out forever — a wake is a fair moment to try again
            ml._probeRetries = 0
            ml.probeGmail()
            return
        }
        ml.ensureToken(function (tok) {
            if (tok === "") { Log.warn("ewe.mail", "resume: token refresh failed — the poll keeps its own retries"); return }
            ml.fetchMail()
        })
    }

    // ── thin API layer: Bearer header, one 401-refresh-retry, JSON parse ───────
    // cb(status, json, err) — err ∈ "" | "offline" | "not-authorized"
    function api(method, url, opts, cb) { ml._apiCall(method, url, opts, cb, true) }
    function _apiCall(method, url, opts, cb, retry) {
        ml.ensureToken(function (tok) {
            if (tok === "") { cb(0, null, "not-authorized"); return }
            var xhr = new XMLHttpRequest()
            xhr.open(method, url)
            xhr.setRequestHeader("Authorization", "Bearer " + tok)
            var body = undefined
            if (opts && opts.body !== undefined) {
                body = typeof opts.body === "string" ? opts.body : JSON.stringify(opts.body)
                xhr.setRequestHeader("Content-Type", opts.contentType || "application/json")
            }
            xhr.onreadystatechange = function () {
                if (xhr.readyState !== XMLHttpRequest.DONE) return
                if (xhr.status === 401 && retry) {
                    ml._accessToken = ""; ml._expiresAt = 0
                    ml._apiCall(method, url, opts, cb, false)
                    return
                }
                var j = null
                try { j = JSON.parse(xhr.responseText) } catch (e) {}
                cb(xhr.status, j, xhr.status === 0 ? "offline" : "")
            }
            xhr.send(body)
        })
    }
}
