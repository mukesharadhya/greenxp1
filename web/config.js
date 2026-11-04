// Public values only; never put secrets here. aws/deploy.ps1 writes the live values from the CloudFormation
// stack's outputs when it uploads the site, so this file only matters for running the page locally.
window.GXP = {
  API_URL: "",              // "" = same site (Caddy on the server sends /api/* to the API)
  COGNITO_REGION: "ap-south-1",
  COGNITO_CLIENT_ID: ""     // from the stack output CognitoClientId
};
