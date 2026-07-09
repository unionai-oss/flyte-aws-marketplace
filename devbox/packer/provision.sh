#!/bin/bash
# Bakes the Flyte devbox runtime into the AMI: Docker, AWS CLI v2, the idle-agent
# python venv, the product scripts + systemd units, and pre-pulled container
# images. Per-instance config (render.env, volume attach, service start) stays in
# the CloudFormation user-data — see cloudformation/flyte-devbox.yaml.
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

# Wait for cloud-init so we don't race the apt lock on first boot.
cloud-init status --wait || true

apt-get update -y
apt-get install -y ca-certificates curl gnupg python3-pip python3-venv jq unzip

# --- AWS CLI v2 ---
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip && ./aws/install && cd /

# --- Docker CE ---
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable docker
systemctl start docker

# --- Layout ---
mkdir -p /opt/flyte-idle-agent /opt/flyte-devbox \
         /etc/flyte-idle-agent /etc/flyte-devbox \
         /var/lib/flyte-idle-agent /var/lib/flyte-devbox-kube

# --- Idle-agent python venv (flyte + boto3) ---
python3 -m venv /opt/flyte-idle-agent/venv
/opt/flyte-idle-agent/venv/bin/pip install --quiet --upgrade pip
/opt/flyte-idle-agent/venv/bin/pip install --quiet flyte boto3

# --- Product scripts (baked; user-data renders configs from them at boot) ---
install -m 0755 /tmp/files/render-override.sh  /usr/local/bin/flyte-render-override.sh
install -m 0755 /tmp/files/render-appdomain.sh /usr/local/bin/flyte-render-appdomain.sh
install -m 0755 /tmp/files/gpu-setup.sh        /opt/flyte-devbox/gpu-setup.sh
install -m 0755 /tmp/files/idle-agent.py       /opt/flyte-idle-agent/flyte_idle_agent.py
# k3s auto-deploy manifest that turns on traefik access logging (idle signal).
install -m 0644 /tmp/files/traefik-accesslog.yaml /opt/flyte-devbox/traefik-accesslog.yaml

# --- ECR credential provider for the k3s kubelet (private-ECR app-image pulls) --
# EKS-standard mechanism: kubelet execs this binary, which mints short-lived ECR
# tokens from the instance role via IMDS (hop limit is 3, so it works from inside
# the devbox container). No stored secrets; tokens auto-rotate. The node role's
# ECR pull perms come from ProdBackendPolicy in the CloudFormation template.
ECR_CP_VERSION="v1.30.3"
mkdir -p /opt/ecr-cred
curl -fsSL "https://artifacts.k8s.io/binaries/cloud-provider-aws/${ECR_CP_VERSION}/linux/amd64/ecr-credential-provider-linux-amd64" \
  -o /opt/ecr-cred/ecr-credential-provider
chmod 0755 /opt/ecr-cred/ecr-credential-provider
cat > /opt/ecr-cred/config.yaml <<'ECRCFG'
apiVersion: kubelet.config.k8s.io/v1
kind: CredentialProviderConfig
providers:
- name: ecr-credential-provider
  matchImages:
  - "*.dkr.ecr.*.amazonaws.com"
  - "*.dkr.ecr.*.amazonaws.com.cn"
  defaultCacheDuration: "12h"
  apiVersion: credentialprovider.kubelet.k8s.io/v1
ECRCFG
# k3s reads /etc/rancher/k3s/config.yaml regardless of the image entrypoint;
# point the embedded kubelet at the credential provider. This file is mounted
# into the devbox container by the user-data `docker run`.
cat > /opt/flyte-devbox/k3s-config.yaml <<'K3SCFG'
kubelet-arg:
  - "image-credential-provider-config=/opt/ecr-cred/config.yaml"
  - "image-credential-provider-bin-dir=/opt/ecr-cred"
K3SCFG

# --- Systemd units (installed, NOT enabled — user-data writes the per-instance
#     EnvironmentFiles then `systemctl enable --now`; `enable` then persists
#     across the auto-stop/wake cycle). ---
install -m 0644 /tmp/files/systemd/flyte-idle-agent.service /etc/systemd/system/flyte-idle-agent.service
install -m 0644 /tmp/files/systemd/flyte-appdomain.service  /etc/systemd/system/flyte-appdomain.service
systemctl daemon-reload

# --- Pre-pull container images so first boot is fast / offline-tolerant ---
docker pull "$DEVBOX_IMAGE"

# --- Cleanup + AMI hygiene (Marketplace: regenerate per-instance identity) ---
rm -rf /tmp/files /tmp/awscliv2.zip /tmp/aws
apt-get clean
rm -rf /var/lib/apt/lists/*

# SSH host keys + machine-id cleared so every launched instance gets unique ones
# (cloud-init / systemd regenerate them on first boot).
rm -f /etc/ssh/ssh_host_*
: > /etc/machine-id
rm -f /var/lib/dbus/machine-id
# cloud-init re-runs on first boot to process the CloudFormation user-data.
cloud-init clean --logs --seed || true
# Drop build-time shell history + logs.
rm -f /root/.bash_history /home/ubuntu/.bash_history
find /var/log -type f -exec truncate -s 0 {} + 2>/dev/null || true

echo "Flyte devbox AMI provisioning complete: $(docker images --format '{{.Repository}}:{{.Tag}}' | tr '\n' ' ')"
