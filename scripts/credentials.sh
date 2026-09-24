# Shared by the generated Bash and Zsh fetch functions.
_fetch_credentials() {
    local credential_profile="$1"
    shift
    if [ "$#" -gt 0 ]; then
        command with-credentials "$credential_profile" -- "$@"
        return $?
    fi

    local credential_exports credential_accounts credential_account credential_status=0 credential_trace=
    case $- in *x*) credential_trace=1; set +x ;; esac
    if [ "${OP_BIOMETRIC_UNLOCK_ENABLED-}" = false ]; then
        credential_accounts=$(command with-credentials --accounts "$credential_profile") || credential_status=$?
        if [ "$credential_status" -eq 0 ]; then
            while IFS= read -r credential_account; do
                [ -n "$credential_account" ] || continue
                op-ensure-session "$credential_account" || { credential_status=$?; break; }
            done <<< "$credential_accounts"
        fi
    fi
    if [ "$credential_status" -eq 0 ]; then
        if credential_exports=$(command with-credentials --shell "$credential_profile"); then
            eval "$credential_exports" || credential_status=$?
        else
            credential_status=$?
        fi
    fi
    unset credential_exports
    if [ -n "$credential_trace" ]; then set -x; fi
    return "$credential_status"
}

op-ensure-session() {
    if [ "$#" -ne 1 ] || [ -z "$1" ]; then
        printf '%s\n' 'op-ensure-session: expected an account' >&2
        return 1
    fi
    local credential_session credential_status=0 credential_trace=
    case $- in *x*) credential_trace=1; set +x ;; esac
    if [ "${OP_BIOMETRIC_UNLOCK_ENABLED-}" = false ] && ! op whoami --account "$1" >/dev/null 2>&1; then
        if credential_session=$(op signin --account "$1"); then
            eval "$credential_session" || credential_status=$?
        else
            credential_status=$?
        fi
    fi
    unset credential_session
    if [ -n "$credential_trace" ]; then set -x; fi
    return "$credential_status"
}

vault-login() {
    _fetch_credentials vault || return $?
    command vault login -method=oidc "$@"
}
