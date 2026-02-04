import os
import boto3
import urllib.request
import urllib.parse
import json
import uuid

# Custom Exception
class AuthenticationError(Exception): pass

ec2 = boto3.client('ec2')
cognito = boto3.client('cognito-idp')

INSTANCE_ID = os.environ['INSTANCE_ID']
APP_DOMAIN = os.environ['APP_DOMAIN']
DOMAIN_NAME = os.environ.get('DOMAIN_NAME', 'Application')

# Cognito Config
COGNITO_DOMAIN = os.environ['COGNITO_DOMAIN']
CLIENT_ID = os.environ['CLIENT_ID']
CLIENT_SECRET = os.environ['CLIENT_SECRET']
REDIRECT_URI = f"https://{APP_DOMAIN}/launcher" # Explicit path for Lambda

def get_instance_state():
    response = ec2.describe_instances(InstanceIds=[INSTANCE_ID])
    return response['Reservations'][0]['Instances'][0]['State']['Name']

def exchange_code(code):
    url = f"https://{COGNITO_DOMAIN}/oauth2/token"
    data = urllib.parse.urlencode({
        'grant_type': 'authorization_code',
        'client_id': CLIENT_ID,
        'client_secret': CLIENT_SECRET,
        'code': code,
        'redirect_uri': REDIRECT_URI
    }).encode()
    
    req = urllib.request.Request(url, data=data, headers={
        'Content-Type': 'application/x-www-form-urlencoded'
    })
    
    with urllib.request.urlopen(req) as response:
        return json.load(response)

# 2. Verify Access Token (Using UserInfo Endpoint)
def verify_token(token):
    try:
        req = urllib.request.Request(f"https://{COGNITO_DOMAIN}/oauth2/userInfo")
        req.add_header("Authorization", f"Bearer {token}")
        with urllib.request.urlopen(req) as response:
            if response.getcode() == 200:
                return True
    except Exception as e:
        print(f"Token Verification Failed: {e}")
    return False

def lambda_handler(event, context):
    try:
        headers = event.get('headers', {})
        query_params = event.get('queryStringParameters') or {}
        # Handle case-insensitive headers
        cookies_header = next((v for k, v in headers.items() if k.lower() == 'cookie'), '')
        
        # Parse Cookies
        cookies = {}
        if cookies_header:
            for item in cookies_header.split(';'):
                if '=' in item:
                    k, v = item.strip().split('=', 1)
                    cookies[k] = v

        # Check for Session Cookie (Access Token)
        access_token = cookies.get('launcher_session')
        authorized = False
        
        if access_token:
            authorized = verify_token(access_token)
        

        def html_redirect(url, message="Redirecting..."):
            return {
                'statusCode': 200,
                'headers': {'Content-Type': 'text/html', 'Cache-Control': 'no-cache'},
                'body': f"""
                <!DOCTYPE html><html><head>
                <meta http-equiv="refresh" content="0;url={url}">
                <script>window.location.href = "{url}";</script>
                </head><body><p>{message}</p></body></html>
                """
            }

        # 1. Handle OAuth Callback (if 'code' is present)
        if 'code' in query_params:
            try:
                tokens = exchange_code(query_params['code'])
                new_access_token = tokens.get('access_token')
                
                if not new_access_token:
                     return {'statusCode': 401, 'body': 'No access token received'}

                # Redirect to root, setting the cookie with the Access Token
                print(f"OAuth callback -> authenticated, redirecting to /")
                response = html_redirect(f'https://{APP_DOMAIN}/', "Authentication successful. Redirecting...")
                response['headers']['Set-Cookie'] = f'launcher_session={new_access_token}; Secure; HttpOnly; Max-Age=3600; Path=/'
                return response
            except Exception as e:
                print(f"Auth Error: {e}")
                return {'statusCode': 401, 'body': 'Authentication Failed'}

        # 2. If Not Authorized, Redirect to Cognito
        if not authorized:
            print(f"No valid session -> redirecting to Cognito")
            login_url = f"https://{COGNITO_DOMAIN}/oauth2/authorize?client_id={CLIENT_ID}&response_type=code&scope=openid+email&redirect_uri={urllib.parse.quote(REDIRECT_URI)}"
            response = html_redirect(login_url, "Redirecting to login...")
             # Clear invalid cookie if present
            response['headers']['Set-Cookie'] = 'launcher_session=; Secure; HttpOnly; Max-Age=0; Path=/'
            return response

        # 3. Authorized Ops (Check State / Start)
        state = get_instance_state()
        print(f"Authorized, EC2 state: {state}")
        
        # Redirect immediately if running
        if state == 'running':
            return html_redirect(f'https://{APP_DOMAIN}', "Instance is running. Redirecting...")
        
        # Handle POST: start instance if stopped
        if event.get('requestContext', {}).get('http', {}).get('method') == 'POST':
            if state == 'stopped':
                ec2.start_instances(InstanceIds=[INSTANCE_ID])
                print(f"Started instance {INSTANCE_ID}")
                state = 'pending'  # Update state for UI
        
        # State-specific UI config
        show_button = False
        show_loader = False
        
        if state == 'stopped':
            message = "Server is sleeping."
            refresh = 60
            show_button = True
        elif state == 'pending':
            message = "Server is starting..."
            refresh = 5
            show_loader = True
        elif state == 'stopping':
            message = "Server is shutting down..."
            refresh = 5
            show_loader = True
        elif state == 'shutting-down':
            message = "Server is being terminated..."
            refresh = 5
            show_loader = True
        elif state == 'terminated':
            message = "Server is terminated."
            refresh = 0  # No refresh
        else:
            message = f"Status: {state}"
            refresh = 10

        # Render HTML
        html = f"""
        <!DOCTYPE html>
        <html>
        <head>
            <title>{DOMAIN_NAME}</title>
            <meta http-equiv="refresh" content="{refresh}">
            <style>
                body {{ font-family: -apple-system, system-ui, sans-serif; display: flex; justify-content: center; align-items: center; height: 100vh; background: #f0f2f5; margin: 0; }}
                .card {{ background: white; padding: 2rem; border-radius: 12px; box-shadow: 0 4px 6px rgba(0,0,0,0.1); text-align: center; max-width: 400px; width: 90%; }}
                h1 {{ margin-bottom: 0.5rem; }}
                .instance-id {{ font-size: 0.75rem; color: #888; margin-bottom: 1rem; font-family: monospace; }}
                button {{ background: #2563eb; color: white; border: none; padding: 12px 24px; border-radius: 6px; font-size: 1rem; cursor: pointer; transition: all 0.2s; }}
                button:hover:not(:disabled) {{ background: #1d4ed8; }}
                button:disabled {{ background: #94a3b8; cursor: not-allowed; }}
                .loader {{ border: 4px solid #f3f3f3; border-top: 4px solid #2563eb; border-radius: 50%; width: 30px; height: 30px; animation: spin 1s linear infinite; margin: 20px auto; }}
                @keyframes spin {{ 0% {{ transform: rotate(0deg); }} 100% {{ transform: rotate(360deg); }} }}
            </style>
        </head>
        <body>
            <div class="card">
                <h1>{DOMAIN_NAME}</h1>
                <div class="instance-id">{INSTANCE_ID}</div>
                <p>{message}</p>
                {'<div class="loader"></div>' if show_loader else ''}
                {f'''<form action="/launcher" method="POST" onsubmit="this.querySelector('button').disabled=true; this.querySelector('button').textContent='Starting...'; setTimeout(()=>this.querySelector('button').disabled=false, 5000);">
                    <button type="submit">Start Instance</button>
                </form>''' if show_button else ''}
            </div>
        </body>
        </html>
        """
        
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'text/html', 'Cache-Control': 'no-cache'},
            'body': html
        }
        
    except Exception as e:
        print(f"Error: {str(e)}")
        return {'statusCode': 500, 'body': f"Internal Error: {str(e)}"}
