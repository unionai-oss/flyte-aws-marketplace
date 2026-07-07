#!/bin/bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
# NVIDIA driver (DKMS; builds against the running kernel).
apt-get update
apt-get install -y ubuntu-drivers-common
ubuntu-drivers install --gpgpu || apt-get install -y nvidia-driver-550-server || true
# nvidia-container-toolkit (configures the docker runtime for --gpus all)
install -d -m 0755 /usr/share/keyrings
curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
  | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update
apt-get install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker
modprobe nvidia || true
