#!/bin/bash
# Install the Claude Usage KDE Plasma widget
# Requires: KDE Plasma 6 (Fedora 43+)

set -e

WIDGET_ID="org.kde.plasma.claude-usage"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PACKAGE_DIR="$SCRIPT_DIR/package"

if ! command -v kpackagetool6 &> /dev/null; then
    echo "Fehler: kpackagetool6 nicht gefunden. KDE Plasma 6 ist erforderlich."
    echo "Installiere mit: sudo dnf install kf6-kpackage"
    exit 1
fi

# Check if already installed, then upgrade; otherwise install fresh
if kpackagetool6 --type Plasma/Applet --show "$WIDGET_ID" &> /dev/null; then
    echo "Widget wird aktualisiert..."
    kpackagetool6 --type Plasma/Applet --upgrade "$PACKAGE_DIR"
else
    echo "Widget wird installiert..."
    kpackagetool6 --type Plasma/Applet --install "$PACKAGE_DIR"
fi

echo ""
echo "Claude Usage Widget wurde installiert!"
echo ""
echo "So fügst du es hinzu:"
echo "  1. Rechtsklick auf das KDE Panel → 'Widgets hinzufügen...'"
echo "  2. Suche nach 'Claude Usage'"
echo "  3. Ziehe es in dein Panel"
echo "  4. Klicke darauf → 'Mit Claude anmelden'"
