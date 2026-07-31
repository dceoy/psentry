def ci_identities:
  (. // [])
  | map({workflow, name})
  | unique_by([.workflow, .name]);

def changed:
  .current as $current
  | .previous as $previous
  | $previous == null
    or $current.draft != $previous.draft
    or $current.head_sha != $previous.head_sha
    or $current.input_fingerprint != $previous.input_fingerprint
    or $current.context_fingerprint != $previous.context_fingerprint
    or $current.external_digest != $previous.external_digest
    or (($current.ci_failures | ci_identities) != ($previous.ci_failures | ci_identities));

def decide:
  .current as $current
  | .previous as $previous
  | if (changed | not) then
      {action: "none", reason: null}
    elif $previous == null then
      if $current.draft
      then {action: "baseline", reason: null}
      else {action: "review", reason: "new-pr"}
      end
    elif $previous.draft and ($current.draft | not) then
      {action: "review", reason: "draft-to-ready"}
    elif $current.draft then
      {action: "baseline", reason: null}
    elif $current.head_sha != $previous.head_sha then
      {action: "review", reason: "head-sha-changed"}
    elif (
      (($current.ci_failures | ci_identities) - ($previous.ci_failures | ci_identities))
      | length
    ) > 0 then
      {action: "review", reason: "ci-failure"}
    elif $current.external_digest != $previous.external_digest then
      {action: "review", reason: "external-activity"}
    elif $current.context_fingerprint != $previous.context_fingerprint then
      {action: "review", reason: "review-input-changed"}
    else
      {action: "baseline", reason: null}
    end;

decide
