import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PC3
import org.kde.plasma.extras as PlasmaExtras

PlasmaExtras.Representation {
    id: fullRoot

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
    property bool isAuthenticated: false
    property bool isAwaitingCode: false
    property var historyPoints: []
    property int pollingMinutes: 30

    signal signInRequested()
    signal signOutRequested()
    signal refreshRequested()
    signal codeSubmitted(string code)
    signal cancelAuthRequested()
    signal pollingChanged(int minutes)

    implicitWidth: Kirigami.Units.gridUnit * 22
    implicitHeight: contentColumn.implicitHeight + Kirigami.Units.largeSpacing * 2

    ColumnLayout {
        id: contentColumn
        anchors.fill: parent
        anchors.margins: Kirigami.Units.largeSpacing
        spacing: Kirigami.Units.mediumSpacing

        // Header
        PlasmaExtras.Heading {
            level: 4
            text: "Claude Usage"
        }

        // Not authenticated
        Loader {
            Layout.fillWidth: true
            active: !fullRoot.isAuthenticated
            visible: active
            sourceComponent: ColumnLayout {
                spacing: Kirigami.Units.mediumSpacing

                Loader {
                    Layout.fillWidth: true
                    active: fullRoot.isAwaitingCode
                    visible: active
                    sourceComponent: ColumnLayout {
                        spacing: Kirigami.Units.smallSpacing

                        PC3.Label {
                            text: "Code aus dem Browser einfügen:"
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                        }

                        RowLayout {
                            spacing: Kirigami.Units.smallSpacing

                            PC3.TextField {
                                id: codeField
                                Layout.fillWidth: true
                                placeholderText: "code#state"
                                font.family: "monospace"
                                onAccepted: fullRoot.codeSubmitted(text)
                            }

                            PC3.Button {
                                icon.name: "edit-paste"
                                onClicked: {
                                    codeField.paste();
                                }
                            }
                        }

                        RowLayout {
                            PC3.Button {
                                text: "Abbrechen"
                                onClicked: fullRoot.cancelAuthRequested()
                            }
                            Item { Layout.fillWidth: true }
                            PC3.Button {
                                text: "Absenden"
                                highlighted: true
                                enabled: codeField.text.length > 0
                                onClicked: fullRoot.codeSubmitted(codeField.text)
                            }
                        }
                    }
                }

                Loader {
                    Layout.fillWidth: true
                    active: !fullRoot.isAwaitingCode
                    visible: active
                    sourceComponent: ColumnLayout {
                        spacing: Kirigami.Units.smallSpacing

                        PC3.Label {
                            text: "Melde dich an, um deine Nutzung zu sehen."
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                        }

                        PC3.Button {
                            text: "Mit Claude anmelden"
                            icon.name: "network-connect"
                            highlighted: true
                            Layout.alignment: Qt.AlignHCenter
                            onClicked: fullRoot.signInRequested()
                        }
                    }
                }

                // Error
                Loader {
                    Layout.fillWidth: true
                    active: fullRoot.lastError !== ""
                    visible: active
                    sourceComponent: PC3.Label {
                        text: fullRoot.lastError
                        color: Kirigami.Theme.negativeTextColor
                        font: Kirigami.Theme.smallFont
                        wrapMode: Text.Wrap
                    }
                }
            }
        }

        // Authenticated view
        Loader {
            Layout.fillWidth: true
            active: fullRoot.isAuthenticated
            visible: active
            sourceComponent: ColumnLayout {
                spacing: Kirigami.Units.mediumSpacing

                // 5-Hour Window
                UsageBucketRow {
                    label: "5-Stunden-Fenster"
                    percentage: fullRoot.pct5h
                    resetTime: fullRoot.reset5h
                    Layout.fillWidth: true
                }

                // 7-Day Window
                UsageBucketRow {
                    label: "7-Tage-Fenster"
                    percentage: fullRoot.pct7d
                    resetTime: fullRoot.reset7d
                    Layout.fillWidth: true
                }

                // Per-Model breakdown
                Loader {
                    Layout.fillWidth: true
                    active: fullRoot.pct7dOpus >= 0
                    visible: active
                    sourceComponent: ColumnLayout {
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Separator { Layout.fillWidth: true }

                        PC3.Label {
                            text: "Pro Modell (7 Tage)"
                            font: Kirigami.Theme.smallFont
                            opacity: 0.7
                        }

                        UsageBucketRow {
                            label: "Opus"
                            percentage: fullRoot.pct7dOpus
                            resetTime: fullRoot.reset7dOpus
                            Layout.fillWidth: true
                        }

                        Loader {
                            Layout.fillWidth: true
                            active: fullRoot.pct7dSonnet >= 0
                            visible: active
                            sourceComponent: UsageBucketRow {
                                label: "Sonnet"
                                percentage: fullRoot.pct7dSonnet
                                resetTime: fullRoot.reset7dSonnet
                            }
                        }
                    }
                }

                // Extra Usage
                Loader {
                    Layout.fillWidth: true
                    active: fullRoot.extraEnabled
                    visible: active
                    sourceComponent: ColumnLayout {
                        spacing: Kirigami.Units.smallSpacing

                        Kirigami.Separator { Layout.fillWidth: true }

                        PC3.Label {
                            text: "Zusätzliche Nutzung"
                            font.bold: true
                        }

                        RowLayout {
                            PC3.Label {
                                text: "$" + fullRoot.extraUsed.toFixed(2) + " / $" + fullRoot.extraLimit.toFixed(2)
                                font: Kirigami.Theme.smallFont
                                font.family: "monospace"
                            }
                            Item { Layout.fillWidth: true }
                            PC3.Label {
                                text: Math.round(fullRoot.extraUtilization) + "%"
                                font: Kirigami.Theme.smallFont
                                font.family: "monospace"
                            }
                        }

                        PC3.ProgressBar {
                            Layout.fillWidth: true
                            from: 0
                            to: 100
                            value: fullRoot.extraUtilization
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                // Usage Chart
                UsageChart {
                    Layout.fillWidth: true
                    Layout.preferredHeight: 120
                    historyPoints: fullRoot.historyPoints
                }

                // Error
                Loader {
                    Layout.fillWidth: true
                    active: fullRoot.lastError !== ""
                    visible: active
                    sourceComponent: ColumnLayout {
                        Kirigami.Separator { Layout.fillWidth: true }
                        PC3.Label {
                            text: fullRoot.lastError
                            color: Kirigami.Theme.negativeTextColor
                            font: Kirigami.Theme.smallFont
                            wrapMode: Text.Wrap
                        }
                    }
                }

                Kirigami.Separator { Layout.fillWidth: true }

                // Status row
                RowLayout {
                    spacing: Kirigami.Units.smallSpacing

                    PC3.Label {
                        visible: fullRoot.lastUpdated.getTime() > 0
                        text: "Aktualisiert " + formatRelativeTime(fullRoot.lastUpdated)
                        font: Kirigami.Theme.smallFont
                        opacity: 0.6
                    }

                    Item { Layout.fillWidth: true }

                    PC3.Label {
                        text: "Polling:"
                        font: Kirigami.Theme.smallFont
                        opacity: 0.6
                    }

                    PC3.ComboBox {
                        id: pollingCombo
                        model: [5, 15, 30, 60]
                        currentIndex: model.indexOf(fullRoot.pollingMinutes)
                        displayText: {
                            var v = model[currentIndex];
                            return v < 60 ? v + " Min" : (v / 60) + " Std";
                        }
                        delegate: PC3.ItemDelegate {
                            text: modelData < 60 ? modelData + " Min" : (modelData / 60) + " Std"
                            width: parent.width
                        }
                        implicitWidth: Kirigami.Units.gridUnit * 4
                        onActivated: function(index) {
                            fullRoot.pollingChanged(model[index]);
                        }
                    }
                }

                // Action buttons
                RowLayout {
                    spacing: Kirigami.Units.smallSpacing

                    PC3.Button {
                        text: "Aktualisieren"
                        icon.name: "view-refresh"
                        flat: true
                        font: Kirigami.Theme.smallFont
                        onClicked: fullRoot.refreshRequested()
                    }

                    Item { Layout.fillWidth: true }

                    PC3.Button {
                        text: "Abmelden"
                        flat: true
                        font: Kirigami.Theme.smallFont
                        onClicked: fullRoot.signOutRequested()
                    }
                }
            }
        }
    }

    function formatRelativeTime(date) {
        var now = new Date();
        var diffMs = now.getTime() - date.getTime();
        var diffMin = Math.floor(diffMs / 60000);
        if (diffMin < 1) return "gerade eben";
        if (diffMin < 60) return "vor " + diffMin + " Min";
        var diffHours = Math.floor(diffMin / 60);
        if (diffHours < 24) return "vor " + diffHours + " Std";
        return "vor " + Math.floor(diffHours / 24) + " Tagen";
    }
}
