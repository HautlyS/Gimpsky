#!/bin/bash
###############################################################################
# Push to GitHub - Run this after authenticating with gh cli
#
# Usage:
#   Option 1: Set GITHUB_TOKEN env var, then run:
#     export GITHUB_TOKEN=ghp_your_token_here
#     ./push-to-github.sh
#
#   Option 2: Run gh auth login first (interactive), then:
#     ./push-to-github.sh
#
#   Option 3: Pass repo name as argument:
#     ./push-to-github.sh my-whisk-gimp-repo
###############################################################################

set -euo pipefail

# Configuration
REPO_NAME="${1:-whisk-gimp}"
REPO_DESCRIPTION="AI image generation tools (Google Whisk/Imagen) integrated into GIMP"
IS_PRIVATE="${IS_PRIVATE:-false}"  # Set to "true" for private repo

echo "═══════════════════════════════════════════════"
echo "  Push Whisk-GIMP to GitHub"
echo "═══════════════════════════════════════════════"
echo ""

# Check authentication
if ! gh auth status >/dev/null 2>&1; then
    echo "Not authenticated with GitHub."
    echo ""
    echo "Please run one of these first:"
    echo "  gh auth login                     # Interactive login"
    echo "  echo 'YOUR_TOKEN' | gh auth login --with-token  # With token"
    echo ""
    echo "Get a token at: https://github.com/settings/tokens"
    exit 1
fi

# Get current user
GH_USER=$(gh api user --jq '.login' 2>/dev/null || echo "unknown")
echo "Authenticated as: $GH_USER"
echo ""

# Check if repo already has a remote
if git remote -v | grep -q origin; then
    echo "Remote 'origin' already exists:"
    git remote -v
    echo ""
    read -p "Do you want to change the remote? (y/N) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        git remote remove origin
    else
        read -p "Do you want to push to existing remote? (Y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Nn]$ ]]; then
            exit 0
        fi
        echo "Pushing to existing remote..."
        git push -u origin main
        echo ""
        echo "Done! Repo URL: $(git remote get-url origin)"
        exit 0
    fi
fi

# Create the repository
echo "Creating repository: github.com/$GH_USER/$REPO_NAME"
echo "Description: $REPO_DESCRIPTION"
echo "Private: $IS_PRIVATE"
echo ""

if [ "$IS_PRIVATE" = "true" ]; then
    gh repo create "$GH_USER/$REPO_NAME" --private --description "$REPO_DESCRIPTION"
else
    gh repo create "$GH_USER/$REPO_NAME" --public --description "$REPO_DESCRIPTION"
fi

# Add remote and push
git remote add origin "https://github.com/$GH_USER/$REPO_NAME.git"
git push -u origin main

echo ""
echo "═══════════════════════════════════════════════"
echo "  Success!"
echo "═══════════════════════════════════════════════"
echo ""
echo "Repository URL: https://github.com/$GH_USER/$REPO_NAME"
echo ""
echo "One-line install for others:"
echo "  curl -fsSL https://raw.githubusercontent.com/$GH_USER/$REPO_NAME/main/install.sh | bash"
echo ""

# Update URLs in files
echo "Updating repository URLs in documentation..."
sed -i "s|YOUR_USER|$GH_USER|g" README.md install.sh 2>/dev/null || true
sed -i "s|https://github.com/YOUR_USER/whisk-gimp|https://github.com/$GH_USER/$REPO_NAME|g" README.md install.sh 2>/dev/null || true

# Commit and push URL updates
git add -A
if git diff --cached --quiet; then
    echo "No URL updates needed."
else
    git commit -m "Update repository URLs to github.com/$GH_USER/$REPO_NAME"
    git push origin main
fi

echo ""
echo "Done!"
