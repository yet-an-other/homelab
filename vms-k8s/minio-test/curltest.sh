#!/bin/bash

host="s3.bdgn.me"
access_key=""
secret_key=""
date_value=$(date -R)
signature_string="GET\n\n\n${date_value}\n/"
signature=$(echo -en "${signature_string}" | openssl sha1 -hmac "${secret_key}" -binary | base64)

curl -v -X GET \
  -H "Host: ${host}" \
  -H "Date: ${date_value}" \
  -H "Authorization: AWS ${access_key}:${signature}" \
  "https://${host}/"