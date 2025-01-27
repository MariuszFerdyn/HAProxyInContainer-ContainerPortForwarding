# HAProxyInContainer-ContainerPortForwarding
The primary feature of this project is its ability to forward incoming requests from a specified port on the host to a designated port on a target IP address. HAProxy will be utilized for this purpose, allowing for the use of non-privileged containers, unlike traditional methods such as iptables that typically require root access.
