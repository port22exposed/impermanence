#!/usr/bin/env bash

set -o nounset            # Fail on use of unset variable.
set -o errexit            # Exit on command failure.
set -o pipefail           # Exit on failure of any command in a pipeline.
set -o errtrace           # Trap errors in functions and subshells.
set -o noglob             # Disable filename expansion (globbing),
                          # since it could otherwise happen during
                          # path splitting.
shopt -s inherit_errexit  # Inherit the errexit option status in subshells.

# Print a useful trace when an error occurs
trap 'echo Error when executing ${BASH_COMMAND} at line ${LINENO}! >&2' ERR

# Symlink a persisted directory into the ephemeral filesystem.
#
# Given a target directory in persistent storage,
# /persistent/target/foo/bar, and a mount point in the ephemeral
# filesystem, /target/foo/bar, we make /target/foo/bar a symlink pointing
# at /persistent/target/foo/bar. Unlike a bind mount this crosses no mount
# boundary, so renames between the persisted directory and its neighbours
# stay simple rename() calls instead of copy-and-delete.
#
# We:
#   1. Ensure the target directory exists in persistent storage, creating
#      it with the requested ownership and mode if it doesn't.
#   2. Ensure the mount point's parent directory exists in the ephemeral
#      filesystem (its parents are created elsewhere).
#   3. Replace an empty placeholder directory at the mount point, if any,
#      and create the symlink.

# Get inputs from command line arguments
if [[ $# != 6 ]]; then
    printf "Error: 'link-directory.bash' requires *six* args.\n" >&2
    exit 1
fi
target="$1"
mountPoint="$2"
user="$3"
group="$4"
mode="$5"
debug="$6"

trace() {
    if (( debug )); then
      echo "$@"
    fi
}
if (( debug )); then
    set -o xtrace
fi

# Ensure the directory exists in persistent storage with the requested
# permissions. If it's already there we leave it untouched.
if [[ ! -d $target ]]; then
    printf "Warning: Target directory '%s' does not exist; it will be created for you with the following permissions: owner: '%s:%s', mode: '%s'.\n" "$target" "$user" "$group" "$mode"
    # The parent chain is created ahead of us by
    # `createPersistentStorageDirs`; create it defensively anyway, then
    # apply the requested mode to the directory itself.
    mkdir -p "$(dirname "$target")"
    mkdir --mode="$mode" "$target"
    chown "$user:$group" "$target"
fi

# Make sure the mount point's parent exists so the symlink has somewhere
# to live.
mkdir -p "$(dirname "$mountPoint")"
targetPhysical=$(readlink -f -- "$target")
mountPointPhysical=$(readlink -f -- "$mountPoint" || true)

if [[ $mountPointPhysical == "$targetPhysical" ]]; then
    trace "$mountPoint already resolves to $target, ignoring"
elif findmnt "$mountPoint" >/dev/null; then
    # A leftover bind mount from an older generation. Leave it alone; the
    # next reboot starts from a clean ephemeral filesystem.
    trace "mount already exists at $mountPoint, ignoring"
elif [[ -d $mountPoint && ! -L $mountPoint ]]; then
    # Something created a real directory here before us. If it's empty we
    # can safely swap it for the symlink; otherwise bail rather than risk
    # losing data.
    if [[ -z "$(ls -A "$mountPoint")" ]]; then
        rmdir "$mountPoint"
        ln -s "$target" "$mountPoint"
    else
        echo "A non-empty directory already exists at $mountPoint!" >&2
        exit 1
    fi
elif [[ -e $mountPoint && ! -L $mountPoint ]]; then
    echo "A file already exists at $mountPoint!" >&2
    exit 1
else
    # Nothing there, or a stale symlink pointing elsewhere.
    ln -sf "$target" "$mountPoint"
fi

if [[ -L $mountPoint ]] && id -u "$user" &>/dev/null; then
    chown -h "$user:$group" "$mountPoint"
fi
