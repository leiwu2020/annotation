#!/bin/bash
set -e

APP_NAME="annotation-app"
TARBALL="${APP_NAME}-$(date +%Y%m%d_%H%M%S).tar.gz"

echo "Packaging app files into $TARBALL..."

tar --exclude='__pycache__' \
    --exclude='*.pyc' \
    --exclude='*.tar.gz' \
    -czvf "$TARBALL" \
    app.py requirements.txt users.db \
    templates static uploads \
    instance

echo "Done. Tarball created: $TARBALL"