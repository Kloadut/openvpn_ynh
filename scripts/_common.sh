#!/bin/bash

#=================================================
# COMMON VARIABLES
#=================================================

# dependencies used by the app
pkg_dependencies="php7.0-fpm openvpn openvpn-auth-ldap netmask"

#============================================================
# Specific to openvpn
#============================================================

configure_firewall () {
    ip4ranges=$(ynh_app_setting_get $app ip4ranges | tr " " "\n")
    iface=$(ynh_app_setting_get $app iface)
    iptables -t filter -$1 FORWARD -i "${iface}" -o tun0 -m state --state ESTABLISHED,RELATED -j ACCEPT
    for ip4range in $ip4ranges
    do
        if [[ "$1" = "A" ]];then
            if ! ( /sbin/iptables -L -t nat | grep $ip4range | grep MASQUERADE > /dev/null 2>&1); then
                iptables -t nat -$1 POSTROUTING -s $ip4range -o "${iface}" -j MASQUERADE
                iptables -t filter -$1 FORWARD -s $ip4range -o "${iface}" -j ACCEPT
            fi
        elif [[ "$1" = "D" ]]; then
            if (/sbin/iptables -L -t nat | grep $ip4range | grep MASQUERADE > /dev/null 2>&1); then
                iptables -t nat -$1 POSTROUTING -s $ip4range -o "${iface}" -j MASQUERADE
                iptables -t filter -$1 FORWARD -s $ip4range -o "${iface}" -j ACCEPT
            fi
        fi
    done
}

add_firewall_rules () {
    configure_firewall A
}

rm_firewall_rules () {
    configure_firewall D
}

install_files () {
    # Make directories and set rights
    mkdir -p /etc/openvpn/auth \
        /etc/openvpn/users \
        "${final_path}" \
        /var/log/openvpn
    touch /var/log/openvpn/status.log
    touch /var/log/openvpn/server.log
    touch /etc/openvpn/users_settings.csv

    # Configurations
    set +x
    export ca_yunohost=$(cat /etc/yunohost/certs/yunohost.org/ca.pem)
    export ta_key=$(cat /etc/openvpn/ta.key)
    export domain=$domain
    export port=$port
    export dedicated_ip=$dedicated_ip
    export base_cert_path=$(ls -d /etc/yunohost/certs/$domain-history/*-selfsigned)
    set -x
    install -b -o root -g root -m 0644 ../conf/server.conf.j2 /etc/openvpn/
    install -b -o root -g root -m 0644 ../conf/client.conf.j2 /etc/openvpn/
    install -b -o root -g root -m 0644 ../conf/client.ovpn.j2 /etc/openvpn/
    install -b -o root -g root -m 0644 ../conf/ldap.conf /etc/openvpn/auth/
    install -b -o root -g root -m 0755 ../conf/handler.sh /etc/openvpn/
    touch /etc/openvpn/crl.pem
    echo "$ip4ranges" | tee /etc/openvpn/ip4ranges

    # IP forwarding
    install -b -o root -g root -m 0644 ../conf/sysctl /etc/sysctl.d/openvpn.conf
}

setup_and_restart () {

    # Find gateway ip and mask and save it
    first_ip4_range=$(echo $ip4ranges | cut -f1 -d" ")
    first_ip=$(netmask -r $first_ip4_range | cut -f1 -d"-" )
    first_ip=$( netmask -x $first_ip )
    first_ip=$(( $first_ip + 1 ))
    export first_ip4=$( netmask $first_ip )
    export last_ip4=$(netmask -r $first_ip4_range | cut -f2 -d"-" )
    first_ip4_range=$(netmask -s $first_ip4_range)
    export gateway_ip4=$(echo $first_ip4_range | cut -f1 -d"/")
    export gateway_mask=$(echo $first_ip4_range | cut -f2 -d"/")

    ynh_app_setting_set "$app" gateway_ip4 $gateway_ip4
    ynh_app_setting_set "$app" gateway_mask $gateway_mask

    # Open port in firewall
    if [ -z $dedicated_ip ]; then
        yunohost firewall allow Both $port > /dev/null 2>&1
    fi

    # Copy files
    install_files
    sysctl -p /etc/sysctl.d/openvpn.conf

    # Modify openvpn config files
    ynh_render_template /etc/openvpn/server.conf.j2 /etc/openvpn/server.conf
    ynh_render_template /etc/openvpn/client.conf.j2 "${final_path}/${domain}.conf"
    ynh_render_template /etc/openvpn/client.ovpn.j2 "${final_path}/${domain}.ovpn"

    # Permissions
    ynh_set_default_perm "${final_path}" $webuser
    chown -R $webuser:www-data "${final_path}"
    chown -R $user: /etc/openvpn
    chmod 640 /etc/openvpn/users_settings.csv
}

#============================================================
# Common helpers
#============================================================

ynh_set_default_perm () {
    local DIRECTORY=$1
    local USER=$2
    # Set permissions
    chown -R $USER:$USER $DIRECTORY
    chmod -R 664 $DIRECTORY
    find $DIRECTORY -type d -print0 | xargs -0 chmod 775 \
        || echo "No file to modify"
}
