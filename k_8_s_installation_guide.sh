# Requred Security Group Rules
# SSH	            TCP	22	        122.255.14.147/32       SSH Communication (general)
# Custom TCP	    TCP	10250	    172.31.0.0/16	        Kubelet Communication
# Custom UDP	    UDP	8472	    172.31.0.0/16	        Flannel
# Custom TCP	    TCP	6443	    172.31.0.0/16	        API Server
# DNS(TCP)          TCP	53	        172.31.0.0/16	        VPCs

#!/usr/bin/env bash
set -euo pipefail

#===============================================================================
# 1. System Update & Reboot (all nodes)
#===============================================================================
sudo dnf update -y
sudo dnf clean all
sudo dnf makecache

# Align kernel modules (if needed for custom drivers)
sudo dnf install -y kernel-core kernel-modules kernel-devel-$(uname -r)
sudo reboot

#===============================================================================
# 2. Core Utilities (all nodes)
#===============================================================================
sudo dnf install -y \
  chrony curl tar conntrack-tools socat firewalld yum-utils \
  device-mapper-persistent-data lvm2

# Verify installation
rpm -q chrony curl tar conntrack-tools socat firewalld yum-utils device-mapper-persistent-data lvm2

# Enable and start chrony
sudo systemctl enable --now chronyd
chronyc tracking

#===============================================================================
# 3. Disable Swap & SELinux (all nodes)
#===============================================================================
sudo swapoff -a
sudo sed -i.bak '/swap/s/^/#/' /etc/fstab

# Set SELinux to permissive (consider enforcing with proper policies in prod)
sudo setenforce 0 || true
sudo sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config

#===============================================================================
# 4. Kernel Modules & Sysctl (all nodes)
#===============================================================================
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/99-k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

#===============================================================================
# 5. Firewall Configuration (custom)
#===============================================================================
sudo systemctl enable --now firewalld

# Master TCP ports
for p in 6443 2379-2380 10250 10251 10252 179 30000-32767; do
  sudo firewall-cmd --permanent --add-port=${p}/tcp
done

# Worker TCP ports
for p in 10250 179 30000-32767; do
  sudo firewall-cmd --permanent --add-port=${p}/tcp
done

# Flannel VXLAN (UDP 8472) (all nodes)
sudo firewall-cmd --permanent --add-port=8472/udp

# Enable masquerading for pod network NAT (required for pod-to-pod across nodes)
sudo firewall-cmd --permanent --add-masquerade

# Trust the Flannel VXLAN interface to skip further firewall checks (optional but recommended)
sudo firewall-cmd --permanent --zone=trusted --add-interface=flannel.1

sudo firewall-cmd --reload

#===============================================================================
# 6. Containerd Setup (CRI) (all nodes)
#===============================================================================
sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

sudo dnf install -y containerd.io-1.7.27-3.1.el9
sudo mkdir -p /etc/containerd
sudo containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/^            SystemdCgroup = false/            SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl enable --now containerd
containerd --version

sudo systemctl restart containerd

#===============================================================================
# 7. CNI Plugins (all nodes)
#===============================================================================
# Choose CNI plugin version:
# - v1.2.x: stable legacy, fewer features
# - v1.3.x: latest stable, includes important bugfixes and performance improvements
CNI_PLUGINS_VER="v1.3.0"

sudo mkdir -p /opt/cni/bin
curl -sSL \
  https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VER}/cni-plugins-linux-amd64-${CNI_PLUGINS_VER}.tgz \
  | sudo tar -C /opt/cni/bin -xz

# Verify one plugin
test -x /opt/cni/bin/bridge && echo "CNI bridge plugin installed"

ls /opt/cni/bin/
# expected result
# bandwidth  bridge  dhcp  dummy  firewall  host-device  host-local  ipvlan
# loopback  macvlan  portmap  ptp  sbr  static  tap  tuning  vlan  vrf

#===============================================================================
# 8. crictl Installation (all nodes)
#===============================================================================
CRICTL_VER="v1.29.0"

curl -LO https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VER}/crictl-${CRICTL_VER}-linux-amd64.tar.gz
sudo tar -C /usr/local/bin -xzf crictl-${CRICTL_VER}-linux-amd64.tar.gz
sudo ln -sf /usr/local/bin/crictl /usr/bin/crictl
crictl --version

#===============================================================================
# 9. Kubernetes Cluster Initialization (Master) grab the nodes' ips from the console
#===============================================================================
sudo hostnamectl set-hostname k8s-master # (on master)
sudo hostnamectl set-hostname k8s-worker1 # (on worker1)
sudo hostnamectl set-hostname k8s-worker2 # (on worker2)

# (all nodes)
sudo tee -a /etc/hosts <<EOF
192.168.4.174 k8s-master
192.168.4.175 k8s-worker1
192.168.4.176 k8s-worker2
EOF

#===============================================================================
# 10. Kubernetes Repo & Binaries (all nodes)
#===============================================================================
sudo dnf install -y dnf-plugins-core

# repo add
sudo tee /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF

sudo dnf clean all
sudo dnf install -y \
  kubelet-1.29.6 kubeadm-1.29.6 kubectl-1.29.6 \
  --disableexcludes=kubernetes

sudo systemctl enable --now kubelet

#===============================================================================
# Only on master node
#===============================================================================
# kubeinit should have master ip
sudo kubeadm config images pull --kubernetes-version v1.29.6
sudo kubeadm init \
  --apiserver-advertise-address=192.168.4.174 \
  --pod-network-cidr=10.244.0.0/16

# Configure kubectl for root
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chmod 600 $HOME/.kube/config

sudo chown $(id -u):$(id -g) $HOME/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

# Install Flannel CNI on master
echo "Applying Flannel v0.25.0..."
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/v0.25.0/Documentation/kube-flannel.yml
kubectl -n kube-system rollout status ds/kube-flannel-ds

#===============================================================================
# 11. Worker Node Join & Verification
#===============================================================================
# These lines are commented out because the worker-node join sequence can’t be scripted “as is”,
# you need to copy in the exact kubeadm join command (with the real token and discovery hash) 
# that was generated by your kubeadm init on the master, and each worker needs its own hostname.
# On each worker, set hostname and /etc/hosts same as master
# sudo hostnamectl set-hostname k8s-workerX
# sudo tee -a /etc/hosts <<EOF
# 192.168.4.174 k8s-master
# 192.168.4.175 k8s-worker1
# 192.168.4.176 k8s-worker2
# EOF

# Then run the join command printed by kubeadm init, e.g.:
# sudo kubeadm join 192.168.4.174:6443 \
#   --token <token> \
#   --discovery-token-ca-cert-hash sha256:<hash>

# !important!
# join command failed, add cloud security groups / firewall rules to ensure port 6443 is open inbound to the master.

# Verify nodes
kubectl get nodes

#===============================================================================
# 12. Post-Install Network Tests
#===============================================================================
kubectl create ns net-test || true
kubectl run pod-a -n net-test --image=busybox --command -- sleep 3600
kubectl run pod-b -n net-test --image=busybox --command -- sleep 3600

# Exec into pod-a and ping pod-b
POD_B_IP=$(kubectl get pod pod-b -n net-test -o jsonpath='{.status.podIP}')
echo "Pinging Pod B at $POD_B_IP from Pod A..."
kubectl exec -n net-test pod-a -- ping -c 3 $POD_B_IP

# DNS test
echo "Testing DNS resolution..."
kubectl exec -n net-test pod-a -- nslookup kubernetes.default.svc.cluster.local

# Cleanup test resources
kubectl delete ns net-test

#===============================================================================
# Installation complete
#===============================================================================
echo "Kubernetes 1.29.6 cluster installation finished."
