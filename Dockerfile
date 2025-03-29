# Use HAProxy 2.3 as base image
FROM haproxy:2.3

# Install bash for script execution
RUN apt-get update && apt-get install -y bash && apt-get install -y tcpdump curl socat && rm -rf /var/lib/apt/lists/*

# Create directory for config
RUN mkdir -p /usr/local/etc/haproxy

# Copy the configuration generator script
COPY generate-config.sh /generate-config.sh
RUN chmod +x /generate-config.sh

# Set the script as the entrypoint
ENTRYPOINT ["/generate-config.sh"]
CMD ["haproxy", "-f", "/usr/local/etc/haproxy/haproxy.cfg"]
