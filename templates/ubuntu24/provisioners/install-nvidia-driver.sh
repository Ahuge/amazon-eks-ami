#!/usr/bin/env bash

set -o pipefail
set -o nounset
set -o errexit

if [ "$ENABLE_ACCELERATOR" != "nvidia" ]; then
  exit 0
fi

#Detect Isolated partitions
function is-isolated-partition() {
  PARTITION=$(imds /latest/meta-data/services/partition)
  NON_ISOLATED_PARTITIONS=("aws" "aws-cn" "aws-us-gov")
  for NON_ISOLATED_PARTITION in "${NON_ISOLATED_PARTITIONS[@]}"; do
    if [ "${NON_ISOLATED_PARTITION}" = "${PARTITION}" ]; then
      return 1
    fi
  done
  return 0
}

function deb_install() {
  local DEBS
  read -ra DEBS <<< "$@"
  echo "Pulling and installing local debs from s3 bucket"
  for DEB in "${DEBS[@]}"; do
    aws s3 cp --region ${BINARY_BUCKET_REGION} s3://${BINARY_BUCKET_NAME}/debs/${DEB} ${WORKING_DIR}/${DEB}
    sudo apt install -y ${WORKING_DIR}/${DEB}
  done
}

echo "Installing NVIDIA ${NVIDIA_DRIVER_MAJOR_VERSION} drivers..."

################################################################################
### Add repository #############################################################
################################################################################
function get_cuda_ubuntu_repo() {
  if [[ $AWS_REGION == cn-* ]]; then
    DOMAIN="nvidia.cn"
  else
    DOMAIN="nvidia.com"
  fi
  echo "https://developer.download.${DOMAIN}/compute/cuda/repos/ubuntu2404/x86_64"
}

# Determine the domain based on the region
if is-isolated-partition; then
  deb_install "nvidia-driver-${NVIDIA_DRIVER_MAJOR_VERSION}*.deb"
else
  if [ -n "${NVIDIA_REPOSITORY:-}" ]; then
    REPO_URL="${NVIDIA_REPOSITORY}"
  else
    REPO_URL="$(get_cuda_ubuntu_repo)"
  fi

  # Add CUDA repository
  KEYRING="/usr/share/keyrings/cuda-keyring.gpg"
  sudo apt-get update
  sudo apt-get install -y curl
  curl -fsSL "${REPO_URL}/3bf863cc.pub" | sudo gpg --dearmor -o "${KEYRING}"
  echo "deb [signed-by=${KEYRING}] ${REPO_URL} /" | \
    sudo tee /etc/apt/sources.list.d/cuda.list
  sudo apt-get update
fi

################################################################################
### Install drivers ############################################################
################################################################################
sudo mv ${WORKING_DIR}/gpu/gpu-ami-util /usr/bin/
sudo mv ${WORKING_DIR}/gpu/kmod-util /usr/bin/

sudo mkdir -p /etc/dkms
echo "MAKE[0]=\"'make' -j$(nproc) module\"" | sudo tee /etc/dkms/nvidia.conf

# Kernel headers installation for Ubuntu
sudo apt install -y linux-headers-generic linux-modules-extra-$(uname -r)
sudo apt-mark hold linux-image-generic linux-headers-generic

# Install build dependencies
sudo apt install -y patch dkms build-essential

################################################################################
### Kernel Module Handling #####################################################
################################################################################
# Updated for Ubuntu package names and structure
function archive-open-kmods() {
  echo "Archiving open kmods"
  if is-isolated-partition; then
    deb_install "nvidia-open-dkms-${NVIDIA_DRIVER_MAJOR_VERSION}*.deb"
  else
    sudo apt install -y nvidia-open-dkms-${NVIDIA_DRIVER_MAJOR_VERSION}
  fi

  NVIDIA_OPEN_VERSION=$(kmod-util module-version nvidia)
  sudo dkms remove "nvidia/$NVIDIA_OPEN_VERSION" --all
  sudo sed -i 's/PACKAGE_NAME="nvidia"/PACKAGE_NAME="nvidia-open"/' /usr/src/nvidia-$NVIDIA_OPEN_VERSION/dkms.conf
  sudo mv /usr/src/nvidia-$NVIDIA_OPEN_VERSION /usr/src/nvidia-open-$NVIDIA_OPEN_VERSION
  sudo dkms add -m nvidia-open -v $NVIDIA_OPEN_VERSION
  sudo dkms build -m nvidia-open -v $NVIDIA_OPEN_VERSION
  sudo dkms install -m nvidia-open -v $NVIDIA_OPEN_VERSION

  sudo kmod-util archive nvidia-open

  # Copy the source files to a new directory for GRID driver installation
  sudo mkdir /usr/src/nvidia-open-grid-$NVIDIA_OPEN_VERSION
  sudo cp -R /usr/src/nvidia-open-$NVIDIA_OPEN_VERSION/* /usr/src/nvidia-open-grid-$NVIDIA_OPEN_VERSION

  KMOD_MAJOR_VERSION=$(sudo kmod-util module-version nvidia-open | cut -d. -f1)
  SUPPORTED_DEVICE_FILE="${WORKING_DIR}/gpu/nvidia-open-supported-devices-${KMOD_MAJOR_VERSION}.txt"
  sudo mv "${SUPPORTED_DEVICE_FILE}" /etc/eks/

  sudo kmod-util remove nvidia-open

  if is-isolated-partition; then
    sudo apt remove -y --purge nvidia-*${NVIDIA_DRIVER_MAJOR_VERSION}*
  else
    sudo apt remove -y --purge nvidia-open-dkms-${NVIDIA_DRIVER_MAJOR_VERSION}
  fi
}

function archive-grid-kmod() {
  [[ "$(uname -m)" != "x86_64" ]] && return

  echo "Archiving GRID kmods"
  NVIDIA_OPEN_VERSION=$(ls -d /usr/src/nvidia-open-grid-* | sed 's/.*nvidia-open-grid-//')
  sudo sed -i 's/PACKAGE_NAME="nvidia-open"/PACKAGE_NAME="nvidia-open-grid"/g' /usr/src/nvidia-open-grid-$NVIDIA_OPEN_VERSION/dkms.conf
  sudo sed -i "s/MAKE\[0\]=\"'make'/MAKE\[0\]=\"'make' GRID_BUILD=1 GRID_BUILD_CSP=1 /g" /usr/src/nvidia-open-grid-$NVIDIA_OPEN_VERSION/dkms.conf
  sudo dkms build -m nvidia-open-grid -v $NVIDIA_OPEN_VERSION
  sudo dkms install nvidia-open-grid/$NVIDIA_OPEN_VERSION

  sudo kmod-util archive nvidia-open-grid
  sudo kmod-util remove nvidia-open-grid
  sudo rm -rf /usr/src/nvidia-open-grid*
}

function archive-proprietary-kmod() {
  echo "Archiving proprietary kmods"
  if is-isolated-partition; then
    deb_install "nvidia-dkms-${NVIDIA_DRIVER_MAJOR_VERSION}*.deb"
  else
    sudo apt install -y nvidia-dkms-${NVIDIA_DRIVER_MAJOR_VERSION}
  fi
  sudo kmod-util archive nvidia
  sudo kmod-util remove nvidia
  sudo rm -rf /usr/src/nvidia*

  # Cleanup packages
  if is-isolated-partition; then
    sudo apt remove -y --purge nvidia-*${NVIDIA_DRIVER_MAJOR_VERSION}*
  else
    sudo apt remove -y --purge nvidia-dkms-${NVIDIA_DRIVER_MAJOR_VERSION}
  fi
}

archive-open-kmods
archive-grid-kmod
archive-proprietary-kmod

################################################################################
### Install NVLSM ##############################################################
################################################################################
if ! is-isolated-partition; then
  echo "ib_umad" | sudo tee -a /etc/modules-load.d/ib-umad.conf
  sudo apt install -y libibumad-dev infiniband-diags
fi

################################################################################
### Prepare for nvidia init ####################################################
################################################################################

sudo mv ${WORKING_DIR}/gpu/nvidia-kmod-load.sh /etc/eks/
sudo mv ${WORKING_DIR}/gpu/nvidia-kmod-load.service /etc/systemd/system/nvidia-kmod-load.service
sudo mv ${WORKING_DIR}/gpu/set-nvidia-clocks.service /etc/systemd/system/set-nvidia-clocks.service
sudo systemctl daemon-reload
sudo systemctl enable nvidia-kmod-load.service
sudo systemctl enable set-nvidia-clocks.service

################################################################################
### Install other dependencies #################################################
################################################################################
sudo apt install -y nvidia-fabricmanager-${NVIDIA_DRIVER_MAJOR_VERSION} \
                   nvidia-imex-${NVIDIA_DRIVER_MAJOR_VERSION} \
                   nvidia-container-toolkit

# Persistenced service
sudo apt install -y nvidia-persistenced
sudo systemctl enable nvidia-fabricmanager
sudo systemctl enable nvidia-persistenced