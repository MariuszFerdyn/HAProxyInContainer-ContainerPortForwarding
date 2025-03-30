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
exec bash -c 'declare -A prev_bytes_in=(); declare -A prev_bytes_out=(); while true; do 
  echo "$(date) - HAProxy Frontend Stats:"; 
  current_stats=$(echo "show stat" | socat unix-connect:/var/run/haproxy.sock stdio | grep "FRONTEND"); 
  
  # Display current stats
  echo "$current_stats" | awk -F, '\''{print $1","$8","$9","$7}'\'' | 
  awk -F, '\''{printf "%-15s | Connections: %-6s | Bytes In: %-10s | Bytes Out: %-10s\n", $1, $4, $2, $3}'\''; 
  
  # Process each frontend
  echo "$current_stats" | while IFS="," read -r line; do 
    frontend=$(echo "$line" | cut -d, -f1); 
    bytes_in=$(echo "$line" | cut -d, -f8); 
    bytes_out=$(echo "$line" | cut -d, -f9);
    
    # Debug info
    echo "DEBUG: Frontend=$frontend, Current bytes_in=$bytes_in, Previous bytes_in=${prev_bytes_in[$frontend]:-0}"
    echo "DEBUG: Frontend=$frontend, Current bytes_out=$bytes_out, Previous bytes_out=${prev_bytes_out[$frontend]:-0}"
    
    # Check for traffic increase
    if [[ -n "${prev_bytes_in[$frontend]}" && "$bytes_in" -gt "${prev_bytes_in[$frontend]}" ]] || 
       [[ -n "${prev_bytes_out[$frontend]}" && "$bytes_out" -gt "${prev_bytes_out[$frontend]}" ]]; then
      
      echo "ALERT: Traffic increase detected for $frontend: Bytes In ${prev_bytes_in[$frontend]:-0} → $bytes_in, Bytes Out ${prev_bytes_out[$frontend]:-0} → $bytes_out"
      
      if [[ -n "$WEBHOOKTRAFFIC" ]]; then
        echo "DEBUG: Using webhook URL: $WEBHOOKTRAFFIC"
        webhook_response=$(curl -v -s -X POST "$WEBHOOKTRAFFIC" \
          -d "frontend=$frontend&bytes_in=$bytes_in&previous_in=${prev_bytes_in[$frontend]:-0}&bytes_out=$bytes_out&previous_out=${prev_bytes_out[$frontend]:-0}" 2>&1)
        echo "WEBHOOK RESPONSE: $webhook_response"
      else
        echo "ALERT: Traffic increase detected but WEBHOOKTRAFFIC not defined."
      fi
    fi
    
    # Update previous values
    prev_bytes_in[$frontend]=$bytes_in
    prev_bytes_out[$frontend]=$bytes_out
  done; 
  
  echo "----------------------------------------"; 
  sleep 60; 
done'
