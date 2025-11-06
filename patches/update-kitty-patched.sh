#!/bin/bash

echo "Fetching from remotes..."
git fetch upstream # fetch from the `upstream` remote, to get the latest release
git fetch origin   # fetch from the `origin` remote (fork), since fetching from `upstream` will delete the tags in the fork

KITTY_LATEST_TAG="$(curl -s "https://api.github.com/repos/kovidgoyal/kitty/releases/latest" | jq -r .tag_name)"
echo "Latest kitty version: $KITTY_LATEST_TAG"
PATCHED_TAG="$KITTY_LATEST_TAG-patch"
PATCHED_TAG_MESSAGE="Kitty $KITTY_LATEST_TAG, patched to swap Ctrl and Meta for macOS"
PATCH_DIRECTORY="patches"

if git rev-parse --verify "$PATCHED_TAG" >/dev/null 2>&1; then
    # If the latest tag has already been patched, then we don't need to
    # do anything.
    echo "Patched tag $PATCHED_TAG found. Checking out $PATCHED_TAG."
    git -c advice.detachedHead=false checkout "$PATCHED_TAG"
else
    echo "No patched tag found for $KITTY_LATEST_TAG. Patching..."
    if [ -z "$(ls -A "$PATCH_DIRECTORY"/*.patch 2>/dev/null)" ]; then
        echo "No patches found in $PATCH_DIRECTORY. Exiting."
        exit 1
    fi
    git checkout -b "$PATCHED_TAG" "$KITTY_LATEST_TAG"

    for patch in $(git show patches:"$PATCH_DIRECTORY" | grep '\.patch$' | sort); do
        echo "Applying patch: $patch"
        git show "patches:$PATCH_DIRECTORY/$patch" | git am
    done
    echo "kitty $KITTY_LATEST_TAG patched successfully."

    git tag -a "$PATCHED_TAG" -m "$PATCHED_TAG_MESSAGE"
    git push
    echo "kitty $PATCHED_TAG tags created and pushed."
fi

# Build kitty
echo "Building kitty with patches"
./dev.sh deps
make clean && ./dev.sh build

# If you haven't already done so, create a self-signed certificate first.
# 1. Open `Keychain Access`
# 2. Choose `Certificate Assistant (from the Menu bar) > Create Certificate`
# 3. Enter a name, e.g., `kitty-patched-build`
# 4. Set "Certificate Type" to "Code Signing"
# Now, you have a newly created self-signed certificate, named `kitty-patched-build`.

# Sign kitty and add it to `/Applications`
echo "Codesigning kitty..."
codesign --force --sign kitty-patched-build kitty/launcher/kitty.app
cp -R kitty/launcher/kitty.app /Applications/
git switch -
echo "kitty $KITTY_LATEST_TAG patched successfully."
