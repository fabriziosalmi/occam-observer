#!/usr/bin/env bash
API_PORT=9998

rm -f /tmp/test_fifo
mkfifo /tmp/test_fifo

echo "Listening on $API_PORT..."
while true; do
    # Read from FIFO, send to nc, read from nc
    nc -l "$API_PORT" < /tmp/test_fifo | (
        read -r request_line
        # Strip carriage return
        request_line="${request_line%$'\r'}"
        echo "Received: $request_line" >&2
        
        method=$(echo "$request_line" | awk '{print $1}')
        url=$(echo "$request_line" | awk '{print $2}')
        
        # Consume headers
        while read -r header; do
            header="${header%$'\r'}"
            [ -z "$header" ] && break
        done
        
        printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n" > /tmp/test_fifo
        
        if [[ "$url" == "/analyze?path="* ]]; then
            target="${url#/analyze?path=}"
            # Extremely basic URL decode for %2F -> /
            target="${target//%2F//}"
            echo "{\"status\": \"analyzing\", \"path\": \"$target\"}" > /tmp/test_fifo
        else
            echo "{\"status\": \"cached\"}" > /tmp/test_fifo
        fi
    )
done
