#!/usr/bin/env bash
# Regenerate OpenAPI-derived client code (web / flutter generated dirs).
#
# Placeholder: the protocol source of truth is docs/openapi.yaml. Once the
# web/flutter agents pick a generator (e.g. openapi-typescript / openapi-generator),
# wire it here so all three stacks regenerate from the same contract.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "docs/openapi.yaml is the single HTTP contract (docs/api.md)."
echo "No generators configured yet: web/ and flutter/ agents decide theirs."
