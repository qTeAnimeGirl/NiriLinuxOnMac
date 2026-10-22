#!/usr/bin/env bash
# vm/scripts/install_assets.sh
# Standard entrypoint: delegates directly to the Arch Linux ARM asset installer.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "${SCRIPT_DIR}/install_arch_assets.sh" "$@"
