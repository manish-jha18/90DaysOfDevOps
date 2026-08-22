#!/bin/bash
# Day 17 - Task 2: count down to zero

read -p "Enter a number to count down from: " NUM

while [ "$NUM" -gt 0 ]; do
    echo "$NUM"
    NUM=$((NUM - 1))
done

echo "Done!"
