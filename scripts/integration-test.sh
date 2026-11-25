#!/bin/bash
# Headless end-to-end test: starts the Tapwire engine on a random port, a local HTTP and HTTPS
# echo server (certificate issued by a throwaway Tapwire CA), and drives curl through the proxy:
# plain HTTP, HTTPS MITM, tunnel, full mock, modify rule, environment mapping (HTTP + HTTPS),
# certificate download, 502 handling, 60 MB bodies, gzip passthrough, breakpoints, keep-alive.
# Nothing touches your real Keychain or settings (everything runs in a temp folder).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v xcodegen >/dev/null || brew install xcodegen
[ -d Tapwire.xcodeproj ] || xcodegen generate
xcodebuild test -scheme Tapwire -derivedDataPath build/DD \
  -only-testing:TapwireCoreTests/IntegrationTests 2>&1 | grep -E "Test Case|error:|TEST (SUCCEEDED|FAILED)"
