#!/bin/bash
# Day 16 - Task 4: does the file exist

read -p "Enter a filename: " FILENAME

if [ -f "$FILENAME" ]; then
    echo "$FILENAME exists and is a regular file"
elif [ -d "$FILENAME" ]; then
    echo "$FILENAME exists but it is a directory, not a file"
else
    echo "$FILENAME does not exist"
fi
