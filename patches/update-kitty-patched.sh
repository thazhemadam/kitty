#!/bin/bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: ./update-kitty-patched.sh [OPTIONS] [VERSION]

VERSION:
  latest    Use the latest stable release (default)
  nightly   Use the latest pre-release/nightly build
  <tag>     Use a specific tag (e.g., v0.38.1)

OPTIONS:
  -h, --help    Show this help message and exit
  -f, --force   Rebuild even if installed version matches target

ENVIRONMENT VARIABLES:
  CODESIGN_CERT   Name of the codesigning certificate (default: kitty-patched-build)

EXAMPLES:
  ./update-kitty-patched.sh              # Build latest stable
  ./update-kitty-patched.sh nightly      # Build latest pre-release
  ./update-kitty-patched.sh v0.38.1      # Build specific version
EOF
    exit 0
}

# Parse flags
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
    -h | --help) usage ;;
    -f | --force)
        FORCE=true
        shift
        ;;
    -*)
        log_error "Unknown option: $1"
        usage
        ;;
    *) break ;;
    esac
done

VERSION_TYPE="${1:-latest}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Check required commands
for cmd in curl jq git codesign; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Required command '$cmd' not found. Please install it first."
        exit 1
    fi
done

log_info "Fetching from upstream..."
# Use --force to handle moving tags like 'nightly'
git fetch --force --tags upstream || {
    log_error "Failed to fetch from upstream"
    exit 1
}

# Fetch tag based on VERSION_TYPE
case "$VERSION_TYPE" in
latest)
    log_info "Fetching latest stable release..."
    API_RESPONSE="$(curl -sf "https://api.github.com/repos/kovidgoyal/kitty/releases/latest")" || {
        log_error "Failed to fetch latest release from GitHub API"
        exit 1
    }
    KITTY_TAG="$(echo "$API_RESPONSE" | jq -r .tag_name)"
    ;;
nightly)
    # The 'nightly' tag is a moving tag that gets updated regularly
    log_info "Using nightly tag..."
    KITTY_TAG="nightly"
    ;;
*)
    # Assume it's a specific tag
    log_info "Using specified tag: $VERSION_TYPE"
    KITTY_TAG="$VERSION_TYPE"
    # Verify the tag exists (use refs/tags/ prefix for reliable lookup)
    if ! git rev-parse --verify "refs/tags/$KITTY_TAG" >/dev/null 2>&1; then
        log_error "Tag '$KITTY_TAG' not found. Make sure it exists in the upstream remote."
        exit 1
    fi
    ;;
esac

if [[ -z "$KITTY_TAG" || "$KITTY_TAG" == "null" ]]; then
    log_error "Failed to determine kitty version tag"
    exit 1
fi
log_info "Target kitty version: $KITTY_TAG"

# Check if kitty is installed and compare versions
# Strip 'v' prefix from tag for comparison (v0.38.1 -> 0.38.1)
TARGET_VERSION="${KITTY_TAG#v}"

if command -v kitty &>/dev/null; then
    # kitty -v outputs: "kitty 0.38.1 created by Kovid Goyal"
    INSTALLED_VERSION="$(kitty -v 2>/dev/null | awk '{print $2}')" || true
    if [[ -n "$INSTALLED_VERSION" ]]; then
        log_info "Installed kitty version: $INSTALLED_VERSION"
        if [[ "$INSTALLED_VERSION" == "$TARGET_VERSION" ]]; then
            if [[ "$FORCE" == true ]]; then
                log_warn "Installed version matches target version, but --force specified. Rebuilding..."
            else
                log_info "Installed version matches target version. Nothing to do."
                log_info "Use --force to rebuild anyway."
                exit 0
            fi
        fi
    fi
else
    log_warn "kitty is not installed. Proceeding with build..."
fi

PATCHED_TAG="$KITTY_TAG-patch"
PATCHED_TAG_MESSAGE="Kitty $KITTY_TAG, patched to swap Ctrl and Meta for macOS"
PATCH_DIRECTORY="patches"

# Track the original branch for cleanup
ORIGINAL_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
CREATED_BRANCH=false

cleanup_on_failure() {
    if [[ "$CREATED_BRANCH" == true ]]; then
        log_warn "Cleaning up failed patch attempt..."
        git am --abort 2>/dev/null || true
        git checkout "$ORIGINAL_BRANCH" 2>/dev/null || true
        git branch -D "$PATCHED_TAG" 2>/dev/null || true
    fi
}
trap cleanup_on_failure ERR

if git rev-parse --verify "$PATCHED_TAG" >/dev/null 2>&1; then
    # If the latest tag has already been patched, then we don't need to
    # do anything.
    log_info "Patched tag $PATCHED_TAG found. Checking out $PATCHED_TAG."
    git -c advice.detachedHead=false checkout "$PATCHED_TAG"
else
    log_info "No patched tag found for $KITTY_TAG. Patching..."

    # Check for patches using git to read from the patches branch
    PATCH_LIST="$(git show patches:"$PATCH_DIRECTORY" 2>/dev/null | grep '\.patch$' | sort)" || true
    if [[ -z "$PATCH_LIST" ]]; then
        log_error "No patches found in $PATCH_DIRECTORY on patches branch. Exiting."
        exit 1
    fi

    git checkout -b "$PATCHED_TAG" "$KITTY_TAG"
    CREATED_BRANCH=true

    while IFS= read -r patch; do
        log_info "Applying patch: $patch"
        if ! git show "patches:$PATCH_DIRECTORY/$patch" | git am; then
            log_error "Failed to apply patch: $patch"
            exit 1
        fi
    done <<<"$PATCH_LIST"
    log_info "kitty $KITTY_TAG patched successfully."

    git tag -a "$PATCHED_TAG" -m "$PATCHED_TAG_MESSAGE"

    # Skip pushing for nightly builds (moving target, no need to persist)
    if [[ "$KITTY_TAG" != "nightly" ]]; then
        # Use explicit refs to avoid ambiguity between branch and tag with same name
        git push --force-with-lease --set-upstream origin "HEAD:refs/heads/$PATCHED_TAG" || {
            log_error "Failed to push branch. You may need to push manually."
        }
        git push --force-with-lease origin "refs/tags/$PATCHED_TAG" || {
            log_error "Failed to push tag. You may need to push manually."
        }
        log_info "kitty $PATCHED_TAG branch and tag created and pushed."
    else
        log_info "Nightly build - skipping push to origin."
    fi
fi

# Disable cleanup trap after successful patching
trap - ERR

# Build kitty
log_info "Building kitty with patches..."
./dev.sh deps || {
    log_error "Failed to install dependencies"
    exit 1
}
make clean || {
    log_error "Failed to clean build"
    exit 1
}
./dev.sh build || {
    log_error "Failed to build kitty"
    exit 1
}

# Codesigning certificate name (can be overridden via environment variable)
CODESIGN_CERT="${CODESIGN_CERT:-kitty-patched-build}"

# If you haven't already done so, create a self-signed certificate first.
# 1. Open `Keychain Access`
# 2. Choose `Certificate Assistant (from the Menu bar) > Create Certificate`
# 3. Enter a name, e.g., `kitty-patched-build`
# 4. Set "Certificate Type" to "Code Signing"
# Now, you have a newly created self-signed certificate, named `kitty-patched-build`.

# Verify kitty.app was built
if [[ ! -d "kitty/launcher/kitty.app" ]]; then
    log_error "kitty.app not found at kitty/launcher/kitty.app"
    exit 1
fi

# Sign kitty and add it to /Applications
log_info "Codesigning kitty with certificate '$CODESIGN_CERT'..."
codesign --force --sign "$CODESIGN_CERT" kitty/launcher/kitty.app || {
    log_error "Failed to codesign kitty.app with certificate '$CODESIGN_CERT'"
    log_error "Create a self-signed certificate in Keychain Access:"
    log_error "  1. Open Keychain Access"
    log_error "  2. Certificate Assistant > Create a Certificate"
    log_error "  3. Name: $CODESIGN_CERT, Type: Code Signing"
    log_error "Or set CODESIGN_CERT env var to use a different certificate."
    exit 1
}

log_info "Installing kitty.app to /Applications..."
cp -R kitty/launcher/kitty.app /Applications/ || {
    log_error "Failed to copy kitty.app to /Applications"
    exit 1
}

git switch - || log_warn "Could not switch back to original branch"
log_info "kitty $KITTY_TAG patched, built, and installed successfully!"
