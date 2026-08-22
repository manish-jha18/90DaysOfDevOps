#!/bin/bash
# Day 17 - Task 3: show what the special argument variables hold

echo "Script name         (\$0): $0"
echo "Number of arguments (\$#): $#"
echo "All arguments       (\$@): $@"
echo "First argument      (\$1): $1"
echo "Second argument     (\$2): $2"

echo "---"
echo "Looping over each argument:"
for ARG in "$@"; do
    echo "  -> $ARG"
done
