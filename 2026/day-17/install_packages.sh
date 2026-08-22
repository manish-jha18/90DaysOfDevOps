#!/bin/bash
# Day 17 - Task 4 and 5: install packages if missing, root required

if [ "$EUID" -ne 0 ]; then
    echo "ERROR: this script must be run as root."
    echo "Try: sudo $0"
    exit 1
fi

PACKAGES="nginx curl wget"

for PKG in $PACKAGES; do
    if dpkg -s "$PKG" &> /dev/null; then
        echo "[SKIP]    $PKG is already installed"
    else
        echo "[INSTALL] $PKG is missing, installing now..."
        if apt-get install -y "$PKG" &> /dev/null; then
            echo "[OK]      $PKG installed successfully"
        else
            echo "[FAIL]    could not install $PKG"
        fi
    fi
done

echo "Done."
