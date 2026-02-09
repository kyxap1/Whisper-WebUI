import os
import boto3

ec2 = boto3.client('ec2')
INSTANCE_ID = os.environ['INSTANCE_ID']

def lambda_handler(event, context):
    try:
        print(f"Stopping instance {INSTANCE_ID} due to inactivity...")
        ec2.stop_instances(InstanceIds=[INSTANCE_ID])
        print("Stop command issued.")
    except Exception as e:
        print(f"Error stopping instance: {str(e)}")
        raise e
