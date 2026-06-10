#!/bin/sh
set -e

if [ -n "${AGENT_SSH_PUBKEY:-}" ]; then
    echo "$AGENT_SSH_PUBKEY" > /home/sandboxuser/.ssh/authorized_keys
    chown sandboxuser:sandboxgroup /home/sandboxuser/.ssh/authorized_keys
    chmod 600 /home/sandboxuser/.ssh/authorized_keys
fi

exec /usr/sbin/sshd -D -e
