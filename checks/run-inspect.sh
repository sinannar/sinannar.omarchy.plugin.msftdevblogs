#!/usr/bin/env bash
set -euo pipefail

OMARCHY_MSFTDEVBLOGS_PLUGIN_ID="sinannar.omarchy.plugin.msftdevblogs"
omarchy plugin list --json \
  | jq --arg id "$OMARCHY_MSFTDEVBLOGS_PLUGIN_ID" '.[] | select(.id == $id)'
