#!/bin/sh

SSH_PUBLIC_KEY='insert_your_ssh_public_key_here'

function add_ssh_public_key() {
    cd
    mkdir -p .ssh
    chmod 700 .ssh
    echo "$SSH_PUBLIC_KEY" >> .ssh/authorized_keys
    chmod 600 .ssh/authorized_keys
}

function get_network_info() {
    echo '* settings for cloud agent'
    read -p ' hostname   (ex:cloudstack)   : ' HOSTNAME
    read -p ' ip address (ex:192.168.1.2)  : ' IPADDR
    read -p ' netmask    (ex:255.255.255.0): ' NETMASK
    read -p ' gateway    (ex:192.168.1.1)  : ' GATEWAY
    read -p ' dns1       (ex:192.168.1.1)  : ' DNS1
    read -p ' dns2       (ex:8.8.4.4)      : ' DNS2
}

function get_nfs_info() {
    echo '* settings for nfs server'
    read -p ' NFS Server IP: ' NFS_SERVER_IP
    read -p ' Primary mount point   (ex:/export/primary)  : ' NFS_SERVER_PRIMARY
    read -p ' Secondary mount point (ex:/export/secondary): ' NFS_SERVER_SECONDARY
}

function get_nfs_network() {
    echo '* settings for nfs server'
    read -p ' accept access from (ex:192.168.1.0/24): ' NETWORK
}

function install_common() {
    sed -i -e 's/SELINUX=enforcing/SELINUX=permissive/g' /etc/selinux/config
    setenforce permissive
    echo "[cloudstack]
name=cloudstack
baseurl=http://cloudstack.apt-get.eu/rhel/4.3/
enabled=1
gpgcheck=0" > /etc/yum.repos.d/CloudStack.repo
    sed -i -e "s/localhost/$HOSTNAME localhost/" /etc/hosts
    yum install ntp wget -y
    service ntpd start
    chkconfig ntpd on
    wget http://download.cloud.com.s3.amazonaws.com/tools/vhd-util
    chmod 777 vhd-util
    mkdir -p /usr/share/cloudstack-common/scripts/vm/hypervisor/xenserver
    mv vhd-util /usr/share/cloudstack-common/scripts/vm/hypervisor/xenserver
}

function install_management() {
    yum install cloudstack-management mysql-server

    service mysqld start
    chkconfig mysqld on

    cloudstack-setup-databases cloud:password@localhost --deploy-as=root
    cloudstack-setup-management
    chkconfig cloudstack-management on
    chkconfig ntpd on
    chkconfig iptables off
    wget http://download.cloud.com.s3.amazonaws.com/tools/vhd-util
    chmod 777 vhd-util
    mv vhd-util /usr/share/cloudstack-common/scripts/vm/hypervisor/xenserver
    chown cloud:cloud /var/log/cloudstack/management/catalina.out
    mkdir -p /mnt/secondary
    mount -t nfs 172.25.103.58:/export/secondary /mnt/secondary
    sleep 10
    /usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt -m /mnt/secondary -f /root/systemvm64template-2014-01-14-master-xen.vhd.bz2 -h xenserver -F
    reboot
}

function initialize_storage() {
    service rpcbind start
    chkconfig rpcbind on
    service nfs start
    chkconfig nfs on
    mkdir -p /mnt/primary
    mkdir -p /mnt/secondary
    mount -t nfs ${NFS_SERVER_IP}:${NFS_SERVER_PRIMARY} /mnt/primary
    sleep 10
    mount -t nfs ${NFS_SERVER_IP}:${NFS_SERVER_SECONDARY} /mnt/secondary
    sleep 10
    rm -rf /mnt/primary/*
    /usr/share/cloudstack-common/scripts/storage/secondary/cloud-install-sys-tmplt -m /mnt/secondary -u http://127.0.0.1/systemvm64template-2014-01-14-master-xen.vhd.bz2 -h xenserver -F
    sync
    umount /mnt/secondary
    rmdir /mnt/secondary
}

function install_agent() {
    yum install qemu-kvm cloud-agent bridge-utils vconfig -y
    modprobe kvm-intel
    echo "group virt {
        cpu {
            cpu.shares=9216;
        }
}" >> /etc/cgconfig.conf
    service cgconfig restart
    echo "listen_tls = 0
listen_tcp = 1
tcp_port = \"16509\"
auth_tcp = \"none\"
mdns_adv = 0" >> /etc/libvirt/libvirtd.conf
    sed -i -e 's/#LIBVIRTD_ARGS="--listen"/LIBVIRTD_ARGS="--listen"/g' /etc/sysconfig/libvirtd
    service libvirtd restart

    HWADDR=`grep HWADDR /etc/sysconfig/network-scripts/ifcfg-eth0 | awk -F '"' '{print $2}'`

    echo "DEVICE=eth0
HWADDR=$HWADDR
NM_CONTROLLED=no
ONBOOT=yes
IPADDR=$IPADDR
NETMASK=$NETMASK
GATEWAY=$GATEWAY
DNS1=$DNS1
DNS2=$DNS2
BRIDGE=cloudbr0" > /etc/sysconfig/network-scripts/ifcfg-eth0
    echo "DEVICE=cloudbr0
HWADDR=$HWADDR
NM_CONTROLLED=no
ONBOOT=yes
IPADDR=$IPADDR
NETMASK=$NETMASK
GATEWAY=$GATEWAY
DNS1=$DNS1
DNS2=$DNS2
TYPE=Bridge" > /etc/sysconfig/network-scripts/ifcfg-cloudbr0
}

function install_nfs() {
    yum install nfs-utils -y
    service rpcbind start
    chkconfig rpcbind on
    service nfs start
    chkconfig nfs on

    mkdir -p $NFS_SERVER_PRIMARY
    mkdir -p $NFS_SERVER_SECONDARY
    echo "$NFS_SERVER_PRIMARY   *(rw,async,no_root_squash)" >  /etc/exports
    echo "$NFS_SERVER_SECONDARY *(rw,async,no_root_squash)" >> /etc/exports
    exportfs -a

    echo "LOCKD_TCPPORT=32803
LOCKD_UDPPORT=32769
MOUNTD_PORT=892
RQUOTAD_PORT=875
STATD_PORT=662
STATD_OUTGOING_PORT=2020" >> /etc/sysconfig/nfs

    chkconfig iptables off

}

if [ $# -eq 0 ]
then
    OPT_ERROR=1
fi

while getopts "acnmhr" flag; do
    case $flag in
    \?) OPT_ERROR=1; break;;
    h) OPT_ERROR=1; break;;
    a) opt_agent=true;;
    c) opt_common=true;;
    n) opt_nfs=true;;
    m) opt_management=true;;
    r) opt_reboot=true;;
    esac
done

shift $(( $OPTIND - 1 ))

if [ $OPT_ERROR ]
then
    echo >&2 "usage: $0 [-cnamhr]
  -c : install common packages
  -n : install nfs server
  -a : install cloud agent
  -m : install management server
  -h : show this help
  -r : reboot after installation"
    exit 1
fi

if [ "$opt_agent" = "true" ]
then
    get_network_info
fi
if [ "$opt_nfs" = "true" ]
then
    get_nfs_network
fi
if [ "$opt_management" = "true" ]
then
    get_nfs_info
fi


if [ "$opt_common" = "true" ]
then
    add_ssh_public_key
    install_common
fi
if [ "$opt_agent" = "true" ]
then
    install_agent
fi
if [ "$opt_nfs" = "true" ]
then
    install_nfs
fi
if [ "$opt_management" = "true" ]
then
    install_management
    initialize_storage
fi
if [ "$opt_reboot" = "true" ]
then
    sync
    sync
    sync
    reboot
fi
