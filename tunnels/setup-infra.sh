#!/usr/bin/env bash

echo "1. Creating SSH EC2 Key Pair"

KP_NAME="tutorial-key"

aws ec2 create-key-pair \
--key-name $KP_NAME \
--key-type ed25519 \
--query "KeyMaterial" \
--output text > ~/.ssh/tutorial-key.pem

chmod 400 ~/.ssh/tutorial-key.pem

echo "2. Creating EC2 Security Group"

CURRENT_IP=$(curl -s http://checkip.amazonaws.com)
SG_NAME="tutorial-security-group"

aws ec2 create-security-group \
--group-name $SG_NAME \
--description "Security Group For Temporary Remote EC2 Instance"

SG_ID=$(aws ec2 describe-security-groups --group-names "$SG_NAME" --query "SecurityGroups[0].GroupId" --output text)

aws ec2 authorize-security-group-ingress \
--group-id $SG_ID \
--protocol tcp \
--port 22 \
--cidr "$CURRENT_IP/32"

echo "3. Creating EC2 Instance"

AMI_ID=ami-087d1c9a513324697 # AMI For Ubuntu

aws ec2 run-instances \
--image-id $AMI_ID \
--count 1 \
--instance-type t2.micro \
--key-name $KP_NAME \
--security-group-ids $SG_ID

echo "4. Saving IP and ID of the EC2 Instance"

INSTANCE_ID=$(aws ec2 describe-instances \
--query "Reservations[0].Instances[0].InstanceId" \
--output text)

aws ec2 wait instance-running --instance-ids $INSTANCE_ID

EC2_IP=$(aws ec2 describe-instances \
--instance-ids $INSTANCE_ID \
--query "Reservations[0].Instances[0].PublicIpAddress" \
--output text)

echo "5. Setup Infra Completed."

