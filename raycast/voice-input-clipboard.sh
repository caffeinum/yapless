#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Voice to Clipboard
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 📋
# @raycast.packageName Voice to Text

# Documentation:
# @raycast.description Record voice and copy transcription to clipboard (no paste)
# @raycast.author caffeinum
# @raycast.authorURL https://github.com/caffeinum

~/.local/bin/voice-to-text --record --clipboard --no-paste
