#!/usr/bin/env bash
set -x
# The suffix to use for decrypted files. The default can be overridden using
# the HELM_SECRETS_DEC_SUFFIX environment variable.
DEC_SUFFIX="${HELM_SECRETS_DEC_SUFFIX:-.dec}"

# Make sure HELM_BIN is set (normally by the helm command)
HELM_BIN="${HELM_BIN:-helm}"

getopt --test > /dev/null
if [[ $? -ne 4 ]]
then
    cat <<EOF
I’m sorry, "getopt --test" failed in this environment.

You may need to install enhanced getopt, e.g. on OSX using
"brew install gnu-getopt".
EOF
    exit 1
fi

set -ueo pipefail

usage() {
    cat <<EOF
GnuPG secrets encryption in Helm Charts

This plugin provides ability to encrypt/decrypt secrets files
to store in less secure places, before they are installed using
Helm.

To decrypt/encrypt/edit you need to initialize/first encrypt secrets with
sops - https://github.com/mozilla/sops

Available Commands:
  enc    	Encrypt secrets file
  dec    	Decrypt secrets file
  view   	Print secrets decrypted
  edit   	Edit secrets file and encrypt afterwards
  clean         Remove all decrypted files in specified directory (recursively)
  install	wrapper that decrypts secrets[.*].yaml files before running helm install
  upgrade	wrapper that decrypts secrets[.*].yaml files before running helm upgrade
  lint		wrapper that decrypts secrets[.*].yaml files before running helm lint
  diff		wrapper that decrypts secrets[.*].yaml files before running helm diff
                  (diff is a helm plugin)

EOF
}

enc_usage() {
    cat <<EOF
Encrypt secrets

It uses your gpg credentials to encrypt .yaml file. If the file is already
encrypted, look for a decrypted ${DEC_SUFFIX} file and encrypt that to .yaml.
This allows you to first decrypt the file, edit it, then encrypt it again.

You can use plain sops to encrypt - https://github.com/mozilla/sops

Example:
  $ ${HELM_BIN} secrets enc <SECRET_FILE_PATH>
  $ git add <SECRET_FILE_PATH>
  $ git commit
  $ git push

EOF
}

dec_usage() {
    cat <<EOF
Decrypt secrets

It uses your gpg credentials to decrypt previously encrypted .yaml file.
Produces ${DEC_SUFFIX} file.

You can use plain sops to decrypt specific files - https://github.com/mozilla/sops

Example:
  $ ${HELM_BIN} secrets dec <SECRET_FILE_PATH>

Typical usage:
  $ ${HELM_BIN} secrets dec secrets/myproject/secrets.yaml
  $ vim secrets/myproject/secrets.yaml.dec

EOF
}

view_usage() {
    cat <<EOF
View specified secrets[.*].yaml file

Example:
  $ ${HELM_BIN} secrets view <SECRET_FILE_PATH>

Typical usage:
  $ ${HELM_BIN} secrets view secrets/myproject/nginx/secrets.yaml | grep basic_auth

EOF
}

edit_usage() {
    cat <<EOF
Edit encrypted secrets

Decrypt encrypted file, edit and then encrypt

You can use plain sops to edit - https://github.com/mozilla/sops

Example:
  $ ${HELM_BIN} secrets edit <SECRET_FILE_PATH>
  or $ sops <SECRET_FILE_PATH>
  $ git add <SECRET_FILE_PATH>
  $ git commit
  $ git push

EOF
}

clean_usage() {
    cat <<EOF
Clean all decrypted files if any exist

It removes all decrypted ${DEC_SUFFIX} files in the specified directory
(recursively) if they exist.

Example:
  $ ${HELM_BIN} secrets clean <dir with secrets>

EOF
}

install_usage() {
    cat <<EOF
Install a chart

This is a wrapper for the "helm install" command. It will detect -f and
--values options, and decrypt any secrets.*.yaml files before running "helm
install".

Example:
  $ ${HELM_BIN} secrets install <HELM INSTALL OPTIONS>

Typical usage:
  $ ${HELM_BIN} secrets install -n i1 stable/nginx-ingress -f values.test.yaml -f secrets.test.yaml

EOF
}

upgrade_usage() {
    cat <<EOF
Upgrade a deployed release

This is a wrapper for the "helm upgrade" command. It will detect -f and
--values options, and decrypt any secrets.*.yaml files before running "helm
upgrade".

Example:
  $ ${HELM_BIN} secrets upgrade <HELM UPGRADE OPTIONS>

Typical usage:
  $ ${HELM_BIN} secrets upgrade i1 stable/nginx-ingress -f values.test.yaml -f secrets.test.yaml

EOF
}

lint_usage() {
    cat <<EOF
Run helm lint on a chart

This is a wrapper for the "helm lint" command. It will detect -f and
--values options, and decrypt any secrets.*.yaml files before running "helm
lint".

Example:
  $ ${HELM_BIN} secrets lint <HELM LINT OPTIONS>

Typical usage:
  $ ${HELM_BIN} secrets lint ./my-chart -f values.test.yaml -f secrets.test.yaml

EOF
}

diff_usage() {
    cat <<EOF
Run helm diff on a chart

"diff" is a helm plugin. This is a wrapper for the "helm diff" command. It
will detect -f and --values options, and decrypt any secrets.*.yaml files
before running "helm diff".

Example:
  $ ${HELM_BIN} secrets diff <HELM DIFF OPTIONS>

Typical usage:
  $ ${HELM_BIN} secrets diff upgrade i1 stable/nginx-ingress -f values.test.yaml -f secrets.test.yaml

EOF
}

is_help() {
    case "$1" in
	-h|--help|help)
	    return 0
	    ;;
	*)
	    return 1
	    ;;
    esac
}

encrypt_helper() {
    local dir=$(dirname "$1")
    local file=$(basename "$1")
    local type=${file:(-4)}

    cd "$dir"
    [[ -e "$file" ]] || { echo "File does not exist: $dir/$file"; exit 1; }
    local file_dec=$(sed -e "s/\\.$type$/.$type${DEC_SUFFIX}/" <<<"$file")
    [[ -e $file_dec ]] || file_dec="$file"

    if [[ $(grep -C10000 'sops:' "$file_dec" | grep -c 'version:') -gt 0 ]]
    then
	echo "Already encrypted: $file_dec"
	return
    fi
    if [[ $file == $file_dec ]]
    then
	sops --encrypt --input-type $type --output-type $type --in-place "$file"
	echo "Encrypted $file"
    else
	sops --encrypt --input-type $type --output-type $type "$file_dec" > "$file"
	echo "Encrypted $file_dec to $file"
    fi
}

enc() {
    if is_help "$1"
    then
	enc_usage
	return
    fi
    file="$1"
    if [[ ! -f "$file" ]]
    then
	echo "$file doesn't exist."
    else
	echo "Encrypting $file"
	encrypt_helper "$file"
    fi
}

# Name references ("declare -n" and "local -n") are a Bash 4 feature.
# For previous versions, work around using eval.
decrypt_helper() {
    local file="$1" __filedec __dec
    local type=${file:(-4)}
    if [[ ${BASH_VERSINFO[0]} -lt 4 ]]
    then
	local __filedec_var='' __dec_var=''
	[[ $# -ge 2 ]] && __filedec_var=$2
	[[ $# -ge 3 ]] && __dec_var=$3
	[[ $__dec_var ]] && eval $__dec_var=0
    else
	[[ $# -ge 2 ]] && local -n __filedec=$2
	[[ $# -ge 3 ]] && local -n __dec=$3
    fi

    __dec=0
    [[ -e "$file" ]] || { echo "File does not exist: $file"; exit 1; }
    if [[ $(grep -C10000 'sops' "$file" | grep -c 'version') -eq 0 ]]
    then
	echo "Not encrypted: $file"
	__filedec="$file"
    else
	__filedec=$(sed -e "s/\\.$type$/.$type${DEC_SUFFIX}/" <<<"$file")
	if [[ -e $__filedec && $__filedec -nt $file ]]
	then
	    echo "$__filedec is newer than $file"
	else
	    sops --decrypt --input-type $type --output-type type "$file" > "$__filedec" || { rm "$__filedec"; exit 1; }
	    __dec=1
	fi
    fi

    if [[ ${BASH_VERSINFO[0]} -lt 4 ]]
    then
	[[ $__filedec_var ]] && eval $__filedec_var="'$__filedec'"
	[[ $__dec_var ]] && eval $__dec_var="'$__dec'"
    fi
    true # just so that decrypt_helper will exit with a true status on no error
}


dec() {
    if is_help "$1"
    then
	dec_usage
	return
    fi
    file="$1"
    if [[ ! -f "$file" ]]
    then
	echo "$file doesn't exist."
    else
	echo "Decrypting $file"
	decrypt_helper "$file"
    fi
}

view_helper() {
    local file="$1"
    local type=${file:(-4)}
    [[ -e "$file" ]] || { echo "File does not exist: $file"; exit 1; }
    sops --decrypt --input-type $type --output-type yaml "$file"
}

view() {
    if is_help "$1"
    then
	view_usage
	return
    fi
    local file="$1"
    view_helper "$file"
}

edit_helper() {
    local file="$1"
    local type=${file:(-4)}
    [[ -e "$file" ]] || { echo "File does not exist: $file"; exit 1; }
    exec sops --input-type $type --output-type $type "$file" < /dev/tty
}

edit() {
    local file="$1"
    edit_helper "$file"
}

clean() {
    if is_help "$1"
    then
	clean_usage
	return
    fi
    local basedir="$1"
    find "$basedir" -type f -name "*${DEC_SUFFIX}" -print0 | xargs -r0 rm -v
}

helm_wrapper() {
    local cmd="$1" subcmd='' cmd_version=''
    shift
    if [[ $cmd == diff ]]
    then
	subcmd="$1"
	shift
	cmd_version=$(${HELM_BIN} diff version)
    fi

    # cache options for the helm command in a file so we don't need to parse the help each time
    local helm_version=$(${HELM_BIN} version --client --short)
    local cur_options_version="${helm_version}${cmd_version:+ ${cmd}: ${cmd_version}}"
    local optfile="$HELM_PLUGIN_DIR/helm.${cmd}${subcmd:+.$subcmd}.options" options_version='' options='' longoptions=''
    [[ -f $optfile ]] && . "$optfile"

    if [[ $cur_options_version != $options_version ]]
    then
	local re='(-([a-zA-Z0-9]), )?--([-_a-zA-Z0-9]+)( ([a-zA-Z0-9]+))?' line
	options='' longoptions=''

	# parse the helm command options and option args from the help output
	while read line
	do
	    if [[ $line =~ $re ]]
	    then
		local opt="${BASH_REMATCH[2]}" lopt="${BASH_REMATCH[3]}" optarg="${BASH_REMATCH[5]:+:}"
		[[ $opt ]] && options+="${opt}${optarg}"
		[[ $lopt ]] && longoptions+="${longoptions:+,}${lopt}${optarg}"
	    fi
	done <<<"$(${HELM_BIN} "$cmd" $subcmd --help | sed -e '1,/^Flags:/d' -e '/^Global Flags:/,$d' )"

	cat >"$optfile" <<EOF
options_version='$cur_options_version'
options='$options'
longoptions='$longoptions'
EOF
    fi
    
    # parse command line
    local parsed # separate line, otherwise the return value of getopt is ignored
    # if parsing fails, getopt returns non-0, and the shell exits due to "set -e"
    parsed=$(getopt --options="$options" --longoptions="$longoptions" --name="${HELM_BIN} $cmd${subcmd:+ ${subcmd}}" -- "$@")

    # collect cmd options with optional option arguments
    local -a cmdopts=() decfiles=()
    local yml ymldec decrypted
    eval set -- "$parsed"
    while [[ $# -gt 0 ]]
    do
	case "$1" in
	    --)
		# skip --, and what remains are the cmd args
		shift 
		break
		;;
            -f|--values)
		cmdopts+=("$1")
		file="$2"
		if [[ $file =~ ^(.*/)?secrets(\.[^.]+)*\.yaml$ ]] || [[ $file =~ ^(.*/)?secrets(\.[^.]+)*\.json$ ]]
		then
		    decrypt_helper $file filedec decrypted
		    cmdopts+=("$filedec")
		    [[ $decrypted -eq 1 ]] && decfiles+=("$filedec")
		else
		    cmdopts+=("$file")
		fi
		shift # to also skip option arg
		;;
	    *)
		cmdopts+=("$1")
		;;
	esac
	shift
    done

    # run helm command with args and opts in correct order
    set +e # ignore errors
    ${HELM_BIN} ${TILLER_HOST:+--host "$TILLER_HOST" }"$cmd" $subcmd "$@" "${cmdopts[@]}"

    # cleanup on-the-fly decrypted files
    [[ ${#decfiles[@]} -gt 0 ]] && rm -v "${decfiles[@]}"
}

helm_command() {
    if [[ $# -lt 2 ]] || is_help "$2"
    then
	"${1}_usage"
	return
    fi
    helm_wrapper "$@"
}

case "${1:-help}" in
    enc)
	if [[ $# -lt 2 ]]
	then
	    enc_usage
	    echo "Error: secrets file required."
	    exit 1
	fi
	enc "$2"
	shift
	;;
    dec)
	if [[ $# -lt 2 ]]
	then
	    dec_usage
	    echo "Error: secrets file required."
	    exit 1
	fi
	dec "$2"
	;;
    view)
	if [[ $# -lt 2 ]]
	then
	    view_usage
	    echo "Error: secrets file required."
	    exit 1
	fi
	view "$2"
	;;
    edit)
	if [[ $# -lt 2 ]]
	then
	    edit_usage
	    echo "Error: secrets file required."
	    exit 1
	fi
	edit "$2"
	shift
	;;
    clean)
	if [[ $# -lt 2 ]]
	then
	    clean_usage
	    echo "Error: Chart package required."
	    exit 1
	fi
	clean "$2"
	;;
    install|upgrade|lint|diff)
	helm_command "$@"
	;;
    --help|-h|help)
	usage
	;;
    *)
	usage
	exit 1
	;;
esac

exit 0
