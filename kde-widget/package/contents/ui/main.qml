import QtQuick
import QtQuick.Layouts
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
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
        var Service = Qt.createQmlObject('import "../../js/usage-service.js" as S; QtObject { }', root);

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
        root.oauthState = state;
        var url = "https://claude.ai/oauth/authorize"
            + "?code=true"
            + "&client_id=9d1c250a-e61b-44d9-88ed-5944d1962f5e"
            + "&response_type=code"
            + "&redirect_uri=" + encodeURIComponent("https://console.anthropic.com/oauth/code/callback")
            + "&scope=" + encodeURIComponent("user:profile user:inference")
            + "&state=" + encodeURIComponent(state);
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
                        Plasmoid.configuration.oauthToken = response.access_token;
                        root.isAwaitingCode = false;
                        root.lastError = "";
                        root.isAuthenticated = true;
                        fetchUsage();
                    } catch (e) {
                        root.lastError = "Token-Antwort konnte nicht verarbeitet werden";
                    }
                } else {
                    root.lastError = "Token-Austausch fehlgeschlagen: HTTP " + xhr.status;
                }
            }
        };
        var body = JSON.stringify({
            grant_type: "authorization_code",
            code: code,
            state: root.oauthState,
            client_id: "9d1c250a-e61b-44d9-88ed-5944d1962f5e",
            redirect_uri: "https://console.anthropic.com/oauth/code/callback"
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

    // History management
    property string historyFilePath: StandardPaths.writableLocation(StandardPaths.ConfigLocation) + "/claude-usage-bar/history.json"

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
        var dir = StandardPaths.writableLocation(StandardPaths.ConfigLocation) + "/claude-usage-bar";
        // Ensure directory exists via a small workaround
        xhr.open("PUT", historyFilePath);
        xhr.send(data);
    }
}
