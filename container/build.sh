#!/bin/bash
# Script to run udocker as non-root in Google Colab

# Create non-root user if needed
if ! id -u colab &>/dev/null; then
    useradd -m colab
    # Add to sudoers without password
    echo "colab ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/colab
fi

# Install udocker for the non-root user
su - colab -c "pip install udocker"
su - colab -c "udocker install"

# Copy current directory to colab user's home
src_dir="$(pwd)"
cp -r "$src_dir" /home/colab/
chown -R colab:colab /home/colab/$(basename "$src_dir")

# Create working script
cat > /home/colab/udocker_build.sh << 'EOF'
#!/bin/bash
set -e

# Base image selection
FRAMEWORK="VLLM"  # Default framework

# Base Images
VLLM_BASE_IMAGE="nvcr.io/nvidia/cuda-dl-base"
VLLM_BASE_IMAGE_TAG="25.01-cuda12.8-devel-ubuntu24.04"
TENSORRTLLM_BASE_IMAGE="tensorrt_llm/release"
TENSORRTLLM_BASE_IMAGE_TAG="latest"
NONE_BASE_IMAGE="ubuntu"
NONE_BASE_IMAGE_TAG="24.04"

# Parse command line options
while [[ $# -gt 0 ]]; do
  key="$1"
  case $key in
    --framework)
      FRAMEWORK="$2"
      shift 2
      ;;
    --tag)
      TAG="$2"
      shift 2
      ;;
    --base-image)
      BASE_IMAGE="$2"
      shift 2
      ;;
    --base-image-tag)
      BASE_IMAGE_TAG="$2"
      shift 2
      ;;
    *)
      # Just skip unknown options
      shift
      ;;
  esac
done

# Convert framework to uppercase
FRAMEWORK=${FRAMEWORK^^}

# Set base image based on framework
if [[ $FRAMEWORK == "VLLM" ]]; then
    BASE_IMAGE=${BASE_IMAGE:-$VLLM_BASE_IMAGE}
    BASE_IMAGE_TAG=${BASE_IMAGE_TAG:-$VLLM_BASE_IMAGE_TAG}
elif [[ $FRAMEWORK == "TENSORRTLLM" ]]; then
    BASE_IMAGE=${BASE_IMAGE:-$TENSORRTLLM_BASE_IMAGE}
    BASE_IMAGE_TAG=${BASE_IMAGE_TAG:-$TENSORRTLLM_BASE_IMAGE_TAG}
elif [[ $FRAMEWORK == "NONE" ]]; then
    BASE_IMAGE=${BASE_IMAGE:-$NONE_BASE_IMAGE}
    BASE_IMAGE_TAG=${BASE_IMAGE_TAG:-$NONE_BASE_IMAGE_TAG}
else
    echo "Unknown framework: $FRAMEWORK"
    echo "Supported frameworks: VLLM, TENSORRTLLM, NONE"
    exit 1
fi

# Set default tag if not provided
TAG=${TAG:-"dynamo-${FRAMEWORK,,}"}
CONTAINER_NAME="${TAG//:/-}-container"

echo "Using framework: $FRAMEWORK"
echo "Base image: $BASE_IMAGE:$BASE_IMAGE_TAG"
echo "Container name: $CONTAINER_NAME"

# Pull the base image
echo "Pulling base image..."
udocker pull "$BASE_IMAGE:$BASE_IMAGE_TAG"

# Create a container from the base image
echo "Creating container..."
udocker create --name="$CONTAINER_NAME" "$BASE_IMAGE:$BASE_IMAGE_TAG"

# Prepare installation script for the container
INSTALL_SCRIPT=$(mktemp)
cat > "$INSTALL_SCRIPT" << 'INNEREOF'
#!/bin/bash
set -e

# Install system dependencies
apt-get update && apt-get install -y \
    git \
    curl \
    python3-pip \
    python3-dev

# Create dynamo directory
mkdir -p /opt/dynamo

# Install Python dependencies based on framework
if [[ "$FRAMEWORK" == "VLLM" ]]; then
    pip3 install torch transformers vllm
elif [[ "$FRAMEWORK" == "TENSORRTLLM" ]]; then
    pip3 install torch transformers
elif [[ "$FRAMEWORK" == "NONE" ]]; then
    pip3 install transformers
fi

# Install common Python dependencies
pip3 install pydantic fastapi uvicorn

echo "Installation completed for $FRAMEWORK framework"
INNEREOF

# Make script executable
chmod +x "$INSTALL_SCRIPT"

# Copy the script to the container
echo "Copying installation script to container..."
udocker cp "$INSTALL_SCRIPT" "$CONTAINER_NAME:/tmp/install.sh"

# Set environment variable for framework
udocker setup --execmode=F3 "$CONTAINER_NAME"

# Run the installation script
echo "Running installation script in container..."
udocker run --env="FRAMEWORK=$FRAMEWORK" "$CONTAINER_NAME" /bin/bash /tmp/install.sh

echo "==================================================="
echo "Container '$CONTAINER_NAME' is ready!"
echo ""
echo "To run the container:"
echo "  udocker run $CONTAINER_NAME"
echo ""
echo "To execute commands in the container:"
echo "  udocker run $CONTAINER_NAME <command>"
echo ""
echo "Example: udocker run $CONTAINER_NAME python3 -c 'print(\"Hello from Dynamo!\")"
echo "==================================================="
EOF

# Make it executable
chmod +x /home/colab/udocker_build.sh

# Run the script as colab user
echo "Running udocker as non-root user..."
su - colab -c "/home/colab/udocker_build.sh $*"
