import executor;
import std;
import gosh_types;
import gosh_os;
import os;

// Simple pattern matching for shell globbing (* and ?)
fn glob_match(pattern: const u8[:], text: const u8[:]) -> bool {
    var p = 0;
    var t = 0;
    var star_p = -1;
    var star_t = -1;

    while t < text.len {
        if p < pattern.len && (pattern[p] == '?' || pattern[p] == text[t]) {
            p++;
            t++;
        } else if p < pattern.len && pattern[p] == '*' {
            star_p = p;
            star_t = t;
            p++;
        } else if star_p >= 0 {
            p = star_p + 1;
            star_t++;
            t = star_t;
        } else {
            return false;
        }
    }

    while p < pattern.len && pattern[p] == '*' {
        p++;
    }

    return p == pattern.len;
}

// Find variable in state or environment
fn get_var(state: const ShellState&, name: const u8[:], out: u8[..1024]&) -> bool {
    out.clear();

    // Check special variables first
    if name == "?" {
        format(out, state.last_status);
        return true;
    }
    if name == "$" {
        format(out, state.pid);
        return true;
    }
    if name == "!" {
        format(out, state.last_bg_pid);
        return true;
    }
    if name == "#" {
        format(out, state.script_args.len);
        return true;
    }
    if name == "0" {
        if state.script_name.len > 0 {
            format(out, state.script_name);
        } else {
            format(out, "gosh");
        }
        return true;
    }
    let arg_num, is_num = parse_int(name);
    if is_num && arg_num >= 1 && arg_num <= state.script_args.len {
        format(out, state.script_args[(arg_num - 1) as i64]);
        return true;
    }
    if name == "PWD" {
        format(out, state.cwd);
        return true;
    }
    if name == "HOME" {
        format(out, state.home);
        return true;
    }
    if name == "USER" {
        format(out, state.user);
        return true;
    }

    // Check shell state variables (most recent first)
    for i in state.var_count {
        let idx = state.var_count - 1 - i;
        if state.vars[idx].name == name {
            format(out, state.vars[idx].val);
            return true;
        }
    }

    // Fallback to OS environment
    var env_buf: u8[>..] = [];
    if env(name, env_buf) {
        format(out, env_buf);
        return true;
    }

    return false;
}

// Set or update a variable in state
fn set_var(state: ShellState&, name: const u8[:], val: const u8[:], export_to_env: bool) -> i32 {
    // Preserve export status when assigning an existing shell variable.
    for i in state.var_count {
        if state.vars[i].name == name {
            let exported = state.vars[i].exported || export_to_env;
            if exported && gosh_setenv(name, val) != 0 {
                print("gosh: failed to update environment variable: ", name);
                return 1;
            }
            state.vars[i].val.clear();
            format(state.vars[i].val, val);
            state.vars[i].exported = exported;
            return 0;
        }
    }

    // Inherited environment variables may not yet have a shell-state entry.
    var env_buf: u8[>..] = [];
    let exported = export_to_env || env(name, env_buf);
    if state.var_count < 256 {
        if exported && gosh_setenv(name, val) != 0 {
            print("gosh: failed to update environment variable: ", name);
            return 1;
        }
        var v = ShellVar { exported: exported };
        format(v.name, name);
        format(v.val, val);
        state.vars.push(v);
        state.var_count = state.vars.len as i32;
    }
    return 0;
}

// Simple arithmetic evaluator: handles +, -, *, /, %, (, ) and numbers/vars
recursive fn eval_arith(state: const ShellState&, expr: const u8[:]) -> i64 {
    var s = trim(expr);
    if s.len == 0 { return 0; }

    // Strip outer parens if wrapped
    if s.len >= 2 && s[0] == '(' && s[s.len - 1] == ')' {
        return eval_arith(state, s[1..s.len - 1]);
    }

    // Look for lowest precedence operators outside parens: + and -
    var depth = 0;
    var split_idx = -1;
    var op = 0;

    for i in s.len {
        let c = s[i];
        if c == '(' { depth++; }
        else if c == ')' { depth--; }
        else if depth == 0 {
            if (c == '+' || c == '-') && i > 0 && s[i - 1] != '+' && s[i - 1] != '-' && s[i - 1] != '*' && s[i - 1] != '/' {
                split_idx = i;
                op = c;
            }
        }
    }

    if split_idx > 0 {
        let left = eval_arith(state, s[..split_idx]);
        let right = eval_arith(state, s[split_idx + 1..]);
        if op == '+' { return left + right; }
        if op == '-' { return left - right; }
    }

    // Look for next precedence: *, /, %
    depth = 0;
    split_idx = -1;
    op = 0;
    for i in s.len {
        let c = s[i];
        if c == '(' { depth++; }
        else if c == ')' { depth--; }
        else if depth == 0 {
            if c == '*' || c == '/' || c == '%' {
                split_idx = i;
                op = c;
            }
        }
    }

    if split_idx > 0 {
        let left = eval_arith(state, s[..split_idx]);
        let right = eval_arith(state, s[split_idx + 1..]);
        if op == '*' { return left * right; }
        if op == '/' { return if right != 0 { left / right } else { 0 }; }
        if op == '%' { return if right != 0 { left % right } else { 0 }; }
    }

    // Single term: number or variable name
    let num, ok = parse_int(s);
    if ok { return num; }

    var var_val: u8[..1024] = [];
    if get_var(state, s, var_val) {
        let v, vok = parse_int(var_val);
        if vok { return v; }
    }

    return 0;
}

// Capture subshell output for $(...) and `...`
fn capture_subshell_output(state: const ShellState&, sub_cmd: const u8[:], out: u8[..128]&) {
    var p: i32[2] = [-1, -1];
    if gosh_pipe(p[0]) != 0 { return; }

    let pid = gosh_fork();
    if pid < 0 {
        gosh_close(p[0]);
        gosh_close(p[1]);
        return;
    }

    if pid == 0 {
        gosh_reset_signals();
        gosh_close(p[0]);
        gosh_dup2(p[1], 1);
        gosh_close(p[1]);

        var sub_state = state;
        execute_script(sub_state, sub_cmd);
        gosh_exit(sub_state.last_status);
    }

    gosh_close(p[1]);

    var cap_buf: u8[4096] = [0; 4096];
    let n = gosh_read_fd(p[0], cap_buf);
    gosh_close(p[0]);
    gosh_wait_pid(pid);

    if n > 0 {
        var end = n;
        while end > 0 && (cap_buf[end - 1] == '\n' || cap_buf[end - 1] == '\r') {
            end--;
        }
        format(out, cap_buf[..end]);
    }
}

// Expand a single word: variables, arithmetic $((...)), cmd sub $(...), tilde
fn expand_word(state: const ShellState&, word: const u8[:], out: u8[..128]&) {
    out.clear();
    if word.len == 0 { return; }

    var i = 0;
    let len = word.len;

    // Tilde expansion at start of word
    if word[0] == '~' && (len == 1 || word[1] == '/') {
        format(out, state.home);
        i = 1;
    }

    while i < len {
        let c = word[i];

        // 1. Single quotes: verbatim content, absolutely no expansions
        if c == '\'' {
            i++;
            while i < len && word[i] != '\'' {
                out.push(word[i]);
                i++;
            }
            if i < len && word[i] == '\'' {
                i++;
            }
            continue;
        }

        // 2. Double quotes: variable and subshell expansions, no globbing
        if c == '"' {
            i++;
            while i < len && word[i] != '"' {
                let qc = word[i];
                if qc == '\\' && i + 1 < len {
                    let next = word[i + 1];
                    if next == '"' || next == '\\' || next == '$' || next == '`' {
                        out.push(next);
                        i += 2;
                        continue;
                    }
                }

                // Command substitution inside double quotes
                if qc == '$' && i + 1 < len && word[i + 1] == '(' {
                    let start = i + 2;
                    var depth = 1;
                    var end = -1;
                    var j = start;
                    while j < len {
                        if word[j] == '(' { depth++; }
                        else if word[j] == ')' {
                            depth--;
                            if depth == 0 { end = j; break; }
                        }
                        j++;
                    }
                    if end >= 0 {
                        var cap: u8[..128] = [];
                        capture_subshell_output(state, word[start..end], cap);
                        format(out, cap);
                        i = end + 1;
                        continue;
                    }
                }

                // Variable inside double quotes: ${VAR} or $VAR
                if qc == '$' && i + 1 < len {
                    if word[i + 1] == '{' {
                        let start = i + 2;
                        var end = -1;
                        var j = start;
                        while j < len {
                            if word[j] == '}' { end = j; break; }
                            j++;
                        }
                        if end >= 0 {
                            let full_param = word[start..end];
                            let dash_idx = find(full_param, ":-");
                            if dash_idx >= 0 {
                                let var_name = full_param[..dash_idx];
                                let def_val = full_param[dash_idx + 2..];
                                var val_buf: u8[..1024] = [];
                                if get_var(state, var_name, val_buf) && val_buf.len > 0 {
                                    format(out, val_buf);
                                } else if def_val.len > 0 {
                                    format(out, def_val);
                                }
                            } else {
                                var val_buf: u8[..1024] = [];
                                if get_var(state, full_param, val_buf) {
                                    format(out, val_buf);
                                }
                            }
                            i = end + 1;
                            continue;
                        }
                    } else if word[i + 1] == '?' || word[i + 1] == '$' || word[i + 1] == '!' || word[i + 1] == '#' || ascii::is_digit(word[i + 1]) {
                        var special_name: u8[..4] = [];
                        special_name.push(word[i + 1]);
                        var val_buf: u8[..1024] = [];
                        if get_var(state, special_name, val_buf) {
                            format(out, val_buf);
                        }
                        i += 2;
                        continue;
                    } else if ascii::is_alpha(word[i + 1]) || word[i + 1] == '_' {
                        let start = i + 1;
                        var j = start;
                        while j < len && (ascii::is_alnum(word[j]) || word[j] == '_') {
                            j++;
                        }
                        let var_name = word[start..j];
                        var val_buf: u8[..1024] = [];
                        if get_var(state, var_name, val_buf) {
                            format(out, val_buf);
                        }
                        i = j;
                        continue;
                    }
                }

                out.push(qc);
                i++;
            }
            if i < len && word[i] == '"' {
                i++;
            }
            continue;
        }

        // 3. Unquoted expansions: Arithmetic $((...))
        if c == '$' && i + 2 < len && word[i + 1] == '(' && word[i + 2] == '(' {
            let start = i + 3;
            var end = -1;
            var j = start;
            while j + 1 < len {
                if word[j] == ')' && word[j + 1] == ')' {
                    end = j;
                    break;
                }
                j++;
            }
            if end >= 0 {
                let res = eval_arith(state, word[start..end]);
                format(out, res);
                i = end + 2;
                continue;
            }
        }

        // 4. Unquoted Command substitution $(...)
        if c == '$' && i + 1 < len && word[i + 1] == '(' {
            let start = i + 2;
            var depth = 1;
            var end = -1;
            var j = start;
            while j < len {
                if word[j] == '(' { depth++; }
                else if word[j] == ')' {
                    depth--;
                    if depth == 0 {
                        end = j;
                        break;
                    }
                }
                j++;
            }
            if end >= 0 {
                let sub_cmd = word[start..end];
                var cap: u8[..128] = [];
                capture_subshell_output(state, sub_cmd, cap);
                format(out, cap);
                i = end + 1;
                continue;
            }
        }

        // 5. Unquoted Command substitution `...`
        if c == '`' {
            let start = i + 1;
            var end = -1;
            var j = start;
            while j < len {
                if word[j] == '`' {
                    end = j;
                    break;
                }
                j++;
            }
            if end >= 0 {
                let sub_cmd = word[start..end];
                var cap: u8[..128] = [];
                capture_subshell_output(state, sub_cmd, cap);
                format(out, cap);
                i = end + 1;
                continue;
            }
        }

        // 6. Unquoted Variable expansion: ${VAR} or ${VAR:-default} or $VAR
        if c == '$' && i + 1 < len {
            if word[i + 1] == '{' {
                let start = i + 2;
                var end = -1;
                var j = start;
                while j < len {
                    if word[j] == '}' {
                        end = j;
                        break;
                    }
                    j++;
                }
                if end >= 0 {
                    let full_param = word[start..end];
                    let dash_idx = find(full_param, ":-");

                    if dash_idx >= 0 {
                        let var_name = full_param[..dash_idx];
                        let def_val = full_param[dash_idx + 2..];
                        var val_buf: u8[..1024] = [];
                        if get_var(state, var_name, val_buf) && val_buf.len > 0 {
                            format(out, val_buf);
                        } else if def_val.len > 0 {
                            format(out, def_val);
                        }
                    } else if full_param.len > 1 && full_param[0] == '#' {
                        var val_buf: u8[..1024] = [];
                        if get_var(state, full_param[1..], val_buf) {
                            format(out, val_buf.len);
                        } else {
                            format(out, 0);
                        }
                    } else {
                        var val_buf: u8[..1024] = [];
                        if get_var(state, full_param, val_buf) {
                            format(out, val_buf);
                        }
                    }

                    i = end + 1;
                    continue;
                }
            } else if word[i + 1] == '?' || word[i + 1] == '$' || word[i + 1] == '!' || word[i + 1] == '#' || ascii::is_digit(word[i + 1]) {
                var special_name: u8[..4] = [];
                special_name.push(word[i + 1]);
                var val_buf: u8[..1024] = [];
                if get_var(state, special_name, val_buf) {
                    format(out, val_buf);
                }
                i += 2;
                continue;
            } else if ascii::is_alpha(word[i + 1]) || word[i + 1] == '_' {
                let start = i + 1;
                var j = start;
                while j < len && (ascii::is_alnum(word[j]) || word[j] == '_') {
                    j++;
                }
                let var_name = word[start..j];
                var val_buf: u8[..1024] = [];
                if get_var(state, var_name, val_buf) {
                    format(out, val_buf);
                }
                i = j;
                continue;
            }
        }

        out.push(c);
        i++;
    }
}

// Expand a word list with globbing and variable expansion
fn expand_arguments(state: const ShellState&, raw_args: const u8[..128][..16]&, expanded_args: u8[..128][..16]&) {
    expanded_args.clear();

    for arg in raw_args {
        var exp: u8[..128] = [];
        expand_word(state, arg, exp);

        // Only glob if the argument was not quoted
        let is_quoted = (starts_with(arg, "\"") || starts_with(arg, "'"));

        // Check if contains glob pattern (* or ?)
        if !is_quoted && (find(exp, "*") >= 0 || find(exp, "?") >= 0) {
            // List current directory and match entries
            var dir_buf: u8[8192] = [0; 8192];
            let list_len = gosh_list_dir(".", dir_buf);
            var match_count = 0;

            if list_len > 0 {
                let dir_text = dir_buf[..list_len];
                each_split(dir_text, '\n') {
                    if it.len > 0 && glob_match(exp, it) {
                        var match_word: u8[..128] = [];
                        format(match_word, it);
                        if expanded_args.len < 16 {
                            expanded_args.push(match_word);
                            match_count++;
                        }
                    }
                };
            }

            if match_count == 0 {
                // No matches: keep pattern as literal argument (standard POSIX)
                if expanded_args.len < 16 {
                    expanded_args.push(exp);
                }
            }
        } else {
            if expanded_args.len < 16 {
                expanded_args.push(exp);
            }
        }
    }
}
