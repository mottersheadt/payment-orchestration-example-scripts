#!/usr/bin/env bash

(
# Setup error handling
set -e
trap 'last_command=$current_command; current_command=$BASH_COMMAND' DEBUG
trap '[ $? = "0" ] || echo "ERROR: \"${last_command}\" command failed with exit code $?."' EXIT


################################################################
# Settings                                                     #
################################################################

# This will be the name of the new sub account that gets generated
SUB_ACCOUNT_NAME=""

# The name of the gateway to which this sub-account will route its transactions
GATEWAY_ID=""

# Payment Orchestration Client ID and Secret created with payments-admin settings.
# These credentials are used for creating the new rule after the sub-account is created.
ADMIN_CLIENT_ID=""
ADMIN_CLIENT_SECRET=""

# Vault ID used for storing card/cvc tokens
VAULT_ID=""
ORGANIZATION_ID=""

# Access Credentials for the Outbound Route's vault.
# These can be created by navigating to the 
#   Administration -> Vault Settings -> Access Credentials
# area in the dashboard
UNAME=""
PASSWORD=""

# This will be the name of the new rule that routes this sub account to the specified gateway
RULE_NAME="${SUB_ACCOUNT_NAME}-to-${GATEWAY_ID}"

# Requests will be proxied through this URL to redact/reveal sensitive data elements.
# Default is sandbox URL
PROXY_URL=https://$UNAME:${PASSWORD}@${VAULT_ID}.sandbox.verygoodproxy.com:8443

# All requests to Payment Orchestration will go to this URL.
# Default is sandbox URL.
PAYMENT_ORCHESTRATION_API_URL="https://payments.sandbox.verygoodsecurity.app"

################################################################
################################################################
################################################################

cat <<-EOF

This script will perform the following operations:

1. Create a new sub-account
2. Create a rule to route the sub-account transactions to an existing gateway
3. Post a transfer using the new sub-account using the /transfers API endpoint
4. Reverse the transfer made in the previous step using the /reversals API endpoint

EOF

if [ -z  $ADMIN_CLIENT_ID ]; then
    echo "ADMIN_CLIENT_ID not provided. Exiting."
    exit
fi
if [ -z  $ADMIN_CLIENT_SECRET ]; then
    echo "ADMIN_CLIENT_SECRET not provided. Exiting."
    exit
fi
if [ -z  $VAULT_ID ]; then
    echo "VAULT_Id not provided. Exiting."
    exit
fi
if [ -z  $UNAME ]; then
    echo "UNAME not provided. Exiting."
    exit
fi
if [ -z $PASSWORD ]; then
    echo "PASSWORD not provided. Exiting."
    exit
fi
if [ -z $GATEWAY_ID ]; then
    echo "GATEWAY_ID not provided. Exiting."
    exit
fi

echo ""
echo ">>> Authenticating to VGS with admin credentials to get access token..."

# Authenticate with VGS
ACCESS_RESPONSE=$(curl -s -X POST "https://auth.verygoodsecurity.com/auth/realms/vgs/protocol/openid-connect/token" \
                       -d "client_id=${ADMIN_CLIENT_ID}" \
                       -d "client_secret=${ADMIN_CLIENT_SECRET}" \
                       -d "grant_type=client_credentials")
echo "Admin Access Token:"
echo ""
ADMIN_ACCESS_TOKEN=$(echo $ACCESS_RESPONSE | jq -r .access_token)
echo $ADMIN_ACCESS_TOKEN

echo ""
echo ">>> Creating new sub-account..."
mkdir -p working
cp resources/sub-account-admin-template.yaml working/sub-account-admin.yaml
sed -i -e "s/~NAME~/${SUB_ACCOUNT_NAME}/" ./working/sub-account-admin.yaml
sed -i -e "s/~VAULT_ID~/${VAULT_ID}/" ./working/sub-account-admin.yaml

echo ""
echo ">>> Created account template:"
cat ./working/sub-account-admin.yaml

echo ""
echo ">>> Applying new account to organization with ID $ORGANIZATION_ID"
vgs apply service-account -O $ORGANIZATION_ID -f ./working/sub-account-admin.yaml > ./working/sub-account-credentials.yaml

echo "Wait 10 seconds to let the new service-account take effect..."
sleep 10

SUB_ACCOUNT_CLIENT_ID=$(cat working/sub-account-credentials.yaml | grep clientId | sed 's/.*clientId: //')
echo "Sub-account Client ID:" $SUB_ACCOUNT_CLIENT_ID

SUB_ACCOUNT_CLIENT_SECRET=$(cat working/sub-account-credentials.yaml | grep clientSecret | sed 's/.*clientSecret: //')
echo "Sub-account Client Secret:" $SUB_ACCOUNT_CLIENT_SECRET

echo ""
echo ">>> Setting up rule for new service-account"
PAYLOAD=$(cat <<-EOF
{
  "action": "route",
  "description": "Route subaccount ${SUB_ACCOUNT_NAME} to ${GATEWAY_ID}",
  "criteria": "env.sub_account == '${SUB_ACCOUNT_NAME}'",
  "route_to_gateway": "${GATEWAY_ID}",
  "id": "${RULE_NAME}",
  "ordinal": 0
}
EOF
)

echo "Create Rule Payload:"
echo $PAYLOAD | jq

echo "Create Rule Response"
curl --location -X POST $PAYMENT_ORCHESTRATION_API_URL"/rules" \
     -H "Authorization: Bearer ${VGS_ACCESS_TOKEN}" \
     -H "Content-Type: application/json" \
     --data-raw "${PAYLOAD}" | jq -R '. as $raw | try fromjson catch $raw'

echo ""
echo ">>> Storing PAN alias in persistent storage:"
RESPONSE=$(curl https://api.sandbox.verygoodvault.com/aliases \
		 -X POST \
		 -u $UNAME:$PASSWORD \
		 -H 'Content-Type: application/json' \
		 -d '{
		      "data": [{
		        "value": "4111111111111111",
        		"classifiers": [],
        		"format": "UUID",
			"storage": "PERSISTENT"
		      }]
  		     }')
echo $RESPONSE | jq -R '. as $raw | try fromjson catch $raw'
PAN_ALIAS=$(echo $RESPONSE | jq -r '.data[].aliases[].alias')
echo "PAN alias:" $PAN_ALIAS

echo ""
echo ">>> Storing CVV alias in volatile storage:"
RESPONSE=$(curl https://api.sandbox.verygoodvault.com/aliases \
		 -X POST \
		 -u $UNAME:$PASSWORD \
		 -H 'Content-Type: application/json' \
		 -d '{
		      "data": [{
		        "value": "123",
        		"classifiers": [],
        		"format": "UUID",
			"storage": "VOLATILE"
		      }]
  		     }')
echo $RESPONSE | jq -R '. as $raw | try fromjson catch $raw'
CVV_ALIAS=$(echo $RESPONSE | jq -r '.data[].aliases[].alias')
echo "CVV alias:" $CVV_ALIAS

PAYLOAD=$(cat <<-EOF
{
    "card": {
        "name": "John Doe",
        "number": "${PAN_ALIAS}",
        "exp_month": 10,
        "exp_year": 2030,
        "cvc": "123",
        "billing_address": { 
            "postal_code": "12301",
            "address1": "888 Test St", 
            "country": "CA",
            "city": "Toronto", 
            "region": "ON"
        }
    }
}
EOF
)

SUB_ACCOUNT_ACCESS_RESPONSE=$(curl -X POST "https://auth.verygoodsecurity.com/auth/realms/vgs/protocol/openid-connect/token" \
                       -d "client_id=${SUB_ACCOUNT_CLIENT_ID}" \
                       -d "client_secret=${SUB_ACCOUNT_CLIENT_SECRET}" \
                       -d "scope=financial-instruments:write transfers:admin" \
                       -d "grant_type=client_credentials")

echo "Sub-account Access Token:"
SUB_ACCOUNT_ACCESS_TOKEN=$(echo $SUB_ACCOUNT_ACCESS_RESPONSE | jq -r .access_token)
echo $SUB_ACCOUNT_ACCESS_TOKEN

if [ -z $SUB_ACCOUNT_ACCESS_TOKEN ]; then
    echo "Failed to authenticate with new sub-account credentials"
    exit
fi

echo ""
echo ">>> Creating a financial instrument using the VGS Proxy..."
URL=$PAYMENT_ORCHESTRATION_API_URL/financial_instruments
echo POST: $URL
echo PROXY: $PROXY_URL
echo PAYLOAD:
echo $PAYLOAD | jq
echo "RESPONSE:"

RESPONSE=$(curl --location -X POST $URL \
		-x $PROXY_URL -k \
		-H "Authorization: Bearer ${SUB_ACCOUNT_ACCESS_TOKEN}" \
		-H "Content-Type: application/json" \
		--data-raw  "${PAYLOAD}")
echo $RESPONSE | jq -R '. as $raw | try fromjson catch $raw'
FI=$(echo $RESPONSE | jq -r .data.id)

echo "Financial Instrument ID:" $FI

if [ -z $FI ]; then
    echo "Failed to create financial instrument with new sub-account credentials"
    exit
fi

echo ""
echo ">>> Perform credit transfer"
PAYLOAD=$(cat <<-EOF
{
    "source": "${FI}", 
    "amount": 100, 
    "action": "capture",
    "currency": "USD"
}
EOF
)

URL=$PAYMENT_ORCHESTRATION_API_URL"/transfers"
echo POST: $URL
echo "REQUEST:"
echo $PAYLOAD | jq
echo "RESPONSE:"
RESPONSE=$(curl --location -X POST $URL \
          -H "Authorization: Bearer ${SUB_ACCOUNT_ACCESS_TOKEN}" \
          -H "Content-Type: application/json" \
          --data-raw "${PAYLOAD}")

echo $RESPONSE | jq -R '. as $raw | try fromjson catch $raw'

TRANS_ID=$(echo $RESPONSE | jq -r .data.id)
echo "Transfer ID:" $TRANS_ID

if [ -z $TRANS_ID ]; then
    echo "Failed to perform credit transfer with new financial instrument."
    exit
fi

echo ""
echo ">>> Refunding transfer..."
URL=$PAYMENT_ORCHESTRATION_API_URL"/transfers/${TRANS_ID}/reversals"
echo POST: $URL
echo "RESPONSE:"
curl --location -X POST $URL \
     -H "Authorization: Bearer ${SUB_ACCOUNT_ACCESS_TOKEN}" \
     -H "Content-Type: application/json" \
     --data-raw "${PAYLOAD}" | jq -R '. as $raw | try fromjson catch $raw'

)
