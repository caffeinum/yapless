#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Voice Input
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🎤
# @raycast.packageName Voice to Text

# Documentation:
# @raycast.description Start voice recording and transcribe to text
# @raycast.author caffeinum
# @raycast.authorURL https://github.com/caffeinum

~/.local/bin/voice-to-text --record --paste
