#!/usr/bin/env bash
set -euo pipefail

OMARCHY_MSFTDEVBLOGS_PLUGIN_ID="sinannar.omarchy.plugin.msftdevblogs"
OMARCHY_MSFTDEVBLOGS_PLUGIN_DIR="$HOME/.config/omarchy/plugins/$OMARCHY_MSFTDEVBLOGS_PLUGIN_ID"

omarchy plugin validate "$OMARCHY_MSFTDEVBLOGS_PLUGIN_DIR"
qmllint -I "${OMARCHY_PATH:?OMARCHY_PATH must be set}/shell" \
  "$OMARCHY_MSFTDEVBLOGS_PLUGIN_DIR/BarWidget.qml" \
  "$OMARCHY_MSFTDEVBLOGS_PLUGIN_DIR/Panel.qml"
