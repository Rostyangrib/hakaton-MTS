#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo "Bootstrap failed at line $LINENO; inspect the error above. No automatic reset is performed." >&2' ERR
cd "$(dirname "${BASH_SOURCE[0]}")"
# shellcheck source=config/versions.env
source config/versions.env
[[ $EUID -eq 0 ]] || { echo 'Run: sudo ./bootstrap.sh' >&2; exit 1; }
# shellcheck source=/etc/os-release
source /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 && $(uname -m) == x86_64 ]] || {
  echo 'Supported platform: dedicated Ubuntu 24.04 amd64.' >&2; exit 1;
}
target_user=${SUDO_USER:-root}
target_home=$(getent passwd "$target_user" | cut -d: -f6)
marker=/etc/mts-devops/bootstrap-owner
if [[ -f /etc/kubernetes/admin.conf && ! -f $marker ]]; then
  echo 'An existing Kubernetes cluster was not created by this project. Refusing to modify it.' >&2
  exit 1
fi
if [[ -f $marker && $(cat "$marker") != "$KUBERNETES_VERSION" ]]; then
  echo 'Existing project cluster has another version. Upgrade is not automatic.' >&2; exit 1
fi
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl gpg jq git containerd conntrack socat logrotate
swapoff -a
sed -i.bak '/^[^#].*[[:space:]]swap[[:space:]]/s/^/# mts-devops: /' /etc/fstab
cat >/etc/modules-load.d/mts-kubernetes.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter
cat >/etc/sysctl.d/99-mts-kubernetes.conf <<'EOF'
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
sysctl --system
install -d /etc/containerd
runtime_config=$(mktemp)
containerd config default >"$runtime_config"
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' "$runtime_config"
if ! cmp -s "$runtime_config" /etc/containerd/config.toml; then
  install -m 644 "$runtime_config" /etc/containerd/config.toml
  systemctl restart containerd
fi
rm -f "$runtime_config"
systemctl enable --now containerd
install -d -m 755 /etc/apt/keyrings
key_file=$(mktemp)
curl -fsSL --retry 3 https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key -o "$key_file"
gpg --batch --yes --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg "$key_file"
rm -f "$key_file"
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /' >/etc/apt/sources.list.d/kubernetes.list
apt-get update
apt-get install -y --allow-change-held-packages "kubelet=$KUBERNETES_PACKAGE_VERSION" "kubeadm=$KUBERNETES_PACKAGE_VERSION" "kubectl=$KUBERNETES_PACKAGE_VERSION"
apt-mark hold kubelet kubeadm kubectl
systemctl enable --now kubelet
if ! command -v helm >/dev/null || [[ $(helm version --template '{{.Version}}') != "v$HELM_VERSION" ]]; then
  helm_tmp=$(mktemp -d)
  curl -fsSL --retry 3 "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" -o "$helm_tmp/helm.tar.gz"
  curl -fsSL --retry 3 "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" -o "$helm_tmp/helm.sha256"
  (cd "$helm_tmp"; printf '%s  helm.tar.gz\n' "$(awk '{print $1}' helm.sha256)" | sha256sum -c -)
  tar -xzf "$helm_tmp/helm.tar.gz" -C "$helm_tmp"
  install -m 755 "$helm_tmp/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "$helm_tmp"
fi
install -d /etc/mts-devops
if [[ ! -f /etc/kubernetes/admin.conf ]]; then
  echo "$KUBERNETES_VERSION" >"$marker"
  cat >/etc/mts-devops/kubeadm.yaml <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v${KUBERNETES_VERSION}
networking:
  podSubnet: 10.244.0.0/16
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
  kubeadm init --config /etc/mts-devops/kubeadm.yaml
fi
export KUBECONFIG=/etc/kubernetes/admin.conf
kubectl apply -f "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"
node_name=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}')
if [[ $(kubectl get node "$node_name" -o jsonpath='{.spec.taints[?(@.key=="node-role.kubernetes.io/control-plane")].key}') ]]; then
  kubectl taint node "$node_name" node-role.kubernetes.io/control-plane:NoSchedule-
fi
kubectl label node "$node_name" mts-devops/managed=true --overwrite
# The single control-plane node also serves external Gateway traffic.
if kubectl get node "$node_name" -o json | jq -e '.metadata.labels | has("node.kubernetes.io/exclude-from-external-load-balancers")' >/dev/null; then
  kubectl label node "$node_name" node.kubernetes.io/exclude-from-external-load-balancers-
fi
kubectl wait --for=condition=Ready node/"$node_name" --timeout=300s
kubectl -n kube-system rollout status deployment/coredns --timeout=300s
install -d -m 700 -o "$target_user" -g "$(id -gn "$target_user")" "$target_home/.kube"
install -m 600 -o "$target_user" -g "$(id -gn "$target_user")" /etc/kubernetes/admin.conf "$target_home/.kube/config"
install -d -m 750 /var/lib/mts-devops/logs /var/lib/mts-devops/fluentd
cat >/etc/logrotate.d/mts-devops <<'EOF'
/var/lib/mts-devops/logs/*.log {
  daily
  maxsize 10M
  rotate 7
  missingok
  notifempty
  compress
  delaycompress
  copytruncate
}
EOF
dpkg-query -W containerd kubeadm kubelet kubectl >/etc/mts-devops/packages.txt
echo 'Kubernetes is ready. Run ./deploy.sh as the invoking user.'
