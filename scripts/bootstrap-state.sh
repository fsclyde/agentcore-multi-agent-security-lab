#!/usr/bin/env bash
# Create an encrypted, versioned, private S3 bucket and a KMS key for the Terraform state.
# Usage: AWS_REGION=eu-west-1 ./scripts/bootstrap-state.sh
set -euo pipefail

REGION="${AWS_REGION:-eu-west-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="acsl-tfstate-${ACCOUNT}"

KEY_ID="$(aws kms create-key --region "$REGION" --description "acsl Terraform state" \
  --query KeyMetadata.KeyId --output text)"
aws kms enable-key-rotation --region "$REGION" --key-id "$KEY_ID"
aws kms create-alias --region "$REGION" --alias-name alias/acsl-tfstate --target-key-id "$KEY_ID"

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled
aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
  "{\"Rules\":[{\"ApplyServerSideEncryptionByDefault\":{\"SSEAlgorithm\":\"aws:kms\",\"KMSMasterKeyID\":\"$KEY_ID\"},\"BucketKeyEnabled\":true}]}"
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-policy --bucket "$BUCKET" --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"HttpsOnly\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"],\"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}}]}"

sed -e "s/<ACCOUNT_ID>/${ACCOUNT}/" -e "s/eu-west-1/${REGION}/" infra/backend.tf.example > infra/backend.tf
echo "Bucket ${BUCKET} ready, infra/backend.tf written. Next: terraform -chdir=infra init"
