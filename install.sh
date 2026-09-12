#!/usr/bin/env bash
set -euo pipefail

SKILLS_DIR="${HOME}/.claude/skills"
REPO_SKILLS_DIR="$(cd "$(dirname "$0")" && pwd)/skills"

mkdir -p "$SKILLS_DIR"

for skill_dir in "$REPO_SKILLS_DIR"/*/; do
  skill_name="$(basename "$skill_dir")"
  target="$SKILLS_DIR/$skill_name"

  if [ -L "$target" ]; then
    echo "updating symlink: $skill_name"
    rm "$target"
  elif [ -d "$target" ]; then
    echo "skipping $skill_name (non-symlink directory exists — remove it manually to link)"
    continue
  else
    echo "linking: $skill_name"
  fi

  ln -s "$skill_dir" "$target"
done

echo "done — linked $(ls -1d "$REPO_SKILLS_DIR"/*/ 2>/dev/null | wc -l | tr -d ' ') skill(s) into $SKILLS_DIR"
