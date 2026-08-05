#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Yapless to Voice AI
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🧠
# @raycast.packageName Yapless

# Documentation:
# @raycast.description Record voice and send it to the "voice" agent on the cotal mesh (reply lands in `paw inbox`)
# @raycast.author caffeinum
# @raycast.authorURL https://github.com/caffeinum

# The sink is passed PER INVOCATION rather than set in ~/.config/yapless/config.json, so ordinary
# dictation stays ordinary dictation. A config-level `output.command` fires on EVERY recording — a
# private note, a half-formed thought, a sentence meant for a text field — and the target agent runs
# with bypassPermissions, i.e. it may act on what it reads. One hotkey types, this one talks.
#
# --no-paste because the transcript is an instruction to an agent, not text for whatever window
# happens to be focused; --clipboard so it's still recoverable if you meant to keep it.
#
# `paw dm voice -` reads the message on STDIN. Not argv: dictation is full of apostrophes and
# newlines, and argv is world-readable in `ps`.
~/.local/bin/yapless --record --clipboard --no-paste --detach \
  --output-command "$HOME/.local/bin/paw dm voice -"
