GITHUB_URL="https://github.com/DanielS-Code/cloud_computing_hw_2"
KEY_NAME="CC_HW2_EC2_KEY"
KEY_PAIR_FILE=$KEY_NAME".pem"
SEC_GRP="CC_HW2_SEC_GRP"
UBUNTU_AMI="ami-04aa66cdfe687d427"
ROLE_NAME="EC2FullAccess"

AMI_NAME="worker"
IMG_TAG_KEY_1="service"
IMG_TAG_VAL_1="dynamic-workload"

PROJ_NAME="cloud_computing_hw_2"
POLICY_PATH="file://EC2_Trust_Policy.json"

ORCH_CONFIG="orchestrator/config.py"
API_CONFIG="api/config.py"

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
    --group-name "$SEC_GRP" --port 5000 --protocol tcp \
    --cidr 0.0.0.0/0 | tr -d '"'

### Deploy Worker Image ###

echo "Creating worker image"

WORKER_AMI_ID=$(aws ec2 describe-images --owners self --filters "Name=tag:$IMG_TAG_KEY_1,Values=[$IMG_TAG_VAL_1]" "Name=name, Values=[$AMI_NAME]" | jq --raw-output '.Images[] | .ImageId')

if [[ $WORKER_AMI_ID ]]
then
  echo "Using existing worker AMI: $WORKER_AMI_ID"
else
  echo "Creating Ubuntu instance using $AMI_ID"

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

  echo "Deploy worker"

  ssh -i $KEY_PAIR_FILE ubuntu@$PUBLIC_IP -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=1500"  << EOF
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
  WORKER_AMI_ID=$(aws ec2 create-image --instance-id $INSTANCE_ID \
                  --name $AMI_NAME \
                  --tag-specifications ResourceType=image,Tags="[{Key=$IMG_TAG_KEY_1,Value=$IMG_TAG_VAL_1}]" \
                  --description "An AMI for workers in hash cluster" \
                  --region $USER_REGION \
                  --query ImageId --output text)

  echo "Waiting for image creation: "$WORKER_AMI_ID
  aws ec2 wait image-available --image-ids $WORKER_AMI_ID

  echo "Termination instance"
  aws ec2 terminate-instances --instance-ids $INSTANCE_ID | tr -d '"'
fi

echo "Worker AMI ID:"$WORKER_AMI_ID

### Deploy Orchestrator ###

echo "Create IAM Role"
aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document $POLICY_PATH

echo "Attach a Policy with the Role"
aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonEC2FullAccess

echo "Verify the policy assignment"
aws iam create-instance-profile --instance-profile-name $ROLE_NAME

echo "Creating Ubuntu instance using: $AMI_ID"

RUN_INSTANCES=$(aws ec2 run-instances   \
  --image-id $UBUNTU_AMI        \
  --instance-type t2.micro            \
  --key-name $KEY_NAME                \
  --security-groups $SEC_GRP)

INSTANCE_ID=$(echo $RUN_INSTANCES | jq -r '.Instances[0].InstanceId')

echo "Waiting for orchestrator creation"
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

ORCHESTRATOR_PUBLIC_IP=$(aws ec2 describe-instances  --instance-ids $INSTANCE_ID | jq -r '.Reservations[0].Instances[0].PublicIpAddress')

echo "New instance $INSTANCE_ID @ $ORCHESTRATOR_PUBLIC_IP"

aws iam add-role-to-instance-profile --role-name $ROLE_NAME --instance-profile-name $ROLE_NAME | tr -d '"'

echo "Associate IAM role to instance"
aws ec2 associate-iam-instance-profile --instance-id $INSTANCE_ID --iam-instance-profile Name=$ROLE_NAME | tr -d '"'

echo "New end point - $INSTANCE_ID @ $ORCHESTRATOR_PUBLIC_IP"

echo "Deploy orchestrator"

ssh -i $KEY_PAIR_FILE ubuntu@$ORCHESTRATOR_PUBLIC_IP -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=1500"  << EOF

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

    echo WORKER_AMI_ID = "'$WORKER_AMI_ID'" >> $ORCH_CONFIG
    echo ORCHESTRATOR_IP = "'$ORCHESTRATOR_PUBLIC_IP'" >> $ORCH_CONFIG
    echo USER_REGION = "'$USER_REGION'" >> $ORCH_CONFIG

    printf "Install requirements\n"
    pip3 install -r "orchestrator/requirements.txt"

    export FLASK_APP="orchestrator/app.py"
    nohup flask run --host=0.0.0.0 &>flask.log & exit
EOF

echo "Orchestrator Public IP:"$ORCHESTRATOR_PUBLIC_IP

### Deploy API 1 ###

echo "Creating api"

RUN_INSTANCES=$(aws ec2 run-instances   \
  --image-id $UBUNTU_AMI                \
  --instance-type t2.micro              \
  --key-name $KEY_NAME                  \
  --security-groups $SEC_GRP)

INSTANCE_ID=$(echo $RUN_INSTANCES | jq -r '.Instances[0].InstanceId')

echo "Waiting for instance creation..."
aws ec2 wait instance-running --instance-ids $INSTANCE_ID

API_1_IP=$(aws ec2 describe-instances  --instance-ids $INSTANCE_ID | jq -r '.Reservations[0].Instances[0].PublicIpAddress')

echo "New instance %s @ %s \n" "$INSTANCE_ID" "API_1_IP"

printf "Deploy app"
ssh -i "$KEY_PEM" -o "StrictHostKeyChecking=no" -o "ConnectionAttempts=10" ubuntu@"$API_1_IP" <<EOF
    echo "update apt get"
    sudo apt-get update -y

    echo "upgrade apt get"
    sudo apt-get upgrade -y

    echo "update apt get x2"
    sudo apt-get update -y

    echo "install pip"
    sudo apt-get install python3-pip -y

    echo "Clone repo"
    git clone "$GITHUB_URL.git"
    cd $PROJ_NAME

    echo "Install requirements"
    pip3 install -r "api/requirements.txt"

    echo ORCHESTRATOR_IP = "'$ORCHESTRATOR_PUBLIC_IP'" >> $API_CONFIG

    export FLASK_APP="api/app.py"
    nohup flask run --host=0.0.0.0 &>/dev/null & exit
EOF

echo "API 1 is up at: $API_1_IP"