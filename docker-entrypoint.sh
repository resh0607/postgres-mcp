#!/bin/bash

# Don't exit immediately so we can debug issues
# set -e

# Function to replace localhost in a string with the Docker host
replace_localhost() {
    local input_str="$1"
    local docker_host=""

    # Try to determine Docker host address
    if ping -c 1 -w 1 host.docker.internal >/dev/null 2>&1; then
        docker_host="host.docker.internal"
        echo "Docker Desktop detected: Using host.docker.internal for localhost" >&2
    elif ping -c 1 -w 1 172.17.0.1 >/dev/null 2>&1; then
        docker_host="172.17.0.1"
        echo "Docker on Linux detected: Using 172.17.0.1 for localhost" >&2
    else
        echo "WARNING: Cannot determine Docker host IP. Using original address." >&2
        return 1
    fi

    # Replace localhost with Docker host
    if [[ -n "$docker_host" ]]; then
        local new_str="${input_str/localhost/$docker_host}"
        echo "  Remapping: $input_str --> $new_str" >&2
        echo "$new_str"
        return 0
    fi

    # No replacement made
    echo "$input_str"
    return 1
}

# Create a new array for the processed arguments
processed_args=()
processed_args+=("$1")
shift 1

# Process remaining command-line arguments for postgres:// or postgresql:// URLs that contain localhost
for arg in "$@"; do
    if [[ "$arg" == *"postgres"*"://"*"localhost"* ]]; then
        echo "Found localhost in database connection: $arg" >&2
        new_arg=$(replace_localhost "$arg")
        if [[ $? -eq 0 ]]; then
            processed_args+=("$new_arg")
        else
            processed_args+=("$arg")
        fi
    else
        processed_args+=("$arg")
    fi
done

# Check and replace localhost in DATABASE_URI if it exists
if [[ -n "$DATABASE_URI" && "$DATABASE_URI" == *"postgres"*"://"*"localhost"* ]]; then
    echo "Found localhost in DATABASE_URI: $DATABASE_URI" >&2
    new_uri=$(replace_localhost "$DATABASE_URI")
    if [[ $? -eq 0 ]]; then
        export DATABASE_URI="$new_uri"
    fi
fi

# Check if SSE transport is specified and --sse-host is not already set
has_sse=false
has_sse_host=false

for arg in "${processed_args[@]}"; do
    if [[ "$arg" == "--transport" ]]; then
        # Check next argument for "sse"
        for next_arg in "${processed_args[@]}"; do
            if [[ "$next_arg" == "sse" ]]; then
                has_sse=true
                break
            fi
        done
    elif [[ "$arg" == "--transport=sse" ]]; then
        has_sse=true
    elif [[ "$arg" == "--sse-host"* ]]; then
        has_sse_host=true
    fi
done

# Add --sse-host if needed
if [[ "$has_sse" == true ]] && [[ "$has_sse_host" == false ]]; then
    echo "SSE transport detected, adding --sse-host=0.0.0.0" >&2
    processed_args+=("--sse-host=0.0.0.0")
fi

echo "----------------" >&2
echo "Executing command:" >&2
echo "${processed_args[@]}" >&2
echo "----------------" >&2

# Docker keeps an interactive container's stdin open after its client
# disconnects unless the container was created with StdinOnce. Once Docker
# does deliver EOF, make sure the stdio server exits even if the MCP runtime is
# still waiting internally. Non-stdio transports keep the direct exec path.
is_stdio=false
if [[ "${processed_args[0]}" == "postgres-mcp" ]]; then
    is_stdio=true
    for ((i = 1; i < ${#processed_args[@]}; i++)); do
        case "${processed_args[i]}" in
            --transport=sse|--transport=streamable-http)
                is_stdio=false
                ;;
            --transport)
                if ((i + 1 < ${#processed_args[@]})) && [[ "${processed_args[i + 1]}" != "stdio" ]]; then
                    is_stdio=false
                fi
                ;;
        esac
    done
fi

if [[ "$is_stdio" == true ]]; then
    runtime_dir=$(mktemp -d /tmp/postgres-mcp-stdio.XXXXXX)
    input_fifo="$runtime_dir/stdin"
    mkfifo "$input_fifo"

    server_pid=""
    relay_pid=""

    cleanup_stdio() {
        trap - EXIT HUP INT TERM
        [[ -n "$relay_pid" ]] && kill "$relay_pid" >/dev/null 2>&1 || true
        [[ -n "$server_pid" ]] && kill "$server_pid" >/dev/null 2>&1 || true
        [[ -n "$relay_pid" ]] && wait "$relay_pid" >/dev/null 2>&1 || true
        [[ -n "$server_pid" ]] && wait "$server_pid" >/dev/null 2>&1 || true
        rm -f "$input_fifo"
        rmdir "$runtime_dir" >/dev/null 2>&1 || true
    }

    trap cleanup_stdio EXIT HUP INT TERM

    cat >"$input_fifo" &
    relay_pid=$!
    "${processed_args[@]}" <"$input_fifo" &
    server_pid=$!

    # Stop both sides when either the MCP process exits or Docker delivers EOF.
    wait -n "$relay_pid" "$server_pid" || true
    exit 0
fi

# SSE and streamable HTTP are long-running services and receive signals
# directly as PID 1.
exec "${processed_args[@]}"
