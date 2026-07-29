# gltf-renderer/Dockerfile
#
# The Debian release is pinned, not just the Python version. `python:3.10-slim`
# floats onto whatever Debian is current, and that moved to trixie -- which
# dropped libgl1-mesa-glx entirely, so every build of this image started failing
# with "no installation candidate" for a Dockerfile nobody had touched. The pip
# pins below already carry a comment about unpinned inputs breaking builds on
# somebody else's release schedule; the base image is the same hazard.
#
# Staying on bookworm rather than moving to trixie: trixie also carries the
# 64-bit time_t transition, which renames libglib2.0-0 to libglib2.0-0t64 and
# similar across the graph. Chasing those renames buys nothing here.
FROM python:3.10-slim-bookworm

# Install system dependencies.
#
# libgl1 + libglx-mesa0 replace libgl1-mesa-glx, which was a transitional
# package removed after bullseye. libgl1 provides libGL.so.1 and libglx-mesa0
# provides the Mesa GLX driver -- together they are what that one name used to
# pull in. pyrender reaches OpenGL through GLX on the Xvfb display that
# entrypoint.sh starts, so both halves are needed.
RUN apt-get update && apt-get install -y \
  libgl1 \
  libglx-mesa0 \
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
#
# pygltflib is deliberately absent: the validator reads the glTF JSON through
# gltf_document, the same stdlib loader the local CLI and the git hooks use, so
# that a verdict reached in this image and a verdict reached on a laptop cannot
# drift. jsonschema is here to check .spec.yaml files against
# schemas/model-spec.schema.json.
RUN pip install --no-cache-dir \
  numpy==1.26.4 \
  trimesh==4.4.9 \
  pyrender==0.1.45 \
  pillow==11.2.1 \
  pyyaml==6.0.2 \
  jsonschema==4.23.0

# Create app directory
WORKDIR /app

# Copy the render script and any local modules.
# Every module validate_gltf.py imports has to be listed here -- a missing COPY
# is an ImportError that only shows up once the image is pulled in CI.
COPY validate_gltf.py /app/
COPY spec_image_tools.py /app/
COPY gltf_axes.py /app/
COPY gltf_transforms.py /app/
COPY gltf_document.py /app/
COPY gltf_measure.py /app/
COPY model_spec.py /app/
COPY entrypoint.sh /app/
RUN chmod +x /app/entrypoint.sh

# Set the entrypoint to the script that starts Xvfb and then runs the validator
ENTRYPOINT ["/app/entrypoint.sh"]