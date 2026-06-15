#!/usr/bin/env bash
#
# Run the relay concurrency suites under ThreadSanitizer. Closes issue #203.
#
# TurnRelay/TextStreamRelay gate event delivery and enforce once-only terminal
# transitions across a producer/consumer race. The `concurrentDeliver*` tests
# exercise that race only *probabilistically* — under a normal Debug build the
# window is tiny, so a regression (dropping the NSLock, a torn read of `finished`,
# or yielding a non-terminal event after the terminal one) can slip through CI by
# luck. TSan deterministically flags data races regardless of timing.
#
# Scoped to the relay suites (--filter Relay) to keep the run fast and avoid
# sanitizing the model-gated FoundationModels tests.
#
# Prerequisites:
#   - Xcode 27+ toolchain. Locally, point DEVELOPER_DIR at it (the default
#     CommandLineTools swift is too old / broken for this package):
#       export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
#     CI selects the newest installed Xcode before invoking this script.
#
# Usage:
#   scripts/test-relay-tsan.sh
#
set -euo pipefail

cd "$(dirname "$0")/.."

echo "Running relay concurrency suites under ThreadSanitizer…"
exec xcrun swift test --sanitize thread --filter Relay
