Simple ttyd WebSSH Setup on Debian 13

This guide shows how to set up ttyd as a simple HTTPS WebSSH terminal on Debian 13.

The final setup looks like this:

Browser
   │
   │ HTTPS :8443
   ▼
 ttyd
   │
   ▼
 /bin/bash


ttyd handles HTTPS and HTTP Basic Authentication directly, so no Nginx or Caddy is required.

1. Install ttyd

Update the package list and install ttyd:

sudo apt update
sudo apt install -y ttyd


Check the installed version:

ttyd --version

2. Create a dedicated user

It is better not to run the web terminal as root.

Create a dedicated user:

sudo adduser webssh


If the user needs administrative access:

sudo usermod -aG sudo webssh


Otherwise, leave the account as an unprivileged user.

3. Prepare the TLS certificate

For this example, assume the certificate and private key are:

/etc/ssl/ttyd/server.pem
/etc/ssl/ttyd/server.key


Make sure the webssh user can read the private key.

For example:

sudo chown webssh:webssh /etc/ssl/ttyd/server.key
sudo chmod 600 /etc/ssl/ttyd/server.key


The certificate itself can normally be readable:

sudo chmod 644 /etc/ssl/ttyd/server.pem


If you use Let's Encrypt, do not blindly change ownership of the entire /etc/letsencrypt directory. Handle certificate permissions separately.

4. Create a systemd service

Create:

sudo nano /etc/systemd/system/ttyd.service


Use the following configuration:

[Unit]
Description=ttyd Web SSH Terminal
After=network.target

[Service]
Type=simple

User=webssh
Group=webssh

ExecStart=/usr/bin/ttyd \
    -i 0.0.0.0 \
    -p 8443 \
    -S \
    -C /etc/ssl/ttyd/server.pem \
    -K /etc/ssl/ttyd/server.key \
    -c web:REPLACE_WITH_A_STRONG_PASSWORD \
    -W \
    /bin/bash

Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target


Replace:

REPLACE_WITH_A_STRONG_PASSWORD


with a strong password.

The important options are:

-i 0.0.0.0 — listen on all network interfaces.

-p 8443 — listen on port 8443.

-S — enable HTTPS.

-C — specify the TLS certificate.

-K — specify the TLS private key.

-c — enable HTTP Basic Authentication.

-W — enable writable/interactive terminal input.

/bin/bash — start Bash for the web terminal.

5. Enable and start ttyd

Reload systemd:

sudo systemctl daemon-reload


Enable ttyd at boot and start it immediately:

sudo systemctl enable --now ttyd


Check its status:

sudo systemctl status ttyd


You should see:

Active: active (running)


You can also verify that ttyd is listening:

sudo ss -lntp | grep 8443


You should see something similar to:

0.0.0.0:8443

6. Connect from a browser

Open:

https://YOUR_SERVER:8443/


Your browser should display an HTTP Basic Authentication prompt.

Enter the username and password configured with:

-c web:YOUR_PASSWORD


After authentication, you should get an interactive Bash terminal.

7. Troubleshooting
systemd reports 217/USER

If you see:

status=217/USER


check that the configured user actually exists:

id webssh


If necessary:

sudo adduser webssh


Then restart the service:

sudo systemctl restart ttyd

Check ttyd logs
sudo journalctl -u ttyd -f


This is particularly useful when debugging TLS or permission problems.

Check the effective service configuration
systemctl cat ttyd


And:

systemctl show ttyd -p ExecStart


These commands are useful if the running ttyd process does not appear to use the options you configured.

8. Basic security considerations

This setup exposes a shell directly to the Internet, so treat it as a remote administration interface.

At minimum:

Use a strong, unique Basic Auth password.

Keep Debian and ttyd updated.

Run ttyd as a dedicated non-root user.

Give the webssh user sudo access only if it is actually needed.

Keep the TLS private key protected.

Use a firewall and expose only the ports you actually need.

Consider adding rate limiting or fail2ban if the service is publicly accessible.

ttyd does not provide a traditional login-attempt rate limiter for Basic Authentication. Its client limit is not the same thing as brute-force protection.

The HTTP Server header may also identify ttyd. Hiding that header is not a substitute for proper authentication, TLS, access control, and software updates.

9. Useful commands

Restart:

sudo systemctl restart ttyd


Stop:

sudo systemctl stop ttyd


Start:

sudo systemctl start ttyd


View logs:

sudo journalctl -u ttyd -f


Check whether it is enabled at boot:

systemctl is-enabled ttyd


Check whether it is running:

systemctl is-active ttyd


That's it. You now have a lightweight HTTPS WebSSH terminal running directly from systemd on Debian 13, without requiring a reverse proxy.
