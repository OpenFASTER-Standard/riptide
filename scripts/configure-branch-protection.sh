#!/usr/bin/env bash
set -euo pipefail

# Configures main's branch protection to match the Docker/CI/CD sub-project's
# design (docs/superpowers/specs/2026-08-24-docker-cicd-design.md §3.5):
# require the ci.yml `test` job, require a PR (no direct pushes), no mandatory
# approval count (effectively solo-maintained today; every PR already goes
# through this project's own AI-driven review process before merge).
#
# Re-runnable: safe to run again if these settings ever need to be reapplied.

REPO="OpenFASTER-Standard/riptide"

gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "repos/${REPO}/branches/main/protection" \
  --input - <<'EOF'
{
  "required_status_checks": {
    "strict": true,
    "checks": [{"context": "test"}]
  },
  "enforce_admins": false,
  "required_pull_request_reviews": {
    "required_approving_review_count": 0
  },
  "restrictions": null,
  "allow_force_pushes": false,
  "allow_deletions": false
}
EOF

echo "Branch protection applied to ${REPO}#main."
