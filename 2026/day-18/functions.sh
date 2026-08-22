#!/bin/bash
# Day 18 - Task 1: basic functions

greet() {
    echo "Hello, $1!"
}

add() {
    local SUM=$(( $1 + $2 ))
    echo "$1 + $2 = $SUM"
}

greet "Manish"
greet "DevOps"
add 5 7
add 100 250
