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

echo ">>> Vaulting card data"
URL="https://${PROXY_VAULT_ID}.sandbox.verygoodproxy.com/post"
echo POST: $URL
PAYLOAD='{
    "card": {
        "number": "4111111111111111",
        "exp": "01 / 24",
        "cvc": "541"
    }
}'
VAULTED_DATA=`curl -s ${URL} \
    -H "Content-type: application/json" \
    -d ${PAYLOAD} | jq -r .json`

echo "Vaulted Card Data:"
echo "${VAULTED_DATA}" | jq
echo ""
PAN_ALIAS=`echo $VAULTED_DATA | jq -r .card.number`
CVV_ALIAS=`echo $VAULTED_DATA | jq -r .card.cvc`


echo ">>> Verifying card with redacted values"
PAYLOAD=$(cat <<-EOF
{
    "card": {
        "name": "John Doe",
        "number": "${PAN_ALIAS}",
        "exp_month": 10,
        "exp_year": 2030,
        "cvc": "${CVV_ALIAS}",
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
URL=$PAYMENT_ORCHESTRATION_API_URL/verifications
echo POST: $URL
echo PROXY: $PROXY_URL
echo PAYLOAD:
echo $PAYLOAD | jq
echo RESPONSE:
curl -s --location -X POST $URL \
     -x $PROXY_URL -k \
     -H "Authorization: Bearer ${VGS_ACCESS_TOKEN}" \
     -H "Content-Type: application/json" \
     --data-raw  "${PAYLOAD}"  | jq -R '. as $raw | try fromjson catch $raw'
