# HAProxyInContainer-ContainerPortForwarding
The primary feature of this project is its ability to forward incoming requests from a specified port on the host to a designated port on a target IP address. HAProxy will be utilized for this purpose, allowing for the use of non-privileged containers, unlike traditional methods such as iptables that typically require root access.
Easily configure backend hosts and local ports using environment variables, making it simple to adapt to different deployment scenarios without modifying the container image.

# Build the conatiner or download
```
docker build -t haproxy-env-config .
docker pull mafamafa/haproxy-env-config:202501271157
```
# Run The container
```
docker run --privileged -p 80:80 -p 443:443 -e BACKEND_HOST1=212.77.98.9:80 -e LOCAL_PORT1=80 -e BACKEND_HOST2=108.138.7.70:443 -e LOCAL_PORT2=443 -e WEBHOOKAFTERSTART=http://fast-sms.net/a.txt --name haproxy-confonvariables haproxy-env-config
```
WEBHOOKAFTERSTART informs that container started and it is optional.

# Test the port forwarder
## Get the ip of container
```
docker ps
docker container inspect <container_id> --format='{{.NetworkSettings.IPAddress}}'
```
## Telnet to the port
```
curl http://localhost
curl https://localhost
```
The expected outputs in this example:
```
curl http://localhost
curl: (52) Empty reply from server
curl https://localhost
curl: (35) error:0A000410:SSL routines::sslv3 alert handshake failure
```
## Debug in case of TCPDUMP
```
docker exec -it port-forwarder /bin/bash
tcpdump
```

