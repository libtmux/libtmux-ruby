# Explicitly source with socket, invitation token, Ruby, helper, and load paths.
[[ -o interactive && -o zle && $# == 5 && -z ${_libtmux_run_fd-} ]] || return 1
[[ $ZSH_VERSION == 5.9 || $ZSH_VERSION == 5.9.<-> ]] || return 1
zmodload zsh/net/socket || return 1
zmodload zsh/system || return 1
zsocket "$1" || return 1
typeset -g _libtmux_run_fd=$REPLY
typeset -g _libtmux_run_ruby=$3 _libtmux_run_helper=$4 _libtmux_run_loadpath=$5 _libtmux_run_buffer=''
print -r -- "ZLE1 $2 $ZSH_VERSION $TMUX_PANE" >&$_libtmux_run_fd || return 1
typeset _libtmux_enrollment_ack
if ! sysread -i $_libtmux_run_fd -s 1 -t 0.5 _libtmux_enrollment_ack || [[ $_libtmux_enrollment_ack != A ]]; then
  exec {_libtmux_run_fd}<&-
  unset _libtmux_run_fd
  return 1
fi
unset _libtmux_enrollment_ack

_libtmux_run_widget() {
  emulate -L zsh
  setopt localtraps
  trap '' PIPE
  local chunk frame exit_status readiness=ready
  local -a fields
  if ! sysread -i $_libtmux_run_fd -s 1024 -t 0 chunk; then
    zle -F $_libtmux_run_fd
    exec {_libtmux_run_fd}<&-
    unset _libtmux_run_fd
    return
  fi
  _libtmux_run_buffer+=$chunk
  if (( ${#_libtmux_run_buffer} > 1024 )); then
    zle -F $_libtmux_run_fd
    exec {_libtmux_run_fd}<&-
    unset _libtmux_run_fd
    return
  fi
  [[ $_libtmux_run_buffer == *$'\n'* ]] || return
  frame=${_libtmux_run_buffer%%$'\n'*}
  _libtmux_run_buffer=${_libtmux_run_buffer#*$'\n'}
  fields=(${=frame})
  [[ $#fields == 6 && $fields[1] == P && ${#fields[2]} == 32 && ${#fields[3]} == 32 && $fields[2] != *[^0-9a-f]* && $fields[3] != *[^0-9a-f]* ]] || return
  if [[ $CONTEXT != start || -n $BUFFER || -n $PREBUFFER || $PENDING -gt 0 || $KEYS_QUEUED_COUNT -gt 0 ]]; then
    readiness=refused
  fi
  "$_libtmux_run_ruby" --disable=rubyopt,gems -I "$_libtmux_run_loadpath" "$_libtmux_run_helper" "$fields[4]" "$fields[3]" "$fields[5]" "$fields[2]" "$fields[6]" "$readiness" </dev/null >/dev/null 2>&1
  exit_status=$?
  print -r -- "DONE $fields[2] $exit_status" >&$_libtmux_run_fd
}
zle -N _libtmux_run_widget
zle -F -w $_libtmux_run_fd _libtmux_run_widget
