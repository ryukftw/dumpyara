#!/usr/bin/env bash

[[ $# = 0 ]] && echo "No Input" && exit 1

OS=$(uname)
if [ "$OS" = 'Darwin' ]; then
	export LC_CTYPE=C
fi

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null && pwd)"
# Create input & working directory if it does not exist
mkdir -p "$PROJECT_DIR"/input "$PROJECT_DIR"/working

# Determine which command to use for privilege escalation
if command -v sudo >/dev/null 2>&1; then
	sudo_cmd="sudo"
elif command -v doas >/dev/null 2>&1; then
	sudo_cmd="doas"
else
	echo "Neither sudo nor doas found. Please install one of them."
	exit 1
fi

# Activate virtual environment
source .venv/bin/activate

# GitHub token
if [[ -n $2 ]]; then
	GITLAB_TOKEN=$2
elif [[ -f ".gitlab_token" ]]; then
	GITLAB_TOKEN=$(<.gitlab_token)
else
	echo "Gitlab token not found. Dumping just locally..."
fi

# download or copy from local?
if echo "$1" | grep -e '^\(https\?\|ftp\)://.*$' >/dev/null; then
	# 1DRV URL DIRECT LINK IMPLEMENTATION
	if echo "$1" | grep -e '1drv.ms' >/dev/null; then
		URL=$(curl -I "$1" -s | grep location | sed -e "s/redir/download/g" | sed -e "s/location: //g")
	else
		URL=$1
	fi
	cd "$PROJECT_DIR"/input || exit
	{ type -p aria2c >/dev/null 2>&1 && printf "Downloading File...\n" && aria2c -x16 -j"$(nproc)" "${URL}"; } || { printf "Downloading File...\n" && wget -q --content-disposition --show-progress --progress=bar:force "${URL}" || exit 1; }
	if [[ ! -f "$(echo ${URL##*/} | inline-detox)" ]]; then
		URL=$(wget --server-response --spider "${URL}" 2>&1 | awk -F"filename=" '{print $2}')
	fi
	detox "${URL##*/}"
else
	URL=$(printf "%s\n" "$1")
	[[ -e "$URL" ]] || { echo "Invalid Input" && exit 1; }
fi

GITLAB_INSTANCE="gitlab.com"
GITLAB_HOST="https://${GITLAB_INSTANCE}"
GITLAB_ORG=rmx3371-dumps #your Gitlab org name
FILE=$(echo ${URL##*/} | inline-detox)
EXTENSION=$(echo ${URL##*.} | inline-detox)
UNZIP_DIR=${FILE/.$EXTENSION/}
PARTITIONS="system systemex system_ext system_other vendor cust odm odm_ext oem factory product modem xrom oppo_product opproduct reserve india my_preload my_odm my_stock my_operator my_country my_product my_company my_engineering my_heytap my_custom my_manifest my_carrier my_region my_bigball my_version special_preload vendor_dlkm odm_dlkm system_dlkm mi_ext"

if [[ -d "$1" ]]; then
	echo 'Directory detected. Copying...'
	cp -a "$1" "$PROJECT_DIR"/working/"${UNZIP_DIR}"
elif [[ -f "$1" ]]; then
	echo 'File detected. Copying...'
	cp -a "$1" "$PROJECT_DIR"/input/"${FILE}" >/dev/null 2>&1
fi

# clone other repo's
if [[ -d "$PROJECT_DIR/Firmware_extractor" ]]; then
	git -C "$PROJECT_DIR"/Firmware_extractor pull --recurse-submodules
else
	git clone -q --recurse-submodules https://github.com/AndroidDumps/Firmware_extractor "$PROJECT_DIR"/Firmware_extractor
fi
if [[ -d "$PROJECT_DIR/vmlinux-to-elf" ]]; then
	git -C "$PROJECT_DIR"/vmlinux-to-elf pull --recurse-submodules
else
	git clone -q https://github.com/marin-m/vmlinux-to-elf "$PROJECT_DIR/vmlinux-to-elf"
fi

# extract rom via Firmware_extractor
[[ ! -d "$1" ]] && bash "$PROJECT_DIR"/Firmware_extractor/extractor.sh "$PROJECT_DIR"/input/"${FILE}" "$PROJECT_DIR"/working/"${UNZIP_DIR}"

# Set path for tools
UNPACKBOOTIMG="${PROJECT_DIR}"/Firmware_extractor/tools/unpackbootimg
KALLSYMS_FINDER="${PROJECT_DIR}"/vmlinux-to-elf/vmlinux_to_elf/kallsyms_finder.py
VMLINUX_TO_ELF="${PROJECT_DIR}"/vmlinux-to-elf/vmlinux_to_elf/main.py

# Extract 'boot.img'
if [[ -f "$PROJECT_DIR"/working/"${UNZIP_DIR}"/boot.img ]]; then
	# Set a variable for each path
	## Image
	IMAGE=${PROJECT_DIR}/working/${UNZIP_DIR}/boot.img

	## Output(s)
	OUTPUT=${PROJECT_DIR}/working/${UNZIP_DIR}/boot

	# Create necessary directories
	mkdir -p "${OUTPUT}/dtb"
	mkdir -p "${OUTPUT}/dts"

	# Extract 'boot.img' content(s)
	"${UNPACKBOOTIMG}" -i "${IMAGE}" -o "${OUTPUT}" >/dev/null 2>&1
	echo 'boot extracted'

	# Extract 'dtb' and decompile then
	extract-dtb "${IMAGE}" -o "${OUTPUT}/dtb" >/dev/null
	rm -rf "${OUTPUT}/dtb/00_kernel"

	## Check whether device-tree blobs were extracted or not
	if [ "$(find ${OUTPUT_DTB} -name "*.dtb")" ]; then
		for dtb in $(find "${OUTPUT_DTB}" -type f); do
			dtc -q -I dtb -O dts "${dtb}" >>"${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')"
		done
		echo 'boot (dtb, dts) extracted'
	else
		## Extraction failed, device-tree resources are probably somewhere else.
		rm -rf "${OUTPUT}/dtb" \
			"${OUTPUT}/dts"
	fi

	# Run 'extract-ikconfig'
	[[ ! -e "${PROJECT_DIR}"/extract-ikconfig ]] && curl https://raw.githubusercontent.com/torvalds/linux/master/scripts/extract-ikconfig >"${PROJECT_DIR}"/extract-ikconfig
	bash "${PROJECT_DIR}"/extract-ikconfig "${IMAGE}" >"$PROJECT_DIR"/working/"${UNZIP_DIR}"/ikconfig

	# Run 'vmlinux-to-elf'
	mkdir -p "$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootRE
	python3 "${KALLSYMS_FINDER}" "${IMAGE}" >"$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootRE/boot_kallsyms.txt 2>&1
	echo 'boot_kallsyms.txt generated'
	python3 "${VMLINUX_TO_ELF}" "${IMAGE}" "$PROJECT_DIR"/working/"${UNZIP_DIR}"/bootRE/boot.elf >/dev/null 2>&1
	echo 'boot.elf generated'
fi

# Extract 'vendor_boot'
if [[ -f "$PROJECT_DIR"/working/"${UNZIP_DIR}"/vendor_boot.img ]]; then
	# Set a variable for each path
	## Image
	IMAGE=${PROJECT_DIR}/working/${UNZIP_DIR}/vendor_boot.img

	## Output(s)
	OUTPUT=${PROJECT_DIR}/working/${UNZIP_DIR}/boot

	# Create necessary directories
	mkdir -p "${OUTPUT}/dtb"
	mkdir -p "${OUTPUT}/dts"

	# Extract 'vendor_boot.img' content(s)
	"${UNPACKBOOTIMG}" -i "${IMAGE}" -o "${OUTPUT}" >/dev/null 2>&1
	echo 'vendor_boot extracted'

	# Extract 'dtb' and decompile then
	extract-dtb "${IMAGE}" -o "${OUTPUT}/dtb" >/dev/null

	## Check whether device-tree blobs were extracted or not
	if [ "$(find "${OUTPUT}/dtb" -name "*.dtb")" ]; then
		for dtb in $(find "${OUTPUT}/dtb" -type f); do
			dtc -q -I dtb -O dts "${dtb}" >>"${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')"
		done
		echo 'vendor_boot (dtb, dts) extracted'
	else
		## Extraction failed, device-tree resources are probably somewhere else.
		rm -rf "${OUTPUT}/dtb" \
			"${OUTPUT}/dts"
	fi
fi

# Extract 'vendor_kernel_boot'
if [[ -f "$PROJECT_DIR"/working/"${UNZIP_DIR}"/vendor_kernel_boot.img ]]; then
	# Set a variable for each path
	## Image
	IMAGE=${PROJECT_DIR}/working/${UNZIP_DIR}/vendor_kernel_boot.img

	## Output(s)
	OUTPUT=${PROJECT_DIR}/working/${UNZIP_DIR}/vendor_kernel_boot

	# Create necessary directories
	mkdir -p "${OUTPUT}/dtb"
	mkdir -p "${OUTPUT}/dts"

	# Extract 'vendor_boot.img' content(s)
	"${UNPACKBOOTIMG}" -i "${IMAGE}" -o "${OUTPUT}" >/dev/null 2>&1
	echo 'vendor_kernel_boot extracted'

	# Extract 'dtb' and decompile then
	extract-dtb "${IMAGE}" -o "${OUTPUT}/dtb" >/dev/null
	rm -rf "${OUTPUT}/dtb/00_kernel"

	## Check whether device-tree blobs were extracted or not
	if [ "$(find "${OUTPUT}/dtb" -name "*.dtb")" ]; then
		for dtb in $(find "${OUTPUT}/dtb" -type f); do
			dtc -q -I dtb -O dts "${dtb}" >>"${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')"
		done
		echo 'vendor_kernel_boot (dtb, dts) extracted'
	else
		# Extraction failed, device-tree resources are probably somewhere else.
		rm -rf "${OUTPUT}/dtb" \
			"${OUTPUT}/dts"
	fi
fi

# Extract 'init_boot'
if [[ -f "$PROJECT_DIR"/working/"${UNZIP_DIR}"/init_boot.img ]]; then
	# Set a variable for each path
	## Image
	IMAGE=${PROJECT_DIR}/working/${UNZIP_DIR}/init_boot.img

	## Output(s)
	OUTPUT=${PROJECT_DIR}/working/${UNZIP_DIR}/init_boot

	# Extract 'init_boot.img' content(s)
	"${UNPACKBOOTIMG}" -i "${IMAGE}" -o "${OUTPUT}" >/dev/null 2>&1
	echo 'init_boot extracted'
fi

if [[ -f "$PROJECT_DIR"/working/"${UNZIP_DIR}"/dtbo.img ]]; then
	# Set a variable for each path
	## Image
	IMAGE=${PROJECT_DIR}/working/${UNZIP_DIR}/dtbo.img

	## Output(s)
	OUTPUT=${PROJECT_DIR}/working/${UNZIP_DIR}/dtbo

	# Create necessary directories
	mkdir -p "${OUTPUT}/dts"

	# Extract 'dtb' and decompile them
	extract-dtb "${IMAGE}" -o "${OUTPUT}" >/dev/null
	rm -rf "${OUTPUT}/00_kernel"
	for dtb in $(find "${PROJECT_DIR}/working/${UNZIP_DIR}/dtbo" -type f -name "*.dtb"); do
		dtc -q -I dtb -O dts "${dtb}" >>"${OUTPUT}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')"
	done
	echo 'dtbo extracted'
fi

# extract PARTITIONS
cd "$PROJECT_DIR"/working/"${UNZIP_DIR}" || exit
for p in $PARTITIONS; do
	# Try to extract images via fsck.erofs
	if [ -f $p.img ] && [ $p != "modem" ]; then
		echo "Trying to extract $p partition via fsck.erofs."
		"$PROJECT_DIR"/Firmware_extractor/tools/fsck.erofs --extract="$p" "$p".img
		# Deletes images if they were correctly extracted via fsck.erofs
		if [ -d "$p" ]; then
			rm "$p".img >/dev/null 2>&1
		else
			# Uses 7z if images could not be extracted via fsck.erofs
			if [[ -e "$p.img" ]]; then
				mkdir "$p" 2>/dev/null || rm -rf "${p:?}"/*
				echo "Extraction via fsck.erofs failed, extracting $p partition via 7z"
				7z x "$p".img -y -o"$p"/ >/dev/null 2>&1
				if [ $? -eq 0 ]; then
					rm "$p".img >/dev/null 2>&1
				else
					echo "Couldn't extract $p partition via 7z. Using mount loop"
					$sudo_cmd mount -o loop -t auto "$p".img "$p"
					mkdir "${p}_"
					$sudo_cmd cp -rf "${p}/"* "${p}_"
					$sudo_cmd umount "${p}"
					$sudo_cmd cp -rf "${p}_/"* "${p}"
					$sudo_cmd rm -rf "${p}_"
					if [ $? -eq 0 ]; then
						rm -fv "$p".img >/dev/null 2>&1
					else
						echo "Couldn't extract $p partition. It might use an unsupported filesystem."
						echo "For EROFS: make sure you're using Linux 5.4+ kernel."
						echo "For F2FS: make sure you're using Linux 5.15+ kernel."
					fi
				fi
			fi
		fi
	fi
done

# Fix permissions
$sudo_cmd chown "$(whoami)" "$PROJECT_DIR"/working/"${UNZIP_DIR}"/./* -fR
$sudo_cmd chmod -fR u+rwX "$PROJECT_DIR"/working/"${UNZIP_DIR}"/./*

# board-info.txt
find "$PROJECT_DIR"/working/"${UNZIP_DIR}"/modem -type f -exec strings {} \; | grep "QC_IMAGE_VERSION_STRING=MPSS." | sed "s|QC_IMAGE_VERSION_STRING=MPSS.||g" | cut -c 4- | sed -e 's/^/require version-baseband=/' >>"$PROJECT_DIR"/working/"${UNZIP_DIR}"/board-info.txt
find "$PROJECT_DIR"/working/"${UNZIP_DIR}"/tz* -type f -exec strings {} \; | grep "QC_IMAGE_VERSION_STRING" | sed "s|QC_IMAGE_VERSION_STRING|require version-trustzone|g" >>"$PROJECT_DIR"/working/"${UNZIP_DIR}"/board-info.txt
if [ -e "$PROJECT_DIR"/working/"${UNZIP_DIR}"/vendor/build.prop ]; then
	strings "$PROJECT_DIR"/working/"${UNZIP_DIR}"/vendor/build.prop | grep "ro.vendor.build.date.utc" | sed "s|ro.vendor.build.date.utc|require version-vendor|g" >>"$PROJECT_DIR"/working/"${UNZIP_DIR}"/board-info.txt
fi
sort -u -o "$PROJECT_DIR"/working/"${UNZIP_DIR}"/board-info.txt "$PROJECT_DIR"/working/"${UNZIP_DIR}"/board-info.txt

# set variables
ls system/build*.prop 2>/dev/null || ls system/system/build*.prop 2>/dev/null || { echo "No system build*.prop found, pushing cancelled!" && exit; }
flavor=$(grep -oP "(?<=^ro.build.flavor=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z "${flavor}" ]] && flavor=$(grep -oP "(?<=^ro.vendor.build.flavor=).*" -hs vendor/build*.prop)
[[ -z "${flavor}" ]] && flavor=$(grep -oP "(?<=^ro.system.build.flavor=).*" -hs {system,system/system}/build*.prop)
[[ -z "${flavor}" ]] && flavor=$(grep -oP "(?<=^ro.build.type=).*" -hs {system,system/system}/build*.prop)
release=$(grep -oP "(?<=^ro.build.version.release=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z "${release}" ]] && release=$(grep -oP "(?<=^ro.vendor.build.version.release=).*" -hs vendor/build*.prop)
[[ -z "${release}" ]] && release=$(grep -oP "(?<=^ro.system.build.version.release=).*" -hs {system,system/system}/build*.prop)
release=$(echo "$release" | head -1)
id=$(grep -oP "(?<=^ro.build.id=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z "${id}" ]] && id=$(grep -oP "(?<=^ro.vendor.build.id=).*" -hs vendor/build*.prop)
[[ -z "${id}" ]] && id=$(grep -oP "(?<=^ro.system.build.id=).*" -hs {system,system/system}/build*.prop)
incremental=$(grep -oP "(?<=^ro.build.version.incremental=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z "${incremental}" ]] && incremental=$(grep -oP "(?<=^ro.vendor.build.version.incremental=).*" -hs vendor/build*.prop)
[[ -z "${incremental}" ]] && incremental=$(grep -oP "(?<=^ro.system.build.version.incremental=).*" -hs {system,system/system}/build*.prop)
tags=$(grep -oP "(?<=^ro.build.tags=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z "${tags}" ]] && tags=$(grep -oP "(?<=^ro.vendor.build.tags=).*" -hs vendor/build*.prop)
[[ -z "${tags}" ]] && tags=$(grep -oP "(?<=^ro.system.build.tags=).*" -hs {system,system/system}/build*.prop)
platform=$(grep -oP "(?<=^ro.board.platform=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z "${platform}" ]] && platform=$(grep -oP "(?<=^ro.vendor.board.platform=).*" -hs vendor/build*.prop)
[[ -z "${platform}" ]] && platform=$(grep -oP "(?<=^ro.system.board.platform=).*" -hs {system,system/system}/build*.prop)
manufacturer=$(grep -oP "(?<=^ro.product.odm.manufacturer=).*" -hs odm/etc/build*.prop)
[[ -z "${manufacturer}" ]] && manufacturer=$(grep -oP "(?<=^ro.product.manufacturer=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z "${manufacturer}" ]] && manufacturer=$(grep -oP "(?<=^ro.vendor.product.manufacturer=).*" -hs vendor/build*.prop)
[[ -z "${manufacturer}" ]] && manufacturer=$(grep -oP "(?<=^ro.system.product.manufacturer=).*" -hs {system,system/system}/build*.prop)
[[ -z "${manufacturer}" ]] && manufacturer=$(grep -oP "(?<=^ro.product.vendor.manufacturer=).*" -hs vendor/build*.prop)
[[ -z "${manufacturer}" ]] && manufacturer=$(grep -oP "(?<=^ro.product.system.manufacturer=).*" -hs {system,system/system}/build*.prop)
fingerprint=$(grep -oP "(?<=^ro.odm.build.fingerprint=).*" -hs odm/etc/*build*.prop)
[[ -z "${fingerprint}" ]] && fingerprint=$(grep -oP "(?<=^ro.build.fingerprint=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z "${fingerprint}" ]] && fingerprint=$(grep -oP "(?<=^ro.vendor.build.fingerprint=).*" -hs vendor/build*.prop)
[[ -z "${fingerprint}" ]] && fingerprint=$(grep -oP "(?<=^ro.system.build.fingerprint=).*" -hs {system,system/system}/build*.prop)
codename=$(grep -oP "(?<=^ro.product.odm.device=).*" -hs odm/etc/build*.prop | head -1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.product.device=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.product.vendor.device=).*" -hs vendor/build*.prop | head -1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.vendor.product.device=).*" -hs vendor/build*.prop | head -1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.product.system.device=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z "${codename}" ]] && codename=$(echo "$fingerprint" | cut -d / -f3 | cut -d : -f1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.build.fota.version=).*" -hs {system,system/system}/build*.prop | cut -d - -f1 | head -1)
[[ -z "${codename}" ]] && codename=$(grep -oP "(?<=^ro.build.product=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
brand=$(grep -oP "(?<=^ro.product.odm.brand=).*" -hs odm/etc/${codename}_build.prop | head -1)
[[ -z "${brand}" ]] && brand=$(grep -oP "(?<=^ro.product.odm.brand=).*" -hs odm/etc/build*.prop | head -1)
[[ -z "${brand}" ]] && brand=$(grep -oP "(?<=^ro.product.brand=).*" -hs {vendor,system,system/system}/build*.prop | head -1)
[[ -z "${brand}" ]] && brand=$(grep -oP "(?<=^ro.product.vendor.brand=).*" -hs vendor/build*.prop | head -1)
[[ -z "${brand}" ]] && brand=$(grep -oP "(?<=^ro.vendor.product.brand=).*" -hs vendor/build*.prop | head -1)
[[ -z "${brand}" ]] && brand=$(grep -oP "(?<=^ro.product.system.brand=).*" -hs {system,system/system}/build*.prop | head -1)
[[ -z "${brand}" ]] && brand=$(echo "$fingerprint" | cut -d / -f1)
description=$(grep -oP "(?<=^ro.build.description=).*" -hs {system,system/system,vendor}/build*.prop)
[[ -z "${description}" ]] && description=$(grep -oP "(?<=^ro.vendor.build.description=).*" -hs vendor/build*.prop)
[[ -z "${description}" ]] && description=$(grep -oP "(?<=^ro.system.build.description=).*" -hs {system,system/system}/build*.prop)
[[ -z "${description}" ]] && description="$flavor $release $id $incremental $tags"
is_ab=$(grep -oP "(?<=^ro.build.ab_update=).*" -hs {system,system/system,vendor}/build*.prop | head -1)
[[ -z "${is_ab}" ]] && is_ab="false"
branch=$(echo "$description" | tr ' ' '-')
platform=$(echo "$platform" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
repo=$(printf "${brand}" | tr '[:upper:]' '[:lower:]' && echo -e "/${codename}")
top_codename=$(echo "$codename" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
manufacturer=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
printf "# %s\n- manufacturer: %s\n- platform: %s\n- codename: %s\n- flavor: %s\n- release: %s\n- id: %s\n- incremental: %s\n- tags: %s\n- fingerprint: %s\n- is_ab: %s\n- brand: %s\n- branch: %s\n- repo: %s\n" "$description" "$manufacturer" "$platform" "$codename" "$flavor" "$release" "$id" "$incremental" "$tags" "$fingerprint" "$is_ab" "$brand" "$branch" "$repo" >"$PROJECT_DIR"/working/"${UNZIP_DIR}"/README.md
cat "$PROJECT_DIR"/working/"${UNZIP_DIR}"/README.md

# Generate AOSP device tree
if python3 -c "import aospdtgen"; then
	echo "aospdtgen installed, generating device tree"
	mkdir -p "${PROJECT_DIR}/working/${UNZIP_DIR}/aosp-device-tree"
	if python3 -m aospdtgen . --output "${PROJECT_DIR}/working/${UNZIP_DIR}/aosp-device-tree"; then
		echo "AOSP device tree successfully generated"
	else
		echo "Failed to generate AOSP device tree"
	fi
fi

# copy file names
chown "$(whoami)" ./* -R
chmod -R u+rwX ./* #ensure final permissions
find "$PROJECT_DIR"/working/"${UNZIP_DIR}" -type f -printf '%P\n' | sort | grep -v ".git/" >"$PROJECT_DIR"/working/"${UNZIP_DIR}"/all_files.txt

# Check if GITLAB_TOKEN is set
if [[ -n $GITLAB_TOKEN ]]; then

	# Check if firmware is already dumped
	if curl -sL "${GITLAB_HOST}/${GITLAB_ORG}/${repo}/-/raw/${branch}/all_files.txt" | grep -q "all_files.txt"; then
		echo -e "Firmware already dumped!\nGo to https://$GITLAB_INSTANCE/${GITLAB_ORG}/${repo}/-/tree/${branch}\n"
		exit 1
	fi

	# Get Group ID
	GRP_ID=$(curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" "${GITLAB_HOST}/api/v4/groups/${GITLAB_ORG}" | jq -r '.id')

	# Create Subgroup
	curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
		--header "Content-Type: application/json" \
		--data "{\"name\": \"${brand}\", \"path\": \"$(echo ${brand} | tr '[:upper:]' '[:lower:]')\", \"visibility\": \"public\", \"parent_id\": \"${GRP_ID}\"}" \
		"${GITLAB_HOST}/api/v4/groups/"

	# Get Subgroup ID
	SUBGRP_ID=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
		"${GITLAB_HOST}/api/v4/groups/${GITLAB_ORG}/subgroups" | jq -r ".[] | select(.path==\"$(echo ${brand} | tr '[:upper:]' '[:lower:]')\") | .id")

	# Create Repository
	curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
		-X POST \
		"${GITLAB_HOST}/api/v4/projects?name=${codename}&namespace_id=${SUBGRP_ID}&visibility=public"

	# Get Project ID
	PROJECT_ID=$(curl -s --header "PRIVATE-TOKEN: $GITLAB_TOKEN" \
		"${GITLAB_HOST}/api/v4/groups/${SUBGRP_ID}/projects" | jq -r ".[] | select(.path==\"${codename}\") | .id")

	# Make project public
	curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
		--request PUT \
		--url "${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}" \
		--data "visibility=public"

	# Git setup
	git init --initial-branch "$branch"
	git config user.email "${GIT_EMAIL:-AndroidDumps@github.com}"
	git config user.name "${GIT_NAME:-AndroidDumps}"

	# Git push function
	git_push() {
		git commit -asm "$1"
		git push "git@$GITLAB_INSTANCE:$GITLAB_ORG/$repo.git" HEAD:refs/heads/"$branch"
	}

	# Add and push files
	git add vendor/ && git_push "Add vendor for ${description}"
	git add system/{system/app,app}/ && git_push "Add system app for ${description}"
	git add system/{system/priv-app,priv-app}/ && git_push "Add system priv-app for ${description}"
	git add system/ && git_push "Add system for ${description}"
	git add product/{app,priv-app}/ && git_push "Add product app for ${description}"
	git add product/ && git_push "Add product for ${description}"

	# Set default branch
	curl -s --header "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
		--request PUT \
		--url "${GITLAB_HOST}/api/v4/projects/${PROJECT_ID}" \
		--data "default_branch=${branch}"

else
	echo "Dump done locally."
	exit 1
fi

# Telegram channel
TG_TOKEN=$(<"$PROJECT_DIR"/.tgtoken)
CHAT_ID="@hopireika_dump"
tg_html_text="<b>Brand</b>: <code>$brand</code>
<b>Device</b>: <code>$codename</code>
<b>Version</b>: <code>$release</code>
<b>Fingerprint</b>: <code>$fingerprint</code>
<b>Platform</b>: <code>$platform</code>
[<a href=\"https://$GITLAB_INSTANCE/$GITLAB_ORG/$repo/tree/$branch/\">repo</a>] $link"

# Send message to Telegram channel
curl --compressed -s "https://api.telegram.org/bot${TG_TOKEN}/sendmessage" --data "text=${tg_html_text}&chat_id=$CHAT_ID&parse_mode=HTML&disable_web_page_preview=True" >/dev/null
