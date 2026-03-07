#!/bin/bash
# Uninstall the Claude Usage KDE Plasma widget

set -e

WIDGET_ID="org.kde.plasma.claude-usage"

if ! command -v kpackagetool6 &> /dev/null; then
    echo "Fehler: kpackagetool6 nicht gefunden."
    exit 1
fi

echo "Widget wird deinstalliert..."
kpackagetool6 --type Plasma/Applet --remove "$WIDGET_ID"

echo "Claude Usage Widget wurde deinstalliert."
echo "Eventuell musst du Plasma neu starten (plasmashell neu starten oder ausloggen/einloggen)."
