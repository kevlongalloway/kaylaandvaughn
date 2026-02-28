#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# setup-gcp.sh — One-command GCP deployment for kaylaandvaughn
#
# What this script does:
#   1. Enables required GCP APIs
#   2. Creates a Cloud SQL (PostgreSQL) instance + database + user
#   3. Stores secrets in Secret Manager
#   4. Builds & pushes the Docker image to Container Registry
#   5. Deploys to Cloud Run
#
# Prerequisites:
#   - gcloud CLI installed and authenticated: https://cloud.google.com/sdk/docs/install
#   - Run: gcloud auth login && gcloud auth configure-docker
#   - Docker installed (for local build) OR just use Cloud Build (set USE_CLOUD_BUILD=true)
#
# Usage:
#   chmod +x setup-gcp.sh
#   ./setup-gcp.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${BLUE}ℹ ${RESET}$*"; }
success() { echo -e "${GREEN}✓ ${RESET}$*"; }
warn()    { echo -e "${YELLOW}⚠ ${RESET}$*"; }
error()   { echo -e "${RED}✗ ${RESET}$*" >&2; exit 1; }
step()    { echo -e "\n${BOLD}━━━ $* ━━━${RESET}"; }

# ── Config (edit these or export them before running) ────────────────────────
APP_NAME="${APP_NAME:-kaylaandvaughn}"
REGION="${REGION:-us-central1}"
DB_INSTANCE="${DB_INSTANCE:-kaylaandvaughn-db}"
DB_NAME="${DB_NAME:-wedding}"
DB_USER="${DB_USER:-wedding_admin}"
USE_CLOUD_BUILD="${USE_CLOUD_BUILD:-false}"   # set to "true" to build in the cloud

# ── Check prerequisites ───────────────────────────────────────────────────────
step "Checking prerequisites"

command -v gcloud &>/dev/null || error "gcloud CLI not found. Install it: https://cloud.google.com/sdk/docs/install"

if [ "$USE_CLOUD_BUILD" = "false" ]; then
  command -v docker &>/dev/null || {
    warn "Docker not found. Switching to Cloud Build."
    USE_CLOUD_BUILD=true
  }
fi

# ── Project ──────────────────────────────────────────────────────────────────
step "GCP Project"

if [ -z "${PROJECT_ID:-}" ]; then
  CURRENT=$(gcloud config get-value project 2>/dev/null || true)
  if [ -n "$CURRENT" ]; then
    read -rp "Use project '$CURRENT'? [Y/n]: " ans
    ans="${ans:-Y}"
    if [[ "$ans" =~ ^[Yy] ]]; then
      PROJECT_ID="$CURRENT"
    fi
  fi
fi

if [ -z "${PROJECT_ID:-}" ]; then
  read -rp "Enter your GCP project ID: " PROJECT_ID
  [ -z "$PROJECT_ID" ] && error "Project ID required."
fi

gcloud config set project "$PROJECT_ID" --quiet
success "Project: $PROJECT_ID"

# ── Enable APIs ───────────────────────────────────────────────────────────────
step "Enabling GCP APIs (this may take ~60 seconds)"

gcloud services enable \
  run.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com \
  cloudbuild.googleapis.com \
  containerregistry.googleapis.com \
  --quiet

success "APIs enabled"

# ── Cloud SQL ─────────────────────────────────────────────────────────────────
step "Cloud SQL PostgreSQL"

EXISTING=$(gcloud sql instances list --filter="name=$DB_INSTANCE" --format="value(name)" 2>/dev/null || true)

if [ -z "$EXISTING" ]; then
  info "Creating Cloud SQL instance '$DB_INSTANCE' in $REGION..."
  info "This takes 3-5 minutes — grab a coffee ☕"

  gcloud sql instances create "$DB_INSTANCE" \
    --database-version=POSTGRES_15 \
    --tier=db-f1-micro \
    --region="$REGION" \
    --storage-type=SSD \
    --storage-size=10GB \
    --storage-auto-increase \
    --no-backup \
    --quiet

  success "Cloud SQL instance created"
else
  success "Cloud SQL instance '$DB_INSTANCE' already exists — skipping"
fi

# Create database
DB_EXISTS=$(gcloud sql databases list --instance="$DB_INSTANCE" --filter="name=$DB_NAME" --format="value(name)" 2>/dev/null || true)
if [ -z "$DB_EXISTS" ]; then
  gcloud sql databases create "$DB_NAME" --instance="$DB_INSTANCE" --quiet
  success "Database '$DB_NAME' created"
else
  success "Database '$DB_NAME' already exists — skipping"
fi

# Create user + generate password
USER_EXISTS=$(gcloud sql users list --instance="$DB_INSTANCE" --filter="name=$DB_USER" --format="value(name)" 2>/dev/null || true)
if [ -z "$USER_EXISTS" ]; then
  DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=')
  gcloud sql users create "$DB_USER" \
    --instance="$DB_INSTANCE" \
    --password="$DB_PASSWORD" \
    --quiet
  success "Database user '$DB_USER' created"
else
  warn "User '$DB_USER' already exists."
  read -rsp "Enter existing password for '$DB_USER': " DB_PASSWORD
  echo
fi

CONNECTION_NAME="$PROJECT_ID:$REGION:$DB_INSTANCE"
DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@/${DB_NAME}?host=/cloudsql/${CONNECTION_NAME}"
success "Database connection configured"

# ── Secrets ──────────────────────────────────────────────────────────────────
step "Secret Manager"

create_or_update_secret() {
  local name="$1"
  local value="$2"
  if gcloud secrets describe "$name" --quiet &>/dev/null; then
    echo -n "$value" | gcloud secrets versions add "$name" --data-file=- --quiet
    success "Secret '$name' updated"
  else
    echo -n "$value" | gcloud secrets create "$name" --data-file=- --quiet
    success "Secret '$name' created"
  fi
}

create_or_update_secret "DATABASE_URL" "$DATABASE_URL"

SESSION_SECRET=$(openssl rand -hex 32)
create_or_update_secret "SESSION_SECRET" "$SESSION_SECRET"

read -rsp "Enter your dashboard password (what you'll type to log in to /dashboard): " DASHBOARD_PASSWORD
echo
[ -z "$DASHBOARD_PASSWORD" ] && error "Dashboard password cannot be empty."
create_or_update_secret "DASHBOARD_PASSWORD" "$DASHBOARD_PASSWORD"

# ── Grant Cloud Run SA access to secrets ─────────────────────────────────────
step "IAM — Secret Manager access"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
CLOUD_RUN_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

for secret in DATABASE_URL SESSION_SECRET DASHBOARD_PASSWORD; do
  gcloud secrets add-iam-policy-binding "$secret" \
    --member="serviceAccount:${CLOUD_RUN_SA}" \
    --role="roles/secretmanager.secretAccessor" \
    --quiet
done

# Grant Cloud Run SA access to Cloud SQL
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${CLOUD_RUN_SA}" \
  --role="roles/cloudsql.client" \
  --quiet

success "IAM policies set"

# ── Build & push Docker image ─────────────────────────────────────────────────
step "Building Docker image"

IMAGE="gcr.io/${PROJECT_ID}/${APP_NAME}:latest"

if [ "$USE_CLOUD_BUILD" = "true" ]; then
  info "Building with Cloud Build (no local Docker required)..."
  gcloud builds submit \
    --tag "$IMAGE" \
    --quiet \
    .
else
  info "Building locally with Docker..."
  docker build -t "$IMAGE" .
  gcloud auth configure-docker --quiet
  docker push "$IMAGE"
fi

success "Image pushed: $IMAGE"

# ── Deploy to Cloud Run ───────────────────────────────────────────────────────
step "Deploying to Cloud Run"

gcloud run deploy "$APP_NAME" \
  --image="$IMAGE" \
  --region="$REGION" \
  --platform=managed \
  --allow-unauthenticated \
  --add-cloudsql-instances="$CONNECTION_NAME" \
  --update-secrets="DATABASE_URL=DATABASE_URL:latest,SESSION_SECRET=SESSION_SECRET:latest,DASHBOARD_PASSWORD=DASHBOARD_PASSWORD:latest" \
  --set-env-vars="NODE_ENV=production" \
  --min-instances=0 \
  --max-instances=10 \
  --memory=256Mi \
  --cpu=1 \
  --timeout=60 \
  --concurrency=100 \
  --quiet

SERVICE_URL=$(gcloud run services describe "$APP_NAME" \
  --region="$REGION" \
  --format="value(status.url)")

# ── Done ─────────────────────────────────────────────────────────────────────
echo
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════╗${RESET}"
echo -e "${GREEN}${BOLD}║  ✨ Deployment complete!                      ║${RESET}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════╝${RESET}"
echo
echo -e "  ${BOLD}Website:${RESET}   $SERVICE_URL"
echo -e "  ${BOLD}Dashboard:${RESET} $SERVICE_URL/dashboard"
echo -e "  ${BOLD}Login:${RESET}     $SERVICE_URL/login"
echo
echo -e "${YELLOW}Next steps (optional):${RESET}"
echo "  • Add a custom domain:"
echo "    gcloud run domain-mappings create --service=$APP_NAME --domain=yourdomain.com --region=$REGION"
echo
echo "  • Set up auto-deploy on git push:"
echo "    Connect this repo at https://console.cloud.google.com/cloud-build/triggers"
echo "    (the cloudbuild.yaml is already configured)"
echo
echo -e "${YELLOW}Estimated monthly cost:${RESET}"
echo "  • Cloud Run:  free for low traffic (2M req/month free)"
echo "  • Cloud SQL:  ~\$7-10/month (db-f1-micro)"
echo "  • Total:      ~\$7-10/month at current scale"
echo
