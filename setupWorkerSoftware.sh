#!/bin/bash
#
# For a bit of speedup, this script is copied over to the worker so it can background most actions
NODE_INSTALLATION_USER=${1}
KUBERNETES_VERSION=${2}

cd /home/${NODE_INSTALLATION_USER}
add-apt-repository -y ppa:alexlarsson/flatpak
apt-add-repository -y ppa:projectatomic/ppa
apt-get update
apt-get remove -y docker docker-engine docker.io
apt-get install -y \
    apt-transport-https \
    ca-certificates \
    software-properties-common
wget -q --https-only \
    https://github.com/containernetworking/plugins/releases/download/v0.6.0/cni-plugins-amd64-v0.6.0.tgz \
    https://github.com/opencontainers/runc/releases/download/v1.0.0-rc4/runc.amd64 \
    https://storage.googleapis.com/kubernetes-the-hard-way/crio-amd64-v1.0.0-beta.0.tar.gz \
    https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kubectl \
    https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kube-proxy \
    https://storage.googleapis.com/kubernetes-release/release/${KUBERNETES_VERSION}/bin/linux/amd64/kubelet &

# Install docker:
wget https://download.docker.com/linux/ubuntu/gpg
apt-key add gpg
add-apt-repository "deb [arch=amd64] https://download.docker.com/linux/ubuntu xenial stable"
apt-get update
apt-get install -y docker-ce \
    btrfs-tools git golang-go libassuan-dev libdevmapper-dev libglib2.0-dev \
    libc6-dev libgpgme11-dev libgpg-error-dev libseccomp-dev libselinux1-dev \
    pkg-config runc skopeo-containers bridge-utils ntp \
    socat libgpgme11 libostree-1-1 conntrack \
    curl \
    nfs-common &

mkdir -p \
    /etc/containers \
    /etc/cni/net.d \
    /etc/crio \
    /opt/cni/bin
mkdir -p  /usr/local/libexec/crio \
    /var/lib/kubelet \
    /var/lib/kube-proxy \
    /var/lib/kubernetes \
    /var/run/kubernetes

# wget needs to finish before the next step
while [ `ps -ef | grep wget | grep -v grep| wc -l` -ne 0 ]
do
  echo "waiting for wget to finish"
  sleep 1
done

tar -xvf cni-plugins-amd64-v0.6.0.tgz -C /opt/cni/bin/ 
tar -xvf crio-amd64-v1.0.0-beta.0.tar.gz 
chmod +x kubectl kube-proxy kubelet runc.amd64
mv runc.amd64 /usr/local/bin/runc
mv crio crioctl kpod kubectl kube-proxy kubelet /usr/local/bin/
mv conmon pause /usr/local/libexec/crio/
