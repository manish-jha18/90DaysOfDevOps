#!/bin/bash
# Day 18 - Task 4: local variables vs global ones

MESSAGE="I am the original global value"

leaky_function() {
    MESSAGE="the global was overwritten in here"
    echo "  inside leaky_function : $MESSAGE"
}

safe_function() {
    local MESSAGE="I only exist inside this function"
    echo "  inside safe_function  : $MESSAGE"
}

echo "Before any function     : $MESSAGE"

safe_function
echo "After safe_function     : $MESSAGE"

leaky_function
echo "After leaky_function    : $MESSAGE"
