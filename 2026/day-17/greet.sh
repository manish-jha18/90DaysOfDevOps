#!/bin/bash
# Day 17 - Task 3: greet using a command line argument

if [ $# -eq 0 ]; then
    echo "Usage: ./greet.sh <name>"
    exit 1
fi

echo "Hello, $1!"
