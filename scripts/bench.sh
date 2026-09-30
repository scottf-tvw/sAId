#!/bin/bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
swift build -c release --product said-bench
bin=$(swift build -c release --show-bin-path)
exec "$bin/said-bench" "$@"
