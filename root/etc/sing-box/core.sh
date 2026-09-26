#!/bin/sh
# shellcheck shell=busybox
# Shared by the rpcd plugin and detached worker. No client-controlled paths/commands.
RUN=/tmp/sing-box-panel
INIT=/etc/init.d/sing-box
BIN=/usr/bin/sing-box
MAX_SIZE=65536

prepare() {
	umask 077
	[ "$(id -u)" = 0 ] || { DETAILS='面板后端必须以 root 身份运行'; return 1; }
	[ ! -L "$RUN" ] || { DETAILS="$RUN 是符号链接"; return 1; }
	mkdir -p "$RUN" || { DETAILS="无法创建 $RUN"; return 1; }
	[ -d "$RUN" ] && [ -O "$RUN" ] || {
		DETAILS="$RUN 必须是 root 所有的目录"; return 1;
	}
	chmod 700 "$RUN" || { DETAILS="无法设置 $RUN 的权限"; return 1; }
}

load_settings() {
	CONFIG=$(uci -q get sing-box.main.conffile)
	WORKDIR=$(uci -q get sing-box.main.workdir)
	SERVICE_USER=$(uci -q get sing-box.main.user)
	[ -n "$WORKDIR" ] || WORKDIR=/etc/sing-box
	[ -n "$SERVICE_USER" ] || SERVICE_USER=root
}

settings() {
	load_settings
	case "$CONFIG" in /*) ;; *) ERROR='config_path_invalid'; return 1;; esac
	case "$WORKDIR" in /*) ;; *) ERROR='workdir_invalid'; return 1;; esac
	[ ! -L "$CONFIG" ] || { ERROR='config_symlink'; return 1; }
	[ ! -e "$CONFIG" ] || [ -f "$CONFIG" ] || { ERROR=config_not_regular; return 1; }
	[ -x "$BIN" ] && [ -x "$INIT" ] || { ERROR='service_missing'; return 1; }
}

action_settings() {
	# Stopping a running service must work even if its configuration is broken.
	if [ "$1" = stop ]; then
		[ -x "$INIT" ] || { ERROR=service_missing; return 1; }
	else
		settings
	fi
}

lock() {
	mkdir "$RUN/lock" 2>/dev/null
}

unlock() {
	rm -f "$RUN/lock/pid"
	rmdir "$RUN/lock" 2>/dev/null
}

job() {
	json_init
	json_add_string state "$1"
	json_add_string code "$2"
	json_add_string argument "${4:-${ERROR_ARG:-}}"
	json_add_string details "${3:-}"
	json_add_int updated "$(date +%s)"
	json_dump > "$RUN/job.new" && mv -f "$RUN/job.new" "$RUN/job.json"
}

running_pid() {
	ubus call service list '{"name":"sing-box"}' 2>/dev/null |
		jsonfilter -e '@["sing-box"].instances.*.pid' 2>/dev/null | head -n 1
}

healthy() {
	# Require a stable live PID across three observations; a respawn is a failure.
	local first current _attempt
	sleep 1
	first=$(running_pid)
	[ -n "$first" ] && kill -0 "$first" 2>/dev/null || return 1
	for _attempt in 1 2; do
		sleep 1
		current=$(running_pid)
		[ "$current" = "$first" ] && kill -0 "$current" 2>/dev/null || return 1
	done
}

# Run a command with a bounded lifetime without requiring coreutils-timeout.
run_timeout() (
	trap - EXIT HUP INT TERM
	limit="$1"
	shift
	command_pid=''
	watchdog_pid=''
	# Called by the EXIT trap below, including timeout and signal exits.
	# shellcheck disable=SC2329
	cleanup_timeout() {
		[ -z "$watchdog_pid" ] || kill "$watchdog_pid" 2>/dev/null
		[ -z "$command_pid" ] || kill -KILL "$command_pid" 2>/dev/null
		[ -z "$watchdog_pid" ] || wait "$watchdog_pid" 2>/dev/null
	}
	trap cleanup_timeout EXIT
	trap 'exit 143' HUP INT TERM
	"$@" &
	command_pid=$!
	(
		trap - EXIT HUP INT TERM
		elapsed=0
		while kill -0 "$command_pid" 2>/dev/null; do
			sleep 1
			elapsed=$((elapsed + 1))
			if [ "$elapsed" -eq "$limit" ]; then
				kill -TERM "$command_pid" 2>/dev/null || exit 0
			elif [ "$elapsed" -ge "$((limit + 2))" ]; then
				kill -KILL "$command_pid" 2>/dev/null
				exit 0
			fi
		done
	) &
	watchdog_pid=$!
	wait "$command_pid"
	result=$?
	command_pid=''
	exit "$result"
)

service_do() {
	run_timeout 12 "$INIT" "$1" > "$RUN/service.log" 2>&1
}

stop_service() {
	local state pids pid attempt alive running
	service_do stop || { ERROR=stop_failed; DETAILS=$(head -c 8192 "$RUN/service.log"); return 1; }
	for attempt in 0 1 2 3 4 5 6 7 8 9 10; do
		# Fail closed if procd cannot confirm the state; check every instance.
		state=$(ubus call service list '{"name":"sing-box"}') || { ERROR=service_status_failed; return 1; }
		json_load "$state" || { ERROR=service_status_failed; return 1; }
		command -v jsonfilter >/dev/null || { ERROR=service_status_failed; return 1; }
		pids=$(jsonfilter -s "$state" -e '@["sing-box"].instances.*.pid')
		running=$(jsonfilter -s "$state" -e '@["sing-box"].instances.*.running')
		case "$pids:$running" in :*true*) ERROR=service_status_failed; return 1;; esac
		alive=0
		for pid in $pids; do
			case "$pid" in ''|*[!0-9]*) ERROR=service_status_failed; return 1;; esac
			if kill -0 "$pid" 2>/dev/null; then alive=1; fi
		done
		[ "$alive" = 0 ] && return 0
		[ "$attempt" -lt 10 ] || { ERROR=stop_failed; DETAILS='等待服务进程退出超时'; return 1; }
		sleep 1
	done
}

# Read Linux mount identity from stdin, retaining the containing filesystem.
cache_mount_identity() {
	awk -v path="$CACHE" -v root="$WORKDIR" '
		$5 == path || $5 == root || (index($5, root "/") == 1 && index(path, $5 "/") == 1) { unsafe=1 }
		($5 == "/" || index(path, $5 "/") == 1) && length($5) > longest {
			longest=length($5); identity=$1 ":" $3 ":" $4 ":" $5
		}
		END {
			if (unsafe) exit 1
			if (!longest) exit 2
			print identity
		}'
}

# BusyBox ls is available even on firmware built without the stat applet.
cache_file_identity() {
	local metadata inode links mount_identity result
	metadata=$(LC_ALL=C ls -ldni "$CACHE") || { ERROR=cache_inspect_failed; return 1; }
	metadata=$(printf '%s\n' "$metadata" | awk '
		NR == 1 && $1 ~ /^[0-9]+$/ && $2 ~ /^-/ && $3 ~ /^[0-9]+$/ { value=$1 ":" $3 }
		END { if (NR != 1 || value == "") exit 1; print value }
	') || { ERROR=cache_inspect_failed; return 1; }
	inode=${metadata%:*}
	links=${metadata##*:}
	[ "$links" = 1 ] || { ERROR=cache_path_unsafe; return 1; }
	mount_identity=$(cache_mount_identity < /proc/self/mountinfo)
	result=$?
	case "$result" in
		0) ;;
		1) ERROR=cache_path_unsafe; return 1;;
		*) ERROR=cache_inspect_failed; return 1;;
	esac
	CACHE_IDENTITY="$mount_identity:$inode"
}

# Resolve only the configured cache database, never a client-provided path.
cache_settings() {
	local enabled='' kind='' path='' canonical
	settings || return 1
	case "$WORKDIR" in
		/etc/sing-box|/usr/share/sing-box|/var/lib/sing-box|/tmp/sing-box) ;;
		*) ERROR=cache_workdir_unsafe; return 1;;
	esac
	[ -d "$WORKDIR" ] && [ "$(readlink -f "$WORKDIR")" = "$WORKDIR" ] || {
		ERROR=cache_workdir_unsafe; return 1;
	}
	[ -f "$CONFIG" ] && [ "$(wc -c < "$CONFIG")" -le "$MAX_SIZE" ] || {
		ERROR=cache_config_invalid; return 1;
	}
	json_load "$(cat "$CONFIG")" || { ERROR=cache_config_invalid; return 1; }
	if ! { json_select experimental && json_select cache_file; }; then
		ERROR=cache_disabled; return 1
	fi
	json_get_type kind enabled
	json_get_var enabled enabled
	[ "$kind" = boolean ] && [ "$enabled" = 1 ] || { ERROR=cache_disabled; return 1; }
	kind=''
	json_get_type kind path
	case "$kind" in
		string) json_get_var path path;;
		'') ;;
		*) ERROR=cache_path_unsafe; return 1;;
	esac
	[ -n "$path" ] || path=cache.db
	case "$path" in /*) CACHE="$path";; *) CACHE="$WORKDIR/$path";; esac
	# A restricted character set also makes mountinfo path comparison unambiguous.
	case "$CACHE" in *[!a-zA-Z0-9_./-]*) ERROR=cache_path_unsafe; return 1;; esac
	case "$CACHE" in "$WORKDIR"/*) ;; *) ERROR=cache_path_unsafe; return 1;; esac
	canonical=$(readlink -f "$CACHE") || { ERROR=cache_path_unsafe; return 1; }
	[ "$canonical" = "$CACHE" ] && [ ! -L "$CACHE" ] || { ERROR=cache_path_unsafe; return 1; }
	[ "$CACHE" != "$(readlink -f "$CONFIG")" ] || { ERROR=cache_path_unsafe; return 1; }
	[ -e "$CACHE" ] || { ERROR=cache_missing; return 1; }
	[ -f "$CACHE" ] || { ERROR=cache_path_unsafe; return 1; }
	cache_file_identity || return 1
	# Do not hash the live database: normal writes must not invalidate confirmation.
	CACHE_TOKEN=$(printf '%s\n' "$CACHE" "$CACHE_IDENTITY" "$SERVICE_USER" "$(config_revision)" | sha256sum | cut -d ' ' -f 1)
}

reset_cache() {
	local expected="$1" start="$2" failure
	DETAILS=''
	cache_settings || return 1
	[ "$expected" = "$CACHE_TOKEN" ] || { ERROR=cache_changed; return 1; }
	stop_service || return 1
	# Re-read configuration and revalidate paths after waiting for the service.
	cache_settings || return 1
	[ "$expected" = "$CACHE_TOKEN" ] || { ERROR=cache_changed; return 1; }
	job running operation_running "缓存文件：$CACHE" cache_reset
	rm -f "$CACHE" || { ERROR=cache_remove_failed; return 1; }
	if [ "$start" = 1 ]; then
		if ! start_service start cache_start_failed; then
			failure="$DETAILS"
			if ! stop_service; then failure="$failure；停止服务失败，请检查运行状态"; fi
			ERROR=cache_start_failed
			DETAILS="$failure"
			return 1
		fi
	fi
	DETAILS="缓存文件：$CACHE"
}

check_config() {
	ERROR_ARG=''
	[ -f "$1" ] || { ERROR='config_missing'; return 1; }
	[ "$(wc -c < "$1")" -le "$MAX_SIZE" ] || { ERROR='config_too_large'; return 1; }
	run_timeout 15 "$BIN" check -c "$1" -D "$WORKDIR" > "$RUN/check.log" 2>&1
	local result=$?
	DETAILS=$(head -c 8192 "$RUN/check.log")
	[ "$result" -eq 0 ] || { ERROR=check_failed; ERROR_ARG="$result"; return 1; }
}

config_revision() {
	# Include the path so a UCI path change invalidates an open editor too.
	{ printf '%s\n' "$CONFIG"; if [ -f "$CONFIG" ]; then sha256sum "$CONFIG"; else printf 'missing\n'; fi; } |
		sha256sum | cut -d ' ' -f 1
}

stage_config() {
	local tmp
	[ ! -L "$CONFIG" ] && { [ ! -e "$CONFIG" ] || [ -f "$CONFIG" ]; } || return 1
	tmp=$(mktemp "${CONFIG}.panel.XXXXXX") || return 1
	if [ -f "$CONFIG" ]; then
		cp -p "$CONFIG" "$tmp" || { rm -f "$tmp"; return 1; }
	else
		if ! chown "$SERVICE_USER" "$tmp" || ! chmod 600 "$tmp"; then
			rm -f "$tmp"
			return 1
		fi
	fi
	printf '%s' "$1" > "$tmp" || { rm -f "$tmp"; return 1; }
	printf '%s' "$tmp"
}

save_config() {
	local content="$1" expected="$2" tmp
	[ -n "$expected" ] && [ "$expected" = "$(config_revision)" ] || {
		ERROR=config_changed; return 1;
	}
	tmp=$(stage_config "$content") || { ERROR=config_save_failed; return 1; }
	if [ -f "$CONFIG" ] && cmp -s "$tmp" "$CONFIG"; then
		rm -f "$tmp"
		return 0
	fi
	mv -f "$tmp" "$CONFIG" || { rm -f "$tmp"; ERROR=config_save_failed; return 1; }
}

start_service() {
	check_config "$CONFIG" || return 1
	if uci set sing-box.main.enabled=1 && uci commit sing-box && service_do "$1" && healthy; then
		return 0
	fi
	DETAILS=$(head -c 8192 "$RUN/service.log" 2>/dev/null)
	ERROR="$2"
	return 1
}

worker() {
	local action="$1" expected="${2:-}"
	printf '%s' "$$" > "$RUN/lock/pid"
	trap 'worker_exit' EXIT
	trap 'job error operation_interrupted; exit 1' HUP INT TERM
	job running operation_running '' "$action"
	action_settings "$action" || { job error "$ERROR"; return 1; }
	case "$action" in apply)
		[ "$expected" = "$(config_revision)" ] || { job error config_changed; return 1; };;
	esac
	case "$action" in
		validate)
			check_config "$RUN/validation.json" || { job error "$ERROR" "$DETAILS"; return 1; }
			job success check_passed "$DETAILS";;
		apply)
			start_service restart apply_failed || { job error "$ERROR" "$DETAILS"; return 1; }
			job success 'config_applied';;
		start|restart)
			start_service "$action" start_failed || { job error "$ERROR" "$DETAILS"; return 1; }
			job success 'service_running';;
		stop)
			stop_service || { job error "$ERROR" "$DETAILS"; return 1; }
			job success 'service_stopped';;
		cache_reset|cache_reset_start)
			reset_cache "$expected" "$([ "$action" = cache_reset_start ] && echo 1 || echo 0)" || {
				job error "$ERROR" "$DETAILS"; return 1;
			}
			job success "$action" "$DETAILS";;
		*) job error 'action_unknown'; return 1;;
	esac
}

worker_exit() {
	rm -f "$RUN/check.log" "$RUN/service.log" "$RUN/validation.json"
	unlock
}
