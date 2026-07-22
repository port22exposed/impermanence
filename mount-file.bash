#!/usr/bin/env bash

set -o nounset            # Fail on use of unset variable.
set -o errexit            # Exit on command failure.
set -o pipefail           # Exit on failure of any command in a pipeline.
set -o errtrace           # Trap errors in functions and subshells.
shopt -s inherit_errexit  # Inherit the errexit option status in subshells.

# Print a useful trace when an error occurs
trap 'echo Error when executing ${BASH_COMMAND} at line ${LINENO}! >&2' ERR

# Get inputs from command line arguments
if [[ $# != 4 ]]; then
    echo "Error: 'mount-file.bash' requires *four* args." >&2
    exit 1
fi

mountPoint="$1"
targetFile="$2"
method="$3"
debug="$4"

trace() {
    if (( debug )); then
      echo "$@"
    fi
}
if (( debug )); then
    set -o xtrace
fi

# /etc/machine-id can't be a symlink: systemd-machine-id-commit wants to
# mount over it, which fails on a symlink. It's also written exactly once,
# so a bind mount costs no extra writes. Force a bind mount regardless of
# the requested method. For more details, see
# https://github.com/nix-community/impermanence/pull/242
if [[ $mountPoint == "/etc/machine-id" ]]; then
    method="bindmount"
fi

if [[ -L $mountPoint && $(readlink -f "$mountPoint") == "$targetFile" ]]; then
    trace "$mountPoint already links to $targetFile, ignoring"
elif findmnt "$mountPoint" >/dev/null; then
    trace "mount already exists at $mountPoint, ignoring"
elif [[ -s $mountPoint ]]; then
    echo "A file already exists at $mountPoint!" >&2
    exit 1
elif [[ $method == "bindmount" || ($method == "auto" && -e $targetFile) ]]; then
    if [[ $mountPoint == "/etc/machine-id" && ! -e $targetFile ]]; then
        echo "Creating initial /etc/machine-id"
        echo "uninitialized" > "$targetFile"
    fi
    touch "$mountPoint"
    mount -o bind "$targetFile" "$mountPoint"
else
    # A stale symlink (e.g. pointing somewhere else) would make `ln -s`
    # fail, so replace it. We only get here when nothing meaningful lives
    # at the mount point (the `-s` check above rejects real files).
    ln -sf "$targetFile" "$mountPoint"
fi
