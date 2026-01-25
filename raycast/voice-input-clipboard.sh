#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Yapless to Clipboard
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 📋
# @raycast.packageName Yapless

# Documentation:
# @raycast.description Record voice and copy transcription to clipboard (no paste)
# @raycast.author caffeinum
# @raycast.authorURL https://github.com/caffeinum

~/.local/bin/yapless --record --clipboard --no-paste
