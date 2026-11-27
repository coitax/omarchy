echo "Limit the Docker DNS firewall allow to Docker bridge interfaces"

command -v ufw >/dev/null || exit 0

# The old rules matched only the source range, so LAN hosts in 192.168.0.0/16
# or 172.16.0.0/12 could query resolved's stub on 172.17.0.1 from Wi-Fi or
# ethernet. ufw reports a missing rule without failing, so reruns are no-ops.
sudo ufw delete allow in proto udp from 172.16.0.0/12 to 172.17.0.1 port 53
sudo ufw delete allow in proto udp from 192.168.0.0/16 to 172.17.0.1 port 53

sudo ufw allow in on docker0 proto udp to 172.17.0.1 port 53 comment 'allow-docker-dns'
sudo ufw allow in on br-+ proto udp to 172.17.0.1 port 53 comment 'allow-docker-dns'
