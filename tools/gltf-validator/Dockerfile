# gltf-renderer/Dockerfile
FROM python:3.10-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
  libgl1-mesa-glx \
  libgl1-mesa-dri \
  xvfb \
  libosmesa6 \
  mesa-utils \
  libglib2.0-0 \
  libsm6 \
  libxext6 \
  libxrender-dev \
  && rm -rf /var/lib/apt/lists/*

# Set up a virtual display
ENV DISPLAY=:99

# Install Python dependencies.
# Pinned deliberately: an unpinned build silently changes validation output the
# next time any of these publishes a release, which shows up as a mystery CI
# failure on an unrelated PR.
# numpy is held below 2.0 because pyrender still uses the numpy 1.x C API.
RUN pip install --no-cache-dir \
  numpy==1.26.4 \
  pygltflib==1.16.2 \
  trimesh==4.4.9 \
  pyrender==0.1.45 \
  pillow==11.2.1 \
  pyyaml==6.0.2

# Create app directory
WORKDIR /app

# Copy the render script and any local modules
COPY validate_gltf.py /app/
COPY spec_image_tools.py /app/
COPY gltf_axes.py /app/
COPY gltf_transforms.py /app/
COPY entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

# Set the entrypoint to the script that starts Xvfb and then runs the validator
ENTRYPOINT ["/app/entrypoint.sh"]