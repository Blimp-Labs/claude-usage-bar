import QtQuick
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PC3

ColumnLayout {
    id: bucketRow

    property string label: ""
    property real percentage: 0
    property string resetTime: ""

    spacing: 2

    RowLayout {
        Layout.fillWidth: true

        PC3.Label {
            text: bucketRow.label
        }

        Item { Layout.fillWidth: true }

        PC3.Label {
            text: Math.round(bucketRow.percentage) + "%"
            font.family: "monospace"
        }
    }

    PC3.ProgressBar {
        Layout.fillWidth: true
        from: 0
        to: 100
        value: bucketRow.percentage

        palette.highlight: {
            var ratio = bucketRow.percentage / 100.0;
            if (ratio < 0.60) return "#27ae60";
            if (ratio < 0.80) return "#f39c12";
            return "#e74c3c";
        }
    }

    PC3.Label {
        visible: bucketRow.resetTime !== ""
        text: "Reset " + formatResetTime(bucketRow.resetTime)
        font: Kirigami.Theme.smallFont
        opacity: 0.6
    }

    function formatResetTime(isoString) {
        if (!isoString) return "";
        var resetDate = new Date(isoString);
        var now = new Date();
        var diffMs = resetDate.getTime() - now.getTime();
        if (diffMs <= 0) return "jetzt";

        var diffMin = Math.floor(diffMs / 60000);
        var diffHours = Math.floor(diffMin / 60);
        var remainMin = diffMin % 60;

        if (diffHours > 24) {
            var days = Math.floor(diffHours / 24);
            var remHours = diffHours % 24;
            return "in " + days + "T " + remHours + "h";
        }
        if (diffHours > 0) {
            return "in " + diffHours + "h " + remainMin + "m";
        }
        return "in " + diffMin + "m";
    }
}
