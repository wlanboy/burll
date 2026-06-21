# shellcheck shell=bash
# burl - curl-like HTTP client using bash /dev/tcp (no external tools for HTTP)
# Source this file, then use burl like curl:
#   source burll.sh
#   burl -v -k -i -X GET http://localhost:8080/actuator/health

burl() {
    local verbose=0 insecure=0 show_headers=0 method="GET"
    local body="" outfile="" url="" max_time=30
    local -a extra_headers=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            -v)                 verbose=1; shift ;;
            -k)                 insecure=1; shift ;;
            -i)                 show_headers=1; shift ;;
            -X)                 method="${2^^}"; shift 2 ;;
            -x|--proxy)         echo "burl: proxy (-x) not supported" >&2; return 1 ;;
            -H)                 extra_headers+=("$2"); shift 2 ;;
            -d|--data)          body="$2"; shift 2 ;;
            -o)                 outfile="$2"; shift 2 ;;
            -m|--max-time)      max_time="$2"; shift 2 ;;
            http://*|https://*)  url="$1"; shift ;;
            *)
                echo "burl: unknown argument: $1" >&2
                return 1
                ;;
        esac
    done

    if [[ -z "$url" ]]; then
        cat >&2 <<'EOF'
usage: burl [OPTIONS] URL

Options:
  -v            verbose (show request/response status on stderr)
  -k            insecure (skip TLS verification, HTTPS only)
  -i            include response headers in output
  -X METHOD     HTTP method (GET POST PUT PATCH DELETE HEAD OPTIONS)
  -H 'K: V'     add request header (repeatable)
  -d BODY       request body
  -m SECONDS    max time for the request (default: 30)
  -o FILE       write output to file instead of stdout

HTTP uses bash /dev/tcp directly. HTTPS requires openssl.
EOF
        return 1
    fi

    # Parse URL into scheme, host, port, path
    local scheme="${url%%://*}"
    local rest="${url#*://}"
    local hostport path

    if [[ "$rest" == */* ]]; then
        hostport="${rest%%/*}"
        path="/${rest#*/}"
    else
        hostport="$rest"
        path="/"
    fi

    local host port
    if [[ "$hostport" == *:* ]]; then
        host="${hostport%%:*}"
        port="${hostport##*:}"
    else
        host="$hostport"
        [[ "$scheme" == "https" ]] && port=443 || port=80
    fi

    # Host header includes port only when non-standard
    local host_hdr="$host"
    { [[ "$scheme" == "http"  && "$port" != "80"  ]] ||
      [[ "$scheme" == "https" && "$port" != "443" ]]; } && host_hdr="${host}:${port}"

    # Assemble request headers
    local -a hdrs=(
        "Host: ${host_hdr}"
        "User-Agent: burl/1.0"
        "Accept: */*"
        "Connection: close"
    )
    for h in "${extra_headers[@]}"; do hdrs+=("$h"); done

    if [[ -n "$body" ]]; then
        hdrs+=("Content-Length: ${#body}")
        local has_ct=0
        for h in "${extra_headers[@]}"; do
            [[ "${h,,}" == content-type:* ]] && { has_ct=1; break; }
        done
        [[ "$has_ct" -eq 0 ]] && hdrs+=("Content-Type: application/x-www-form-urlencoded")
    fi

    # Verbose: show outgoing request on stderr
    if [[ "$verbose" -eq 1 ]]; then
        printf '> %s %s HTTP/1.1\n' "$method" "$path" >&2
        for h in "${hdrs[@]}"; do printf '> %s\n' "$h" >&2; done
        printf '>\n' >&2
        [[ -n "$body" ]] && printf '> %s\n' "$body" >&2
    fi

    # Writes the raw HTTP/1.1 request with proper CRLF line endings
    _burl_send() {
        printf '%s\r\n' "$method $path HTTP/1.1"
        for h in "${hdrs[@]}"; do printf '%s\r\n' "$h"; done
        printf '\r\n'
        [[ -n "$body" ]] && printf '%s' "$body"
    }

    # Send request and capture raw response.
    # The entire TCP lifecycle runs inside a subshell so that Ctrl+C kills the
    # child process group cleanly instead of blocking the interactive shell.
    local raw
    case "$scheme" in
        http)
            raw=$(
                exec 3<>/dev/tcp/"${host}"/"${port}" 2>/dev/null || exit 1
                _burl_send >&3
                timeout "${max_time}" cat <&3
            ) || {
                echo "burl: cannot connect to ${host}:${port} (or timed out after ${max_time}s)" >&2
                unset -f _burl_send
                return 1
            }
            ;;
        https)
            command -v openssl &>/dev/null || {
                echo "burl: HTTPS requires openssl in PATH" >&2
                unset -f _burl_send
                return 1
            }
            local -a ssl_opts=(-connect "${host}:${port}" -quiet -ign_eof)
            [[ "$insecure" -eq 1 ]] && ssl_opts+=(-verify 0 -verify_quiet)
            raw=$(
                _burl_send | timeout "${max_time}" openssl s_client "${ssl_opts[@]}" 2>/dev/null
            ) || {
                echo "burl: HTTPS request to ${host}:${port} failed (or timed out after ${max_time}s)" >&2
                unset -f _burl_send
                return 1
            }
            ;;
        *)
            echo "burl: unsupported scheme '${scheme}' — use http:// or https://" >&2
            unset -f _burl_send
            return 1
            ;;
    esac
    unset -f _burl_send

    # Verbose: show response status line on stderr
    [[ "$verbose" -eq 1 ]] && \
        printf '< %s\n' "$(printf '%s' "$raw" | head -1 | tr -d '\r')" >&2

    # Produce output: all (headers+body) or body only
    local output
    if [[ "$show_headers" -eq 1 ]]; then
        output="$raw"
    else
        # HTTP headers end at the first blank line (\r\n\r\n); print everything after
        output=$(printf '%s' "$raw" | awk 'BEGIN{h=1} h&&/^\r?$/{h=0;next} !h')
    fi

    if [[ -n "$outfile" ]]; then
        printf '%s\n' "$output" > "$outfile"
    else
        printf '%s\n' "$output"
    fi
}
