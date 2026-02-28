# Deploying to Google Cloud Platform

This app runs on **Cloud Run** (containerised Node.js) backed by **Cloud SQL for PostgreSQL**.
Deployments are automated via **Cloud Build** — every push to `main` builds and ships a new revision.

---

## Architecture

| Component | GCP service |
|---|---|
| Web server | Cloud Run (us-central1, min=0, max=1 instance) |
| Database | Cloud SQL for PostgreSQL 15 (db-f1-micro) |
| Secrets | Secret Manager |
| Container registry | Artifact Registry |
| CI/CD | Cloud Build trigger (push to `main`) |

---

## Prerequisites

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud` CLI) installed and authenticated
- Docker installed (for local testing only)
- Billing enabled on your GCP account

---

## One-Time Setup

### 1. Create a GCP project

```bash
gcloud projects create YOUR_PROJECT_ID --name="Kayla and Vaughn"
gcloud config set project YOUR_PROJECT_ID

# Link billing (required for Cloud Run and Cloud SQL)
# Do this via the console: https://console.cloud.google.com/billing
```

### 2. Enable required APIs

```bash
gcloud services enable \
  cloudbuild.googleapis.com \
  run.googleapis.com \
  artifactregistry.googleapis.com \
  sqladmin.googleapis.com \
  secretmanager.googleapis.com
```

### 3. Create Artifact Registry repository

```bash
gcloud artifacts repositories create wedding-app \
  --repository-format=docker \
  --location=us-central1 \
  --description="Wedding app container images"
```

### 4. Create Cloud SQL instance and database

```bash
# Create the instance (db-f1-micro = ~$8/mo, no public IP for security)
gcloud sql instances create wedding-db \
  --database-version=POSTGRES_15 \
  --tier=db-f1-micro \
  --region=us-central1 \
  --no-assign-ip \
  --storage-type=SSD \
  --storage-size=10GB

# Create the database
gcloud sql databases create wedding --instance=wedding-db

# Create the user (choose a strong password)
gcloud sql users create wedding_admin \
  --instance=wedding-db \
  --password=CHOOSE_A_STRONG_PASSWORD
```

### 5. Create secrets in Secret Manager

The app needs three secrets. Populate them as follows:

```bash
# Database URL — uses Unix socket (no SSL needed, no public IP required)
echo -n "postgresql://wedding_admin:CHOOSE_A_STRONG_PASSWORD@/wedding?host=/cloudsql/YOUR_PROJECT_ID:us-central1:wedding-db" \
  | gcloud secrets create database-url --data-file=-

# Session secret — long random string
openssl rand -hex 32 \
  | gcloud secrets create session-secret --data-file=-

# Dashboard admin password — what you'll type at /login
echo -n "YOUR_DASHBOARD_PASSWORD" \
  | gcloud secrets create dashboard-password --data-file=-
```

> **Rotating a secret:** `echo -n "NEW_VALUE" | gcloud secrets versions add SECRET_NAME --data-file=-`
> Cloud Run picks up `:latest` automatically on the next deploy.

### 6. Grant IAM permissions

```bash
PROJECT_ID=$(gcloud config get-value project)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')

CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
CLOUDRUN_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

# Cloud Build needs to deploy to Cloud Run and push to Artifact Registry
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${CLOUDBUILD_SA}" \
  --role="roles/run.admin"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${CLOUDBUILD_SA}" \
  --role="roles/artifactregistry.writer"

gcloud iam service-accounts add-iam-policy-binding \
  ${CLOUDRUN_SA} \
  --member="serviceAccount:${CLOUDBUILD_SA}" \
  --role="roles/iam.serviceAccountUser"

# Cloud Run needs to read secrets and connect to Cloud SQL
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${CLOUDRUN_SA}" \
  --role="roles/secretmanager.secretAccessor"

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:${CLOUDRUN_SA}" \
  --role="roles/cloudsql.client"
```

### 7. Connect GitHub and create a Cloud Build trigger

1. Open [Cloud Build → Triggers](https://console.cloud.google.com/cloud-build/triggers) in the console.
2. Click **Connect Repository** → select **GitHub** → authorise and pick this repo.
3. Click **Create Trigger** with these settings:
   - **Event:** Push to a branch
   - **Branch:** `^main$`
   - **Configuration:** Cloud Build configuration file → `cloudbuild.yaml`
   - **Substitution variables:**
     | Variable | Value |
     |---|---|
     | `_CLOUD_SQL_INSTANCE` | `YOUR_PROJECT_ID:us-central1:wedding-db` |

Now every push to `main` will build and deploy automatically.

---

## First (Manual) Deploy

After completing the setup steps, trigger the first build manually:

```bash
gcloud builds submit \
  --config cloudbuild.yaml \
  --substitutions _CLOUD_SQL_INSTANCE=YOUR_PROJECT_ID:us-central1:wedding-db \
  .
```

Once it completes, get the service URL:

```bash
gcloud run services describe kaylaandvaughn \
  --region=us-central1 \
  --format='value(status.url)'
```

Visit the URL and verify:
- `/` — wedding homepage loads with all photos
- `/api/rsvp` — accepts a test RSVP submission
- `/login` — dashboard login page works
- `/dashboard` — RSVP list visible after login
- `/api/rsvps/export.csv` — CSV download works

---

## Custom Domain (optional)

```bash
# Map your domain to the Cloud Run service
gcloud run domain-mappings create \
  --service=kaylaandvaughn \
  --domain=YOUR_DOMAIN.com \
  --region=us-central1
```

GCP will provide DNS records to add at your registrar. TLS is provisioned automatically.

---

## Local Testing with Docker

```bash
# Build the image
docker build -t kaylaandvaughn:local .

# Run with test credentials (no real DB needed for smoke-testing the container)
docker run --rm -p 3000:8080 \
  -e DATABASE_URL="postgresql://user:pass@host/wedding" \
  -e SESSION_SECRET="local-dev-secret" \
  -e DASHBOARD_PASSWORD="testpass" \
  kaylaandvaughn:local
```

Visit http://localhost:3000.

---

## Migrating Data from Render

If you have existing RSVPs on Render's PostgreSQL, export and import them:

```bash
# 1. Export from Render (run this with your Render DATABASE_URL)
pg_dump --no-owner --no-acl \
  "YOUR_RENDER_DATABASE_URL" \
  --table=rsvps \
  -f rsvps_backup.sql

# 2. Import into Cloud SQL via the Auth Proxy
# Install the proxy: https://cloud.google.com/sql/docs/postgres/connect-auth-proxy
cloud-sql-proxy YOUR_PROJECT_ID:us-central1:wedding-db &

psql "postgresql://wedding_admin:PASSWORD@localhost/wedding" \
  -f rsvps_backup.sql
```

---

## Estimated Monthly Cost

| Service | Config | Cost |
|---|---|---|
| Cloud Run | min=0, max=1, 256MB, low traffic | ~$0–2 |
| Cloud SQL | db-f1-micro, 10GB SSD | ~$8–9 |
| Artifact Registry | ~1GB images | ~$0.10 |
| Secret Manager | 3 secrets | ~$0.18 |
| Cloud Build | ~120 free mins/day | ~$0 |
| **Total** | | **~$8–12/mo** |

> The Cloud SQL instance is the main cost driver. If cost is a concern, consider pausing the instance between events or using the [Neon serverless PostgreSQL](https://neon.tech) free tier with a `DATABASE_URL` connection string — no other changes to the app are needed.
