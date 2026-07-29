#!/bin/bash
cd /opt/svc-inference
source venv/bin/activate
export USE_MOCK=0
export SVC_BASE_DIR=/opt/svc-inference
export PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True
exec python3 server.py
