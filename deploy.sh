GITHUB_URL = https://github.com/DanielS-Code/cloud_computing_hw_2
KEY_NAME="CC-HW2-EC2-KEY"
KEY_PAIR_FILE=$KEY_NAME".pem"
SEC_GRP="CC_HW2_SEC_GRP"
UBUNTU_AMI = ami-04aa66cdfe687d427

AMI_NAME="worker"
IMG_TAG_KEY_1="service"
IMG_TAG_VAL_1="dynamic-workload"

MY_IP=$(curl --silent ipinfo.io/ip)
echo "PC_IP_ADDRESS: $MY_IP"

echo "creating ec2 key pair: $KEY_NAME"
aws ec2 create-key-pair \
    --key-name $KEY_NAME \
    --key-type rsa \
    --key-format pem \
    --query "KeyMaterial" \
    --output text > $KEY_PAIR_FILE
chmod 400 $KEY_PAIR_FILE

USER_REGION=$(aws configure get region --output text)

echo "create security group $SEC_GRP"
aws ec2 create-security-group --group-name $SEC_GRP --description "HW2 security group" | tr -d '"'

echo "allow ssh from $MY_IP only "
aws ec2 authorize-security-group-ingress        \
    --group-name $SEC_GRP --port 22 --protocol tcp \
    --cidr $MY_IP/32 | tr -d '"'

aws ec2 authorize-security-group-ingress        \
    --group-name $SEC_GRP --port 5000 --protocol tcp \
    --cidr $MY_IP/32 | tr -d '"'

function deploy_worker_image() {
  IMAGE_ID=$(aws ec2 describe-images --owners self --filters "Name=tag:$IMG_TAG_KEY_1,Values=[$IMG_TAG_VAL_1]" "Name=name, Values=[$AMI_NAME]" | jq --raw-output '.Images[] | .ImageId')

  if [[ $IMAGE_ID ]]
  then
    return $IMAGE_ID
  fi

  printf "Creating Ubuntu 22.04 instance using %s...\n" "$AMI_ID"

  RUN_INSTANCES=$(aws ec2 run-instances   \
    --image-id $UBUNTU_AMI          \
    --instance-type t2.micro              \
    --key-name $KEY_NAME                  \
    --security-groups $SEC_GRP)

  INSTANCE_ID=$(echo "$RUN_INSTANCES" | jq -r '.Instances[0].InstanceId')

  echo "Waiting for instance creation..."
  aws ec2 wait instance-running --instance-ids $INSTANCE_ID

  PUBLIC_IP=$(aws ec2 describe-instances  --instance-ids $INSTANCE_ID | jq -r '.Reservations[0].Instances[0].PublicIpAddress')

  echo "New instance $INSTANCE_ID @ $PUBLIC_IP"

  echo "Deploy app"

  ssh -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=1500" -i $KEY_PAIR_FILE ubuntu@$PUBLIC_IP << EOF
      printf "update apt get\n"
      sudo apt-get update -y

      printf "upgrade apt get\n"
      sudo apt-get upgrade -y

      printf "update apt get x2\n"
      sudo apt-get update -y

      printf "install pip\n"
      sudo apt-get install python3-pip -y

      printf "Clone repo\n"
      git clone "$GITHUB_URL.git"
      cd $PROJ_NAME

      printf "Install requirements\n"
      pip3 install -r "worker/requirements.txt"
EOF


  echo "Creating new image"
  IMAGE_ID=$(aws ec2 create-image --instance-id $INSTANCE_ID \
        --name $AMI_NAME \
        --tag-specifications ResourceType=image,Tags="[{Key=$IMG_TAG_KEY_1,Value=$IMG_TAG_VAL_1}]" \
        --description "An AMI for workers in hash cluster" \
        --region $USER_REGION \
        --query ImageId --output text)

  echo "Waiting for image creation"
  aws ec2 wait image-available --image-ids $IMAGE_ID

  aws ec2 terminate-instances --instance-ids $INSTANCE_ID

  return $IMAGE_ID
}

WORKER_AMI_ID=$(deploy_worker_image)
echo "Worker AMI ID: $WORKER_AMI_ID"