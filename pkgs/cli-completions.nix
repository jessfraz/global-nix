{
  runCommand,
  bash,
  rustup,
  zooCli,
}:
runCommand "cli-completions" {
  nativeBuildInputs = [bash zooCli];
  disallowedReferences = [rustup zooCli];
} ''
  export HOME="$TMPDIR"
  completions="$out/share/bash-completion/completions"
  mkdir -p "$completions"
  zoo completion -s bash > "$completions/zoo"
  cp ${rustup}/share/bash-completion/completions/rustup.bash "$completions/rustup"

  for command in zoo rustup; do
    bash -n "$completions/$command"
    bash --noprofile --norc -c '
      source "$1"
      complete -p "$2" >/dev/null
    ' _ "$completions/$command" "$command"
  done
''
