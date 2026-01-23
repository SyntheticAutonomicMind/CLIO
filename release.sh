#!/bin/bash
# CLIO Release Script
#
# This script automates the correct release process:
# 1. Update VERSION file
# 2. Update lib/CLIO.pm version
# 3. Commit the version changes
# 4. Create and push the tag
# 5. Trigger GitHub Actions release workflow
#
# Usage:
#   ./release.sh <version>
#
# Example:
#   ./release.sh 20260123.8

set -e  # Exit on error

# Check argument
if [ $# -ne 1 ]; then
    echo "Usage: $0 <version>"
    echo "Example: $0 20260123.8"
    exit 1
fi

VERSION="$1"

# Validate version format (YYYYMMDD.N)
if ! echo "$VERSION" | grep -qE '^[0-9]{8}\.[0-9]+$'; then
    echo "ERROR: Invalid version format: $VERSION"
    echo "Expected format: YYYYMMDD.N (e.g., 20260123.8)"
    exit 1
fi

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "CLIO Release Script"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Preparing release: $VERSION"
echo ""

# Check if we're in a git repository
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "ERROR: Not in a git repository"
    exit 1
fi

# Check if there are uncommitted changes
if ! git diff-index --quiet HEAD --; then
    echo "ERROR: You have uncommitted changes"
    echo "Please commit or stash them before creating a release"
    git status --short
    exit 1
fi

# Check if tag already exists
if git rev-parse "$VERSION" >/dev/null 2>&1; then
    echo "ERROR: Tag $VERSION already exists"
    echo "To delete it: git tag -d $VERSION && git push origin :refs/tags/$VERSION"
    exit 1
fi

# Update VERSION file
echo "Step 1: Updating VERSION file..."
echo "$VERSION" > VERSION

# Update lib/CLIO.pm
echo "Step 2: Updating lib/CLIO.pm..."
perl -i -pe "s/^our \\\$VERSION = '[^']+';/our \\\$VERSION = '$VERSION';/" lib/CLIO.pm
perl -i -pe "s/^Version [0-9.]+/Version $VERSION/" lib/CLIO.pm

# Verify updates
echo ""
echo "Verification:"
echo "  VERSION file: $(cat VERSION)"
echo "  lib/CLIO.pm:  $(grep 'our \$VERSION' lib/CLIO.pm | head -1)"
echo ""

# Commit changes
echo "Step 3: Committing version updates..."
git add VERSION lib/CLIO.pm
git commit -m "chore(release): prepare version $VERSION"

# Create tag
echo "Step 4: Creating tag $VERSION..."
git tag -a "$VERSION" -m "Release $VERSION"

# Show summary
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Release prepared successfully!"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Next steps:"
echo "  1. Review the changes:"
echo "     git show $VERSION"
echo ""
echo "  2. Push to GitHub:"
echo "     git push && git push --tags"
echo ""
echo "This will trigger the GitHub Actions workflow to:"
echo "  - Run syntax checks"
echo "  - Create distribution packages (tar.gz, zip)"
echo "  - Create GitHub release with changelog"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
