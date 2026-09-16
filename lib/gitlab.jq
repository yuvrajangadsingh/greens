# Only normalized activity records leave this filter; never persist API bodies.
def epoch:
  sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
def record($id; $date; $kind):
  ($date | epoch) as $time |
  select($time >= $since and $time <= $until) |
  {key: ($host + "/" + ($project|tostring) + "/" + $id),
   epoch: $time, date: ($date | sub("\\.[0-9]+Z$"; "Z")),
   kind: $kind, project: $path};
if $mode == "events" then
  .[] | select(.author_id == $user and .project_id == $project) |
  # Pushes represent the commits collected from Git; notes have their own IDs.
  select(.target_type == "MergeRequest") |
  select(.action_name == "approved" or .action_name == "unapproved") |
  record("event/" + (.id|tostring); .created_at; "approvals")
elif $mode == "objects" then
  .[] | select(.author.id == $user) |
  record($kind + "/" + (.id|tostring) + "/opened"; .created_at; $kind)
elif $mode == "discussions" then
  .[].notes[] | select(.author.id == $user and .system == false) |
  record("note/" + (.id|tostring); .created_at; "comments")
elif $mode == "states" then
  .[] | select(.user.id == $user) |
  select(.state == "closed" or .state == "reopened" or .state == "merged") |
  record("state/" + $kind + "/" + (.id|tostring); .created_at;
    if .state == "merged" then "merges" else "state_changes" end)
else error("Unknown collection mode") end
