################################################################
# Settings                                                     #
################################################################

# Payment Orchestration Client ID and Secret as provided by VGS
CLIENT_ID=""
CLIENT_SECRET=""

# Vault ID used for storing card/cvc tokens
PROXY_VAULT_ID=""

# Access Credentials for the Outbound Route's vault.
# These can be created by navigating to the 
#   Administration -> Vault Settings -> Access Credentials
# area in the dashboard
UNAME=""
PASSWORD=""

# Requests will be proxied through this URL to redact/reveal sensitive data elements.
# Default is sandbox URL
PROXY_URL=https://$UNAME:${PASSWORD}@${PROXY_VAULT_ID}.sandbox.verygoodproxy.com:8443

# All requests to Payment Orchestration will go to this URL.
# Default is sandbox URL.
PAYMENT_ORCHESTRATION_API_URL="https://payments.sandbox.verygoodsecurity.app"

################################################################
################################################################
################################################################

echo "What is the Financial Instrument ID you want to use?"
read FI
echo ""
echo "Financial ID: $FI"
echo ""

# Authenticate with VGS
echo ">>> Authenticating to VGS to get access token..."

ACCESS_RESPONSE=$(curl -s -X POST "https://auth.verygoodsecurity.com/auth/realms/vgs/protocol/openid-connect/token" \
                       -d "client_id=${CLIENT_ID}" \
                       -d "client_secret=${CLIENT_SECRET}" \
                       -d "grant_type=client_credentials")
echo "Access Token:"
echo $ACCESS_RESPONSE
echo ""
VGS_ACCESS_TOKEN=$(echo $ACCESS_RESPONSE | jq -r .access_token)

echo ">>> Authorize credit transfer"
PAYLOAD=$(cat <<-EOF
{
    "source": "${FI}", 
    "amount": 100, 
    "action": "authorize",
    "currency": "BRL",
    "gateway_options": { 
        "customer_id": "12345",
	"dynamic_mcc": "123"
    }
}
EOF
)

URL=$PAYMENT_ORCHESTRATION_API_URL"/transfers"
echo POST: $URL
echo "REQUEST:"
echo $PAYLOAD | jq
echo "RESPONSE:"
RESPONSE=$(curl -s --location -X POST $URL \
          -x $PROXY_URL -k \
          -H "Authorization: Bearer ${VGS_ACCESS_TOKEN}" \
          -H "Content-Type: application/json" \
          --data-raw "${PAYLOAD}")

echo $RESPONSE | jq -R '. as $raw | try fromjson catch $raw'
TRANS_ID=$(echo $RESPONSE | jq -r .data.id)
echo "Transfer ID:" $TRANS_ID
echo ""


echo ">>> Void authorized credit transfer"
URL=$PAYMENT_ORCHESTRATION_API_URL"/transfers/"$TRANS_ID

PAYLOAD=$(cat <<-EOF
{
    "action": "cancel"
}
EOF
)

echo POST: $URL
echo "REQUEST:"
echo $PAYLOAD | jq
echo "RESPONSE:"
curl -X PUT $URL \
     -H "Authorization: Bearer ${VGS_ACCESS_TOKEN}" \
     -H "Content-Type: application/json" \
     -d ${PAYLOAD} | jq
