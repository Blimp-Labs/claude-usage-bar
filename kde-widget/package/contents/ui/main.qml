import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami
import Qt.labs.platform as Platform
import "." as Local

PlasmoidItem {
    id: root

    // Usage state
    property real pct5h: 0
    property real pct7d: 0
    property string reset5h: ""
    property string reset7d: ""
    property real pct7dOpus: -1
    property real pct7dSonnet: -1
    property string reset7dOpus: ""
    property string reset7dSonnet: ""
    property bool extraEnabled: false
    property real extraUtilization: 0
    property real extraUsed: 0
    property real extraLimit: 0

    property string lastError: ""
    property date lastUpdated: new Date(0)
    property bool isAuthenticated: Plasmoid.configuration.oauthToken !== ""
    property bool isAwaitingCode: false
    property string oauthState: ""
    property string codeVerifier: ""

    // History for chart
    property var historyPoints: []

    switchWidth: Kirigami.Units.gridUnit * 12
    switchHeight: Kirigami.Units.gridUnit * 12

    compactRepresentation: CompactRepresentation {
        pct5h: root.pct5h
        pct7d: root.pct7d
        isAuthenticated: root.isAuthenticated
    }

    fullRepresentation: FullRepresentation {
        pct5h: root.pct5h
        pct7d: root.pct7d
        reset5h: root.reset5h
        reset7d: root.reset7d
        pct7dOpus: root.pct7dOpus
        pct7dSonnet: root.pct7dSonnet
        reset7dOpus: root.reset7dOpus
        reset7dSonnet: root.reset7dSonnet
        extraEnabled: root.extraEnabled
        extraUtilization: root.extraUtilization
        extraUsed: root.extraUsed
        extraLimit: root.extraLimit
        lastError: root.lastError
        lastUpdated: root.lastUpdated
        isAuthenticated: root.isAuthenticated
        isAwaitingCode: root.isAwaitingCode
        historyPoints: root.historyPoints
        pollingMinutes: Plasmoid.configuration.pollingMinutes

        onSignInRequested: startOAuthFlow()
        onSignOutRequested: signOut()
        onRefreshRequested: fetchUsage()
        onCodeSubmitted: function(rawCode) { submitOAuthCode(rawCode) }
        onCancelAuthRequested: { root.isAwaitingCode = false }
        onPollingChanged: function(minutes) {
            Plasmoid.configuration.pollingMinutes = minutes;
            pollingTimer.interval = minutes * 60 * 1000;
            pollingTimer.restart();
        }
    }

    Timer {
        id: pollingTimer
        interval: Plasmoid.configuration.pollingMinutes * 60 * 1000
        running: root.isAuthenticated
        repeat: true
        onTriggered: fetchUsage()
    }

    // Reset time update timer (every 30s)
    Timer {
        id: resetTimer
        interval: 30000
        running: root.isAuthenticated
        repeat: true
        onTriggered: root.lastUpdated = root.lastUpdated // trigger binding re-eval
    }

    Component.onCompleted: {
        loadHistory();
        if (isAuthenticated) {
            fetchUsage();
        }
    }

    function fetchUsage() {
        if (!isAuthenticated) return;
        var token = Plasmoid.configuration.oauthToken;

        var xhr = new XMLHttpRequest();
        xhr.open("GET", "https://api.anthropic.com/api/oauth/usage");
        xhr.setRequestHeader("Authorization", "Bearer " + token);
        xhr.setRequestHeader("anthropic-beta", "oauth-2025-04-20");
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200) {
                    try {
                        var data = JSON.parse(xhr.responseText);
                        applyUsageData(data);
                        root.lastError = "";
                        root.lastUpdated = new Date();
                        recordHistory();
                    } catch (e) {
                        root.lastError = "Fehler beim Parsen der Antwort";
                    }
                } else if (xhr.status === 401) {
                    root.lastError = "Sitzung abgelaufen — bitte erneut anmelden";
                    signOut();
                } else if (xhr.status === 429) {
                    root.lastError = "Rate-Limit erreicht — Intervall erhöht";
                } else {
                    root.lastError = "HTTP " + xhr.status;
                }
            }
        };
        xhr.send();
    }

    function applyUsageData(data) {
        if (data.five_hour) {
            root.pct5h = data.five_hour.utilization || 0;
            root.reset5h = data.five_hour.resets_at || "";
        }
        if (data.seven_day) {
            root.pct7d = data.seven_day.utilization || 0;
            root.reset7d = data.seven_day.resets_at || "";
        }
        if (data.seven_day_opus && data.seven_day_opus.utilization !== undefined && data.seven_day_opus.utilization !== null) {
            root.pct7dOpus = data.seven_day_opus.utilization;
            root.reset7dOpus = data.seven_day_opus.resets_at || "";
        } else {
            root.pct7dOpus = -1;
        }
        if (data.seven_day_sonnet && data.seven_day_sonnet.utilization !== undefined && data.seven_day_sonnet.utilization !== null) {
            root.pct7dSonnet = data.seven_day_sonnet.utilization;
            root.reset7dSonnet = data.seven_day_sonnet.resets_at || "";
        } else {
            root.pct7dSonnet = -1;
        }
        if (data.extra_usage) {
            root.extraEnabled = data.extra_usage.is_enabled || false;
            root.extraUtilization = data.extra_usage.utilization || 0;
            root.extraUsed = (data.extra_usage.used_credits || 0) / 100.0;
            root.extraLimit = (data.extra_usage.monthly_limit || 0) / 100.0;
        }
    }

    function startOAuthFlow() {
        var state = generateRandomString(32);
        var verifier = generateRandomString(64);
        root.oauthState = state;
        root.codeVerifier = verifier;
        var url = "https://claude.ai/oauth/authorize"
            + "?code=true"
            + "&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
            + "&response_type=code"
            + "&redirect_uri=" + encodeURIComponent("https://console.anthropic.com/oauth/code/callback")
            + "&scope=" + encodeURIComponent("user:profile user:inference")
            + "&state=" + encodeURIComponent(state)
            + "&code_challenge=" + encodeURIComponent(pkceChallenge(verifier))
            + "&code_challenge_method=S256";
        Qt.openUrlExternally(url);
        root.isAwaitingCode = true;
    }

    function submitOAuthCode(rawCode) {
        var parts = rawCode.trim().split("#");
        var code = parts[0];
        var returnedState = parts.length > 1 ? parts[1] : "";

        if (returnedState && returnedState !== root.oauthState) {
            root.lastError = "OAuth-Status stimmt nicht überein — erneut versuchen";
            root.isAwaitingCode = false;
            return;
        }

        var xhr = new XMLHttpRequest();
        xhr.open("POST", "https://console.anthropic.com/v1/oauth/token");
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200) {
                    try {
                        var response = JSON.parse(xhr.responseText);
                        if (!response.access_token) {
                            root.lastError = "Kein access_token in Antwort. Keys: " + Object.keys(response).join(", ");
                            return;
                        }
                        Plasmoid.configuration.oauthToken = response.access_token;
                        root.isAwaitingCode = false;
                        root.lastError = "";
                        root.isAuthenticated = true;
                        fetchUsage();
                    } catch (e) {
                        root.lastError = "Parse-Fehler: " + e.message + " | Antwort: " + (xhr.responseText || "").substring(0, 200);
                    }
                } else {
                    root.lastError = "Token-Austausch fehlgeschlagen: HTTP " + xhr.status + " | " + (xhr.responseText || "").substring(0, 200);
                }
            }
        };
        var body = JSON.stringify({
            grant_type: "authorization_code",
            code: code,
            state: root.oauthState,
            client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            redirect_uri: "https://console.anthropic.com/oauth/code/callback",
            code_verifier: root.codeVerifier
        });
        xhr.send(body);
    }

    function signOut() {
        Plasmoid.configuration.oauthToken = "";
        root.isAuthenticated = false;
        root.pct5h = 0;
        root.pct7d = 0;
        root.reset5h = "";
        root.reset7d = "";
        root.lastError = "";
        root.lastUpdated = new Date(0);
    }

    function generateRandomString(length) {
        var chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
        var result = "";
        for (var i = 0; i < length; i++) {
            result += chars.charAt(Math.floor(Math.random() * chars.length));
        }
        return result;
    }

    // SHA-256 + base64url for PKCE S256
    function rightRotate(v, n) { return (v >>> n) | (v << (32 - n)); }

    function sha256bytes(msg) {
        var K = [
            0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
            0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
            0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
            0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
            0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
            0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
            0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
            0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
        ];
        var H = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19];
        var bytes = [];
        for (var i = 0; i < msg.length; i++) bytes.push(msg.charCodeAt(i));
        var bitLen = bytes.length * 8;
        bytes.push(0x80);
        while (bytes.length % 64 !== 56) bytes.push(0);
        for (var i = 7; i >= 0; i--) bytes.push((bitLen / Math.pow(2, i * 8)) & 0xff);
        for (var off = 0; off < bytes.length; off += 64) {
            var W = [];
            for (var t = 0; t < 16; t++)
                W[t] = (bytes[off+t*4]<<24)|(bytes[off+t*4+1]<<16)|(bytes[off+t*4+2]<<8)|bytes[off+t*4+3];
            for (var t = 16; t < 64; t++) {
                var s0 = rightRotate(W[t-15],7)^rightRotate(W[t-15],18)^(W[t-15]>>>3);
                var s1 = rightRotate(W[t-2],17)^rightRotate(W[t-2],19)^(W[t-2]>>>10);
                W[t] = (W[t-16]+s0+W[t-7]+s1)|0;
            }
            var a=H[0],b=H[1],c=H[2],d=H[3],e=H[4],f=H[5],g=H[6],h=H[7];
            for (var t = 0; t < 64; t++) {
                var S1 = rightRotate(e,6)^rightRotate(e,11)^rightRotate(e,25);
                var ch = (e&f)^(~e&g);
                var t1 = (h+S1+ch+K[t]+W[t])|0;
                var S0 = rightRotate(a,2)^rightRotate(a,13)^rightRotate(a,22);
                var maj = (a&b)^(a&c)^(b&c);
                var t2 = (S0+maj)|0;
                h=g;g=f;f=e;e=(d+t1)|0;d=c;c=b;b=a;a=(t1+t2)|0;
            }
            H[0]=(H[0]+a)|0;H[1]=(H[1]+b)|0;H[2]=(H[2]+c)|0;H[3]=(H[3]+d)|0;
            H[4]=(H[4]+e)|0;H[5]=(H[5]+f)|0;H[6]=(H[6]+g)|0;H[7]=(H[7]+h)|0;
        }
        var res = [];
        for (var i = 0; i < 8; i++) {
            res.push((H[i]>>24)&0xff,(H[i]>>16)&0xff,(H[i]>>8)&0xff,H[i]&0xff);
        }
        return res;
    }

    function base64url(bytes) {
        var c = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        var r = "";
        for (var i = 0; i < bytes.length; i += 3) {
            var b1=bytes[i], b2=i+1<bytes.length?bytes[i+1]:0, b3=i+2<bytes.length?bytes[i+2]:0;
            r += c.charAt(b1>>2);
            r += c.charAt(((b1&3)<<4)|(b2>>4));
            if (i+1<bytes.length) r += c.charAt(((b2&15)<<2)|(b3>>6));
            if (i+2<bytes.length) r += c.charAt(b3&63);
        }
        return r.replace(/\+/g,"-").replace(/\//g,"_");
    }

    function pkceChallenge(verifier) {
        return base64url(sha256bytes(verifier));
    }

    // History management
    property string historyFilePath: Platform.StandardPaths.writableLocation(Platform.StandardPaths.ConfigLocation) + "/claude-usage-bar/history.json"

    function loadHistory() {
        var xhr = new XMLHttpRequest();
        xhr.open("GET", historyFilePath);
        xhr.onreadystatechange = function() {
            if (xhr.readyState === XMLHttpRequest.DONE) {
                if (xhr.status === 200 || xhr.status === 0) {
                    try {
                        var data = JSON.parse(xhr.responseText);
                        root.historyPoints = data.dataPoints || [];
                    } catch (e) {
                        root.historyPoints = [];
                    }
                }
            }
        };
        try { xhr.send(); } catch (e) { /* file may not exist */ }
    }

    function recordHistory() {
        var point = {
            timestamp: new Date().toISOString(),
            pct5h: root.pct5h / 100.0,
            pct7d: root.pct7d / 100.0
        };
        var points = root.historyPoints.slice();
        points.push(point);
        // Keep max 30 days
        var cutoff = new Date();
        cutoff.setDate(cutoff.getDate() - 30);
        points = points.filter(function(p) {
            return new Date(p.timestamp) >= cutoff;
        });
        root.historyPoints = points;
        saveHistory();
    }

    function saveHistory() {
        var data = JSON.stringify({ dataPoints: root.historyPoints });
        var xhr = new XMLHttpRequest();
        var dir = Platform.StandardPaths.writableLocation(Platform.StandardPaths.ConfigLocation) + "/claude-usage-bar";
        // Ensure directory exists via a small workaround
        xhr.open("PUT", historyFilePath);
        xhr.send(data);
    }
}
