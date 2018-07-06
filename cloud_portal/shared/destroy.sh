#!/usr/bin/env bash

# Exit immediately if a command exits with a non-zero status
# (but allow for the error trap)
set -eE

function report_err() {

  # post deployment log to slack channel (only if portal deployment)
  if [[ ! -n "$LOCAL_DEPLOYMENT" ]]; then

    # Debug OS-vars (skip secrets)
    env | grep OS_ | grep -v -e PASSWORD -e TOKEN -e OS_RC_FILE -e pass -e Pass -e PASS

    # Debug TF-vars (skip secrets)
    env | grep TF_VAR_ | grep -v -e PASSWORD -e TOKEN -e secret -e GOOGLE_CREDENTIALS -e aws_secret_access_key -e pass -e Pass -e PASS

    curl -F text="Portal deployment failed" \
	     -F channels="portal-deploy-error" \
	     -F token="$SLACK_ERR_REPORT_TOKEN" \
	     https://slack.com/api/chat.postMessage
  fi
}

function parse_and_export_vars() {
  input_file="$1"

  while IFS= read -r line; do
    [[ "$line" =~ ^export ]] || continue # skip non-export lines

    line=${line#export }        # remove "export " from start of line
    line=${line%%#*}            # strip comment (if any)

    case $line in
      *=*)
        var=${line%%=*}
        case $var in
            *[!A-Z_a-z]*)
                echo "Warning: invalid variable name $var ignored" >&2
                continue ;;
        esac

        line=${line#*=}
        line="${line%\"}"       # remove trailing "
        line="${line#\"}"       # remove starting "
        line="${line%\'}"       # remove trailing '
        line="${line#\'}"       # remove starting '
        echo eval export $var='"$line"'
        eval export $var='"$line"'
    esac
  done <"$input_file"
}

# Trap errors
trap report_err ERR

echo "Version: git-commit should be here"

# Destroy everything
cd "$PORTAL_DEPLOYMENTS_ROOT/$PORTAL_DEPLOYMENT_REFERENCE"

ansible_inventory_file="$PORTAL_DEPLOYMENTS_ROOT/$PORTAL_DEPLOYMENT_REFERENCE/inventory"

# read portal secrets from private repo
if [ -z "$LOCAL_DEPLOYMENT" ]; then
   if [ ! -d "$PORTAL_APP_REPO_FOLDER/phenomenal-cloudflare" ]; then
      git clone git@github.com:EMBL-EBI-TSI/phenomenal-cloudflare.git "$PORTAL_APP_REPO_FOLDER/phenomenal-cloudflare"
   fi
   source "$PORTAL_APP_REPO_FOLDER/phenomenal-cloudflare/cloudflare_token_phenomenal.cloud.sh"
   export SLACK_ERR_REPORT_TOKEN=$(cat "$PORTAL_APP_REPO_FOLDER/phenomenal-cloudflare/slacktoken")

   # Read preset rc-file from secrets repo if specified
   if [ -n "$OS_PRESET" ]; then
     OS_RC_FILE=$(cat "$PORTAL_APP_REPO_FOLDER/phenomenal-cloudflare/$OS_PRESET" | base64)
   fi
fi

# TODO read this from deploy.sh file
export TF_VAR_boot_image="kubenow-v052"
export TF_VAR_kubeadm_token="fake.token"
export TF_VAR_master_disk_size="20"
export TF_VAR_node_disk_size="20"
export TF_VAR_edge_disk_size="20"
export TF_VAR_glusternode_disk_size="20"
export TF_VAR_ssh_key="$PORTAL_DEPLOYMENTS_ROOT/$PORTAL_DEPLOYMENT_REFERENCE/vre.key.pub"

# workaround: -the credentials are provided as an environment variable, but KubeNow terraform scripts need a file.
if [ -n "$GOOGLE_CREDENTIALS" ]; then
  echo $GOOGLE_CREDENTIALS > "$PORTAL_DEPLOYMENTS_ROOT/$PORTAL_DEPLOYMENT_REFERENCE/gce_credentials_file.json"
  export TF_VAR_gce_credentials_file="$PORTAL_DEPLOYMENTS_ROOT/$PORTAL_DEPLOYMENT_REFERENCE/gce_credentials_file.json"
fi

# print env-var into file
if [ -n "$OS_RC_FILE" ]; then
  echo "$OS_RC_FILE" | base64 --decode > "$PORTAL_DEPLOYMENTS_ROOT/$PORTAL_DEPLOYMENT_REFERENCE/os-credentials.rc"
  parse_and_export_vars "$PORTAL_DEPLOYMENTS_ROOT/$PORTAL_DEPLOYMENT_REFERENCE/os-credentials.rc"
fi

# Add terraform to path (TODO) remove this portal workaround eventually
export PATH=/usr/lib/terraform_0.10.7:$PATH

KUBENOW_TERRAFORM_FOLDER="$PORTAL_APP_REPO_FOLDER/KubeNow/$PROVIDER"
terraform destroy -no-color --parallelism=50 --force --state="$PORTAL_DEPLOYMENTS_ROOT/$PORTAL_DEPLOYMENT_REFERENCE/terraform.tfstate" "$KUBENOW_TERRAFORM_FOLDER"

# remove the gce workaround file if it is there
rm -f "$PORTAL_DEPLOYMENTS_ROOT/$PORTAL_DEPLOYMENT_REFERENCE/gce_credentials_file.json"
