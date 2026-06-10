import QtQuick
import QtQuick.Controls as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.kcmutils as KCM

KCM.SimpleKCM {
    id: configPage

    property alias cfg_pollingMinutes: pollingSpinBox.value

    Kirigami.FormLayout {
        QQC2.SpinBox {
            id: pollingSpinBox
            Kirigami.FormData.label: "Polling-Intervall (Minuten):"
            from: 1
            to: 120
            stepSize: 5
            value: 30
        }

        QQC2.Label {
            text: "Die Authentifizierung erfolgt über das Widget selbst.\nKlicke auf das Widget und wähle 'Mit Claude anmelden'."
            wrapMode: Text.Wrap
            opacity: 0.7
        }
    }
}
