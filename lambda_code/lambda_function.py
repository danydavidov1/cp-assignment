import os
import re
import hmac
import json
import hashlib
import logging

import boto3

from github import Github

logger = logging.getLogger()
logger.setLevel(logging.INFO)

GITHUB_TOKEN_SECRET_ID = os.getenv('GITHUB_TOKEN_SECRET_ID')
WEBHOOK_SECRET_SECRET_ID = os.getenv('WEBHOOK_SECRET_SECRET_ID')

client = boto3.client('secretsmanager')

def calculate_signature(github_signature, payload):
    try:
        signature_bytes = bytes(github_signature, 'utf-8')
        digest = hmac.new(key=signature_bytes, msg=payload, digestmod=hashlib.sha256)
        signature = digest.hexdigest()
        logger.info(f"Calculated signature: {signature}")
        return signature
    except Exception as e:
        logger.error(f"Error calculating signature: {e}")
        raise

def retrieve_secret_value(sc_client, secret_id):
    try:
        response = client.get_secret_value(SecretId=secret_id)
        secret_value = response.get('SecretString')
        return secret_value
    except Exception as e:
        logger.error(f"Error retrieving secret value for {secret_id}: {e}")
        raise

def lambda_handler(event, context):
    try:
        logger.info("Received new webhook")
        logger.info("Starting to validate secret")
        webhook_secret = retrieve_secret_value(client, WEBHOOK_SECRET_SECRET_ID)
        incoming_signature = re.sub(r'^sha256=', '', event['headers']['X-Hub-Signature-256'])
        calculated_signature = calculate_signature(webhook_secret, event['body'].encode('utf-8'))
        
        if incoming_signature != calculated_signature:
            logger.warning("Unauthorized attempt")
            response_data = {
                "statusCode": 403,
                "body": json.dumps({"Error": "Unauthorized attempt"})
            }
            return response_data
        
        logger.info("Authorized webhook")
        logger.info("Starting to check webhook event type")
        if event['headers']['X-GitHub-Event'] == "ping":
            logger.info("Received ping event")
            response_data = {
                "statusCode": 200,
                "body": json.dumps({"message": "pong"}),
            }
            return response_data
        
        body = json.loads(event['body'])
        action = body['action']
        merged = body['pull_request']['merged']

        if merged and action == 'closed':
            try:
                logger.info("Received pull request merged event")
                repo_full_name = body['pull_request']['head']['repo']['full_name']
                pr_number = body['number']
                github_access_token = retrieve_secret_value(client, GITHUB_TOKEN_SECRET_ID)
                g = Github(github_access_token)
                logger.info(f"Start to get pull request details from repo {repo_full_name}")
                repo = g.get_repo(repo_full_name)
                pull_request = repo.get_pull(number=pr_number)
                files = pull_request.get_files()
                logger.info("Start to log changed files")
                for file in files:
                    logger.info(f"File: {file.filename} was changed in the {pr_number} pull request")
                
                response_data = {
                    "statusCode": 200,
                    "body": json.dumps({"message": "The webhook was successfully received"})
                }
                return response_data
            except Exception as e:
                logger.error(f"Error processing pull request: {e}")
                response_data = {
                    "statusCode": 500,
                    "body": json.dumps({"Error": "Internal server error"})
                }
                return response_data
        else: 
            logger.info("Not merged event")
            response_data = {
                "statusCode": 200,
                "body": json.dumps({"message": "Not merged event"})
            }
            return response_data
    
    except Exception as e:
        logger.error(f"Error handling the event: {e}")
        response_data = {
            "statusCode": 500,
            "body": json.dumps({"Error": "Internal server error"})
        }
        return response_data
