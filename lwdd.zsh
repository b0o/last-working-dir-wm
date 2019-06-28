#!/bin/env zsh
sourcedir="$(dirname $0)"

LWD_AUTO_CD=0
source "${sourcedir}/last-working-dir-wm.plugin.zsh"

typeset -g  quiet=0
typeset -g  logfile

typeset -g  mode="daemon"

typeset -g  daemon_ctlfile
typeset -g  daemon_pidfile

typeset -g  daemon_interval=0.5
typeset -gA workspaces
typeset -gA screen_active_ws
typeset -gA screen_pipes

typeset -g  client_daemon_pid
typeset -g  client_pidfile
typeset -g  client_screen
typeset -g  client_replace=0
typeset -g  client_wait=0
typeset -g  client_retry_interval=1

typeset -g  client_transform="print"

client_transform() {
	[[ -z $client_transform ]] && {
		cat
		return
	}
	_log "client_transform: '$client_transform'"
	awk "$client_transform" || {
		_log "error: client_transform exited with code $?"
		exit 1
	}
}

_log() {
	[[ -z $logfile ]] && {
		[[ $quiet -eq 0 ]] && {
			echo "$*" >&2
		}
	} || {
		echo "$*" >>$logfile
	}
}

daemon_setup() {
	daemon_pidfile="${LWDD_RUNTIME_DIR}/${_lwdd_pidfile_name}"
	daemon_ctlfile="${LWDD_RUNTIME_DIR}/${_lwdd_ctlfile_name}"
	[[ -e "$daemon_pidfile" ]] && {
		local lpid
		read -r lpid <"$daemon_pidfile"
		[[ -n "$lpid" ]] && {
			ps --pid="$lpid" &>/dev/null && {
				daemon_pidfile=""
				_log "error: lwdd already running (pid=$lpid)"
				return 1
			}
			[[ $1 -ne 1 ]] && {
				_log "warning: stale pidfile found at '$daemon_pidfile' - cleaning up..."
				daemon_cleanup
				daemon_setup 1
				return $?
			}
			_log "error: unexpected file(s) at '$LWDD_RUNTIME_DIR'"
			return 1
		}
	}
	echo $$ > "$daemon_pidfile"

	mkfifo "$daemon_ctlfile" || {
		_log "error: unable to create ctlfile at ${daemon_ctlfile}"
		return 1
	}

	# initialize a pipe for each screen
	while read -r l; do
		eval "$l"
		local fifo="${screen_pipes[$screen]}"
		[[ -z "$fifo" ]] && {
			fifo="${LWDD_RUNTIME_DIR}/screen-${screen}"
			[[ -p "$fifo" ]] || {
				mkfifo "$fifo" || {
					_log "error: unable to create FIFO at ${fifo}"
					return 1
				}
			}
			_log "use fifo '$fifo' for screen '$screen'"
			screen_pipes[$screen]="$fifo"
		}
	done <<<"$(_lwd_get_wss)"
	return 0
}

daemon_cleanup() {
	for screen in "${(k)screen_pipes[@]}"; do
		local fifo="${screen_pipes[$screen]}"
		local j=${screen_tx_jobs[$screen]}
		[[ $j -gt 0 ]] && {
			kill -KILL $j 2>/dev/null && {
				_log "killed tx job '$j'"
			}
			unset "screen_tx_jobs[$screen]"
		}
		[[ -p $fifo ]] && {
			_log "unlink '$fifo'"
			unlink "$fifo"
		}
	done
	[[ -e "$daemon_ctlfile" ]] && {
		_log "unlink ctlfile '$daemon_ctlfile'"
		unlink "$daemon_ctlfile"
	}
	[[ -e "$daemon_pidfile" ]] && {
		_log "unlink pidfile '$daemon_pidfile'"
		unlink "$daemon_pidfile"
	}
}

set_active_ws() {
	local l
	if [[ $# -eq 0 ]]; then
		l="$(_lwd_get_active_ws)"
	else
		l="$1"
	fi
	eval "$l"
	_log "set active ws for screen '$screen' to '$id'"
	screen_active_ws[$screen]="$id"
	tx_screen_lwd "$screen"
}

update_screens() {
	_log "update screens"
	for screen in "${(k)screen_pipes[@]}"; do
		tx_screen_lwd "$screen"
	done
}

tx_screen_lwd() {
	local screen="$1"
	[[ ! -p "${screen_pipes[$screen]}" ]] && {
		echo "error: no named pipe for screen '$screen' at '${screen_pipes[$screen]}'"
		return 1
	}
	local l d
	l="${workspaces[${screen_active_ws[$screen]}]}"
	d="$(_lwd_read "$l")"

	integer j
	j=${screen_tx_jobs[$screen]}
	[[ $j -gt 0 ]] && {
		_log "kill write job for screen '$screen' (pid=$j)"
		kill -TERM $j 2>/dev/null
	}

	_log "tx '$d' > '${screen_pipes[$screen]}'"
	() {
		echo "$d" > "${screen_pipes[$screen]}"
		unset "screen_tx_jobs[$screen]"
	} &

	j=$!
	[[ $j -gt 0 ]] && {
		screen_tx_jobs[$screen]=$j
	}
}

daemon_read_wss() {
	while read -r l; do
		eval "$l"
		if [[ ! -v "workspaces[$id]" ]]; then
			# this is a newly seen workspace, add it to workspaces array
			workspaces[$id]="$l"
		elif [[ ${workspaces[$id]} == "$l" ]]; then
			# ws hasn't changed since last time we saw it
			continue
		fi
		[[ $active -eq 1 ]] && {
			set_active_ws "$l"
		}
		workspaces[$id]="$l"
	done <<<"$(_lwd_get_wss)"
}

daemon_read_ctl() {
	integer fd e
	local l
	exec {fd}<>"$daemon_ctlfile"
	read -t 0.01 -u $fd cmd && [[ -n "$cmd" ]] && {
		_log "rx ctl cmd: '$cmd'"
		daemon_parse_ctl "$cmd"
	}
	exec {fd}>&-
}

daemon_parse_ctl() {
	local _ifs="$IFS"
	local IFS=' '
	read -Ar cmd <<< "$1"
	local IFS="$_ifs"
	if [[ ${#cmd[@]} -eq 2 && ${cmd[1]} == "screen_lwd" ]]; then
		tx_screen_lwd "${cmd[2]}"
	else
		_log "warning: unknown cmd '${cmd[1]}'"
		return 1
	fi
}

daemon_loop() {
	while daemon_read_wss; do
		daemon_read_ctl
		sleep "$daemon_interval"
	done
}

client_setup() {
	daemon_pidfile="${LWDD_RUNTIME_DIR}/${_lwdd_pidfile_name}"
	daemon_ctlfile="${LWDD_RUNTIME_DIR}/${_lwdd_ctlfile_name}"

	[[ ! -e "$daemon_pidfile" ]] && {
		_log "error: no lwd daemon is running"
		return 1
	}
	read -r client_daemon_pid <"$daemon_pidfile"
	ps --pid="$client_daemon_pid" &>/dev/null || {
		_log "error: lwd daemon daemon_pidfile exists but process not found (pid=$client_daemon_pid)"
		return 1
	}
	client_pipe="${LWDD_RUNTIME_DIR}/screen-${client_screen}"
	[[ ! -p "$client_pipe" ]] && {
		_log "error: unable to connect to lwd daemon client pipe (pid=$client_daemon_pid) at '$client_pipe'"
		return 1
	}
	[[ ! -p "$daemon_ctlfile" ]] && {
		_log "error: unable to connect to lwd daemon control pipe (pid=$client_daemon_pid) at '$daemon_ctlfile'"
		return 1
	}

	client_pidfile="${LWDD_RUNTIME_DIR}/client-${client_screen}.pid"
	[[ -e "$client_pidfile" ]] && {
		local lpid
		local stale=0
		read -r lpid <"$client_pidfile"
		if [[ -n "$lpid" ]]; then
			if ps --pid="$lpid" &>/dev/null; then
				if [[ $client_replace -eq 1 ]]; then
					_log "warning: replacing existing lwdd client for screen $client_screen (pid=$lpid)"
					kill -TERM $lpid || {
						_log "error: unable to kill client"
						return 2
					}
					local i=0
					local timeout=5
					while ps --pid="$lpid" &>/dev/null; do
							[[ $i -ge $timeout ]] && {
								_log "error: timed out trying to replace client $lpid"
								return 1
							}
							_log "waiting for replaced client to die..."
							sleep 1
							i=$((i + 1))
					done
					_log "successfully replaced client $lpid"
				else
					client_pidfile=""
					_log "error: lwdd client already running for screen $client_screen (pid=$lpid)"
					return 2
				fi
			else
				stale=1
			fi
		else
			stale=1
		fi
		[[ $stale -eq 1 ]] && {
			_log "warning: stale pidfile found at '$client_pidfile' - cleaning up..."
			unlink "$client_pidfile" || return 1
		}
	}
	echo $$ > "$client_pidfile"
	return 0
}

client_cleanup() {
	[[ -n "$client_pidfile" && -e "$client_pidfile" ]] && {
		_log "unlink pidfile '$client_pidfile'"
		unlink "$client_pidfile"
	}
	[[ -n "$client_pidfile" && -e "$client_pidfile" ]] && {
		_log "unlink pidfile '$client_pidfile'"
		unlink "$client_pidfile"
	}
}

client_req_ws() {
	local cmd="screen_lwd $client_screen"
	_log "tx ctl cmd: '$cmd'"
	echo "$cmd" >> "$daemon_ctlfile"
}

client_loop() {
	client_req_ws
	while read -r l <"$client_pipe"; do
		echo "$l" | client_transform
	done
}

daemon_handle() {
	local sig="$1"
	_log "-\nFATAL: caught SIG${sig}"
	if [[ $sig == "USR1" ]]; then
		update_screens
	elif [[ $sig == "USR2" ]]; then
		_log "warning: SIGUSR2 not implemented"
	else
		_log "Exiting..."
		daemon_cleanup
		exit 1
	fi
}

client_handle() {
	local sig="$1"
	_log "-\nFATAL: caught SIG${sig}"
	_log "Exiting..."
	client_cleanup
	exit 1
}

[[ ! -v _lwd_init ]] && {
	_log "error: lwd is not initialized yet"
	exit 1
}

# while getopts "l:dc:i:t:wrT:C:q" opt; do
while getopts "ql:dc:i:t:wr" opt; do
	case $opt in
		q)
			quiet=1
			;;
		l)
			logfile="$OPTARG"
			;;
		d)
			mode="daemon"
			;;
		c)
			mode="client"
			client_screen="$OPTARG"
			;;
		i)
			daemon_interval="$OPTARG"
			;;
		t)
			client_transform="$OPTARG"
			;;
		w)
			client_wait=1
			;;
		r)
			client_replace=1
			;;
	esac
done
shift $((OPTIND - 1))

trap "exit 1" INT QUIT TERM ABRT

[[ ! -d "${LWDD_RUNTIME_DIR}" ]] && {
	_log "make runtime dir '${LWDD_RUNTIME_DIR}'"
	mkdir -p "${LWDD_RUNTIME_DIR}" || {
		_log "error: unable to create runtime directory at '${LWDD_RUNTIME_DIR}'"
		return 1
	}
}

if [[ $mode == "daemon" ]]; then
	trap "daemon_handle EXIT" EXIT
	trap "daemon_handle USR1" USR1
	trap "daemon_handle USR2" USR2

	_log "running in daemon mode"
	daemon_setup || {
		_log "error: setup failed"
		exit 1
	}
	daemon_loop || {
		_log "runtime error"
		exit 1
	}

elif [[ $mode == "client" ]]; then
	trap "client_handle EXIT" EXIT

	_log "running in client mode"
	client_setup || {
		client_setup_failure=$?
		_log "client setup failed"
		if [[ $client_wait -eq 1 ]]; then
			while [[ $client_setup_failure -eq 1 ]]; do
				_log "retrying client_setup in $client_retry_interval second(s)..."
				sleep $client_retry_interval
				client_setup || {
					client_setup_failure=$?
					continue
				}
				break
			done
		else
			_log "error: setup failed"
			exit 1
		fi
	}
	client_loop || {
		_log "runtime error"
		exit 1
	}

else
	_log "error: invalid mode '$mode'"
	exit 1
fi
