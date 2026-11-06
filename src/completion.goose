import std;
import gosh_types;
import gosh_os;
import builtins;
import os;

// Builtin list for completion
let BUILTIN_NAMES: const u8[:][21] = [
    "cd", "pwd", "exit", "export", "unset", "echo",
    "printf", "history", "alias", "unalias", "type", "command",
    "jobs", "fg", "bg", "source", ".", "set",
    "test", "[", "help"
];

// Complete files in a directory matching prefix
fn complete_files(dir_path: const u8[:], file_prefix: const u8[:], results: u8[..256][..64]&) {
    var buf: u8[8192] = [0; 8192];
    let n = gosh_list_dir(dir_path, buf);
    if n <= 0 { return; }

    let text = buf[..n];
    each_split(text, '\n') {
        if it.len > 0 && results.len < 64 {
            if file_prefix.len == 0 || starts_with(it, file_prefix) {
                // Ignore hidden files unless prefix starts with '.'
                if it[0] != '.' || (file_prefix.len > 0 && file_prefix[0] == '.') {
                    var full_entry: u8[..256] = [];
                    format(full_entry, it);

                    // Check if directory
                    var check_path: u8[>..] = [];
                    if dir_path != "." && dir_path.len > 0 {
                        format(check_path, dir_path, "/", it);
                    } else {
                        format(check_path, it);
                    }
                    if gosh_is_dir(check_path) != 0 {
                        full_entry.push('/');
                    }

                    results.push(full_entry);
                }
            }
        }
    };
}

// Complete PATH executables
fn complete_path(prefix: const u8[:], results: u8[..256][..64]&) {
    var path_env: u8[>..] = [];
    if !env("PATH", path_env) { return; }

    // Iterate explicitly so leading, trailing and repeated ':' retain empty entries.
    var start = 0;
    for end in path_env.len + 1 {
        if end < path_env.len && path_env[end] != ':' { continue; }
        let dir = if end == start { "." } else { path_env[start..end] };
        start = end + 1;
        if results.len < 64 {
            var buf: u8[8192] = [0; 8192];
            let n = gosh_list_dir(dir, buf);
            if n > 0 {
                let dir_text = buf[..n];
                each_split(dir_text, '\n') {
                    if it.len > 0 && results.len < 64 {
                        if starts_with(it, prefix) {
                            var full_path: u8[>..] = [];
                            format(full_path, dir, "/", it);
                            if gosh_is_executable(full_path) == 0 { continue; }
                            // Check if already in results
                            var already = false;
                            for r in results {
                                if r == it { already = true; break; }
                            }
                            if !already {
                                var w: u8[..256] = [];
                                format(w, it);
                                results.push(w);
                            }
                        }
                    }
                };
            }
        }
    }
}

struct CompletionContext {
    word_start: i32 = 0,
    command_position: bool = true,
}

// Only track word boundaries, quotes, escapes and simple-command separators.
// This deliberately does not parse substitutions or compound shell grammar.
fn completion_context(input: const u8[:]) -> CompletionContext {
    var context = CompletionContext {};
    var quote: u8 = 0;
    var escaped = false;
    for i in input.len {
        let c = input[i];
        if escaped { escaped = false; continue; }
        if c == '\\' && quote != '\'' { escaped = true; continue; }
        if quote != 0 {
            if c == quote { quote = 0; }
            continue;
        }
        if c == '\'' || c == '"' { quote = c; continue; }
        // '&' in redirections is not a command separator.
        let redir_amp = c == '&' &&
            ((i > 0 && (input[i - 1] == '>' || input[i - 1] == '<')) ||
             (i + 1 < input.len && input[i + 1] == '>'));
        if c == '|' || c == ';' || (c == '&' && !redir_amp) {
            context.word_start = i + 1;
            context.command_position = true;
        } else if c == ' ' || c == '\t' {
            if context.word_start < i { context.command_position = false; }
            context.word_start = i + 1;
        }
    }
    return context;
}

// Find all completions for current word under cursor
fn find_completions(state: const ShellState&, input_line: const u8[:], results: u8[..256][..64]&) {
    results.clear();

    let context = completion_context(input_line);
    let current_word = input_line[context.word_start..];
    let is_cmd_pos = context.command_position;

    // 1. Variable completion if starts with $
    if current_word.len > 0 && current_word[0] == '$' {
        let var_prefix = current_word[1..];
        for v in state.vars {
            if results.len < 64 && starts_with(v.name, var_prefix) {
                var w: u8[..256] = [];
                format(w, "$", v.name);
                results.push(w);
            }
        }
        return;
    }

    if is_cmd_pos {
        // Complete Builtins
        for b in BUILTIN_NAMES {
            if results.len < 64 && starts_with(b, current_word) {
                var w: u8[..256] = [];
                format(w, b);
                results.push(w);
            }
        }

        // Complete Aliases
        for a in state.aliases {
            if results.len < 64 && starts_with(a.name, current_word) {
                var w: u8[..256] = [];
                format(w, a.name);
                results.push(w);
            }
        }

        // Complete Functions
        for f in state.funcs {
            if results.len < 64 && starts_with(f.name, current_word) {
                var w: u8[..256] = [];
                format(w, f.name);
                results.push(w);
            }
        }

        // Complete PATH executables
        complete_path(current_word, results);
    }

    // Also complete files / directories
    let last_slash = rfind(current_word, "/");
    if last_slash >= 0 {
        let dir_part = current_word[..last_slash];
        let file_prefix = current_word[last_slash + 1..];
        var dir_results: u8[..256][..64] = [];
        complete_files(if dir_part.len > 0 { dir_part } else { "/" }, file_prefix, dir_results);
        for res in dir_results {
            if results.len < 64 {
                var w: u8[..256] = [];
                if dir_part == "/" {
                    format(w, "/", res);
                } else {
                    format(w, dir_part, "/", res);
                }
                results.push(w);
            }
        }
    } else {
        complete_files(".", current_word, results);
    }
}
