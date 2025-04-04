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
    timeout client 3600000ms    # increase to 1 hour
    timeout server 3600000ms    # increase to 1 hour

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
# Keep container running and showing statistics
echo "--- ENVIRONMENT VARIABLES ver 1.05 ---"
env | sort
echo "--------------------------------------"

# Main monitoring loop
exec bash -c '# Initialize traffic monitoring variables
declare -A prev_in_octets=()
declare -A prev_out_octets=()
prev_total_in=0
prev_total_out=0

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
  
  # Use netstat to count connections to this destination (works in unprivileged containers)
  local count=$(netstat -an | grep -c "$ip:$port")
  echo "$count"
}

# Function to get network statistics from netstat
get_net_stats() {
  # Extract InOctets and OutOctets from netstat -s
  local in_octets=$(netstat -s | grep "InOctets:" | awk "{print \$2}")
  local out_octets=$(netstat -s | grep "OutOctets:" | awk "{print \$2}")
  local tcp_rcv_coalesce=$(netstat -s | grep "TCPRcvCoalesce:" | awk "{print \$2}")
  local tcp_orig_data_sent=$(netstat -s | grep "TCPOrigDataSent:" | awk "{print \$2}")
  local tcp_delivered=$(netstat -s | grep "TCPDelivered:" | awk "{print \$2}")
  
  echo "$in_octets $out_octets $tcp_rcv_coalesce $tcp_orig_data_sent $tcp_delivered"
}

# Get initial values
initial_stats=($(get_net_stats))
prev_total_in=${initial_stats[0]}
prev_total_out=${initial_stats[1]}
prev_tcp_rcv_coalesce=${initial_stats[2]:-0}
prev_tcp_orig_data_sent=${initial_stats[3]:-0}
prev_tcp_delivered=${initial_stats[4]:-0}

echo "Initial network stats - In: $prev_total_in bytes, Out: $prev_total_out bytes"
echo "Initial TCP stats - RcvCoalesce: $prev_tcp_rcv_coalesce, OrigDataSent: $prev_tcp_orig_data_sent, Delivered: $prev_tcp_delivered"

while true; do 
  # Set default threshold if environment variable not set - using 100 as default
  THRESHOLD=${WEBHOOKTRAFFICAMOUNT:-100}
  timestamp=$(date "+%Y-%m-%d %H:%M:%S")
  echo "$timestamp - Traffic Monitoring:"
  echo "Current threshold for alerts (TCPOrigDataSent): $THRESHOLD"
  
  # Get current network statistics
  current_stats=($(get_net_stats))
  current_total_in=${current_stats[0]}
  current_total_out=${current_stats[1]}
  current_tcp_rcv_coalesce=${current_stats[2]:-0}
  current_tcp_orig_data_sent=${current_stats[3]:-0}
  current_tcp_delivered=${current_stats[4]:-0}
  
  # Calculate differences since last check
  total_in_diff=$((current_total_in - prev_total_in))
  total_out_diff=$((current_total_out - prev_total_out))
  tcp_rcv_coalesce_diff=$((current_tcp_rcv_coalesce - prev_tcp_rcv_coalesce))
  tcp_orig_data_sent_diff=$((current_tcp_orig_data_sent - prev_tcp_orig_data_sent))
  tcp_delivered_diff=$((current_tcp_delivered - prev_tcp_delivered))
  
  # Update previous values
  prev_total_in=$current_total_in
  prev_total_out=$current_total_out
  prev_tcp_rcv_coalesce=$current_tcp_rcv_coalesce
  prev_tcp_orig_data_sent=$current_tcp_orig_data_sent
  prev_tcp_delivered=$current_tcp_delivered
  
  # Show overall traffic statistics
  echo -e "\n--- Overall Network Traffic ---"
  echo "Total Incoming Bytes: $current_total_in (+$total_in_diff since last check)"
  echo "Total Outgoing Bytes: $current_total_out (+$total_out_diff since last check)"
  echo -e "\n--- TCP Statistics ---"
  echo "TCPRcvCoalesce: $current_tcp_rcv_coalesce (+$tcp_rcv_coalesce_diff)"
  echo "TCPOrigDataSent: $current_tcp_orig_data_sent (+$tcp_orig_data_sent_diff)"
  echo "TCPDelivered: $current_tcp_delivered (+$tcp_delivered_diff)"
  
  # Show HAProxy frontend stats if socket is available
  echo -e "\n--- HAProxy Frontend Stats ---"
  if [ -S /var/run/haproxy.sock ]; then
    mapfile -t current_stats < <(echo "show stat" | socat unix-connect:/var/run/haproxy.sock stdio 2>/dev/null | grep "FRONTEND");
    
    if [ ${#current_stats[@]} -gt 0 ]; then
      for line in "${current_stats[@]}"; do
        frontend=$(echo "$line" | cut -d, -f1);
        bytes_in=$(echo "$line" | cut -d, -f8);
        bytes_out=$(echo "$line" | cut -d, -f9);
        connections=$(echo "$line" | cut -d, -f7);
        printf "%-15s | Connections: %-6s | Bytes In: %-10s | Bytes Out: %-10s\n" "$frontend" "$connections" "$bytes_in" "$bytes_out";
      done
    else
      echo "No frontend statistics available from HAProxy"
    fi
  else
    echo "HAProxy socket not found at /var/run/haproxy.sock - skipping HAProxy stats"
  fi
  
  # Check backend connections
  echo -e "\n--- Backend Connection Stats ---"
  for var in $(env | grep -E "^BACKEND_HOST[0-9]+" | cut -d= -f1); do
    val=$(eval echo \$$var)
    if [[ -n "$val" ]]; then
      ip=$(extract_ip "$val")
      port=$(extract_port "$val")
      
      if [[ -n "$ip" && -n "$port" ]]; then
        # Get current connection count
        conn_count=$(get_connection_count "$ip" "$port")
        
        printf "%-15s | IP:Port: %-20s | Active Connections: %-5s\n" \
          "$var" "$val" "$conn_count"
      fi
    fi
  done
  
  # Check if TCPOrigDataSent exceeds threshold and send alert
  if [[ $tcp_orig_data_sent_diff -gt $THRESHOLD ]]; then
    echo "ALERT: TCP data sent increase exceeds threshold ($THRESHOLD): +$tcp_orig_data_sent_diff"
    
    if [[ -n "$WEBHOOKTRAFFIC" ]]; then
      echo "DEBUG: Using webhook URL: $WEBHOOKTRAFFIC"
      webhook_response=$(curl -v -k -s -X POST "$WEBHOOKTRAFFIC" \
        -d "type=network&bytes_in_current=$current_total_in&bytes_in_diff=$total_in_diff&bytes_out_current=$current_total_out&bytes_out_diff=$total_out_diff&threshold=$THRESHOLD&tcp_rcv_coalesce=$current_tcp_rcv_coalesce&tcp_rcv_coalesce_diff=$tcp_rcv_coalesce_diff&tcp_orig_data_sent=$current_tcp_orig_data_sent&tcp_orig_data_sent_diff=$tcp_orig_data_sent_diff&tcp_delivered=$current_tcp_delivered&tcp_delivered_diff=$tcp_delivered_diff" 2>&1)
      echo "WEBHOOK RESPONSE: $webhook_response"
    else
      echo "ALERT: Traffic increase detected but WEBHOOKTRAFFIC not defined."
    fi
  fi
  
  echo "----------------------------------------"; 
  sleep 60; 
done'
