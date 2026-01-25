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
	cp .build/release/yapless ~/.local/bin/
	@echo "Installed to ~/.local/bin/yapless"
	@echo "Make sure ~/.local/bin is in your PATH"

# Clean build artifacts
clean:
	swift package clean
	rm -rf .build

# Run tests
test:
	swift test

# Download whisper model (for local backend)
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
	chmod +x ~/Library/Application\ Support/Raycast/Script\ Commands/*.sh
	@echo "Raycast scripts installed. Reload Raycast to see them."

# Create default config
init-config:
	@mkdir -p ~/.config/yapless
	@if [ ! -f ~/.config/yapless/config.json ]; then \
		echo '{"animation":{"style":"orb","position":"center"},"whisper":{"backend":"auto","model":"base"},"output":{"copyToClipboard":true,"pasteToActiveApp":true}}' | python3 -m json.tool > ~/.config/yapless/config.json; \
		echo "Config created at ~/.config/yapless/config.json"; \
	else \
		echo "Config already exists, skipping"; \
	fi

# Full setup
setup: release install install-raycast init-config
	@echo ""
	@echo "Setup complete!"
	@echo "1. Open Raycast and reload script commands"
	@echo "2. Assign a hotkey to 'Yapless'"
	@echo "3. Try it out!"
