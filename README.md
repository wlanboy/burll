# burll

A curl-like HTTP client implemented in pure bash using `/dev/tcp` — no curl, no wget, no external tools required for plain HTTP.

## Usage

```bash
source burll.sh
burl [OPTIONS] URL
```

## Options

| Flag | curl equivalent | Description |
|------|----------------|-------------|
| `-v` | `--verbose` | Show request and response status on stderr |
| `-k` | `--insecure` | Skip TLS certificate verification (HTTPS only) |
| `-i` | `--include` | Include response headers in output |
| `-X METHOD` | `--request` | HTTP method (GET, POST, PUT, PATCH, DELETE, HEAD) |
| `-H 'K: V'` | `--header` | Add a request header (repeatable) |
| `-d BODY` | `--data` | Request body |
| `-o FILE` | `--output` | Write response body to file instead of stdout |

## Examples

```bash
# Source once per shell session (or add to .bashrc)
source /path/to/burll.sh

# Simple GET
burl http://localhost:8080/actuator/health

# Verbose GET with headers in output
burl -v -i -X GET http://localhost:8080/actuator/health

# POST with JSON body
burl -X POST \
     -H 'Content-Type: application/json' \
     -d '{"status":"UP"}' \
     http://localhost:8080/api/resource

# Multiple custom headers
burl -H 'Authorization: Bearer mytoken' \
     -H 'Accept: application/json' \
     http://localhost:8080/api/protected

# Save response to file
burl -o health.json http://localhost:8080/actuator/health

# HTTPS (requires openssl in PATH)
burl -k https://api.example.com/health
```

## How it works

Plain HTTP connections are opened directly via bash's built-in `/dev/tcp/host/port` pseudo-device — no subprocess, no external binary:

```bash
exec 3<>/dev/tcp/localhost/8080
printf 'GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n' >&3
cat <&3
exec 3>&-
```

For HTTPS, `openssl s_client` is used as the TLS layer.

## Requirements

- bash 4.0+ (built with `--enable-net-redirections`, which is the default on all major Linux distributions)
- `openssl` — only required for HTTPS requests
