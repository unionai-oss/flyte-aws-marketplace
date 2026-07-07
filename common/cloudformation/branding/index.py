"""CloudFormation custom resource: brand the Cognito hosted-UI login page.

CloudFormation's native AWS::Cognito::UserPoolUICustomizationAttachment only
supports CSS, not the logo image. This resource calls the SetUICustomization API
(boto3) to apply BOTH the CSS colour scheme and the logo, so the login page for
every Flyte product looks the same. The assets (login-ui.css, login-logo.png)
are bundled next to this handler and uploaded by `aws cloudformation package`.
"""
import json
import os
import urllib.request

import boto3

cognito = boto3.client("cognito-idp")
HERE = os.path.dirname(__file__)


def _respond(event, context, status, reason=""):
    body = json.dumps({
        "Status": status,
        "Reason": reason or f"see CloudWatch log stream {context.log_stream_name}",
        "PhysicalResourceId": event.get("PhysicalResourceId") or context.log_stream_name,
        "StackId": event["StackId"],
        "RequestId": event["RequestId"],
        "LogicalResourceId": event["LogicalResourceId"],
        "Data": {},
    }).encode()
    req = urllib.request.Request(
        event["ResponseURL"], data=body, method="PUT",
        headers={"content-type": "", "content-length": str(len(body))},
    )
    urllib.request.urlopen(req)  # noqa: S310 (the URL is the CFN-provided pre-signed S3 URL)


def handler(event, context):
    try:
        if event["RequestType"] == "Delete":
            # Nothing to clean up — the customization dies with the user pool.
            _respond(event, context, "SUCCESS", "delete: nothing to do")
            return
        pool_id = event["ResourceProperties"]["UserPoolId"]
        with open(os.path.join(HERE, "login-ui.css"), "r", encoding="utf-8") as f:
            css = f.read()
        with open(os.path.join(HERE, "login-logo.png"), "rb") as f:
            logo = f.read()
        cognito.set_ui_customization(UserPoolId=pool_id, CSS=css, ImageFile=logo)
        _respond(event, context, "SUCCESS", "hosted-UI branded")
    except Exception as e:  # noqa: BLE001 — always signal CFN so the stack never hangs
        _respond(event, context, "FAILED", str(e)[:1000])
