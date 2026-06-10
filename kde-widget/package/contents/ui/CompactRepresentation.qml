import QtQuick
import QtQuick.Layouts
import org.kde.plasma.core as PlasmaCore
import org.kde.kirigami as Kirigami

MouseArea {
    id: compactRoot

    property real pct5h: 0
    property real pct7d: 0
    property bool isAuthenticated: false

    Layout.minimumWidth: row.implicitWidth
    Layout.preferredWidth: row.implicitWidth

    onClicked: root.expanded = !root.expanded

    RowLayout {
        id: row
        anchors.centerIn: parent
        spacing: Kirigami.Units.smallSpacing

        // Claude "C" logo text
        Text {
            text: "C"
            font.pixelSize: Kirigami.Units.iconSizes.small
            font.bold: true
            color: Kirigami.Theme.textColor
        }

        // Dual bar indicator
        Column {
            spacing: 1
            Layout.alignment: Qt.AlignVCenter

            // 5h label + bar
            Row {
                spacing: 2

                Text {
                    text: "5h"
                    font.pixelSize: 7
                    font.family: "monospace"
                    color: Kirigami.Theme.textColor
                    opacity: 0.8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14
                    horizontalAlignment: Text.AlignRight
                }

                UsageBar {
                    width: 28
                    height: 5
                    percentage: compactRoot.isAuthenticated ? compactRoot.pct5h : -1
                }
            }

            // 7d label + bar
            Row {
                spacing: 2

                Text {
                    text: "7d"
                    font.pixelSize: 7
                    font.family: "monospace"
                    color: Kirigami.Theme.textColor
                    opacity: 0.8
                    anchors.verticalCenter: parent.verticalCenter
                    width: 14
                    horizontalAlignment: Text.AlignRight
                }

                UsageBar {
                    width: 28
                    height: 5
                    percentage: compactRoot.isAuthenticated ? compactRoot.pct7d : -1
                }
            }
        }
    }
}
