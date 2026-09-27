#!/bin/sh
# Manual recovery entrypoint. The Job that runs this script is created suspended
# and must be explicitly unsuspended by an operator.
set -eu

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

mc alias set backup "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY"
ARCHIVE_PATH="${BACKUP_OBJECT:-$(mc find "backup/$S3_BUCKET/$S3_PREFIX/" --name '*.tar.gz' | sort | tail -n 1)}"
if [ -z "$ARCHIVE_PATH" ]; then
  echo "no backup archive found" >&2
  exit 1
fi

mc cp "$ARCHIVE_PATH" "$WORKDIR/backup.tar.gz"
mc cp "$ARCHIVE_PATH.sha256" "$WORKDIR/backup.tar.gz.sha256"
EXPECTED="$(cat "$WORKDIR/backup.tar.gz.sha256")"
echo "$EXPECTED  $WORKDIR/backup.tar.gz" | sha256sum -c -
tar -xzf "$WORKDIR/backup.tar.gz" -C "$WORKDIR"
EXPORT_DIR="$(find "$WORKDIR" -mindepth 1 -maxdepth 1 -type d | head -n 1)"

# Establish API extensions and namespaces before their dependent objects.
if [ -f "$EXPORT_DIR/cluster/customresourcedefinitions.apiextensions.k8s.io.yaml" ]; then
  kubectl apply -f "$EXPORT_DIR/cluster/customresourcedefinitions.apiextensions.k8s.io.yaml"
fi
if [ -f "$EXPORT_DIR/cluster/namespaces.yaml" ]; then
  kubectl apply -f "$EXPORT_DIR/cluster/namespaces.yaml"
fi
kubectl apply -f "$EXPORT_DIR/cluster"
kubectl apply -f "$EXPORT_DIR/namespaced"

echo "restored $ARCHIVE_PATH"
