#!/usr/bin/env bash
# Prove an image was built by THIS repo's CI on main — not by someone with a stolen registry token.
#   ./verify-image.sh ghcr.io/<owner>/pulse-api@sha256:...
set -euo pipefail
IMAGE="${1:?usage: $0 <image@digest>}"
REPO="${REPO:-$(git config --get remote.origin.url | sed -E 's#(git@|https://)github.com[:/]##; s#\.git$##')}"

IDENTITY="https://github.com/${REPO}/.github/workflows/ci.yml@refs/heads/main"
ISSUER="https://token.actions.githubusercontent.com"

echo "== Signature (must be signed by ${IDENTITY})"
cosign verify "$IMAGE" --certificate-identity "$IDENTITY" --certificate-oidc-issuer "$ISSUER" >/dev/null
echo "  ok"

echo "== SBOM attestation"
cosign verify-attestation "$IMAGE" --type spdxjson --certificate-identity "$IDENTITY" --certificate-oidc-issuer "$ISSUER" \
  | jq -r '.payload' | base64 -d | jq -r '"  \(.predicate.packages | length) packages in SBOM"'

echo "✅ $IMAGE was built and signed by ${REPO} CI on main"
