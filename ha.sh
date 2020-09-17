#!/bin/bash

source /etc/wspecs/global.conf
source /etc/wspecs/functions.sh

function join() {
    # $1 is return variable name
    # $2 is sep
    # $3... are the elements to join
    local retname=$1 sep=$2 ret=$3
    shift 3 || shift $(($#))
    printf -v "$retname" "%s" "$ret${@/#/$sep}"
}

CONFIG_FILE=${CONFIG_FILE:-/etc/corosync/corosync.conf}
HAPROXY_CONFIG_FILE=${HAPROXY_CONFIG_FILE:-/etc/haproxy/haproxy.cfg}
NGINX_CONFIG_FILE=${NGINX_CONFIG_FILE:-/etc/nginx/sites-available/default}
ALLOW_IP=${ALLOW_IP:-10.108.0.0/20}
TIMEZONE=${TIMEZONE:-"America/New_York"}
CURRENT_IP=$(curl 169.254.169.254/metadata/v1/interfaces/private/0/ipv4/address && echo)
HOSTNAME=$(curl -s http://169.254.169.254/metadata/v1/hostname)
PUBLIC_IPV4=$(curl -s http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
ANCHOR_IP=$(curl 169.254.169.254/metadata/v1/interfaces/public/0/anchor_ipv4/address && echo)
SERVER_ID=1

sudo timedatectl set-timezone "${TIMEZONE}"
sudo dpkg-reconfigure -f noninteractive tzdata
install_once ntp
install_once pacemaker

sudo ufw allow 5404/udp
sudo ufw allow 5405/udp
sudo ufw allow 5406/udp

SERVERS=($SERVERS_PRIVATE_IPS)
if [[ "${SERVERS[0]}" = "${CURRENT_IP}" ]]; then
  if [[ ! -f /etc/corosync/authkey ]]; then
    install_once haveged
    sudo corosync-keygen
    chmod 600 /etc/corosync/authkey
    echo '-------------------------------------------------------' 
    echo '     Sync corosync key to other servers continue       '
    echo '-------------------------------------------------------'
    exit 1
  fi
else
  if [[ ! -f /etc/corosync/authkey ]]; then
    echo '-----------------------------------------------------------'
    echo '     Sync corosync key from primary server to continue     '
    echo '-----------------------------------------------------------'
    exit 1
  fi
fi

sudo service pacemaker stop
sudo service corosync stop

chmod 400 /etc/corosync/authkey
ALLOW_NGINX_IPS=""
NODELIST=""
NODE_NAMES=(primary secondary tertiary)
BACKEND_POOL=""
for i in "${!SERVERS[@]}"; do
  NODELIST+="  node {
    ring0_addr: ${SERVERS[$i]}
    name: ${NODE_NAMES[$i]}
    nodeid: $(echo ${i} + 1 | bc)\n  }\n"
  ALLOW_NGINX_IPS+="  allow ${SERVERS[$i]};\n"
  BACKEND_POOL+="    server app-$(echo ${i} + 1 | bc) ${SERVERS[$i]}:80 check\n"
done

TWO_NODES=0
sed "s#SERVER_ID#$SERVER_ID#" corosync.conf > $CONFIG_FILE
perl -i -p0e "s/NODELIST/$NODELIST/s" $CONFIG_FILE
if [[ "${#SERVERS[@]}" = 2 ]]; then
  TWO_NODES=1
fi
sed -i "s#TWO_NODES#$TWO_NODES#" $CONFIG_FILE
sed -i "s#CURRENT_IP#$CURRENT_IP#" $CONFIG_FILE

mkdir -p  /etc/corosync/service.d

cat > /etc/corosync/service.d/pcmk <<EOL
service {
  name: pacemaker
  ver: 1
}
EOL

cat > /etc/default/corosync <<EOL
START=yes
EOL

sudo service corosync start
corosync-cmapctl | grep members

update-rc.d pacemaker defaults 20 01
service pacemaker start
crm status

crm configure property stonith-enabled=false
crm configure property no-quorum-policy=ignore
crm configure show

curl -L -o /usr/local/bin/assign-ip http://do.co/assign-ip
chmod +x /usr/local/bin/assign-ip

mkdir -p /usr/lib/ocf/resource.d/digitalocean
sudo curl -o /usr/lib/ocf/resource.d/digitalocean/floatip https://gist.githubusercontent.com/thisismitch/b4c91438e56bfe6b7bfb/raw/2dffe2ae52ba2df575baae46338c155adbaef678/floatip-ocf
chmod +x /usr/lib/ocf/resource.d/digitalocean/floatip

if [[ $(fgrep -c "python3" /usr/local/bin/assign-ip) -eq 0 ]]; then
  sed -i "s/python/python3/g" /usr/local/bin/assign-ip
fi

if [[ $(fgrep -c "python3" /usr/lib/ocf/resource.d/digitalocean/floatip) -eq 0 ]]; then
  sed -i "s/python /python3 /g" /usr/lib/ocf/resource.d/digitalocean/floatip
fi

crm configure primitive FloatIP ocf:digitalocean:floatip \
  params do_token=$DO_TOKEN \
  floating_ip=$FLOATING_IP || true;

install_once nginx
echo Droplet: $HOSTNAME, IP Address: $PUBLIC_IPV4 > /var/www/html/index.nginx-debian.html
ufw allow from $ALLOW_IP to any port 80
ufw allow from $ALLOW_IP to any port 443

if ! grep -q haproxy_log /etc/nginx/nginx.conf; then		 
  perl -i -p0e "s/http {/http {\n  log_format haproxy_log 'ProxyIP: \$remote_addr - ClientIP: \$http_x_forwarded_for - \$remote_user [\$time_local] ' '\"\$request\" \$status \$body_bytes_sent \"\$http_referer\" ' '\"\$http_user_agent\"';/s" /etc/nginx/nginx.conf
fi

sed "s#CURRENT_IP#$CURRENT_IP#" default_nginx.conf > $NGINX_CONFIG_FILE
perl -i -p0e "s/ALLOW_HTTP_IPS/$ALLOW_NGINX_IPS/s" $NGINX_CONFIG_FILE

nginx -t
service nginx restart

install_once haproxy
sed "s#LOAD_BALANCER_ANCHOR_IP#$ANCHOR_IP#" haproxy.cfg > $HAPROXY_CONFIG_FILE
perl -i -p0e "s/BACKEND_POOL/$BACKEND_POOL/s" $HAPROXY_CONFIG_FILE

haproxy -f /etc/haproxy/haproxy.cfg -c
service haproxy restart
cd /usr/lib/ocf/resource.d/heartbeat
curl -O https://raw.githubusercontent.com/thisismitch/cluster-agents/master/haproxy
chmod +x haproxy
crm configure primitive haproxy ocf:heartbeat:haproxy op monitor interval=15s || true
crm configure clone haproxy-clone haproxy || true
crm configure colocation FloatIP-haproxy inf: FloatIP haproxy-clone || true
crm configure show
