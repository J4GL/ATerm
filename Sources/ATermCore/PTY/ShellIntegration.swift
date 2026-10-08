import Darwin
import Foundation

/// ATerm's additions to an interactive zsh: while a line is typed, the most recent history entry starting with
/// it, else the model's completion, is shown after it in grey. zsh keeps editing the line; ATerm only answers
/// its completion requests. See SPEC/pty/shell-integration.md.
public struct ShellIntegration: Sendable, Equatable {
    /// zsh asks for a completion with `OSC 6973 ; <nonce> ; <line>`; an empty line withdraws the request.
    public static let completionRequestCode = 6973
    /// The longest message `send(_:)` writes, its LF included: a FIFO write of at most `PIPE_BUF` bytes is atomic.
    static let maxMessageBytes = Int(PIPE_BUF)

    /// The FIFO zsh reads completions from.
    public let fifoPath: String
    /// Carried by every request of this shell, so that no other program can ask in its name.
    public let nonce: String

    /// For zsh, writes `.zshenv` and `aterm.zsh` into `directory/zsh`, makes a FIFO in `directory` and points
    /// `environment` at them. Nil, leaving everything untouched, for another shell or when a file cannot be made.
    public static func install(for executable: String, environment: inout [String: String],
                               directory: String) -> ShellIntegration? {
        guard (executable as NSString).lastPathComponent == "zsh" else { return nil }
        let zsh = (directory as NSString).appendingPathComponent("zsh")
        let fifo = (directory as NSString).appendingPathComponent("\(UUID().uuidString).fifo")
        guard makePrivateDirectory(directory), makePrivateDirectory(zsh),
              write(zshenv, to: ".zshenv", in: zsh), write(script, to: "aterm.zsh", in: zsh),
              mkfifo(fifo, 0o600) == 0
        else { return nil }
        var bytes = [UInt8](repeating: 0, count: 16)
        arc4random_buf(&bytes, bytes.count)
        let nonce = bytes.map { String(format: "%02x", $0) }.joined()
        environment["ATERM_ZSH_ZDOTDIR"] = environment["ZDOTDIR"]
        environment["ZDOTDIR"] = zsh
        environment["ATERM_SUGGEST_FIFO"] = fifo
        environment["ATERM_SUGGEST_NONCE"] = nonce
        return ShellIntegration(fifoPath: fifo, nonce: nonce)
    }

    /// Hands a completed line to the shell without blocking; false when the shell does not read the FIFO, when it
    /// is full, or when the line holds a line break or is too long.
    @discardableResult
    public func send(_ line: String) -> Bool {
        let message = Array((line + "\n").utf8)
        guard !line.contains("\n"), message.count <= Self.maxMessageBytes else { return false }
        let descriptor = open(fifoPath, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        return message.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) } == message.count
    }

    /// Tells the shell the user clicked in the terminal: an empty line, which no completion is. zsh then drops the
    /// highlight of pasted text.
    @discardableResult
    public func sendClick() -> Bool {
        send("")
    }

    /// Removes the FIFO, once the shell has gone.
    public func remove() {
        unlink(fifoPath)
    }

    private static func makePrivateDirectory(_ path: String) -> Bool {
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        return (try? manager.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: attributes))
            != nil && (try? manager.setAttributes(attributes, ofItemAtPath: path)) != nil
    }

    /// Writes `content` unless the file already holds it, atomically: a starting shell never reads half a file.
    private static func write(_ content: String, to name: String, in directory: String) -> Bool {
        let path = (directory as NSString).appendingPathComponent(name)
        let data = Data(content.utf8)
        if FileManager.default.contents(atPath: path) == data { return true }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    // MARK: - zsh

    /// Restores the user's `ZDOTDIR` and `.zshenv`, then loads `aterm.zsh` in an interactive shell.
    static let zshenv = #"""
        # ATerm: restores the user's ZDOTDIR and .zshenv, then adds ATerm's suggestions to an interactive
        # shell. See SPEC/pty/shell-integration.md.
        if [[ -n ${ATERM_ZSH_ZDOTDIR+X} ]]; then
          builtin export ZDOTDIR=$ATERM_ZSH_ZDOTDIR
          builtin unset ATERM_ZSH_ZDOTDIR
        else
          builtin unset ZDOTDIR
        fi
        {
          builtin typeset _aterm_file=${ZDOTDIR-$HOME}/.zshenv
          [[ ! -r $_aterm_file ]] || builtin source -- $_aterm_file
        } always {
          if [[ -o interactive ]]; then
            _aterm_file=${${(%):-%x}:A:h}/aterm.zsh
            [[ ! -r $_aterm_file ]] || builtin source -- $_aterm_file
          fi
          builtin unset _aterm_file
        }

        """#

    /// The suggestions: history first, then the model's completion asked to ATerm.
    static let script = #"""
        # ATerm suggestions (SPEC/pty/shell-integration.md): while a line is typed, the most recent history
        # entry starting with it, else the model's completion, is shown after it in grey. →, End, ⌃E and ⌃F at the
        # end of the line accept it, ⌥→ accepts it up to the next word. A click in the terminal drops the highlight
        # of pasted text. Set up at the first prompt, after the user's .zshrc, unless zsh-autosuggestions is loaded.
        builtin typeset -g _aterm_nonce=$ATERM_SUGGEST_NONCE _aterm_fifo=$ATERM_SUGGEST_FIFO
        builtin unset ATERM_SUGGEST_NONCE ATERM_SUGGEST_FIFO
        builtin typeset -ga precmd_functions
        precmd_functions+=(_aterm_init)

        _aterm_init() {
          emulate -L zsh
          setopt no_local_traps
          precmd_functions=(${precmd_functions:#_aterm_init})
          autoload -Uz is-at-least add-zle-hook-widget
          (( ! $+functions[_zsh_autosuggest_start] )) && is-at-least 5.9 || return 0
          typeset -g _aterm_ai= _aterm_asked= _aterm_fd= _aterm_yanked=0
          local widget
          for widget in forward-char end-of-line vi-forward-char vi-end-of-line; do
            zle -A $widget _aterm_orig_$widget && zle -N $widget _aterm_accept
          done
          for widget in forward-word emacs-forward-word; do
            zle -A $widget _aterm_orig_$widget && zle -N $widget _aterm_accept_word
          done
          # End and Home as ATerm sends them, when nothing uses them.
          [[ $(bindkey '^[[F') == *undefined-key ]] && bindkey '^[[F' end-of-line
          [[ $(bindkey '^[[H') == *undefined-key ]] && bindkey '^[[H' beginning-of-line
          zle -N _aterm_clear
          add-zle-hook-widget line-pre-redraw _aterm_suggest
          add-zle-hook-widget line-finish _aterm_clear
          if (( ! $+functions[TRAPINT] )); then
            TRAPINT() { zle && zle _aterm_clear; return $(( 128 + $1 )) }
          fi
          if [[ -n $_aterm_nonce && -p $_aterm_fifo ]] && zmodload zsh/system 2>/dev/null &&
              sysopen -r -w -o cloexec -u _aterm_fd $_aterm_fifo 2>/dev/null; then
            zle -N _aterm_receive
            zle -F -w $_aterm_fd _aterm_receive
          fi
        }

        # Before each redraw: the suggestion after the line, and the request for a completion when the history has
        # none (an empty line withdraws it). Notes whether the line shows pasted text highlighted.
        _aterm_suggest() {
          emulate -L zsh
          _aterm_yanked=$YANK_ACTIVE
          region_highlight=("${(@)region_highlight:#*memo=aterm}")
          POSTDISPLAY=
          local match= ask=
          if [[ -n $BUFFER && $LASTWIDGET != *(history|search)* ]]; then
            match=${history[(r)${(b)BUFFER}*]}
            [[ -z $match && $_aterm_ai == "$BUFFER"?* ]] && match=$_aterm_ai
            [[ -z $match && -n $_aterm_fd && $BUFFER != "$_aterm_ai" && $BUFFER != *[[:cntrl:]]* ]] &&
              ask=$BUFFER
          fi
          if [[ $ask != "$_aterm_asked" ]]; then
            _aterm_asked=$ask
            builtin print -rn -- $'\e]\#(completionRequestCode);'"$_aterm_nonce;$ask"$'\a'
          fi
          POSTDISPLAY=${match:$#BUFFER}
          [[ -z $POSTDISPLAY ]] || region_highlight+=("$#BUFFER $(( $#BUFFER + $#POSTDISPLAY )) fg=8 memo=aterm")
        }

        # →, End, ⌃E, ⌃F: at the end of the line, take the whole suggestion.
        _aterm_accept() {
          if [[ -n $POSTDISPLAY ]] && (( CURSOR == $#BUFFER )); then
            BUFFER+=$POSTDISPLAY
            CURSOR=$#BUFFER
          else
            zle _aterm_orig_$WIDGET -- "$@"
          fi
        }

        # ⌥→: take the suggestion up to where the word motion goes.
        _aterm_accept_word() {
          local line=$BUFFER
          BUFFER+=$POSTDISPLAY
          zle _aterm_orig_$WIDGET -- "$@"
          if (( CURSOR > $#line )); then BUFFER=${BUFFER:0:$CURSOR}; else BUFFER=$line; fi
        }

        # The line is accepted or interrupted: no grey text left behind, no request pending.
        _aterm_clear() {
          emulate -L zsh
          POSTDISPLAY=
          region_highlight=("${(@)region_highlight:#*memo=aterm}")
          _aterm_ai=
          if [[ -n $_aterm_asked ]]; then
            _aterm_asked=
            builtin print -rn -- $'\e]\#(completionRequestCode);'"$_aterm_nonce;"$'\a'
          fi
          zle -R
        }

        # A completion from ATerm, shown while it extends the line. An empty line is a click: redrawn, the line
        # no longer highlights pasted text.
        _aterm_receive() {
          emulate -L zsh
          local line
          IFS= read -r -t 0.1 -u $1 line || return 0
          if [[ -z $line ]]; then
            # YANK_ACTIVE stays set until this widget returns, though the redrawn line no longer shows it.
            (( _aterm_yanked )) && zle .redisplay && _aterm_yanked=0
            return 0
          fi
          _aterm_ai=$line
          _aterm_suggest
          zle -R
        }

        """#
}
