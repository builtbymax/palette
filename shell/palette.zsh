# Palette — Fig-style autocomplete for zsh.
#
# Source this file last in ~/.zshrc. While you type, the plugin sends the text
# left of the cursor and the cursor's cell to Palette.app, which shows the
# dropdown. While it is open:
#
#   ↑/↓, Ctrl-P/Ctrl-N   move the selection
#   Tab                  insert the selection
#   Enter                insert the selection once you have moved it,
#                        otherwise run the command as usual
#   Esc                  close until the next word
#
# Everything else behaves exactly as without Palette. `palette help` lists
# the command-line tool; `palette unload` removes Palette from this shell.

[[ -o interactive && -o zle ]] || return 0
[[ -n $PALETTE_WORKER ]] && return 0
(( ${+_PALETTE_LOADED} )) && return 0
zmodload zsh/net/socket 2>/dev/null || return 0
zmodload zsh/datetime 2>/dev/null
typeset -g _PALETTE_LOADED=1
autoload -Uz add-zsh-hook add-zle-hook-widget

typeset -g _pal_sock=${PALETTE_SOCKET:-$HOME/.local/state/palette/palette.sock}
typeset -g _pal_script=${${(%):-%x}:A}
typeset -gi _pal_fd=-1 _pal_seq=0 _pal_open=0 _pal_sel=1 _pal_moved=0 _pal_launched=0
typeset -gi _pal_row0=-1 _pal_col0=0 _pal_locate=1 _pal_lastw=0
typeset -gF _pal_seen=0
typeset -g _pal_last='' _pal_path='' _pal_dims='' _pal_snap_sig=''
typeset -ga _pal_items        # replace count, text, replace count, text, …
typeset -gA _pal_orig         # key sequence -> widget it replaced

_pal_send() {
  (( _pal_fd >= 0 )) || return 1
  setopt localoptions localtraps
  trap '' PIPE
  print -rn -u $_pal_fd -- "${(pj:\x1f:)@}"$'\n' 2>/dev/null || { _pal_disconnect; return 1 }
}

_pal_connect() {
  (( _pal_fd >= 0 )) && return 0
  if [[ -S $_pal_sock ]] && zsocket $_pal_sock 2>/dev/null; then
    _pal_fd=$REPLY
    zle -F -w $_pal_fd _pal_receive
    _pal_send hello $$ ${TTY:-} ${(j.:.)fpath}
    _pal_path=$PATH
    _pal_send env $PATH
    _pal_snap_sig=''
    _pal_snapshot
    return 0
  fi
  # Start the app once per shell; the next prompt connects.
  if (( ! _pal_launched && ${PALETTE_AUTOSTART:-1} )) && [[ $OSTYPE == darwin* ]]; then
    _pal_launched=1
    command open -g -b dev.builtbymax.palette >/dev/null 2>&1 &!
  fi
  return 1
}

# Writes what the completion worker needs from this shell to a private file:
# styles, completion functions that aren't on $fpath (with helpers from the
# same file), compdefs, names of user functions, and aliases last so they
# don't affect how the functions are parsed. Rewritten only when the counts
# change.
_pal_snapshot() {
  emulate -L zsh
  setopt extendedglob
  local sig="${#aliases}:${#galiases}:${#saliases}:${#functions}:${#_comps}"
  [[ $sig == $_pal_snap_sig ]] && return 0
  local file=${_pal_sock:h}/shell-$$.zsh f src
  local -a defs stubs found
  local -A files
  if (( ${+_comps} )); then
    for f in ${(u)${(v)_comps}}; do
      [[ -n $functions[$f] && $functions[$f] != *'autoload -X'* ]] || continue
      found=( ${^fpath}/$f(N) )
      (( $#found )) && continue
      src=${functions_source[$f]-}
      if [[ -n $src ]]; then files[$src]=1; else defs+=$f; fi
    done
    for f src in "${(@kv)functions_source}"; do
      [[ -n $src && -n ${files[$src]-} ]] && defs+=$f
    done
  fi
  for f in ${(k)functions}; do
    [[ $f == [[:alnum:]]* && $f != (TRAP*|precmd|preexec|chpwd|periodic|zshexit|zshaddhistory|command_not_found_handler) ]] \
      && stubs+=$f
  done
  local mask=$(umask)
  umask 077   # aliases and functions can hold secrets
  {
    {
      print -r -- "# Palette snapshot of shell $$"
      zstyle -L
      (( $#defs )) && functions -- ${(u)defs}
      (( ${+_comps} )) && print -r -- "_comps+=( ${(j: :)${(@qq)${(@kv)_comps}}} )"
      (( ${+_services} && $#_services )) && print -r -- "_services+=( ${(j: :)${(@qq)${(@kv)_services}}} )"
      print -r -- "_pal_stubs=( ${(j: :)${(@qq)stubs}} )"
      alias -L
    } >| $file.tmp && command mv -f $file.tmp $file
  } 2>/dev/null || { umask $mask; return 0 }
  umask $mask
  _pal_snap_sig=$sig
  _pal_send snapshot $file $sig
}

_pal_disconnect() {
  (( _pal_fd >= 0 )) || return 0
  zle -F $_pal_fd 2>/dev/null
  exec {_pal_fd}>&-
  _pal_fd=-1 _pal_open=0
}

# Messages from the app.
_pal_receive() {
  local fd=${1:-$_pal_fd} line
  if ! IFS= read -r -u $fd line; then
    _pal_disconnect
    return 0
  fi
  local -a f=( "${(@ps:\x1f:)line}" )
  case $f[1] in
    items)
      (( f[2] == _pal_seq )) || return 0
      _pal_items=( "${(@)f[3,-1]}" )
      _pal_sel=1 _pal_moved=0
      (( _pal_open = $#_pal_items >= 2 ))
      ;;
    none)
      (( f[2] == _pal_seq )) && _pal_open=0
      ;;
    closed)
      _pal_open=0
      ;;
    unload)
      _pal_unload
      zle -M "Palette is unloaded from this shell. Run \`palette load\` to load it again."
      ;;
    pick)
      if (( _pal_open && f[2] == _pal_seq )); then
        _pal_sel=$(( f[3] + 1 ))
        _pal_accept
        zle -R
      fi
      ;;
  esac
  return 0
}
zle -N _pal_receive

# Find the screen cell where the editable text starts, by asking the terminal
# for the cursor position (DSR). Before a redraw the cursor still sits after
# the previous buffer, whose width is _pal_lastw.
_pal_locate_prompt() {
  setopt localoptions extendedglob
  _pal_locate=0
  local reply='' ch='' typed=''
  print -rn -- $'\e[6n' > $TTY
  while read -rs -k 1 -t 0.25 ch < $TTY; do
    if [[ -z $reply && $ch != $'\e' ]]; then
      typed+=$ch          # keys typed before the reply arrived
    else
      reply+=$ch
      [[ $ch == R ]] && break
    fi
  done
  [[ -n $typed ]] && zle -U -- $typed
  if [[ $reply == $'\e['(#b)([0-9]##)';'([0-9]##)R ]]; then
    local -i cols=${COLUMNS:-80}
    local -i abs=$(( (match[1] - 1) * cols + match[2] - 1 - _pal_lastw ))
    (( abs < 0 )) && abs=0
    _pal_row0=$(( abs / cols )) _pal_col0=$(( abs % cols ))
  else
    _pal_row0=-1
  fi
}

_pal_update() {
  (( _pal_fd >= 0 )) || return 0
  (( _pal_seq++ ))
  local -i w=${(m)#LBUFFER}
  # After a pause (another app or pane, a reflow, an async prompt redraw) the
  # remembered cell may be stale: measure again.
  (( ${EPOCHREALTIME:-0} - _pal_seen > 1 )) && _pal_locate=1
  _pal_seen=${EPOCHREALTIME:-0}
  if [[ -z $BUFFER || $LBUFFER == *$'\n'* || $LASTWIDGET == *(history|search)* ]] || (( REGION_ACTIVE )); then
    _pal_lastw=$w
    _pal_send hide
    return 0
  fi
  [[ $COLUMNS:$LINES != $_pal_dims ]] && { _pal_dims=$COLUMNS:$LINES; _pal_locate=1; }
  (( _pal_locate )) && _pal_locate_prompt
  local -i cols=${COLUMNS:-80} lines=${LINES:-24} row=-1 col=0
  if (( _pal_row0 >= 0 )); then
    local -i abs=$(( _pal_row0 * cols + _pal_col0 + w ))
    row=$(( abs / cols )) col=$(( abs % cols ))
    if (( row >= lines )); then   # the terminal scrolled
      _pal_row0=$(( _pal_row0 - (row - lines + 1) ))
      row=$(( lines - 1 ))
    fi
  fi
  _pal_lastw=$w
  _pal_send update $_pal_seq $PWD $LBUFFER $row $col $cols $lines
}

_pal_accept() {
  local -i n=$_pal_items[2*_pal_sel-1]
  local text=$_pal_items[2*_pal_sel]
  (( n > 0 )) && LBUFFER=${LBUFFER[1,-n-1]}
  LBUFFER+=$text
  _pal_open=0
  _pal_send accept $text
}

_pal_move() {
  local -i n=$(( $#_pal_items / 2 ))
  (( n )) || return 0
  _pal_sel=$(( (_pal_sel - 1 + $1 + n) % n + 1 ))
  _pal_moved=1
  _pal_send select $(( _pal_sel - 1 ))
}

# Bound to the navigation keys; falls through to the original widget whenever
# the dropdown is closed.
_pal_key() {
  if (( _pal_open )); then
    case $KEYS in
      $'\e[A'|$'\eOA'|$'\C-p') _pal_move -1; return 0 ;;
      $'\e[B'|$'\eOB'|$'\C-n') _pal_move 1; return 0 ;;
      $'\t') _pal_accept; return 0 ;;
      $'\r') (( _pal_moved )) && { _pal_accept; return 0; } ;;
      $'\e') _pal_open=0; _pal_send dismiss; return 0 ;;
    esac
    _pal_open=0
    _pal_send hide
  fi
  local orig=$_pal_orig[$KEYS]
  [[ -n $orig ]] && zle $orig -- "$@"
  return 0
}
zle -N _pal_key

_pal_bind() {
  local key=$1 orig
  orig=${${(z)$(bindkey -M main -- $key 2>/dev/null)}[2]}
  [[ $orig == (undefined-key|_pal_key) ]] && orig=''
  _pal_orig[$key]=$orig
  bindkey -M main -- $key _pal_key
}

_pal_line_init() {
  _pal_locate=1 _pal_open=0 _pal_last=''
  _pal_lastw=${(m)#LBUFFER}
}

_pal_line_pre_redraw() {
  [[ $BUFFER$'\0'$CURSOR == $_pal_last ]] && return 0
  _pal_last=$BUFFER$'\0'$CURSOR
  _pal_open=0
  _pal_update
}

_pal_line_finish() {
  _pal_open=0
  _pal_send hide
}

_pal_precmd() {
  if (( _pal_fd < 0 )); then
    _pal_connect
  else
    if [[ $PATH != $_pal_path ]]; then
      _pal_path=$PATH
      _pal_send env $PATH
    fi
    _pal_snapshot
  fi
}

# Remove this shell's snapshot even when Palette isn't running.
_pal_exit() {
  command rm -f -- ${_pal_sock:h}/shell-$$.zsh 2>/dev/null
}

_pal_clear_screen() {
  zle .clear-screen
  _pal_locate=1
}
zle -N clear-screen _pal_clear_screen

# Removes Palette's key bindings and hooks and disconnects, for when it
# misbehaves in this shell. The menu-bar item can ask for this too.
_pal_unload() {
  (( ${+_PALETTE_LOADED} )) || return 1
  local key
  for key in ${(k)_pal_orig}; do
    # Leave keys alone that another plugin bound after Palette.
    [[ ${${(z)$(bindkey -M main -- $key 2>/dev/null)}[2]} == _pal_key ]] || continue
    if [[ -n $_pal_orig[$key] ]]; then
      bindkey -M main -- $key $_pal_orig[$key]
    else
      bindkey -M main -r -- $key
    fi
  done
  _pal_orig=()
  zle -A .clear-screen clear-screen
  add-zle-hook-widget -d line-init _pal_line_init
  add-zle-hook-widget -d line-pre-redraw _pal_line_pre_redraw
  add-zle-hook-widget -d line-finish _pal_line_finish
  add-zsh-hook -d precmd _pal_precmd
  add-zsh-hook -d zshexit _pal_exit
  _pal_send hide
  _pal_disconnect
  _pal_exit
  unset _PALETTE_LOADED
}

# The command-line tool. `unload` and `load` act on this shell; everything
# else runs the Palette binary next to this script.
palette() {
  case $*:$# in
    unload:1)
      _pal_unload || { print -ru2 -- "palette: not loaded in this shell"; return 1; }
      print -r -- "Palette is unloaded from this shell. Run \`palette load\` to load it again."
      return 0
      ;;
    load:1)
      (( ${+_PALETTE_LOADED} )) && { print -r -- "Palette is already loaded in this shell."; return 0; }
      source $_pal_script && _pal_connect
      return 0
      ;;
  esac
  local bin
  for bin in ${_pal_script:h:h}/{MacOS/Palette,.build/debug/Palette}; do
    [[ -x $bin ]] && { PALETTE_SOCKET=$_pal_sock command $bin "$@"; return; }
  done
  print -ru2 -- "palette: can't find the Palette binary next to $_pal_script"
  return 1
}

# Completion for `palette`, for Tab and for Palette's own dropdown.
fpath+=( ${_pal_script:h}/completions )
autoload -Uz _palette
(( ${+functions[compdef]} )) && compdef _palette palette

() {
  local key
  for key in $'\e[A' $'\eOA' $'\e[B' $'\eOB' $'\C-p' $'\C-n' $'\t' $'\r' $'\e'; do
    _pal_bind $key
  done
}
add-zle-hook-widget line-init _pal_line_init
add-zle-hook-widget line-pre-redraw _pal_line_pre_redraw
add-zle-hook-widget line-finish _pal_line_finish
add-zsh-hook precmd _pal_precmd
add-zsh-hook zshexit _pal_exit
