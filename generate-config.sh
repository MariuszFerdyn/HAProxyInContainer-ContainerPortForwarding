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
echo "--- ENVIRONMENT VARIABLES ver 1.03 ---"
env | sort
echo "--------------------------------------"

# Main monitoring loop
exec bash -c 'declare -A prev_conn_count=(); declare -A connection_bytes=(); 

# Initialize backend hosts tracking
for var in $(env | grep -E "^BACKEND_HOST[0-9]+" | cut -d= -f1); do
  val=$(eval echo \$$var)
  if [[ -n "$val" ]]; then
    prev_conn_count["$var"]=0
    connection_bytes["$var"]=0
  fi
done

# Function to extract IP from IP:port format
extract_ip() {
  echo "$1" | cut -d: -f1
}

# Function to extract port from IP:port format
extract_port() {
  echo "$1" | cut -d: -f2
}

# Function to get connection count to a specific IP:port
get_connection_count() {
  local ip="$1"
  local port="$2"
  
  # Convert IP:port to hex format used in /proc/net/tcp
  local hex_port=$(printf "%04X" "$port")
  local hex_ip=$(printf "%02X%02X%02X%02X" $(echo "$ip" | tr "." " "))
  
  # Count active connections to this destination
  local count=$(cat /proc/net/tcp /proc/net/tcp6 2>/dev/null | grep -i "$hex_ip:$hex_port" | wc -l)
  echo "$count"
}

# Function to estimate bytes based on connection count
estimate_bytes() {
  local current_count="$1"
  local previous_count="$2"
  local previous_bytes="$3"
  
  if [[ "$current_count" -gt "$previous_count" ]]; then
    # New connections - estimate 1000 bytes per new connection
    local new_connections=$((current_count - previous_count))
    echo $((previous_bytes + (new_connections * 1000)))
  elif [[ "$current_count" -eq "$previous_count" && "$current_count" -gt 0 ]]; then
    # Same connections - assume some activity
    echo $((previous_bytes + (current_count * 500)))
  else
    # Fewer connections - keep existing bytes
    echo "$previous_bytes"
  fi
}

while true; do 
  # Set default threshold if environment variable not set
  THRESHOLD=${WEBHOOKTRAFFICAMOUNT:-2000}
  echo "$(date) - HAProxy Backend Connection Stats:"
  echo "Current threshold for alerts: $THRESHOLD bytes"
  
  # Show HAProxy frontend stats (for display only)
  echo -e "\n--- HAProxy Frontend Stats ---"
  mapfile -t current_stats < <(echo "show stat" | socat unix-connect:/var/run/haproxy.sock stdio | grep "FRONTEND"); 
  
  for line in "${current_stats[@]}"; do
    frontend=$(echo "$line" | cut -d, -f1);
    bytes_in=$(echo "$line" | cut -d, -f8);
    bytes_out=$(echo "$line" | cut -d, -f9);
    connections=$(echo "$line" | cut -d, -f7);
    printf "%-15s | Connections: %-6s | Bytes In: %-10s | Bytes Out: %-10s\n" "$frontend" "$connections" "$bytes_in" "$bytes_out";
  done
  
  # Monitor direct backend connections
  echo -e "\n--- Backend Connection Stats ---"
  for var in $(env | grep -E "^BACKEND_HOST[0-9]+" | cut -d= -f1); do
    val=$(eval echo \$$var)
    if [[ -n "$val" ]]; then
      ip=$(extract_ip "$val")
      port=$(extract_port "$val")
      
      if [[ -n "$ip" && -n "$port" ]]; then
        # Get current connection count
        curr_count=$(get_connection_count "$ip" "$port")
        prev_count=${prev_conn_count[$var]:-0}
        
        # Estimate bytes based on connection count
        prev_bytes=${connection_bytes[$var]:-0}
        curr_bytes=$(estimate_bytes "$curr_count" "$prev_count" "$prev_bytes")
        
        # Calculate byte difference
        diff=$((curr_bytes - prev_bytes))
        
        printf "%-15s | IP:Port: %-20s | Connections: %-5s | Est. Bytes: %-10s | Diff: +%-8s\n" \
          "$var" "$val" "$curr_count" "$curr_bytes" "$diff"
        
        # Check if above threshold and alert if needed
        if [[ $diff -gt $THRESHOLD ]]; then
          echo "ALERT: Connection traffic increase exceeds threshold ($THRESHOLD) for $var ($val): $prev_bytes to $curr_bytes (diff: $diff)"
          
          if [[ -n "$WEBHOOKTRAFFIC" ]]; then
            echo "DEBUG: Using webhook URL: $WEBHOOKTRAFFIC"
            webhook_response=$(curl -s -X POST "$WEBHOOKTRAFFIC" \
              -d "host=$var&ip_port=$val&bytes_current=$curr_bytes&bytes_previous=$prev_bytes&bytes_diff=$diff&threshold=$THRESHOLD&conn_count=$curr_count" 2>&1)
            echo "WEBHOOK RESPONSE: $webhook_response"
          else
            echo "ALERT: Traffic increase detected but WEBHOOKTRAFFIC not defined."
          fi
        fi
        
        # Update stored values
        prev_conn_count[$var]=$curr_count
        connection_bytes[$var]=$curr_bytes
      fi
    fi
  done
  
  echo "----------------------------------------"; 
  sleep 60; 
done'
