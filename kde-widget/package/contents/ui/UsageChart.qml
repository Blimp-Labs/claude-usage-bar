import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PC3

ColumnLayout {
    id: chartRoot

    property var historyPoints: []
    property string selectedRange: "1d"
    property int hoverIndex: -1

    spacing: Kirigami.Units.smallSpacing

    // Time range selector
    RowLayout {
        Layout.fillWidth: true
        spacing: 1

        Repeater {
            model: ["1h", "6h", "1d", "7d", "30d"]

            PC3.Button {
                text: modelData
                flat: chartRoot.selectedRange !== modelData
                highlighted: chartRoot.selectedRange === modelData
                font.pixelSize: Kirigami.Theme.smallFont.pixelSize
                implicitWidth: Kirigami.Units.gridUnit * 2.5
                onClicked: chartRoot.selectedRange = modelData
            }
        }
    }

    // Chart canvas
    Item {
        Layout.fillWidth: true
        Layout.preferredHeight: 100

        Canvas {
            id: canvas
            anchors.fill: parent

            property var filteredPoints: filterPoints()
            property int hoveredIdx: chartRoot.hoverIndex

            onFilteredPointsChanged: requestPaint()
            onHoveredIdxChanged: requestPaint()

            onPaint: {
                var ctx = getContext("2d");
                ctx.clearRect(0, 0, width, height);

                var pts = filteredPoints;
                if (pts.length < 2) {
                    ctx.fillStyle = Kirigami.Theme.disabledTextColor;
                    ctx.font = "11px sans-serif";
                    ctx.textAlign = "center";
                    ctx.fillText("Noch keine Verlaufsdaten.", width / 2, height / 2);
                    return;
                }

                var margin = { left: 30, right: 10, top: 15, bottom: 5 };
                var chartW = width - margin.left - margin.right;
                var chartH = height - margin.top - margin.bottom;

                // Y axis labels
                ctx.fillStyle = Kirigami.Theme.disabledTextColor;
                ctx.font = "9px monospace";
                ctx.textAlign = "right";
                for (var pct = 0; pct <= 100; pct += 25) {
                    var yPos = margin.top + chartH * (1 - pct / 100);
                    ctx.fillText(pct + "%", margin.left - 4, yPos + 3);
                    // Grid line
                    ctx.strokeStyle = Kirigami.Theme.disabledTextColor;
                    ctx.globalAlpha = 0.15;
                    ctx.lineWidth = 0.5;
                    ctx.beginPath();
                    ctx.moveTo(margin.left, yPos);
                    ctx.lineTo(margin.left + chartW, yPos);
                    ctx.stroke();
                    ctx.globalAlpha = 1.0;
                }

                // Find time range
                var now = new Date().getTime();
                var rangeMs = getRangeMs();
                var startTime = now - rangeMs;

                function xForTime(t) {
                    return margin.left + ((t - startTime) / rangeMs) * chartW;
                }
                function yForPct(p) {
                    return margin.top + chartH * (1 - p);
                }

                // Draw 5h line (blue)
                ctx.strokeStyle = "#3498db";
                ctx.lineWidth = 1.5;
                ctx.beginPath();
                for (var i = 0; i < pts.length; i++) {
                    var x = xForTime(new Date(pts[i].timestamp).getTime());
                    var y = yForPct(pts[i].pct5h);
                    if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
                }
                ctx.stroke();

                // Draw 7d line (orange)
                ctx.strokeStyle = "#e67e22";
                ctx.lineWidth = 1.5;
                ctx.beginPath();
                for (var j = 0; j < pts.length; j++) {
                    var x2 = xForTime(new Date(pts[j].timestamp).getTime());
                    var y2 = yForPct(pts[j].pct7d);
                    if (j === 0) ctx.moveTo(x2, y2); else ctx.lineTo(x2, y2);
                }
                ctx.stroke();

                // Legend
                ctx.font = "9px sans-serif";
                ctx.textAlign = "left";
                // 5h
                ctx.fillStyle = "#3498db";
                ctx.fillRect(margin.left, 2, 8, 8);
                ctx.fillText("5h", margin.left + 10, 10);
                // 7d
                ctx.fillStyle = "#e67e22";
                ctx.fillRect(margin.left + 35, 2, 8, 8);
                ctx.fillText("7d", margin.left + 45, 10);

                // Hover indicator
                if (hoveredIdx >= 0 && hoveredIdx < pts.length) {
                    var hPt = pts[hoveredIdx];
                    var hx = xForTime(new Date(hPt.timestamp).getTime());

                    ctx.strokeStyle = Kirigami.Theme.textColor;
                    ctx.globalAlpha = 0.3;
                    ctx.lineWidth = 1;
                    ctx.beginPath();
                    ctx.moveTo(hx, margin.top);
                    ctx.lineTo(hx, margin.top + chartH);
                    ctx.stroke();
                    ctx.globalAlpha = 1.0;

                    // Dots
                    ctx.fillStyle = "#3498db";
                    ctx.beginPath();
                    ctx.arc(hx, yForPct(hPt.pct5h), 3, 0, 2 * Math.PI);
                    ctx.fill();

                    ctx.fillStyle = "#e67e22";
                    ctx.beginPath();
                    ctx.arc(hx, yForPct(hPt.pct7d), 3, 0, 2 * Math.PI);
                    ctx.fill();

                    // Tooltip
                    var tooltipText = Math.round(hPt.pct5h * 100) + "% / " + Math.round(hPt.pct7d * 100) + "%";
                    ctx.fillStyle = Kirigami.Theme.backgroundColor;
                    ctx.globalAlpha = 0.85;
                    var tw = ctx.measureText(tooltipText).width + 8;
                    var tx = Math.min(hx - tw / 2, width - tw - 2);
                    tx = Math.max(tx, 2);
                    ctx.fillRect(tx, margin.top - 14, tw, 13);
                    ctx.globalAlpha = 1.0;
                    ctx.fillStyle = Kirigami.Theme.textColor;
                    ctx.font = "9px monospace";
                    ctx.textAlign = "left";
                    ctx.fillText(tooltipText, tx + 4, margin.top - 4);
                }
            }

            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onPositionChanged: function(mouse) {
                    var pts = canvas.filteredPoints;
                    if (pts.length === 0) return;

                    var margin = { left: 30, right: 10 };
                    var chartW = canvas.width - margin.left - margin.right;
                    var now = new Date().getTime();
                    var rangeMs = getRangeMs();
                    var startTime = now - rangeMs;

                    var mouseTime = startTime + ((mouse.x - margin.left) / chartW) * rangeMs;
                    var bestIdx = 0;
                    var bestDist = Math.abs(new Date(pts[0].timestamp).getTime() - mouseTime);
                    for (var i = 1; i < pts.length; i++) {
                        var dist = Math.abs(new Date(pts[i].timestamp).getTime() - mouseTime);
                        if (dist < bestDist) {
                            bestDist = dist;
                            bestIdx = i;
                        }
                    }
                    chartRoot.hoverIndex = bestIdx;
                }
                onExited: chartRoot.hoverIndex = -1
            }
        }
    }

    function getRangeMs() {
        switch (chartRoot.selectedRange) {
            case "1h": return 3600000;
            case "6h": return 6 * 3600000;
            case "1d": return 86400000;
            case "7d": return 7 * 86400000;
            case "30d": return 30 * 86400000;
        }
        return 86400000;
    }

    function filterPoints() {
        var now = new Date().getTime();
        var rangeMs = getRangeMs();
        var cutoff = now - rangeMs;

        var pts = [];
        for (var i = 0; i < chartRoot.historyPoints.length; i++) {
            var p = chartRoot.historyPoints[i];
            if (new Date(p.timestamp).getTime() >= cutoff) {
                pts.push(p);
            }
        }

        // Sort by time
        pts.sort(function(a, b) {
            return new Date(a.timestamp).getTime() - new Date(b.timestamp).getTime();
        });

        // Downsample if needed (max 200 points)
        if (pts.length > 200) {
            var step = Math.ceil(pts.length / 200);
            var downsampled = [];
            for (var j = 0; j < pts.length; j += step) {
                downsampled.push(pts[j]);
            }
            return downsampled;
        }

        return pts;
    }
}
