# ocserv-config-template
You no longer need config firewall manually, just create a one system service. 




There is a easy way to setup your ocserv server.

This article will teach you how to set up an OpenConnect server on a Debian system in five minutes, for use with AnyConnect/OpenConnect clients.

1. Install the packages
apt install iptables-persistent ocserv


When installing the iptables-persistent package, you will be prompted whether you want to save the current iptables rules. Select No for both prompts.

2. Modify the configuration files

First, modify /etc/sysctl.conf and add the following settings to enable IP forwarding:

net.ipv4.ip_forward = 1
net.ipv4.ip_forward_update_priority = 0
net.ipv4.ip_forward_use_pmtu = 1
net.ipv6.conf.all.forwarding = 1


Next, modify /etc/ocserv/ocserv.conf to configure the basic server settings. The configuration below contains internal network ranges and other settings that can be modified as needed.

(It is recommended to back up the original configuration file beforehand for reference.)

# openconnect server user
run-as-user = ocserv
run-as-group = ocserv

# require file while server run
socket-file = /run/ocserv-socket
chroot-dir = /var/lib/ocserv

# isolate sub proccess control
isolate-workers = true

# net interface for server
device = op

# mtu size for server
mtu = 1480

# log level
log-level = 1

# auth method
auth = "plain[/etc/ocserv/ocpasswd]"

# maximum users allowed connect
max-clients = 10

# maximum client allowed connect for per user
max-same-clients = 5

# server listen address (default is all)
# listen-host =

# server listen ports (default is 443, but can modified)
tcp-port = 443
udp-port = 443

# mtu auto discovery for per tunnel
try-mtu-discovery = true

# user certificate type
# cert-user-oid = 2.5.4.3

# certificate and private key for server
server-cert = /etc/ocserv/server.pem
server-key = /etc/ocserv/server.key

# dns while clients connected use
dns = 8.8.8.8
dns = 9.9.9.9
tunnel-all-dns = true

# route option (set it to default as a gateway)
#route = 192.168.1.0/255.255.255.0
route = default

# enable cisco anyconnect compatible
cisco-client-compat = true

# keep alive interval
keepalive = 32400
dpd = 60
mobile-dpd = 120

# other option
output-buffer = 0
rate-limit-ms = 0

# access control
restrict-user-to-routes = false
restrict-user-to-ports = ""

# disconnected idle time
# idle-timeout = 1200
# mobile-idle-timeout = 1800

# dtls protocol control
dtls-legacy = true
switch-to-tcp-timeout = 30
tls-priorities = "NORMAL:%SERVER_PRECEDENCE:%COMPAT:-VERS-SSL3.0:-VERS-TLS1.0:-VERS-TLS1.1:-VERS-TLS1.2"

# compression control
compression = true
no-compress-limit = 0

# speed limit by per client
rx-data-per-sec = 0
tx-data-per-sec = 0

# client auth control
auth-timeout = 240
min-reauth-time = 300
max-ban-score = 80
ban-reset-time = 1200

# client status control
cookie-timeout = 600
rekey-time = 172800
deny-roaming = false
use-occtl = true

# internal network settings
ipv4-network = 10.255.255.0/24
ipv6-network = fd09::/80
ipv6-subnet-prefix = 128
client-bypass-protocol = false
predictable-ips = true
ping-leases = true
net-priority = 3

3. Create a self-signed SSL certificate and configure the iptables rules

First, create a self-signed SSL certificate. After entering the following command, follow the prompts to fill in the required information. Once the files have been generated, place them in /etc/ocserv/.

openssl req -x509 -sha256 -nodes -days 3650 -newkey rsa:4096 -keyout server.key -out server.pem


Next, configure the appropriate iptables forwarding rules for the internal network ranges. Replace the IP address ranges below with the actual ranges specified in your configuration file:

# These rules allow traffic from the internal network range to be forwarded
# through the machine. Without these rules, UDP forwarding will not work.
iptables -I FORWARD -s 10.255.255.0/24 -j ACCEPT
iptables -I FORWARD -d 10.255.255.0/24 -j ACCEPT
ip6tables -I FORWARD -s fd09::/80 -j ACCEPT
ip6tables -I FORWARD -d fd09::/80 -j ACCEPT

# These rules enable IP masquerading.
# In other words, except for the network interface created by the
# OpenConnect server, traffic originating from the OpenConnect server's
# internal network will be NATed before being sent out through other interfaces.
iptables -A POSTROUTING -s 10.255.255.0/24 ! -o op+ -j MASQUERADE
ip6tables -A POSTROUTING -s fd09::/80 ! -o op+ -j MASQUERADE


After configuring the rules, save them permanently so that they remain effective after a reboot:

iptables-save >> /etc/iptables/rules.v4
ip6tables-save >> /etc/iptables/rules.v6

4. Add a user

If you have not changed the user authentication method in the configuration file to another method, you need to add a user who can log in.

Run:

# Format:
# ocpasswd -c <user-file> <username>
# You will then be prompted to set the user's password.

# To delete a user, edit the corresponding line in the user file.
ocpasswd -c /etc/ocserv/ocpasswd boss

5. Optional settings

Open the appropriate port(s) in your firewall as needed.

6. Restart the server

After completing the steps above, you can test whether the server can connect normally.

Under normal circumstances, the connection should now work.

If you can upgrade the server-side ocserv program to version 1.2.1 or later, you can also enable a camouflage feature. With this feature enabled, the client connects using a specific URL path. Anyone who does not know the correct path will simply see what appears to be an ordinary device-management web interface.

If you have confirmed that your version is 1.2.1 or later, add the following to the configuration file:

# camouflage
camouflage = true

# Secret phrase:
# Once enabled, the client can connect through:
# https://server-address/?secret
camouflage_secret = "dark"

camouflage_realm = "router admin panel"
