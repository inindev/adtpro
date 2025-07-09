#!/bin/sh

# mkdmg.sh - makes an osx disk image for adtpro.app installation
# original inpriration from Philip Weaver: http://www.informagen.com/JarBundler/DiskImage.html
# rewritten, extended, and robustified by John Clark in 2025: https://github.com/inindev/adtpro

# cleanup function for errors
cleanup() {
    local disk_id="$1"
    local dmg_temp_file="$2"

    echo "Cleaning up due to error"
    if [ -n "$disk_id" ]; then
        echo "Ejecting disk: $disk_id"
        hdiutil eject "$disk_id" 2>/dev/null || hdiutil eject -force "$disk_id" 2>/dev/null || echo "Failed to eject disk"
    fi
    if [ -f "$dmg_temp_file" ]; then
        echo "Removing temporary DMG: $dmg_temp_file"
        rm "$dmg_temp_file" || echo "Failed to remove temporary DMG"
    fi
}

# setup dmg: create, attach, format, and eject
setup_dmg() {
    local dmg_temp_file="$1"
    local vol_name="$2"
    local dmg_mb="$3"

    echo "Creating temporary DMG: $dmg_temp_file"
    hdiutil create -megabytes "$dmg_mb" "$dmg_temp_file" -layout NONE || {
        echo "Failed to create DMG"
        exit 1
    }

    echo "Attaching DMG to get disk identifier"
    disk_id=$(hdiutil attach -nomount -readwrite -noverify "$dmg_temp_file" | grep '^/dev/' | awk '{print $1}' | head -n 1)
    if [ -z "$disk_id" ]; then
        echo "Error: Failed to get disk identifier"
        exit 1
    fi
    echo "Disk identifier: $disk_id"

    echo "Formatting DMG with HFS+"
    newfs_hfs -v "$vol_name" "$disk_id" || {
        echo "Failed to format DMG"
        exit 1
    }

    echo "Ejecting DMG"
    hdiutil eject "$disk_id" || {
        echo "Failed to eject DMG"
        exit 1
    }
    disk_id=''
}

# populate dmg: mount, copy resources, clean, and configure finder
populate_dmg() {
    local dmg_temp_file="$1"
    local vol_name="$2"
    local app_name="$3"
    local back_img="$4"
    local icon_file="$5"

    echo "Mounting DMG"
    disk_id=$(hdid "$dmg_temp_file" | grep '^/dev/' | awk '{print $1}' | head -n 1)
    if [ -z "$disk_id" ]; then
        echo "Error: Failed to get disk identifier for mount"
        exit 1
    fi
    echo "Mounted disk identifier: $disk_id"

    echo "Copying application and resources"
    chflags -R nouchg,noschg "$app_name"
    cp -R "$app_name" "/Volumes/$vol_name" || {
        echo "Failed to copy application"
        exit 1
    }

    mkdir "/Volumes/$vol_name/.background"

    cp "$back_img" "/Volumes/$vol_name/.background/background.png" || {
        echo "Failed to copy background"
        exit 1
    }
    cp "$icon_file" "/Volumes/$vol_name/.VolumeIcon.icns" || {
        echo "Failed to copy icon"
        exit 1
    }

    SetFile -c icns "/Volumes/$vol_name/.VolumeIcon.icns" || {
        echo "Failed to set icon type"
        exit 1
    }
    SetFile -a C "/Volumes/$vol_name" || {
        echo "Failed to set custom icon attribute"
        exit 1
    }

    rm -rf "/Volumes/$vol_name/.Trashes" "/Volumes/$vol_name/.fseventsd"

    echo "Configuring Finder appearance"
    osascript <<-EOF
	tell application "Finder"
	    tell disk "$vol_name"
	        open
	        set current view of container window to icon view
	        set toolbar visible of container window to false
	        set statusbar visible of container window to false
	        set the bounds of container window to {400, 100, 775, 305}
	        set theViewOptions to the icon view options of container window
	        set arrangement of theViewOptions to not arranged
	        set icon size of theViewOptions to 72
	        set background picture of theViewOptions to file ".background:background.png"
	        make new alias file at container window to POSIX file "/Applications" with properties {name:"Applications"}
	        set position of item "$vol_name" of container window to {83, 101}
	        set position of item "Applications" of container window to {274, 101}
	        update without registering applications
	        close
	        open
	        delay 5
	    end tell
	end tell
	EOF

    if [ $? -ne 0 ]; then
        echo "Failed to configure Finder"
        exit 1
    fi
}

# set dmg icon using an .icns file
set_dmg_icon() {
    local dmg_file="$1"
    local icon_file="$2"

    # check arguments
    if [ -z "$dmg_file" ] || [ -z "$icon_file" ]; then
        echo "Error: DMG file and icon file must be specified" >&2
        exit 2
    fi

    # verify files exist and are accessible
    if [ ! -f "$dmg_file" ] || [ ! -r "$dmg_file" ] || [ ! -w "$dmg_file" ]; then
        echo "Error: DMG file not found or not accessible: $dmg_file" >&2
        exit 1
    fi
    if [ ! -f "$icon_file" ] || [ ! -r "$icon_file" ]; then
        echo "Error: Icon file not found or not readable: $icon_file" >&2
        exit 1
    fi

    # set the icon using AppleScript with Cocoa
    osascript <<-EOF >/dev/null
	use framework "Cocoa"

	set sourcePath to "$icon_file"
	set destPath to "$dmg_file"

	set imageData to (current application's NSImage's alloc()'s initWithContentsOfFile:sourcePath)
	(current application's NSWorkspace's sharedWorkspace()'s setIcon:imageData forFile:destPath options:2)
	EOF

    if [ $? -ne 0 ]; then
        echo "Error: Failed to set icon" >&2
        exit 1
    fi

    echo "Custom icon set for $dmg_file using $icon_file"
}

# finalize dmg: eject, convert, rename, and set icon
finalize_dmg() {
    local dmg_temp_file="$1"
    local dmg_file="$2"
    local icon_file="$3"

    echo "Ejecting final DMG"
    hdiutil eject "$disk_id" || {
        echo "Failed to eject final DMG"
        exit 1
    }
    disk_id=''

    echo "Converting DMG to final format"
    rm -f "$dmg_file"
    hdiutil convert -format UDCO "$dmg_temp_file" -o "$dmg_file" || {
        echo "Failed to convert DMG"
        exit 1
    }
    rm -f "$dmg_temp_file" || {
        echo "Failed to remove temporary DMG"
        exit 1
    }

    echo "Setting DMG icon"
    set_dmg_icon "$dmg_file" "$icon_file"
}

main() {
    local build_dir="$1"
    local dist_name="$2"
    local icon_file="$3"
    local back_img="$4"
    local dmg_mb="${5:-64}"

    local app_name="$build_dir/${dist_name}.app"
    local dmg_file="$build_dir/${dist_name}.dmg"
    local dmg_temp_file="$build_dir/${dist_name}_temp.dmg"
    local disk_id=''

    # set trap for cleanup
    trap 'if [ $? -ne 0 ]; then cleanup "$disk_id" "$dmg_temp_file"; fi' EXIT

    setup_dmg "$dmg_temp_file" "$dist_name" "$dmg_mb"
    populate_dmg "$dmg_temp_file" "$dist_name" "$app_name" "$back_img" "$icon_file"
    finalize_dmg "$dmg_temp_file" "$dmg_file" "$icon_file"

    echo "DMG creation completed: $dmg_file"
}

# execute main
main "$@"
