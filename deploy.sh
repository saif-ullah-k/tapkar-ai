#!/usr/bin/env bash
# Deploy the TapKar AI backend to Cloud Run.
# Run this from the repo root.  Requires: gcloud CLI, authenticated user.
#
# Usage:
#   ./deploy.sh                # full deploy: enable APIs + build + deploy
#   ./deploy.sh --skip-apis    # skip API-enable step (faster re-deploys)
#   ./deploy.sh --skip-iam     # skip IAM grant (faster re-deploys)

set -euo pipefail

# Source local env so GOOGLE_MAPS_API_KEY, GEMINI_API_KEY etc. flow through.
if [ -f backend/.env ]; then
  set -a; . backend/.env; set +a
fi

# ─── Config ──────────────────────────────────────────────────────────────────
PROJECT="${GCP_PROJECT:-fcmapp-30770}"
REGION="${GCP_LOCATION:-us-central1}"
SERVICE="${SERVICE_NAME:-tapkar-ai-backend}"
REPO="${ARTIFACT_REPO:-cloud-run}"
IMAGE_TAG="${REGION}-docker.pkg.dev/${PROJECT}/${REPO}/${SERVICE}:latest"

SKIP_APIS=false
SKIP_IAM=false
for arg in "$@"; do
  case "$arg" in
    --skip-apis) SKIP_APIS=true ;;
    --skip-iam)  SKIP_IAM=true ;;
  esac
done

echo "═══════════════════════════════════════════════════════════════"
echo "  TapKar AI — Cloud Run deploy"
echo "  Project:  $PROJECT"
echo "  Region:   $REGION"
echo "  Service:  $SERVICE"
echo "  Image:    $IMAGE_TAG"
echo "═══════════════════════════════════════════════════════════════"

# ─── 1. Enable required APIs ─────────────────────────────────────────────────
if ! $SKIP_APIS; then
  echo ""
  echo "▸ Enabling APIs (artifactregistry, cloudbuild, run, aiplatform)..."
  gcloud services enable \
    artifactregistry.googleapis.com \
    cloudbuild.googleapis.com \
    run.googleapis.com \
    aiplatform.googleapis.com \
    texttospeech.googleapis.com \
    --project="$PROJECT"
fi

# ─── 2. Ensure Artifact Registry repo exists ────────────────────────────────
echo ""
echo "▸ Ensuring Artifact Registry repo '$REPO' in $REGION..."
gcloud artifacts repositories describe "$REPO" \
  --location="$REGION" --project="$PROJECT" >/dev/null 2>&1 || \
gcloud artifacts repositories create "$REPO" \
  --repository-format=docker \
  --location="$REGION" \
  --project="$PROJECT" \
  --description="TapKar AI container images"

# ─── 3. Grant Vertex AI access to the Cloud Run service account ─────────────
if ! $SKIP_IAM; then
  echo ""
  echo "▸ Granting roles/aiplatform.user to default Compute Engine SA..."
  PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')
  SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
  gcloud projects add-iam-policy-binding "$PROJECT" \
    --member="serviceAccount:${SA}" \
    --role=roles/aiplatform.user \
    --condition=None \
    --quiet >/dev/null
  echo "  ✓ ${SA}  has roles/aiplatform.user"
fi

# ─── 4. Build container via Cloud Build ─────────────────────────────────────
echo ""
echo "▸ Building image via Cloud Build (this may take 3–5 minutes)..."
gcloud builds submit . \
  --project="$PROJECT" \
  --tag="$IMAGE_TAG" \
  --timeout=20m

# ─── 5. Deploy to Cloud Run ─────────────────────────────────────────────────
echo ""
echo "▸ Deploying to Cloud Run..."
gcloud run deploy "$SERVICE" \
  --image="$IMAGE_TAG" \
  --project="$PROJECT" \
  --region="$REGION" \
  --platform=managed \
  --allow-unauthenticated \
  --memory=1Gi \
  --cpu=1 \
  --timeout=600 \
  --concurrency=10 \
  --max-instances=1 \
  --port=8080 \
  --set-env-vars="USE_VERTEX_AI=true,GCP_PROJECT=${PROJECT},GCP_LOCATION=${REGION},GEMINI_MODEL=gemini-2.5-flash-lite,GEMINI_FLASH_MODEL=gemini-2.5-flash-lite,MODEL_INTENT=gemini-2.5-flash-lite,MODEL_BOOKING=gemini-2.5-flash,MODEL_DISCOVERY=gemini-2.5-flash-lite,MODEL_RANKING=gemini-2.5-flash-lite,MODEL_FOLLOWUP=gemini-2.5-flash-lite,USE_REAL_PLACES=true,GOOGLE_MAPS_API_KEY=${GOOGLE_MAPS_API_KEY:-},USE_FIRESTORE=true,DEBUG_TRACES=true,RUN_TIMEOUT_MS=480000,AGENT_TIMEOUT_MS=120000,MAX_STEPS=8"

# ─── 6. Smoke test ───────────────────────────────────────────────────────────
URL=$(gcloud run services describe "$SERVICE" \
  --project="$PROJECT" \
  --region="$REGION" \
  --format='value(status.url)')

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  ✓ Deployed!"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "URL:  $URL"
echo ""
echo "Smoke test (paste in another shell):"
echo "  curl $URL/healthz"
echo ""
echo "Full pipeline test:"
echo "  curl -N -X POST $URL/run \\"
echo "    -H 'Content-Type: application/json' \\"
echo "    -d '{\"user_id\":\"u_demo\",\"user_input\":\"plumber Gulshan kal subah 9 baje\"}'"
echo ""
echo "Mobile app config — rebuild APK with:"
echo "  flutter build apk --release --dart-define=API_URL=$URL"
echo ""
