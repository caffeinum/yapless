.PHONY: build release install clean test

# Default target
all: build

# Build in debug mode
build:
	swift build

# Build in release mode
release:
	swift build -c release

# Install to ~/.local/bin
install: release
	@mkdir -p ~/.local/bin
	cp .build/release/voice-to-text ~/.local/bin/
	@echo "Installed to ~/.local/bin/voice-to-text"
	@echo "Make sure ~/.local/bin is in your PATH"

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build

# Run tests
test:
	swift test

# Download whisper model
download-model:
	@mkdir -p ~/.local/share/whisper
	@echo "Downloading base model..."
	curl -L -o ~/.local/share/whisper/ggml-base.bin \
		https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.bin
	@echo "Model downloaded to ~/.local/share/whisper/ggml-base.bin"

# Install Raycast scripts
install-raycast:
	@mkdir -p ~/Library/Application\ Support/Raycast/Script\ Commands
	cp raycast/*.sh ~/Library/Application\ Support/Raycast/Script\ Commands/
	chmod +x ~/Library/Application\ Support/Raycast/Script\ Commands/voice-*.sh
	@echo "Raycast scripts installed. Reload Raycast to see them."

# Create default config (skip if exists)
init-config:
	@mkdir -p ~/.config/voice-to-text
	@if [ ! -f ~/.config/voice-to-text/config.json ]; then \
		echo '{"animation":{"style":"orb","primaryColor":"#007AFF","secondaryColor":"#5856D6","opacity":0.9,"size":120,"position":"center"},"whisper":{"model":"base","vadEnabled":true},"output":{"copyToClipboard":true,"pasteToActiveApp":true,"playCompletionSound":true}}' | python3 -m json.tool > ~/.config/voice-to-text/config.json; \
		echo "Config created at ~/.config/voice-to-text/config.json"; \
	else \
		echo "Config already exists, skipping"; \
	fi

# Full setup
setup: release install download-model install-raycast init-config
	@echo ""
	@echo "✅ Setup complete!"
	@echo "1. Open Raycast and reload script commands"
	@echo "2. Assign a hotkey to 'Voice Input'"
	@echo "3. Try it out!"
