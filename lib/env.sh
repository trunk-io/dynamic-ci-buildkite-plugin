#!/usr/bin/env bash
# A variable read by a name the customer configured.

# `${!name}` on a name that is not a variable name is a shell error, which
# abandons the whole enclosing command rather than failing it; this reads it as unset.
dci_env() {
    local name="$1"
    if [[ ${name} =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        printf '%s' "${!name-}"
    fi
}
