#!/usr/bin/busybox sh

# This file is part of https://github.com/random-archer/mkinitcpio-systemd-tool

# Provides initrd shell program:
# * expects invocation from systemd service unit
# * expects invocation as default shell ~/.profile
# * uses only capabilities of busybox and systemd
# * implements minimal interactive menu
# * implements password query/reply agent, see reference.md

# Using shell linter: https://github.com/koalaman/shellcheck
# shellcheck shell=dash
# shellcheck disable=SC1008 # This shebang was unrecognized
# shellcheck disable=SC2169 # In dash, [[ ]] is not supported

# verify if shell started form systemd unit
is_entry_service() {
    [[ "$script_entry" == "service" ]]
}

# verify if shell started form tty or ssh
is_entry_console() {
    [[ "$script_entry" == "console" ]]
}

# verify if shell started form console debug shell
is_debug_shell() {
    ! is_entry_service && ! is_ssh_session
}

# verify if shell started form some debug tool
is_tool_shell() {
    [[ -n "$script_tool_vars" ]]
}

# verify if this is a remote session shell
is_ssh_session() {
    [[ -n "$SSH_CONNECTION" ]]
}

# verify if there are any crypto requests
has_ask_files() {
    [[ -n "$(list_ask_files)" ]]
}

# verify if any crypttab jobs are in the queue
has_crypt_jobs() {
    $systemd_ctl list-jobs | grep -i -q 'cryptsetup'
}

# print empty line
print_eol() {
   printf "\n"
}

# log output to console and journal
log_log() {
    local mode="$1" text="$2" session=""
    [[ "$script_verbose" == *"info"* ]] && [[ "$mode" == *"info"* ]] && echo "$text"
    [[ "$script_verbose" == *"warn"* ]] && [[ "$mode" == *"warn"* ]] && echo "$text"
    [[ "$script_verbose" == *"err"*  ]] && [[ "$mode" == *"err"*  ]] && echo "$text"
    if is_ssh_session ; then session="ssh" ; else session="loc" ; fi
    text="$script_entry/$session $text"
    echo "$text" | $systemd_cat --priority="$mode" --identifier="$script_identifier"
}

# log at detail level "information"
log_info() {
    local text="$1" ; log_log "info"     "info : $text" ;
}

# log at detail level "warning"
log_warn() {
    local text="$1" ; log_log "warning"  "warn : $text" ;
}

# log at detail level "error"
log_error() {
    local text="$1" ; log_log "err"      "error: $text" ;
}

# list current crypto question files
list_ask_files() {
    2>/dev/null grep -i -l 'cryptsetup' "$watch_folder"/ask.*
}

# size of space separated list
list_size() {
    local list="$1" ; echo "$list" | wc -w
}

# parse and clean ask password request file
convert_ask_file() {
    local file="$1" text=""
    # shellcheck disable=SC2002
    text=$(cat "$file" | grep -v -F '[Ask]' | sed -r -e 's%([^=]+)=([^=]+)%\1=\2%' -e 's%[ ()!]%-%g')
    # flatten array
    echo "$text"
}

# read named field from string of 'name=value' entries
extract_property() {
    local text="$1" name="$2"
    # shellcheck disable=SC2086 # Double quote to prevent globbing and word splitting
    # shellcheck disable=SC1083 # This {/} is literal. Check expression
    local $text && eval echo \${$name}
}

# remove any pending content from the console input
clear_console_input() {
    read -r -s -n 10000000 -t 1
}

# invoke operation within a timeout
await_condition() {
    local command="$*" count=1
    while true ; do
        $command && return 0
        sleep "$sleep_delay" ; count=$((count+1))
        [[ "$count" -gt "$sleep_count" ]] && return 1
    done
}

# get a portion of current console output
read_console_tail() {
    tail -c 256 "/dev/vcs"
}

# verify if console is changing
is_console_stable() {
    local text1="" text2=""
    text1=$(read_console_tail)
    sleep "$sleep_delay"
    text2=$(read_console_tail)
    [[ "$text1" == "$text2" ]]
}

# ensure console is no longer changing
await_console_stable() {
    local tty="$(tty)"
    [[ -z "${tty##/dev/pts/*}" ]] && return 0
    await_condition is_console_stable
}

# ensure crypto jobs posted questions (ask files are present)
await_request_present() {
    await_condition has_ask_files
}

# ensure secret was correct (crypto jobs are gone)
await_secret_validated() {
    await_condition [[ ! has_crypt_jobs ]]
}

# query password from the terminal or plymouth
# https://www.freedesktop.org/software/systemd/man/systemd-ask-password.html
# https://www.systutorials.com/docs/linux/man/1-plymouth/
run_secret_query() {
    if is_entry_console ; then
        $systemd_query --timeout="$query_timeout" "$query_prompt"
    elif is_entry_service ; then
        case "$service_name" in
            crypto_terminal) $systemd_query --timeout="$query_timeout" "$query_prompt" ;;
            crypto_plymouth) $plymouth_client ask-for-password --prompt="$query_prompt" ;;
            *) log_error "invalid service_name=$service_name" ;;
        esac
    fi
}

# reply password to the requester
run_secret_reply() {
    local secret="$1" socket="$2"
    echo "$secret" | $systemd_reply "1" "$socket"
}

# crypto secret default logic: implement custom password agent
do_agent_custom() {
    local secret="" request_list="" request_size="" request_file=""
    local text="" pid="" id="" socket="" message="" signature="" result=""
    local count=1 error_file=""
    error_file=$(mktemp)
    while true ; do
        log_info "custom agent try count=$count" ;  count=$((count+1)) ;
        await_request_present || { log_warn "missing request @1" ; return 0 ; }
        await_console_stable || { log_warn "volatile console" ; }
        log_info "query start" ;
        secret=$(2>"$error_file" run_secret_query) || { log_error "query failure [$(cat "$error_file")]" ; return 1 ; }
        log_info "query finish" ;
        [[ -n "$secret" ]] || { log_warn "ignore empty secret" ; continue ; }
        await_request_present || { log_warn "missing request @2" ; return 0 ; }
        request_list=$(list_ask_files) ; request_size=$(list_size "$request_list") ;
        log_info "request list size=$request_size" ;
        for request_file in $request_list ; do
            [[ -e "$request_file" ]] || { log_warn "request removed [$request_file]" ; continue ; }
            text=$(convert_ask_file "$request_file") || { log_error "convert failure [$(cat "$request_file")]" ; return 1 ; }
            id=$(extract_property "$text" "Id") || { log_error "extract failure [id]" ; return 1 ; }
            pid=$(extract_property "$text" "PID") || { log_error "extract failure [pid]" ; return 1 ; }
            socket=$(extract_property "$text" "Socket") || { log_error "extract failure [socket]" ; return 1 ; }
            message=$(extract_property "$text" "Message") || { log_error "extract failure [message]" ; return 1 ; }
            signature="pid=$pid id=$id message=$message"
            [[ -e "$socket" ]] || { log_warn "socket removed [$signature]" ; continue ; }
            log_info "reply $signature" ;
            result=$(2>&1 run_secret_reply "$secret" "$socket") || { log_error "reply failure [$signature] [$result]" ; return 1 ; }
        done
        await_secret_validated || { log_warn "invalid secret" ; continue ; }
        return 0
    done
}

# crypto secret fall back logic: hand over to standard password agent
do_agent_system() {
    log_info "system agent"
    $systemd_agent --query
}

do_agent() {
    . /etc/initrd-shell.conf
    if [[ "$password_agent" == "system" ]]; then
        do_agent_system
    else
        do_agent_custom
    fi
    if [ $? -ne 0 ]; then
        do_agent_system
    fi
}

# exit this script
do_exit() {
    local code="$1"
    [[ "$code" == "" ]] && code=0
    log_info "exit code=$code"
    exit "$code"
}

# invoke sub shell
do_shell() {
    log_info "run sub shell"
    PS1="$script_prompt" /usr/bin/sh
}

# change systemd state
do_reboot() {
    log_info "invoke reboot"
    $systemd_log --sync --flush
    # shellcheck disable=SC2086 # Double quote to prevent globbing and word splitting
    $systemd_ctl $reboot_options reboot
}

# try custom password agent, fall back to standard agent
run_crypt_jobs() {
    log_info "crypt jobs"
    if do_agent; then
        log_info "crypt success"
        do_exit 0
    else
        log_warn "crypt failure"
        do_exit 1
    fi
}

# process invocation from tty console or ssh connection
entry_console() {
    if is_debug_shell ; then
        log_info "debug shell"
    elif is_tool_shell ; then
        log_info "tool shell"
    elif has_crypt_jobs ; then
        run_crypt_jobs
    else
        log_info "user menu"
        do_prompt
    fi
}

# process invocation from a systemd service unit
entry_service() {
    case "$service_name" in
        default) service_default ;;
        crypto_plymouth) service_cryptsetup ;;
        crypto_terminal) service_cryptsetup ;;
        *) log_error "invalid service_name=$service_name" ;;
    esac
}

# default service implementation
service_default() {
    log_info "service: default"
    do_exit "$service_restart_prevent_code"
}

# cryptsetup service implementation
service_cryptsetup() {
    log_info "service: cryptsetup/$service_name"
    [[ $watch_folder ]] || log_error "missing $watch_folder"
    if has_crypt_jobs ; then
        run_crypt_jobs
    else
        log_info "nothing to do"
        do_exit "$service_restart_prevent_code"
    fi
}

# interactive user menu
do_prompt() {
    local choice=""
    while true ; do
        echo "select:"
        echo "a) secret agent"
        echo "s) sys shell"
        echo "r) reboot"
        echo "q) quit"
        read -r -n 1 -p "?> " choice
        print_eol
        case "$choice" in
            a) do_agent ;;
            s) do_shell ;;
            r) do_reboot ;;
            q) do_exit 0 ;;
            *) echo "$choice ?" ;;
        esac
    done
}

# respond to interrupt
do_trap() {
    print_eol
    if is_entry_service ; then
        log_info "interrupt service"
        do_exit 1
    elif is_entry_console ; then
        log_info "interrupt console"
        do_prompt
    else
        log_info "interrupt"
        do_exit 0
    fi
}

# handle ssh close / service termination
trap_HUP() {
    log_info "session disconnect (HUP)"
    do_exit 0
}

# handle "CTRL-C"
trap_INT () {
    log_info "user event (INT)"
    do_trap
}

# handle "CTRL-\"
trap_QUIT() {
    log_info "user event (QUIT)"
    do_trap
}

# handle "CTRL-Z"
trap_TSTP() {
    log_info "user event (TSTP)"
    do_trap
}

# handle termination
trap_TERM() {
    log_info "program termination (TERM)"
    do_exit 0
}

# systemd service unit can override these arguments via 'name=value'
setup_defaults() {
    # script behaviour
    [[ -z "$script_entry" ]] && readonly script_entry="console" # default entry mode
    [[ -z "$script_prompt" ]] && readonly script_prompt="=> " # /usr/bin/sh prompt
    [[ -z "$script_verbose" ]] && readonly script_verbose="error" # can be {info,warn,error}
    [[ -z "$script_tool_vars" ]] && readonly script_tool_vars="$MC_SID" # tool shell detection
    [[ -z "$script_identifier" ]] && readonly script_identifier="shell" # systemd journal log tag
    # service settings
    [[ -z "$service_name" ]] && readonly service_name="default"
    [[ -z "$service_restart_prevent_code" ]] && readonly service_restart_prevent_code=100 # see [Unit]/RestartPreventExitStatus
    # reboot options
    [[ -z "$reboot_options" ]] && readonly reboot_options="--force --force --no-ask-password"
    # password query settings
    [[ -z "$query_prompt" ]] && readonly query_prompt=" secret>"
    [[ -z "$query_timeout" ]] && readonly query_timeout=0 # a timeout of 0 waits indefinitely
    # active operation timeout
    [[ -z "$sleep_count" ]] && readonly sleep_count=20 # number of delay increments
    [[ -z "$sleep_delay" ]] && readonly sleep_delay=0.3 # seconds, incremental timeout
    # password inotify watch folder
    [[ -z "$watch_folder" ]] && readonly watch_folder="/run/systemd/ask-password"
    # required systemd binaries
    [[ -z "$systemd_cat" ]] && readonly systemd_cat="/usr/bin/systemd-cat"
    [[ -z "$systemd_ctl" ]] && readonly systemd_ctl="/usr/bin/systemctl"
    [[ -z "$systemd_log" ]] && readonly systemd_log="/usr/bin/journalctl"
    # optional systemd binaries for cryptsetup
    [[ -z "$systemd_query" ]] && readonly systemd_query="/usr/bin/systemd-ask-password"
    [[ -z "$systemd_reply" ]] && readonly systemd_reply="/usr/lib/systemd/systemd-reply-password"
    [[ -z "$systemd_agent" ]] && readonly systemd_agent="/usr/bin/systemd-tty-ask-password-agent"
    # optional plymouth binaries for cryptsetup
    [[ -z "$plymouth_client" ]] && readonly plymouth_client="/usr/bin/plymouth"
}

# map signal handlers
setup_interrupts() {
    trap trap_HUP HUP
    trap trap_INT INT
    trap trap_QUIT QUIT
    trap trap_TSTP TSTP
    trap trap_TERM TERM
}

# respond depending on script invocation type 'script_entry=xxx'
process_invocation() {
    log_info "init"
    case "$script_entry" in
        # development
        exit)     do_exit ;;
        shell)    do_shell ;;
        reboot)   do_reboot ;;
        prompt)   do_prompt ;;
        custom)   do_agent_custom ;;
        system)   do_agent_system ;;
        # production
        service)  entry_service ;;
        console)  entry_console ;;
              *)  log_error "program error" ;;
    esac
    log_info "done"
}

# shell entry point
program() {
    readonly "$@"
    setup_defaults
    setup_interrupts
    process_invocation
}

program "$@"
