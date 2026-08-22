#!/bin/bash
# Day 16 - Task 2: variables and quoting

NAME="Manish"
ROLE="DevOps Engineer"

echo "Hello, I am $NAME and I am a $ROLE"

# double quotes expand the variable, single quotes do not
echo "Double quotes: $NAME"
echo 'Single quotes: $NAME'
