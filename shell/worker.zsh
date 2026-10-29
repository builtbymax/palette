# Palette completion worker.
#
# Palette.app runs `zsh -f -i` in a private pseudo-terminal and sources this
# file. Each request is written to $PALETTE_REQ (cwd, PATH, snapshot path,
# snapshot signature and command line, one per line) and triggered with
# Ctrl-G. The snapshot, written by palette.zsh, brings the user's aliases,
# completion functions, compdefs and styles into this clean shell. The widget runs zsh's own
# completion system with `compadd` captured, and prints every match between
# STX and ETX as RS…GS framed records with US separated fields:
#
#   tag  display  word  description

setopt no_beep no_monitor no_notify no_prompt_cr no_prompt_sp
PS1='' RPS1='' PS2=''
HISTFILE='' SAVEHIST=0
COLUMNS=400
bindkey -e
zmodload zsh/zutil zsh/parameter

[[ -n $PALETTE_FPATH ]] && fpath=( ${(s.:.)PALETTE_FPATH} $fpath )
typeset -U fpath
autoload -Uz compinit
compinit -C -i -d "${PALETTE_CACHE:-${TMPDIR:-/tmp}}/zcompdump-$ZSH_VERSION"

# Styles the capture depends on. User styles for the same names are removed
# so that more specific user patterns can't override them.
_pw_styles() {
  local p
  local -a patterns
  zstyle -g patterns
  for p in $patterns; do
    zstyle -d $p completer menu list-grouped insert-tab verbose
  done
  zstyle ':completion:*' completer _complete
  zstyle ':completion:*' menu no
  zstyle ':completion:*' verbose yes
  zstyle ':completion:*' list-grouped false
  zstyle ':completion:*' insert-tab false
  zstyle ':completion:*' use-cache yes
  zstyle ':completion:*' cache-path "${PALETTE_CACHE:-${TMPDIR:-/tmp}}/compcache"
}
_pw_styles

# Loads a shell snapshot. Function names listed in _pal_stubs become no-op
# functions so they are offered as commands.
_pw_load() {
  local -a _pal_stubs
  local f
  { builtin source $1 } 2>/dev/null
  for f in $_pal_stubs; do
    (( $+functions[$f] )) || functions[$f]=':'
  done
  _pw_styles
}

# Value of an option parsed by zparseopts: (-P value) or (-Pvalue).
_pw_val() {
  if (( $# >= 2 )); then REPLY=$2
  elif (( $# == 1 )); then REPLY=${1#-?}
  else REPLY=''
  fi
}

compadd() {
  setopt localoptions extendedglob no_ksharrays
  local a __d='' quoted=0 files=0 i
  for (( i = 1; i <= $#; i++ )); do
    a=${@[i]}
    [[ $a == (-|--) ]] && break
    [[ $a == -* ]] || continue
    # Internal queries (-O/-A/-D) must behave exactly like the builtin.
    [[ $a == -[a-zA-Z]#[OAD]* ]] && { builtin compadd "$@"; return }
    [[ $a == -[a-zA-Z]#Q* ]] && quoted=1
    [[ $a == -[a-zA-Z]#f* ]] && files=1
    # Descriptions: -d name, -ld name or -dname.
    if [[ $a == -[a-zA-Z]#d ]]; then __d=${@[i+1]}; (( i++ ))
    elif [[ $a == -[a-ce-zA-Z]#d?* ]]; then __d=${a#*d}
    fi
  done

  local -a __hits __dscr
  if [[ -n $__d ]]; then
    if [[ $__d == \(* ]]; then eval "__dscr=$__d"; else __dscr=( "${(@P)__d}" ); fi
  fi
  builtin compadd -A __hits -D __dscr "$@"
  (( $#__hits )) || return 1

  local -a apre hpre hsuf asuf wdir
  zparseopts -E P:=apre p:=hpre s:=hsuf S:=asuf W:=wdir
  local ap hp hs as wd
  _pw_val $apre; ap=$REPLY
  _pw_val $hpre; hp=$REPLY
  _pw_val $hsuf; hs=$REPLY
  _pw_val $asuf; as=$REPLY
  _pw_val $wdir; wd=$REPLY
  [[ $as == [[:space:]]# ]] && as=''

  local i hit word display desc dir
  for (( i = 1; i <= $#__hits; i++ )); do
    hit=$__hits[i]
    (( quoted )) && word=$hit || word=${(q)hit}
    word=$IPREFIX$ap$hp$word$hs$as
    display=$hit
    if (( files )) && [[ $word != */ ]]; then
      if [[ -n $wd ]]; then dir=$wd/$hit; else dir=${(Q)hp}$hit; fi
      [[ -d ${~dir} ]] && { word+=/; display+=/ }
    fi
    desc=''
    if (( i <= $#__dscr )); then
      desc=${__dscr[i]#"$hit"}
      desc=${${desc##[[:space:]]#}#--}
      desc=${${desc##[[:space:]]#}%%[[:space:]]#}
      [[ $desc == $hit ]] && desc=''
    fi
    print -rn -- $'\x1e'"${curtag:-}"$'\x1f'"$display"$'\x1f'"$word"$'\x1f'"${desc//[$'\n\t']/ }"$'\x1d'
  done
}

typeset -g _pw_cwd='' _pw_path='' _pw_snapshot=''
_pw_capture() {
  local cwd p snapshot signature line
  {
    IFS= read -r cwd; IFS= read -r p; IFS= read -r snapshot; IFS= read -r signature; IFS= read -r line
  } < $PALETTE_REQ
  if [[ -r $snapshot && $snapshot:$signature != $_pw_snapshot ]]; then
    _pw_snapshot=$snapshot:$signature
    _pw_load $snapshot
  fi
  if [[ $cwd != $_pw_cwd ]]; then builtin cd -q -- $cwd 2>/dev/null; _pw_cwd=$cwd; fi
  if [[ -n $p && $p != $_pw_path ]]; then PATH=$p; rehash; _pw_path=$p; fi
  BUFFER=$line
  CURSOR=$#BUFFER
  print -rn -- $'\x02'
  zle complete-word
  print -rn -- $'\x03'
  BUFFER=''
  CURSOR=0
}
zle -N _pw_capture
bindkey '^G' _pw_capture
print -rn -- $'\x04'
