#!/usr/bin/env bash

echo "Terminating EC2 Instance: $INSTANCE_ID"
aws ec2 terminate-instances --instance-ids $INSTANCE_ID
aws ec2 wait instance-terminated --instance-ids $INSTANCE_ID

echo "Deleting EC2 Security Group: $SG_NAME, $SG_ID"
aws ec2 delete-security-group --group-id $SG_ID

echo "Deleting SSH EC2 Key Pair: $KP_NAME"
aws ec2 delete-key-pair --key-name tutorial-key

echo "Teardown Completed."
