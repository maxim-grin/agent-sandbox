#!/usr/bin/env bash

clone_repo() {
  local repo_url="$1"
  local commit="$2"
  local dest="$3"

  echo "[clone] Cloning $repo_url @ $commit into $dest"

  # Shallow clone of the specific branch/tag; fall back to full clone + checkout for a SHA
  if git clone --depth=1 --branch "$commit" "$repo_url" "$dest" 2>/dev/null; then
    :
  else
    echo "[clone] Branch clone failed, trying full clone for SHA: $commit"
    git clone "$repo_url" "$dest"
    git -C "$dest" checkout "$commit"
  fi

  # Fix ownership so sandboxuser (UID 1001) can write to the workspace
  # (the supervisor runs as root; the worker runs as non-root sandboxuser).
  chown -R 1001:1001 "$dest"
  echo "[clone] Workspace ownership set to sandboxuser (1001:1001)"
}
