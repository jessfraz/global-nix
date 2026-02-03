set -euo pipefail

weekday=$(/bin/date +%u)
if [ "$weekday" -gt 5 ]; then
  /usr/bin/shortcuts run "DND Off"
  exit 0
fi

busy=$(/usr/bin/osascript <<'APPLESCRIPT'
set busy to false
tell application "Calendar"
  set nowDate to current date
  repeat with cal in calendars
    set matches to (every event of cal where its start date is less than or equal to nowDate and its end date is greater than or equal to nowDate)
    if (count of matches) > 0 then
      set busy to true
      exit repeat
    end if
  end repeat
end tell
if busy then
  return "1"
else
  return "0"
end if
APPLESCRIPT
)

if [ "$busy" = "1" ]; then
  /usr/bin/shortcuts run "DND On"
else
  /usr/bin/shortcuts run "DND Off"
fi
