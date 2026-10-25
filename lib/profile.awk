# Parse exact init service stanzas, without executing/importing vendor code.
FNR == 1 { active = 0 }
/^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
/^[[:space:]]*on[[:space:]].*property:init[.]svc[.]vendor[.]soter=/ {
    unsafe = 1
    print "unsafe_trigger=" FILENAME ":" FNR ":" $0
}
$1 == "service" {
    active = ($2 == "vendor.soter")
    if (active) {
        count++
        print "file=" FILENAME
        print "binary=" $3
        binary = tolower($3)
        if ($3 !~ /^\/(vendor|odm)\/bin\/[A-Za-z0-9_@.+\/:=-]+$/ || binary !~ /soter/ ||
            binary ~ /keymint|keymaster|keystore|strongbox|qsee|rkp/) unsafe = 1
        # Arguments could load another HAL into the same process.
        if (NF > 3) unsafe = 1
    }
    next
}
/^[^[:space:]]/ { active = 0 }
active {
    print "option=" $0
    if ($1 == "disabled" || $1 == "oneshot") lazy = 1
    if ($1 == "critical" || $1 == "reboot_on_failure" || $1 == "onrestart" ||
        $1 == "override" || $1 == "updatable" || $1 == "shutdown") unsafe = 1
    if ($1 == "interface" && tolower($0) !~ /soter/) unsafe = 1
}
END {
    print "definitions=" count + 0
    if (count != 1) print "profile=unknown"
    else if (unsafe) print "profile=unsafe"
    else if (lazy) print "profile=lazy"
    else print "profile=persistent"
}
