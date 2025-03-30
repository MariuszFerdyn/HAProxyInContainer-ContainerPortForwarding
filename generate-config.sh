#!/bin/bash

# Function to generate HAProxy config
generate_config() {
    # Start with global and defaults sections
    cat > /usr/local/etc/haproxy/haproxy.cfg << EOF
global
    daemon
    maxconn 256
    stats socket /var/run/haproxy.sock mode 600 level admin

defaults
    mode tcp
    timeout connect 5000ms
    timeout client 50000ms
    timeout server 50000ms

EOF

    # Generate frontend and backend configurations based on environment variables
    env | sort | while IFS='=' read -r name value; do
        if [[ $name =~ ^BACKEND_HOST([0-9]+)$ ]]; then
            port_num="${BASH_REMATCH[1]}"
            local_port_var="LOCAL_PORT${port_num}"
            local_port="${!local_port_var}"
            
            if [ ! -z "$local_port" ]; then
                cat >> /usr/local/etc/haproxy/haproxy.cfg << EOF
frontend front${port_num}
    bind *:${local_port}
    default_backend back${port_num}

backend back${port_num}
    server server${port_num} ${value}

EOF
            fi
        fi
    done
}

# Generate the config
generate_config

# Execute HAProxy with the remaining arguments
"$@" &


# Display config
echo -e "---***--- HAPROXY - Config ---***---"
cat /usr/local/etc/haproxy/haproxy.cfg
echo -e "---***--- *************** ---****---"

# Send webhook notification if URL is provided
if [ -n "${WEBHOOKAFTERSTART+x}" ]; then
    echo -e "\nSending webhook notification to $WEBHOOKAFTERSTART..."
    webhook_response=$(curl -s -X POST "$WEBHOOKAFTERSTART" -H "Content-Type: application/json" -d "{\"status\":\"container_started\", \"timestamp\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"}")
    echo "Webhook response: $webhook_response"
fi

# Keep container running and showing statistics
exec bash -c 'declare -A prev_bytes=(); while true; do echo "$(date) - HAProxy Frontend Stats:"; current_stats=$(echo "show stat" | socat unix-connect:/var/run/haproxy.sock stdio | grep "FRONTEND"); echo "$current_stats" | awk -F, '\''{print $1","$8","$9","$7}'\'' | awk -F, '\''{printf "%-15s | Connections: %-6s | Bytes In: %-10s | Bytes Out: %-10s\n", $1, $4, $2, $3}'\''; echo "$current_stats" | while IFS="," read -r line; do frontend=$(echo "$line" | cut -d, -f1); bytes_in=$(echo "$line" | cut -d, -f8); if [[ -n "${prev_bytes[$frontend]}" && "$bytes_in" -gt "${prev_bytes[$frontend]}" ]]; then if [[ -n "$WEBHOOKTRAFFIC" ]]; then echo "Traffic increase detected for $frontend: ${prev_bytes[$frontend]} → $bytes_in bytes"; webhook_response=$(curl -v -s -X POST "$WEBHOOKTRAFFIC" -d "frontend=$frontend&bytes_in=$bytes_in&previous=${prev_bytes[$frontend]}" 2>&1); echo "Webhook response: $webhook_response"; else echo "Traffic increase detected for $frontend: ${prev_bytes[$frontend]} → $bytes_in bytes (WEBHOOKTRAFFIC not defined)"; fi; fi; prev_bytes[$frontend]=$bytes_in; done; echo "----------------------------------------"; sleep 60; done'
