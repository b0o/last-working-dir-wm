#!/bin/env zsh
sourcedir="$(dirname $0)"

LWD_AUTO_CD=0
source "${sourcedir}/last-working-dir-wm.plugin.zsh"

typeset -g  mode="daemon"
typeset -g  pidfile
typeset -g  ctlfile

typeset -g  daemon_interval=1
typeset -gA workspaces
typeset -gA screen_active_ws
typeset -gA screen_pipes
# typeset -g  ctljob

typeset -g  client_daemon_pid
typeset -g  client_transform
typeset -g  client_screen
typeset -g  client_out_pipe

daemon_setup() {
	# attempt to obtain pidfile
	pidfile="${LWDD_RUNTIME_DIR}/${_lwdd_pidfile_name}"
	[[ -e "$pidfile" ]] && {
		read -r lpid <"$pidfile"
		[[ -n "$lpid" ]] && {
			ps --pid="$lpid" &>/dev/null && {
				pidfile=""
				echo "lwd: error: lwdd already running (pid=$lpid)" >&2
				return 1
			}
			echo "lwd: warning: stale pidfile found at '$pidfile' - removing..." >&2
			unlink "$pidfile"
		}
	}
	echo $$ > "$pidfile"

	# initialize the control pipe
	ctlfile="${LWDD_RUNTIME_DIR}/${_lwdd_ctlfile_name}"
	[[ -e "$ctlfile" ]] && {
		echo "lwd: warning: stale ctlfile found at '$ctlfile' - removing..." >&2
		unlink "$ctlfile"
	}
	mkfifo "$ctlfile" || {
		echo "lwd: error creating ctlfile at ${ctlfile}" >&2
		return 1
	}

	# initialize a pipe for each screen
	while read -r l; do
		eval "$l"
		local fifo="${screen_pipes[$screen]}"
		[[ -z "$fifo" ]] && {
			fifo="${LWDD_RUNTIME_DIR}/f-${screen}"
			echo "make fifo for '$screen' at '$fifo'" >&2
			mkfifo "$fifo" || {
				echo "lwd: error creating FIFO at ${fifo}" >&2
				return 1
			}
			screen_pipes[$screen]="$fifo"
		}
	done <<<"$(_lwd_get_wss)"
	return 0
}

daemon_cleanup() {
	echo -e "\nExiting..." >&2
	for screen in "${(k)screen_pipes[@]}"; do
		local fifo="${screen_pipes[$screen]}"
		local j=$screen_tx_jobs[$screen]
		[[ $j -gt 0 ]] && {
			echo "kill tx job '${screen_tx_jobs[$screen]}'..." >&2
			kill -KILL ${screen_tx_jobs[$screen]}
			unset "screen_tx_jobs[$screen]"
		}
		[[ -p $fifo ]] && {
			echo "unlink '$fifo'" >&2
			unlink "$fifo"
		}
	done
	[[ -n "$ctlfile" && -e "$ctlfile" ]] && {
		echo "unlink ctlfile '$ctlfile'" >&2
		unlink "$ctlfile"
	}
	[[ -e "$pidfile" ]] && {
		read -r lpid <"$pidfile"
		[[ $$ -eq $lpid ]] && {
			echo "unlink pidfile '$pidfile'" >&2
			unlink "$pidfile"
		}
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
	echo "set active ws for screen '$screen' to '$id'" >&2
	screen_active_ws[$screen]="$id"
	tx_screen_lwd "$screen"
}

update_screens() {
	echo "update screens" >&2
	for screen in "${(k)screen_pipes[@]}"; do
		tx_screen_lwd "$screen"
	done
}

tx_screen_lwd() {
	local screen="$1"
	[[ ! -p "${screen_pipes[$screen]}" ]] && {
		echo "lwd: error: no named pipe for screen '$screen' at '${screen_pipes[$screen]}'"
		return 1
	}
	local l d
	l="${workspaces[${screen_active_ws[$screen]}]}"
	d="$(_lwd_read "$l")"

	integer j
	j=${screen_tx_jobs[$screen]}
	[[ $j -gt 0 ]] && {
		echo "kill write job for screen '$screen' (pid=$j)" >&2
		kill -TERM $j 2>/dev/null
	}

	echo "tx '$d' > '${screen_pipes[$screen]}'" >&2
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
	exec {fd}<>"$ctlfile"
	read -t 0.01 -u $fd l && [[ -n "$l" ]] && {
		echo "read control command: $l" >&2
		eval "$l" >&$fd
		e=$?
	}
	exec {fd}>&-
	[[ $e -ne 0 ]] && {
		echo "lwdd (daemon): error: command exited with code $e" >&2
		return 1
	}
}

daemon_loop() {
	while daemon_read_wss; do
		daemon_read_ctl || sleep "$daemon_interval"
	done
}

client_setup() {
	pidfile="${LWDD_RUNTIME_DIR}/${_lwdd_pidfile_name}"
	[[ ! -e "$pidfile" ]] && {
		echo "lwdd (client): error: no lwd daemon is running" >&2
		exit 1
	}
	read -r client_daemon_pid <"$pidfile"
	ps --pid="$client_daemon_pid" &>/dev/null || {
		echo "lwdd (client): error: lwd daemon pidfile exists but process not found (pid=$client_daemon_pid)" >&2
		exit 1
	}
	client_pipe="${LWDD_RUNTIME_DIR}/f-${client_screen}"
	[[ ! -p $client_pipe ]] && {
		echo "lwdd (client): error: unable to connect to lwd daemon (pid=$client_daemon_pid) at '$client_pipe'" >&2
	}
	kill -USR1 $client_daemon_pid
}

client_cleanup() {
	echo -e "\nExiting..." >&2
	[[ -n "$pidfile" && -p "$pidfile" ]] && {
		read -r lpid <"$pidfile"
		[[ $$ -eq $lpid ]] && {
			echo "unlink pidfile '$pidfile'" >&2
			unlink "$pidfile"
		}
	}
}

client_loop() {
	while read -r l <"$client_pipe"; do
		echo "$l"
	done
}

daemon_handle() {
	local sig="$1"
	echo "handle SIG${sig}" >&2
	if [[ $sig == "USR1" ]]; then
		update_screens
	elif [[ $sig == "USR2" ]]; then
		echo "lwdd: warning: SIGUSR2 not implemented" >&2
	else
		echo "lwdd: error: unknown signal $sig" >&2
		return 1
	fi
}

[[ ! -v _lwd_init ]] && {
	echo "lwdd: error: lwd is not initialized yet" >&2
	exit 1
}

while getopts "dc:i:t:p:" opt; do
	case $opt in
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
		p)
			screen_pipe_tee="$OPTARG"
			;;
	esac
done
shift $((OPTIND - 1))

trap "exit 1" INT QUIT TERM ABRT

[[ ! -d "${LWDD_RUNTIME_DIR}" ]] && {
	echo "make runtime dir '${LWDD_RUNTIME_DIR}'" >&2
	mkdir -p "${LWDD_RUNTIME_DIR}" || {
		echo "lwdd: error creating runtime directory at '${LWDD_RUNTIME_DIR}'" >&2
		return 1
	}
}

if [[ $mode == "daemon" ]]; then
	trap "daemon_cleanup"     EXIT
	trap "daemon_handle USR1" USR1
	trap "daemon_handle USR2" USR2

	echo "running in daemon mode" >&2
	daemon_setup || {
		echo "lwdd: (daemon) setup failed" >&2
		exit 1
	}
	daemon_loop || {
		echo "lwdd: (daemon) runtime error" >&2
		exit 1
	}

elif [[ $mode == "client" ]]; then
	trap "client_cleanup"     EXIT

	echo "running in client mode" >&2
	client_setup || {
		echo "lwdd: (client) setup failed" >&2
		exit 1
	}
	client_loop || {
		echo "lwdd: (client) runtime error" >&2
		exit 1
	}

else
	echo "lwdd: error: invalid mode '$mode'" >&2
	exit 1
fi
