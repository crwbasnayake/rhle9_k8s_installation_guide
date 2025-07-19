# Kubernetes v1.29.6 Installation Guide for RHEL 9

This guide provides a step-by-step walkthrough to install Kubernetes v1.29.6 on RHEL 9 using `containerd` as the container runtime and `Flannel` as the CNI plugin. It includes all necessary system configurations, firewall settings, pinned version installations, and testing steps.

---

## Security Policies and Firewall Configuration

Ensure the following ports are allowed through your security groups or firewalls:

### Control Plane Node (Master)

* TCP 6443: Kubernetes API Server
* TCP 2379-2380: etcd server client API
* TCP 10250: Kubelet API
* TCP 10259: kube-scheduler
* TCP 10257: kube-controller-manager

### Worker Nodes

* TCP 10250: Kubelet API
* TCP 30000–32767: NodePort Services

### All Nodes

* TCP 22: SSH
* UDP 8472: Flannel VXLAN overlay
* TCP/UDP 53: DNS

**Flannel requires UDP 8472 for pod communication**

---

## Pinned Versions Used

* **Kubernetes:** v1.29.6
* **Container Runtime:** containerd v1.7.27
* **CNI Plugins:** v1.3.0
* **crictl:** v1.29.0
* **Flannel:** v0.25.0

---

## System Preparation (All Nodes)

1. **Update System and Install Required Packages:**

   ```bash
   sudo dnf update -y
   sudo dnf install -y chrony conntrack-tools firewalld wget curl tar git bash-completion yum-utils
   ```

2. **Disable Swap:**

   ```bash
   sudo swapoff -a
   sudo sed -i '/swap/d' /etc/fstab
   ```

3. **Set SELinux to Permissive:**

   ```bash
   sudo setenforce 0
   sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
   ```

4. **Enable Required Kernel Modules and Sysctl Params:**

   ```bash
   cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
   overlay
   br_netfilter
   EOF

   sudo modprobe overlay
   sudo modprobe br_netfilter

   cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
   net.bridge.bridge-nf-call-iptables = 1
   net.bridge.bridge-nf-call-ip6tables = 1
   net.ipv4.ip_forward = 1
   EOF

   sudo sysctl --system
   ```

5. **Set Hostname and Hosts File:**

   ```bash
   sudo hostnamectl set-hostname <your-hostname>
   echo "<node-ip> <your-hostname>" | sudo tee -a /etc/hosts
   ```

---

## Firewall Setup (All Nodes)

```bash
sudo systemctl enable --now firewalld
sudo firewall-cmd --add-port=6443/tcp --permanent
sudo firewall-cmd --add-port=2379-2380/tcp --permanent
sudo firewall-cmd --add-port=10250/tcp --permanent
sudo firewall-cmd --add-port=10259/tcp --permanent
sudo firewall-cmd --add-port=10257/tcp --permanent
sudo firewall-cmd --add-port=8472/udp --permanent
sudo firewall-cmd --add-masquerade --permanent
sudo firewall-cmd --reload
```

---

## Install containerd (All Nodes)

```bash
sudo dnf install -y containerd.io-1.7.27-3.1.el9
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
```

Edit `/etc/containerd/config.toml` and set:

```toml
SystemdCgroup = true
```

Then restart:

```bash
sudo systemctl restart containerd
sudo systemctl enable containerd
```

---

## Install CNI Plugins (All Nodes)

```bash
wget https://github.com/containernetworking/plugins/releases/download/v1.3.0/cni-plugins-linux-amd64-v1.3.0.tgz
sudo mkdir -p /opt/cni/bin
sudo tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v1.3.0.tgz
```

---

## Install crictl (All Nodes)

```bash
wget https://github.com/kubernetes-sigs/cri-tools/releases/download/v1.29.0/crictl-v1.29.0-linux-amd64.tar.gz
sudo tar zxvf crictl-v1.29.0-linux-amd64.tar.gz -C /usr/local/bin
```

---

## Install Kubernetes Components (All Nodes)

```bash
cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://packages.cloud.google.com/yum/repos/kubernetes-el7-\$basearch
enabled=1
gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg \
       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF

sudo dnf install -y kubelet-1.29.6 kubeadm-1.29.6 kubectl-1.29.6 --disableexcludes=kubernetes
sudo systemctl enable kubelet
```

---

## Cluster Initialization (Control Plane Only)

```bash
sudo kubeadm init \
  --apiserver-advertise-address=<master-ip> \
  --pod-network-cidr=10.244.0.0/16
```

After success, set up `kubectl` for root:

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

---

## Install Flannel CNI (Control Plane Only)

```bash
kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/v0.25.0/Documentation/kube-flannel.yml
```

---

## Worker Node Join

Run the `kubeadm join ...` command on each worker node provided after `kubeadm init`. Example:

```bash
sudo kubeadm join <master-ip>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash>
```

---

## Post-Installation Testing (Control Plane)

```bash
kubectl create ns test
kubectl run testpod1 --image=nginx -n test
kubectl run testpod2 --image=nginx -n test
kubectl get pods -n test -o wide
kubectl exec -n test testpod1 -- ping testpod2
kubectl exec -n test testpod1 -- nslookup kubernetes.default
kubectl delete ns test
```

---

## Notes

* If `kubeadm join` command expires, regenerate with:

  ```bash
  kubeadm token create --print-join-command
  ```
* Make sure all nodes have matching Kubernetes versions.
* Ensure containerd and kubelet are running on all nodes.

---

## Support

For issues, please create a ticket in your Git repository.
