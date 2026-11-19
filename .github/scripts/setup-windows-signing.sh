#!/bin/bash
# Sets up Windows signing with Azure Artifact Signing for the GitHub Actions
# build.  Safe to rerun.
#
# - Finds the Artifact Signing account of the subscription, and its Public
#   Trust certificate profile (creating one from the identity validation if
#   there is none)
# - Creates an app registration that GitHub Actions logs in as, with a
#   federated credential for the 'windows-signing' environment (no secret)
# - Gives it the Certificate Profile Signer role on the profile
# - Creates the 'windows-signing' environment (master and v* tags only) and
#   its variables
#
# Usage: .github/scripts/setup-windows-signing.sh <subscription ID> \
#            [<identity validation ID>] [<owner/repo>]
#
# Needs: az (logged in with 'az login', owner of the subscription), gh (admin
# on the repo), python3

set -euo pipefail

SUBSCRIPTION="${1:?usage: $0 <subscription ID> [<identity validation ID>] [<owner/repo>]}"
VALIDATION_ID="${2:-}"
REPO="${3:-$(gh repo view --json nameWithOwner -q .nameWithOwner)}"
ENV_NAME=windows-signing
PROFILE_NAME=kynvpn
APP_NAME="GitHub $REPO signing"

json() { python3 -I -c "import json, sys; d = json.load(sys.stdin); print($1)"; }

az account set --subscription "$SUBSCRIPTION"
TENANT="$(az account show --query tenantId -o tsv)"
API="$(az provider show -n Microsoft.CodeSigning -o json |
    json '[sorted(t["apiVersions"], key=lambda v: ("preview" not in v, v))[-1] for t in d["resourceTypes"] if t["resourceType"] == "codeSigningAccounts"][0]')"
echo "Repository:   $REPO"
echo "Subscription: $SUBSCRIPTION (tenant $TENANT)"

# Artifact Signing account
ACCOUNTS="$(az resource list --resource-type Microsoft.CodeSigning/codeSigningAccounts --query '[].id' -o tsv)"
[ -n "$ACCOUNTS" ] || { echo "No Artifact Signing account in this subscription" >&2; exit 1; }
[ "$(wc -l <<<"$ACCOUNTS")" -eq 1 ] || { echo "Several Artifact Signing accounts, not sure which one to use:" >&2; echo "$ACCOUNTS" >&2; exit 1; }
ACCOUNT_ID="$ACCOUNTS"
ACCOUNT_JSON="$(az rest --method get --url "https://management.azure.com$ACCOUNT_ID?api-version=$API")"
ACCOUNT_NAME="$(json 'd["name"]' <<<"$ACCOUNT_JSON")"
ENDPOINT="$(json 'd["properties"]["accountUri"].rstrip("/")' <<<"$ACCOUNT_JSON")"
echo "Account:      $ACCOUNT_NAME ($ENDPOINT)"

# Certificate profile
PROFILES="$(az rest --method get --url "https://management.azure.com$ACCOUNT_ID/certificateProfiles?api-version=$API")"
PROFILE="$(json '" ".join(p["name"] for p in d["value"] if p["properties"].get("profileType") == "PublicTrust")' <<<"$PROFILES")"
if [ -z "$PROFILE" ]; then
    [ -n "$VALIDATION_ID" ] || { echo "No Public Trust certificate profile yet; pass the identity validation ID to create one" >&2; exit 1; }
    echo "Creating the '$PROFILE_NAME' certificate profile..."
    az rest --method put --url "https://management.azure.com$ACCOUNT_ID/certificateProfiles/$PROFILE_NAME?api-version=$API" \
        --body "{\"properties\": {\"profileType\": \"PublicTrust\", \"identityValidationId\": \"$VALIDATION_ID\"}}" >/dev/null
    PROFILE="$PROFILE_NAME"
    for _ in $(seq 60); do
        state="$(az rest --method get --url "https://management.azure.com$ACCOUNT_ID/certificateProfiles/$PROFILE?api-version=$API" |
            json 'd["properties"].get("provisioningState", "")')"
        [ "$state" = Succeeded ] && break
        [ "$state" = Failed ] && { echo "Creating the certificate profile failed" >&2; exit 1; }
        sleep 5
    done
    [ "$state" = Succeeded ] || { echo "The certificate profile is still being created ($state); rerun this later" >&2; exit 1; }
elif [[ "$PROFILE" == *" "* ]]; then
    echo "Several Public Trust certificate profiles, not sure which one to use: $PROFILE" >&2
    exit 1
fi
PROFILE_ID="$ACCOUNT_ID/certificateProfiles/$PROFILE"
echo "Profile:      $PROFILE"

# App registration GitHub Actions logs in as
APP_ID="$(az ad app list --display-name "$APP_NAME" --query '[0].appId' -o tsv)"
if [ -z "$APP_ID" ]; then
    echo "Creating the '$APP_NAME' app registration..."
    APP_ID="$(az ad app create --display-name "$APP_NAME" --sign-in-audience AzureADMyOrg --query appId -o tsv)"
fi
az ad sp show --id "$APP_ID" >/dev/null 2>&1 || az ad sp create --id "$APP_ID" >/dev/null
SUBJECT="repo:$REPO:environment:$ENV_NAME"
if ! az ad app federated-credential list --id "$APP_ID" --query '[].subject' -o tsv | grep -xF "$SUBJECT" >/dev/null; then
    echo "Adding the federated credential for $SUBJECT..."
    az ad app federated-credential create --id "$APP_ID" --parameters "{
        \"name\": \"github-$ENV_NAME\",
        \"issuer\": \"https://token.actions.githubusercontent.com\",
        \"subject\": \"$SUBJECT\",
        \"audiences\": [\"api://AzureADTokenExchange\"]
    }" >/dev/null
fi
echo "App:          $APP_NAME ($APP_ID)"

# Signer role (named "Trusted Signing ..." before the rename)
ROLE="$(az role definition list --query "[?ends_with(roleName, 'Certificate Profile Signer')].roleName | [0]" -o tsv)"
[ -n "$ROLE" ] || { echo "Can't find the Certificate Profile Signer role" >&2; exit 1; }
if [ -z "$(az role assignment list --assignee "$APP_ID" --scope "$PROFILE_ID" --role "$ROLE" --query '[0].id' -o tsv)" ]; then
    echo "Assigning '$ROLE'..."
    # The service principal can take a moment to show up
    for attempt in $(seq 10); do
        az role assignment create --assignee-object-id "$(az ad sp show --id "$APP_ID" --query id -o tsv)" \
            --assignee-principal-type ServicePrincipal --role "$ROLE" --scope "$PROFILE_ID" >/dev/null && break
        [ "$attempt" -lt 10 ] || exit 1
        sleep 10
    done
fi

# Environment limited to master and v* tags, and its variables
echo "Creating the '$ENV_NAME' environment..."
gh api -X PUT "repos/$REPO/environments/$ENV_NAME" --input - >/dev/null <<'EOF'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
existing="$(gh api "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
    -q '.branch_policies[] | "\(.type):\(.name)"')"
for policy in branch:master tag:v*; do
    if ! grep -qxF "$policy" <<<"$existing"; then
        gh api -X POST "repos/$REPO/environments/$ENV_NAME/deployment-branch-policies" \
            -f "type=${policy%%:*}" -f "name=${policy#*:}" >/dev/null
    fi
done
setvar() { gh variable set "$1" -R "$REPO" --env "$ENV_NAME" --body "$2"; }
setvar AZURE_CLIENT_ID "$APP_ID"
setvar AZURE_TENANT_ID "$TENANT"
setvar ARTIFACT_SIGNING_ENDPOINT "$ENDPOINT"
setvar ARTIFACT_SIGNING_ACCOUNT "$ACCOUNT_NAME"
setvar ARTIFACT_SIGNING_PROFILE "$PROFILE"
echo
echo "Done.  The next build of master or of a v* tag will be signed."
