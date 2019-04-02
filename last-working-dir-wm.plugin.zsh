#!/bin/env zsh

# The default directory to use if no lwd has been set
typeset -g LWD_DEFAULT_DIR="${LWD_DEFAULT_DIR:-$HOME}"

# The directory for storing lwd runtime files
typeset -g LWD_RUNTIME_DIR="${LWD_RUNTIME_DIR:-${ZSH_CACHE_DIR:-/tmp}/last-working-dir}"

# The directory for storing lwdd (client/daemon) runtime files
typeset -g LWDD_RUNTIME_DIR="${LWDD_RUNTIME_DIR:-$LWD_RUNTIME_DIR/lwdd}"

# If true, automatically cd to the detected lwd on shell init
typeset -g LWD_AUTO_CD="${LWD_AUTO_CD:-1}"

# A list of directories to ignore
[[ ! -v LWD_IGNORE_DIRS ]] && {
	typeset -ga LWD_IGNORE_DIRS
}

typeset -g _lwd_wmfile_name="wmname"

typeset -g _lwdd_pidfile_name="daemon.pid"
typeset -g _lwdd_ctlfile_name="daemon.ctl"

_lwd_get_wss() {
	# matches against desktops named following the format: (MONITOR_INDEX)_(WORKSPACE_INDEX):(WORKSPACE_NAME)
	# where MONITOR_INDEX and WORKSPACE_INDEX are integers and WORKSPACE_NAME is a
	# string containing only lower- and upper-case letters, dashes (-), and underscore (_)
	# e.g. 1_3:Web
	read -rd '' scr <<"EOF"
match($9, /^([[:digit:]]+)_([[:digit:]]+):([[:alpha:]_-]+)$/, m){
	print "local "                 \
		"id='"       m[0]       "' " \
		"screen="    (m[1]+1)    " " \
		"ws_index="  m[2]        " " \
		"ws_name='"  m[3]       "' " \
		"active="    ($2 == "*") ";"
}
EOF
	wmctrl -d | gawk "$scr"
}

_lwd_get_active_ws() {
	while read -r l; do
		eval "$l"
		[[ $active -eq 1 ]] && {
			echo "$l"
			return 0
		}
	done <<<"$(_lwd_get_wss)"
	return 1
}

# Outputs a list of lwd file paths ordered by descending precedence, one per line.
# The files do not necessarily exist.
# Accepts desktop ID as an optional argument; if unspecified, the currently
# active desktop will be used.
_lwd_get_file_paths() {
	local ws
	local query_wm=0
	typeset -A files
	typeset -a query
  local OPTIND OPTARG
	while getopts "wsg" opt; do
		case $opt in
			w)
				query+=('w')
				query_wm=1
				;;
			s)
				query+=('s')
				query_wm=1
				;;
			g)
				query+=('g')
				;;
			\?)
				echo "Invalid option: -$OPTARG" >&2
				return 1
				;;
		esac
	done
  shift $((OPTIND - 1))

	[[ ${#query} -eq 0 ]] && {
		query=('w' 's' 'g')
		query_wm=1
	}

	[[ -v _lwd_wm && $query_wm -eq 1 ]] && {
		if [[ $# -gt 0 ]]; then
			ws="$*"
		else
			ws="$(_lwd_get_active_ws)"
		fi
		eval "$ws"
		[[ ! -v id || ! -v screen ]] && {
			echo "error: expected id and screen to be set" >&2
			return 1
		}
		files['w']="w-$id"
		files['s']="s-$screen"
	}
	files['g']="g"

	for q in "${query[@]}"; do
		f="${files['$q']}"
		[[ ! -z "$f" ]] && echo "${LWD_RUNTIME_DIR}/${f}"
	done
}

_lwd_write() {
	local dir="$PWD"
	local ws
	if [[ $# -ge 1 ]]; then
		if [[ -e "$1" ]]; then
			dir="$1"
			shift
		fi
	fi
	for ignore in $LWD_IGNORE_DIRS; do
		[[ $ignore -ef "$dir" ]] && {
			echo "ignore $dir" >&2
			return 0
		}
	done
	while read -r p; do
		echo "$dir" >| "$p"
	done <<<"$(_lwd_get_file_paths $@)"

	[[ -e "${LWDD_RUNTIME_DIR}/${_lwdd_pidfile_name}" ]] && {
		read -r dpid <"${LWDD_RUNTIME_DIR}/${_lwdd_pidfile_name}"
		[[ -z "$dpid" ]] && return
		kill -USR1 $dpid 2>/dev/null || true
	}
}

_lwd_read() {
	while read -r p; do
		head -1 "$p" 2>/dev/null && return 0
	done <<<"$(_lwd_get_file_paths $@)"
	echo "$LWD_DEFAULT_DIR"
}

# last-working-directory
lwd() {
	_lwd_just_ws=1
	cd "$(_lwd_read $@)"
}

_lwd_chpwd_hook() {
	[[ $_lwd_just_ws -eq 1 ]] && {
		_lwd_just_ws=0
		_lwd_write -w
		return $?
	}
	_lwd_write
}

# determine window manager in use, if any
_lwd_init_wm() {
	[[ -v _lwd_wm ]] && {
		return 0
	}
	local wm
	local wmfile="${LWD_RUNTIME_DIR}/${_lwd_wmfile_name}"
	if [[ -e $wmfile ]]; then
		read -r wm <$wmfile
	fi
	[[ -z "$wm" ]] && {
		if wm="$(wmctrl -m 2>/dev/null)"; then
			wm="$(gawk 'match($0, /^Name: (\w+)$/, m){ print m[1] }' <<<"$wm")"
		else
			wm=""
		fi
		echo $wm >$wmfile
	}
	if [[ -n "$wm" ]]; then
		typeset -g _lwd_wm="$wm"

		# workspace last-working-directory
		alias wwd="lwd -w"

		# screen last-working-directory
		alias swd="lwd -s"

		# global last-working-directory
		alias gwd="lwd -g"
	else
		alias wwd=lwd
		alias swd=lwd
		alias gwd=lwd
	fi
}

# initialize lwd plugin
() {
	[[ ! -v _lwd_init ]] && {
		[[ ! -d "${LWD_RUNTIME_DIR}" ]] && {
			echo "make runtime dir '${LWD_RUNTIME_DIR}'" >&2
			mkdir -p "${LWD_RUNTIME_DIR}" || {
				echo "lwd: error creating runtime directory at '${LWD_RUNTIME_DIR}'" >&2
				return 1
			}
		}

		_lwd_init_wm

		chpwd_functions+=("_lwd_chpwd_hook")

		typeset -g _lwd_init=1
		[[ $LWD_AUTO_CD -eq 1 && $PWD -ef "$LWD_DEFAULT_DIR" ]] && {
			lwd
		}
	}
}
