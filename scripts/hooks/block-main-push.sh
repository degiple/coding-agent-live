#!/usr/bin/env bash
# PreToolUse フック（Claude Code と Codex で共用）。
# 標準入力のJSONから tool_input.command を取り出し、main への push と
# force push を見つけたら、permissionDecision を deny にして返す。
# 該当しなければ何も出力せず exit 0（通常の権限確認に任せる）。
#
# 判定は「git がコマンドの位置にあるとき」だけ行う。
# コマンドの位置 = 先頭、または ; & | ( $( ` 改行 の直後、
# または sh -c / bash -c / eval の引数の先頭。
# 引用符の中の文字列（コミットメッセージ、gh の --body など）は対象にしない。
# 注意: 完全な防御ではない（公式も「完全な強制手段ではない」としている）。

input="$(cat)"

command=""
cwd=""
loose=0
if command -v jq >/dev/null 2>&1; then
  command="$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
fi

# JSON の文字列値を取り出して、エスケープを戻す（jq が無いとき用）。
json_field() {
  printf '%s' "$input" |
    sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\(\(\\\\.\|[^\"\\\\]\)*\)\".*/\1/p" |
    head -n 1 |
    sed -e 's/\\\\/\x01/g' -e 's/\\"/"/g' -e 's/\\n/\n/g' -e 's/\\t/\t/g' -e 's#\\/#/#g' -e 's/\x01/\\/g'
}

if [ -z "$command" ]; then
  command="$(json_field command)"
  [ -n "$cwd" ] || cwd="$(json_field cwd)"
fi
# 取り出せないときは、JSON全体を対象にして、位置の条件も外す（厳しい側に倒れる）。
if [ -z "$command" ]; then
  command="$input"
  loose=1
fi
[ -n "$cwd" ] || cwd="$PWD"

deny() {
  printf '%s\n' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"main への push と force push は禁止です。作業用のブランチを切って push してください。"}}'
  exit 0
}

current_branch="$(git -C "$cwd" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"

# 文字列を単語に分ける。引用符は外し、区切りの直後の単語には C=1 を付ける。
# 結果は配列 T（単語）と C（区切り直後なら 1）に入れる。
tokenize() {
  local s="$1" len=${#1} i=0 ch nx cur="" have=0 cmd=1 tokcmd=1 q="" sub=0 bt=0
  T=()
  C=()
  while [ "$i" -lt "$len" ]; do
    ch="${s:i:1}"
    nx="${s:i+1:1}"
    if [ "$q" = "'" ]; then
      if [ "$ch" = "'" ]; then q=""; else
        [ "$have" -eq 0 ] && { tokcmd=$cmd; have=1; }
        cur+="$ch"
      fi
    elif [ "$q" = '"' ]; then
      # 二重引用符の中でも $( ) と `` の中身はコマンドとして実行されるので、区切りとして扱う。
      if [ "$sub" -gt 0 ] || [ "$bt" -eq 1 ]; then
        case "$ch" in
          ' ' | $'\t')
            if [ "$have" -eq 1 ]; then T+=("$cur"); C+=("$tokcmd"); cur=""; have=0; cmd=0; fi
            i=$((i + 1)); continue ;;
          $'\n' | ';' | '|' | '&' | '(')
            if [ "$have" -eq 1 ]; then T+=("$cur"); C+=("$tokcmd"); cur=""; have=0; fi
            cmd=1
            i=$((i + 1)); continue ;;
        esac
      fi
      case "$ch" in
        '"') q="" ;;
        '\')
          [ "$have" -eq 0 ] && { tokcmd=$cmd; have=1; }
          case "$nx" in
            '$' | '`' | '"' | '\') cur+="$nx"; i=$((i + 1)) ;;
            *) cur+="$ch" ;;
          esac
          ;;
        '$')
          if [ "$nx" = "(" ]; then
            [ "$have" -eq 1 ] && { T+=("$cur"); C+=("$tokcmd"); cur=""; have=0; }
            cmd=1; sub=$((sub + 1)); i=$((i + 1))
          else
            [ "$have" -eq 0 ] && { tokcmd=$cmd; have=1; }
            cur+="$ch"
          fi
          ;;
        '`')
          [ "$have" -eq 1 ] && { T+=("$cur"); C+=("$tokcmd"); cur=""; have=0; }
          if [ "$bt" -eq 0 ]; then bt=1; cmd=1; else bt=0; cmd=0; fi
          ;;
        ')')
          if [ "$sub" -gt 0 ]; then
            [ "$have" -eq 1 ] && { T+=("$cur"); C+=("$tokcmd"); cur=""; have=0; }
            sub=$((sub - 1)); cmd=0
          else
            [ "$have" -eq 0 ] && { tokcmd=$cmd; have=1; }
            cur+="$ch"
          fi
          ;;
        *)
          [ "$have" -eq 0 ] && { tokcmd=$cmd; have=1; }
          cur+="$ch" ;;
      esac
    else
      case "$ch" in
        "'" | '"')
          if [ "$have" -eq 0 ]; then tokcmd=$cmd; have=1; fi
          q="$ch"
          ;;
        '\')
          if [ "$nx" != $'\n' ]; then
            if [ "$have" -eq 0 ]; then tokcmd=$cmd; have=1; fi
            cur+="$nx"
          fi
          i=$((i + 1))
          ;;
        ' ' | $'\t')
          if [ "$have" -eq 1 ]; then T+=("$cur"); C+=("$tokcmd"); cur=""; have=0; cmd=0; fi
          ;;
        $'\n' | ';' | '|' | '&' | '(' | '`')
          if [ "$have" -eq 1 ]; then T+=("$cur"); C+=("$tokcmd"); cur=""; have=0; fi
          cmd=1
          ;;
        ')')
          if [ "$have" -eq 1 ]; then T+=("$cur"); C+=("$tokcmd"); cur=""; have=0; fi
          cmd=0
          ;;
        '$')
          if [ "$nx" = "(" ]; then
            if [ "$have" -eq 1 ]; then T+=("$cur"); C+=("$tokcmd"); cur=""; have=0; fi
            cmd=1
            i=$((i + 1))
          else
            if [ "$have" -eq 0 ]; then tokcmd=$cmd; have=1; fi
            cur+="$ch"
          fi
          ;;
        *)
          if [ "$have" -eq 0 ]; then tokcmd=$cmd; have=1; fi
          cur+="$ch"
          ;;
      esac
    fi
    i=$((i + 1))
  done
  if [ "$have" -eq 1 ]; then T+=("$cur"); C+=("$tokcmd"); fi
}

# 位置 $1 にある git の push を調べる（main 宛て・force・宛先なしを deny）。
check_git() {
  local n=${#T[@]} j=$(($1 + 1)) k a ref dst
  # git のグローバルオプションを読み飛ばす
  while [ "$j" -lt "$n" ]; do
    case "${T[$j]}" in
      -C | -c | --git-dir | --work-tree | --namespace) j=$((j + 2)) ;;
      -*) j=$((j + 1)) ;;
      *) break ;;
    esac
  done
  [ "$j" -lt "$n" ] && [ "${T[$j]}" = "push" ] || return 0

  local positional=()
  k=$((j + 1))
  while [ "$k" -lt "$n" ]; do
    # 次のコマンドの手前までを、この push の引数とする
    if [ "$loose" -eq 0 ] && [ "${C[$k]}" = "1" ]; then break; fi
    a="${T[$k]}"
    case "$a" in
      -f | --force | --force-with-lease* | --force-if-includes | --mirror) deny ;;
      --all) deny ;;
      --*) ;;
      -*[f]*) deny ;;
      -*) ;;
      *) positional+=("$a") ;;
    esac
    k=$((k + 1))
  done
  for a in "${positional[@]}"; do
    ref="${a#+}"
    dst="${ref##*:}"
    dst="${dst#refs/heads/}"
    if [ "$dst" = "main" ] || [ "$dst" = "master" ]; then
      deny
    fi
  done
  # 宛先を明示しない push（git push / git push origin / HEAD）は、今のブランチが main のとき危険
  if [ "$current_branch" = "main" ] || [ "$current_branch" = "master" ]; then
    if [ "${#positional[@]}" -lt 2 ]; then
      deny
    fi
    for a in "${positional[@]}"; do
      [ "$a" = "HEAD" ] && deny
    done
  fi
}

# コマンド文字列を調べる。sh -c / bash -c / eval の引数は、自分を呼び直して調べる。
scan() {
  local depth="$2"
  [ "$depth" -le 5 ] || return 0
  local -a T C
  local s="$1"
  if [ "$loose" -eq 1 ]; then
    s="${s//\\\"/ }"
    s="${s//\"/ }"
    s="${s//\'/ }"
  fi
  tokenize "$s"
  local n=${#T[@]} idx=0 pending=0 prevwrap=0 w base k rest
  while [ "$idx" -lt "$n" ]; do
    w="${T[$idx]}"
    if [ "${C[$idx]}" = "1" ] || [ "$loose" -eq 1 ]; then
      pending=1
      prevwrap=0
    fi
    if [ "$pending" -eq 1 ]; then
      if [[ "$w" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
        : # VAR=値 は読み飛ばす
      else
        case "$w" in
          env | command | exec | time | nohup | sudo | nice | builtin | if | then | do | else | elif | while | until | '!' | '{')
            prevwrap=1
            ;;
          -*)
            [ "$prevwrap" -eq 1 ] || pending=0
            ;;
          *)
            pending=0
            base="${w##*/}"
            case "$base" in
              git) check_git "$idx" ;;
              sh | bash | zsh | dash | ksh)
                k=$((idx + 1))
                while [ "$k" -lt "$n" ]; do
                  if [ "$loose" -eq 0 ] && [ "${C[$k]}" = "1" ]; then break; fi
                  if [[ "${T[$k]}" =~ ^-[A-Za-z]*c[A-Za-z]*$ ]] && [ $((k + 1)) -lt "$n" ]; then
                    scan "${T[$((k + 1))]}" $((depth + 1))
                    break
                  fi
                  k=$((k + 1))
                done
                ;;
              eval)
                k=$((idx + 1))
                rest=""
                while [ "$k" -lt "$n" ]; do
                  if [ "$loose" -eq 0 ] && [ "${C[$k]}" = "1" ]; then break; fi
                  rest+="${T[$k]} "
                  k=$((k + 1))
                done
                scan "$rest" $((depth + 1))
                ;;
            esac
            ;;
        esac
      fi
    fi
    idx=$((idx + 1))
  done
}

scan "$command" 0

exit 0
