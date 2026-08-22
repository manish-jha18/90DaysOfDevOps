#!/bin/bash
# Day 17 - Task 5: basic error handling

set -e

TARGET="/tmp/devops-test"

mkdir "$TARGET" || echo "Directory already exists, carrying on"

cd "$TARGET" || { echo "Could not enter $TARGET"; exit 1; }

echo "created by safe_script.sh" > notes.txt || { echo "Could not write the file"; exit 1; }

echo "All steps finished. Working directory is now $(pwd)"
ls -l "$TARGET"
