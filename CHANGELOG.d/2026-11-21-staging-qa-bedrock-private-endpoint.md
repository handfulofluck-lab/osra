### Staging synthetic analyzer networking (#962)

- Route armed synthetic classification through the Frankfurt Bedrock interface endpoint's regional
  hostname. Remove the staging VPC-wide Bedrock DNS alias and reject missing or invalid analyzer
  endpoint configuration before contacting Bedrock.
