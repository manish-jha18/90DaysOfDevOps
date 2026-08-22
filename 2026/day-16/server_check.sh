#!/bin/bash
# Day 16 - Task 5: check a service status

SERVICE="ssh"

read -p "Do you want to check the status of $SERVICE? (y/n) " ANSWER

if [ "$ANSWER" = "y" ]; then
    if systemctl is-active --quiet "$SERVICE"; then
        echo "$SERVICE is ACTIVE"
    else
        echo "$SERVICE is NOT active"
    fi
    systemctl status "$SERVICE" --no-pager
elif [ "$ANSWER" = "n" ]; then
    echo "Skipped."
else
    echo "Please answer y or n"
fi
