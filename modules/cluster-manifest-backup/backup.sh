#!/bin/sh
# Exports live Kubernetes API resources as YAML and uploads one archive per run.
#
# This reads through the API server, so it is independent of how many
# control-plane nodes exist and of which node the pod lands on. It is NOT an
# etcd backup: it captures API objects, not the etcd database itself.
set -eu

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

GENERATION="$(date -u +%Y%m%dT%H%M%SZ)"
EXPORT_DIR="$WORKDIR/$GENERATION"
mkdir -p "$EXPORT_DIR/cluster" "$EXPORT_DIR/namespaced"

mc alias set backup "$S3_ENDPOINT" "$S3_ACCESS_KEY" "$S3_SECRET_KEY"

# api-resources is the only reliable source of truth for what exists in this
# cluster: `kubectl get all` silently omits most types, including CRDs.
kubectl api-resources --verbs=list --namespaced=false -o name |
  sort -u |
  while read -r resource; do
    kubectl get "$resource" -o yaml > "$EXPORT_DIR/cluster/$resource.yaml" 2>/dev/null ||
      echo "skipped cluster-scoped $resource" >&2
  done

kubectl api-resources --verbs=list --namespaced=true -o name |
  sort -u |
  while read -r resource; do
    kubectl get "$resource" --all-namespaces -o yaml > "$EXPORT_DIR/namespaced/$resource.yaml" 2>/dev/null ||
      echo "skipped namespaced $resource" >&2
  done

# Fail instead of uploading an empty archive: an authentication or RBAC failure
# must not quietly replace real backups with useless ones.
if [ ! -s "$EXPORT_DIR/cluster/namespaces.yaml" ]; then
  echo "refusing to upload: namespaces export is empty, check RBAC" >&2
  exit 1
fi

ARCHIVE="$WORKDIR/$GENERATION.tar.gz"
tar -czf "$ARCHIVE" -C "$WORKDIR" "$GENERATION"
sha256sum "$ARCHIVE" | awk '{print $1}' > "$ARCHIVE.sha256"

mc cp "$ARCHIVE" "backup/$S3_BUCKET/$S3_PREFIX/$GENERATION.tar.gz"
mc cp "$ARCHIVE.sha256" "backup/$S3_BUCKET/$S3_PREFIX/$GENERATION.tar.gz.sha256"

# Pruning runs after a verified upload so a failed run never expires the
# generations that are still the newest good backup.
mc rm --recursive --force --older-than "${RETAIN_DAYS}d" \
  "backup/$S3_BUCKET/$S3_PREFIX/" || true

echo "uploaded $S3_PREFIX/$GENERATION.tar.gz"
