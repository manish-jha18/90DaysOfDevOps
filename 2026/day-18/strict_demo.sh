#!/bin/bash
# Day 18 - Task 3: what strict mode catches
set -euo pipefail

echo "Script started"

# 1. set -u : using a variable that was never defined
echo "About to use an undefined variable..."
echo "Value is: $UNDEFINED_VAR"

# these lines are never reached
echo "This line never prints"
