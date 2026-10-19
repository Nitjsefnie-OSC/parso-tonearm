#!/usr/bin/env bash
set -Eeuo pipefail
: "${GITHUB_REPOSITORY:?}" "${GH_TOKEN:?}" "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}"
repo=$GITHUB_REPOSITORY; test -f "$ASC_KEY_PATH"
token=$(ruby -rjson -ropenssl -rbase64 -e 'h=Base64.urlsafe_encode64({alg:"ES256",kid:ENV.fetch("ASC_KEY_ID"),typ:"JWT"}.to_json,padding:false);p=Base64.urlsafe_encode64({iss:ENV.fetch("ASC_ISSUER_ID"),aud:"appstoreconnect-v1",exp:Time.now.to_i+600}.to_json,padding:false);k=OpenSSL::PKey.read(File.read(ENV.fetch("ASC_KEY_PATH")));s=Base64.urlsafe_encode64(k.sign("SHA256","#{h}.#{p}"),padding:false);print "#{h}.#{p}.#{s}"')
auth=(-H "Authorization: Bearer $token")
for spec in 'testflight-uploaded|1D76DB|TestFlight upload was accepted; Apple processing is being reconciled.' 'testflight-processing|FBCA04|Apple is still processing the accepted TestFlight build.' 'testflight-distribution-confirmed|5319E7|App Store Connect reports an assigned tester group.' 'testflight-access-unverified|BFD4F2|Tester-group access was not verified automatically.' 'ready-for-qa|0E8A16|Apple processing completed; the exact TestFlight build is ready for human QA.'; do IFS='|' read -r n c d <<<"$spec"; gh label create "$n" --repo "$repo" --color "$c" --description "$d" --force >/dev/null; done
for issue in $(gh issue list --repo "$repo" --state open --limit 1000 --json number --jq '.[].number'); do
  marker=$(gh api --paginate "repos/$repo/issues/$issue/comments" --jq '.[].body' | rg '<!-- testflight-delivery:[^:]+:[^:]+:[^ ]+ -->' | tail -1 || true); [[ -n "$marker" ]] || continue
  bundle=$(sed -E 's/^<!-- testflight-delivery:([^:]+):.*$/\1/' <<<"$marker"); build=$(sed -E 's/^<!-- testflight-delivery:[^:]+:[^:]+:([^ ]+) -->$/\1/' <<<"$marker")
  app=$(curl -sS "${auth[@]}" --get --data-urlencode "filter[bundleId]=$bundle" https://api.appstoreconnect.apple.com/v1/apps || true); app_id=$(jq -r '.data[0].id // empty' <<<"$app")
  data=''; [[ -z "$app_id" ]] || data=$(curl -sS "${auth[@]}" --get --data-urlencode "filter[app]=$app_id" --data-urlencode "filter[version]=$build" https://api.appstoreconnect.apple.com/v1/builds || true)
  id=$(jq -r '.data[0].id // empty' <<<"$data"); state=$(jq -r '.data[0].attributes.processingState // empty' <<<"$data")
  if [[ "$state" == VALID && -n "$id" ]]; then
    groups=$(curl -sS "${auth[@]}" "https://api.appstoreconnect.apple.com/v1/builds/$id/betaGroups" || true); count=$(jq '.data | length' <<<"$groups" 2>/dev/null || echo 0)
    args=(--add-label testflight-uploaded --add-label ready-for-qa --remove-label testflight-processing)
    if [[ "$count" -gt 0 ]]; then args+=(--add-label testflight-distribution-confirmed --remove-label testflight-access-unverified); else args+=(--add-label testflight-access-unverified --remove-label testflight-distribution-confirmed); fi
  else
    args=(--add-label testflight-uploaded --add-label testflight-processing --remove-label ready-for-qa --remove-label testflight-distribution-confirmed)
  fi
  gh issue edit "$issue" --repo "$repo" "${args[@]}" >/dev/null; echo "Reconciled #$issue ($state)"
done
