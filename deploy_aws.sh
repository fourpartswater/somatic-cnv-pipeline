#!/bin/bash
# Deploy script for AWS
# Usage: ./deploy_aws.sh [environment] [region]
# 
# Note: This assumes you have AWS CLI configured already

set -euo pipefail  # exit on errors

# Configuration
ENVIRONMENT="${1:-dev}"
AWS_REGION="${2:-us-east-1}"
PIPELINE_NAME="somatic-cnv-pipeline"
STACK_NAME="${PIPELINE_NAME}-${ENVIRONMENT}"

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Deploying ${PIPELINE_NAME} to AWS ${ENVIRONMENT} environment${NC}"
echo "Region: ${AWS_REGION}"
echo "Stack: ${STACK_NAME}"

# Check prerequisites
check_prerequisites() {
    echo -e "\n${YELLOW}Checking prerequisites...${NC}"
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        echo -e "${RED}ERROR: AWS CLI not found. Please install it first.${NC}"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        echo -e "${RED}ERROR: AWS credentials not configured.${NC}"
        exit 1
    fi
    
    # Check jq for JSON parsing
    if ! command -v jq &> /dev/null; then
        echo -e "${RED}ERROR: jq not found. Please install it first.${NC}"
        exit 1
    fi
    
    echo -e "${GREEN}All prerequisites met${NC}"
}

# Create S3 buckets
create_s3_buckets() {
    echo -e "\n${YELLOW}Creating S3 buckets...${NC}"
    
    BUCKETS=(
        "${PIPELINE_NAME}-${ENVIRONMENT}-inputs"
        "${PIPELINE_NAME}-${ENVIRONMENT}-outputs"
        "${PIPELINE_NAME}-${ENVIRONMENT}-work"
        "${PIPELINE_NAME}-${ENVIRONMENT}-references"
    )
    
    for bucket in "${BUCKETS[@]}"; do
        if aws s3 ls "s3://${bucket}" 2>&1 | grep -q 'NoSuchBucket'; then
            echo "Creating bucket: ${bucket}"
            aws s3 mb "s3://${bucket}" --region "${AWS_REGION}"
            
            # Enable versioning for outputs
            if [[ "${bucket}" == *"outputs"* ]]; then
                aws s3api put-bucket-versioning \
                    --bucket "${bucket}" \
                    --versioning-configuration Status=Enabled
            fi
            
            # Configure lifecycle for work directory
            if [[ "${bucket}" == *"work"* ]]; then
                cat > lifecycle.json <<EOF
{
    "Rules": [{
        "Id": "DeleteOldWorkFiles",
        "Status": "Enabled",
        "Prefix": "",
        "Expiration": {
            "Days": 7
        }
    }]
}
EOF
                aws s3api put-bucket-lifecycle-configuration \
                    --bucket "${bucket}" \
                    --lifecycle-configuration file://lifecycle.json
                rm lifecycle.json
            fi
        else
            echo "Bucket already exists: ${bucket}"
        fi
    done
    
    echo -e "${GREEN}S3 buckets ready${NC}"
}

# Create Batch compute environment
create_batch_environment() {
    echo -e "\n${YELLOW}Creating AWS Batch environment...${NC}"
    
    # Create IAM role for Batch
    BATCH_ROLE_NAME="${PIPELINE_NAME}-${ENVIRONMENT}-batch-role"
    
    # Check if role exists
    if ! aws iam get-role --role-name "${BATCH_ROLE_NAME}" 2>/dev/null; then
        echo "Creating IAM role: ${BATCH_ROLE_NAME}"
        
        # Create trust policy
        cat > trust-policy.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Principal": {
            "Service": ["batch.amazonaws.com", "ec2.amazonaws.com"]
        },
        "Action": "sts:AssumeRole"
    }]
}
EOF
        
        aws iam create-role \
            --role-name "${BATCH_ROLE_NAME}" \
            --assume-role-policy-document file://trust-policy.json
        
        # Attach policies
        aws iam attach-role-policy \
            --role-name "${BATCH_ROLE_NAME}" \
            --policy-arn arn:aws:iam::aws:policy/service-role/AWSBatchServiceRole
        
        aws iam attach-role-policy \
            --role-name "${BATCH_ROLE_NAME}" \
            --policy-arn arn:aws:iam::aws:policy/AmazonS3FullAccess
        
        rm trust-policy.json
    fi
    
    # Get default VPC and subnets
    VPC_ID=$(aws ec2 describe-vpcs --filters "Name=isDefault,Values=true" --query "Vpcs[0].VpcId" --output text)
    SUBNET_IDS=$(aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query "Subnets[*].SubnetId" --output text | tr '\t' ',')
    
    # Create compute environment
    CE_NAME="${PIPELINE_NAME}-${ENVIRONMENT}-compute-env"
    
    if ! aws batch describe-compute-environments --compute-environments "${CE_NAME}" --query "computeEnvironments[0]" 2>/dev/null | grep -q "${CE_NAME}"; then
        echo "Creating compute environment: ${CE_NAME}"
        
        aws batch create-compute-environment \
            --compute-environment-name "${CE_NAME}" \
            --type MANAGED \
            --state ENABLED \
            --compute-resources '{
                "type": "EC2",
                "minvCpus": 0,
                "maxvCpus": 256,
                "desiredvCpus": 0,
                "instanceTypes": ["optimal"],
                "subnets": ["'"${SUBNET_IDS//,/\",\"}"'"],
                "instanceRole": "arn:aws:iam::'$(aws sts get-caller-identity --query Account --output text)':instance-profile/ecsInstanceRole",
                "tags": {
                    "Name": "'"${PIPELINE_NAME}-${ENVIRONMENT}"'",
                    "Environment": "'"${ENVIRONMENT}"'"
                }
            }'
    fi
    
    # Create job queue
    QUEUE_NAME="${PIPELINE_NAME}-${ENVIRONMENT}-queue"
    
    if ! aws batch describe-job-queues --job-queues "${QUEUE_NAME}" --query "jobQueues[0]" 2>/dev/null | grep -q "${QUEUE_NAME}"; then
        echo "Creating job queue: ${QUEUE_NAME}"
        
        # Wait for compute environment to be valid
        echo "Waiting for compute environment to be ready..."
        sleep 30
        
        aws batch create-job-queue \
            --job-queue-name "${QUEUE_NAME}" \
            --state ENABLED \
            --priority 100 \
            --compute-environment-order '[{
                "order": 1,
                "computeEnvironment": "'"${CE_NAME}"'"
            }]'
    fi
    
    echo -e "${GREEN}AWS Batch environment ready${NC}"
}

# Upload pipeline code
upload_pipeline() {
    echo -e "\n${YELLOW}Uploading pipeline code...${NC}"
    
    PIPELINE_BUCKET="${PIPELINE_NAME}-${ENVIRONMENT}-inputs"
    PIPELINE_PREFIX="pipeline/${PIPELINE_NAME}/latest"
    
    # Create tarball excluding unnecessary files
    tar czf pipeline.tar.gz \
        --exclude='.git' \
        --exclude='work' \
        --exclude='results' \
        --exclude='.nextflow' \
        --exclude='*.log' \
        .
    
    # Upload to S3
    aws s3 cp pipeline.tar.gz "s3://${PIPELINE_BUCKET}/${PIPELINE_PREFIX}/pipeline.tar.gz"
    
    # Upload main files individually for easy access
    aws s3 cp main.nf "s3://${PIPELINE_BUCKET}/${PIPELINE_PREFIX}/main.nf"
    aws s3 cp nextflow.config "s3://${PIPELINE_BUCKET}/${PIPELINE_PREFIX}/nextflow.config"
    
    rm pipeline.tar.gz
    
    echo -e "${GREEN}Pipeline uploaded to S3${NC}"
}

# Create CloudFormation stack for additional resources
create_cloudformation_stack() {
    echo -e "\n${YELLOW}Creating CloudFormation stack...${NC}"
    
    # Create CloudFormation template
    cat > cfn-template.yaml <<EOF
AWSTemplateFormatVersion: '2010-09-09'
Description: 'Resources for ${PIPELINE_NAME} - ${ENVIRONMENT}'

Parameters:
  Environment:
    Type: String
    Default: ${ENVIRONMENT}

Resources:
  # ECR Repository for custom containers
  ECRRepository:
    Type: AWS::ECR::Repository
    Properties:
      RepositoryName: ${PIPELINE_NAME}-${ENVIRONMENT}
      LifecyclePolicy:
        LifecyclePolicyText: |
          {
            "rules": [{
              "rulePriority": 1,
              "description": "Keep last 10 images",
              "selection": {
                "tagStatus": "any",
                "countType": "imageCountMoreThan",
                "countNumber": 10
              },
              "action": {
                "type": "expire"
              }
            }]
          }

  # SSM Parameters for configuration
  BatchQueueParameter:
    Type: AWS::SSM::Parameter
    Properties:
      Name: /${PIPELINE_NAME}/${ENVIRONMENT}/batch-queue
      Type: String
      Value: ${PIPELINE_NAME}-${ENVIRONMENT}-queue

  S3WorkDirParameter:
    Type: AWS::SSM::Parameter
    Properties:
      Name: /${PIPELINE_NAME}/${ENVIRONMENT}/s3-work-dir
      Type: String
      Value: s3://${PIPELINE_NAME}-${ENVIRONMENT}-work

Outputs:
  ECRRepositoryURI:
    Description: ECR Repository URI
    Value: !Sub '\${AWS::AccountId}.dkr.ecr.\${AWS::Region}.amazonaws.com/\${ECRRepository}'
    Export:
      Name: !Sub '\${AWS::StackName}-ECR-URI'
EOF
    
    # Deploy stack
    aws cloudformation deploy \
        --template-file cfn-template.yaml \
        --stack-name "${STACK_NAME}" \
        --capabilities CAPABILITY_IAM \
        --region "${AWS_REGION}" \
        --parameter-overrides Environment="${ENVIRONMENT}"
    
    rm cfn-template.yaml
    
    echo -e "${GREEN}CloudFormation stack deployed${NC}"
}

# Generate run script
generate_run_script() {
    echo -e "\n${YELLOW}Generating run script...${NC}"
    
    cat > "run_pipeline_${ENVIRONMENT}.sh" <<EOF
#!/bin/bash
# Run ${PIPELINE_NAME} on AWS Batch - ${ENVIRONMENT} environment

# Configuration
QUEUE="${PIPELINE_NAME}-${ENVIRONMENT}-queue"
WORK_DIR="s3://${PIPELINE_NAME}-${ENVIRONMENT}-work"
INPUT_BUCKET="${PIPELINE_NAME}-${ENVIRONMENT}-inputs"
OUTPUT_BUCKET="${PIPELINE_NAME}-${ENVIRONMENT}-outputs"

# Run pipeline
nextflow run \\
    s3://\${INPUT_BUCKET}/pipeline/${PIPELINE_NAME}/latest/main.nf \\
    -profile awsbatch \\
    -work-dir \${WORK_DIR} \\
    --awsqueue \${QUEUE} \\
    --awsregion ${AWS_REGION} \\
    --input \$1 \\
    --outdir s3://\${OUTPUT_BUCKET}/\$(date +%Y%m%d_%H%M%S) \\
    \${@:2}
EOF
    
    chmod +x "run_pipeline_${ENVIRONMENT}.sh"
    
    echo -e "${GREEN}Run script generated: run_pipeline_${ENVIRONMENT}.sh${NC}"
}

# Main deployment
main() {
    check_prerequisites
    create_s3_buckets
    create_batch_environment
    upload_pipeline
    create_cloudformation_stack
    generate_run_script
    
    echo -e "\n${GREEN}Deployment complete!${NC}"
    echo -e "\nTo run the pipeline:"
    echo -e "  ./run_pipeline_${ENVIRONMENT}.sh <samplesheet.csv>"
    echo -e "\nResources created:"
    echo -e "  - S3 buckets: ${PIPELINE_NAME}-${ENVIRONMENT}-*"
    echo -e "  - Batch queue: ${PIPELINE_NAME}-${ENVIRONMENT}-queue"
    echo -e "  - CloudFormation stack: ${STACK_NAME}"
}

# Run deployment
main
