#!/bin/bash
###############################################################################
# Quick Push to GitHub - No gh cli required
#
# Usage:
#   ./quick-push.sh YOUR_GITHUB_USERNAME [REPO_NAME]
#
# Example:
#   ./quick-push.sh john_doe
#   ./quick-push.sh john_doe my-whisk-repo
###############################################################################

set -euo pipefail

GITHUB_USER="${1:-}"
REPO_NAME="${2:-whisk-gimp}"

if [ -z "$GITHUB_USER" ]; then
    echo "Usage: ./quick-push.sh YOUR_GITHUB_USERNAME [REPO_NAME]"
    echo ""
    echo "Example:"
    echo "  ./quick-push.sh john_doe"
    echo "  ./quick-push.sh john_doe my-whisk-repo"
    echo ""
    echo "You need a GitHub Personal Access Token with repo scope."
    echo "Create one at: https://github.com/settings/tokens/new"
    echo ""
    echo "Then set it as:"
    echo "  export GITHUB_TOKEN=ghp_your_token_here"
    exit 1
fi

echo "═══════════════════════════════════════════════════"
echo "  Push Whisk-GIMP to GitHub"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Target: github.com/$GITHUB_USER/$REPO_NAME"
echo ""

# Check for token
if [ -z "${GITHUB_TOKEN:-}" ]; then
    echo "GITHUB_TOKEN not set."
    echo ""
    echo "Create a token at: https://github.com/settings/tokens/new"
    echo "  - Select 'repo' scope"
    echo "  - Copy the token"
    echo "  - Run: export GITHUB_TOKEN=ghp_your_token_here"
    echo ""
    echo "Then run this script again."
    exit 1
fi

# Create repo via API
echo "Creating repository via GitHub API..."
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "https://api.github.com/user/repos" \
    -H "Authorization: token $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github.v3+json" \
    -d "{
        \"name\": \"$REPO_NAME\",
        \"description\": \"AI image generation tools (Google Whisk/Imagen) integrated into GIMP\",
        \"private\": false,
        \"auto_init\": true
    }")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | sed '$d')

if [ "$HTTP_CODE" = "201" ]; then
    echo "Repository created successfully!"
elif [ "$HTTP_CODE" = "422" ]; then
    echo "Repository may already exist. Continuing..."
else
    echo "API Response (HTTP $HTTP_CODE):"
    echo "$BODY"
    if [ "$HTTP_CODE" = "401" ]; then
        echo ""
        echo "Authentication failed. Check your GITHUB_TOKEN."
    fi
    exit 1
fi

echo ""

# Add remote and push
REPO_URL="https://${GITHUB_TOKEN}@github.com/${GITHUB_USER}/${REPO_NAME}.git"

echo "Adding remote..."
git remote add origin "$REPO_URL" 2>/dev/null || git remote set-url origin "$REPO_URL"

echo "Pushing to GitHub..."
git push -u origin main --force

echo ""
echo "═══════════════════════════════════════════════════"
echo "  Success!"
echo "═══════════════════════════════════════════════════"
echo ""
echo "Repository URL: https://github.com/$GITHUB_USER/$REPO_NAME"
echo ""
echo "One-line install for others:"
echo "  curl -fsSL https://raw.githubusercontent.com/$GITHUB_USER/$REPO_NAME/main/install.sh | bash"
echo ""

# Update URLs in files
echo "Updating repository URLs in documentation..."
sed -i "s|YOUR_USER|$GITHUB_USER|g" README.md install.sh 2>/dev/null || true
sed -i "s|https://github.com/YOUR_USER/whisk-gimp|https://github.com/$GITHUB_USER/$REPO_NAME|g" README.md install.sh 2>/dev/null || true

# Commit and push URL updates
git add -A
if ! git diff --cached --quiet; then
    git commit -m "Update repository URLs to github.com/$GITHUB_USER/$REPO_NAME"
    git push origin main
fi

echo ""
echo "Done!"
