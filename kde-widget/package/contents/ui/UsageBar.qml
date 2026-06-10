import QtQuick
import org.kde.kirigami as Kirigami

// A small usage bar with rounded corners, colored by percentage
Item {
    id: bar

    // percentage 0-100, or -1 for unauthenticated (dashed)
    property real percentage: 0

    Rectangle {
        id: background
        anchors.fill: parent
        radius: 2
        color: Kirigami.Theme.textColor
        opacity: 0.15
        border.width: bar.percentage < 0 ? 1 : 0
        border.color: Kirigami.Theme.textColor
    }

    Rectangle {
        id: fill
        visible: bar.percentage >= 0
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: parent.width * Math.max(0, Math.min(1, bar.percentage / 100.0))
        radius: 2
        color: {
            var ratio = bar.percentage / 100.0;
            if (ratio < 0.60) return "#27ae60";
            if (ratio < 0.80) return "#f39c12";
            return "#e74c3c";
        }
    }

    // Dashed overlay when unauthenticated
    Canvas {
        id: dashedOverlay
        anchors.fill: parent
        visible: bar.percentage < 0
        onPaint: {
            var ctx = getContext("2d");
            ctx.clearRect(0, 0, width, height);
            ctx.strokeStyle = Kirigami.Theme.textColor;
            ctx.globalAlpha = 0.3;
            ctx.lineWidth = 1;
            ctx.setLineDash([2, 2]);
            ctx.strokeRect(0.5, 0.5, width - 1, height - 1);
        }
    }
}
