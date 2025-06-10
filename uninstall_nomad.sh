#!/bin/bash

set -e

echo "Stopping Nomad service (if running)..."
systemctl stop nomad || true

echo "Disabling Nomad service..."
systemctl disable nomad || true

echo "Removing all Nomad binaries found in PATH..."
while IFS= read -r bin; do
    if [ -f "$bin" ]; then
        echo "Removing $bin"
        rm -f "$bin"
    fi
done < <(which -a nomad 2>/dev/null | sort -u)

echo "Removing Nomad configuration directory..."
rm -rf /etc/nomad.d

echo "Removing Nomad data directory..."
rm -rf /opt/nomad

echo "Removing Nomad systemd service file (if exists)..."
rm -f /etc/systemd/system/nomad.service

echo "Reloading systemd daemon..."
systemctl daemon-reload

echo "Removing Nomad user (if exists)..."
if id "nomad" &>/dev/null; then
    userdel nomad
    if id "nomad" &>/dev/null; then
        echo "Failed to remove nomad user."
    else
        echo "Nomad user removed."
    fi
else
    echo "Nomad user does not exist."
fi

echo "Removing Nomad group (if exists)..."
if getent group nomad > /dev/null 2>&1; then
    if id "nomad" &>/dev/null; then
        echo "Nomad group is still the primary group of an existing user. Skipping group deletion."
    else
        groupdel nomad
        echo "Nomad group removed."
    fi
else
    echo "Nomad group does not exist."
fi

echo "Nomad uninstallation complete."
