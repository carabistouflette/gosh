import std;
import gosh_types;
import gosh_os;
import os;

fn is_builtin(cmd: const u8[:]) -> bool {
    cmd == "cd" || cmd == "pwd" || cmd == "exit" ||
    cmd == "export" || cmd == "unset" || cmd == "echo" ||
    cmd == "printf" || cmd == "history" || cmd == "alias" ||
    cmd == "unalias" || cmd == "type" || cmd == "command" ||
    cmd == "jobs" || cmd == "fg" || cmd == "bg" ||
    cmd == "source" || cmd == "." || cmd == "set" ||
    cmd == "test" || cmd == "[" || cmd == "help"
}

// Builtin: echo [-n] [-e] [args...]
fn builtin_echo(args: const u8[..128][..16]&) -> i32 {
    var no_newline = false;
    var interpret_escapes = false;
    var start_idx = 1;

    while start_idx < args.len {
        let arg = args[start_idx];
        if arg == "-n" {
            no_newline = true;
            start_idx++;
        } else if arg == "-e" {
            interpret_escapes = true;
            start_idx++;
        } else if arg == "-ne" || arg == "-en" {
            no_newline = true;
            interpret_escapes = true;
            start_idx++;
        } else {
            break;
        }
    }

    var out_line: u8[>..] = [];

    for i in start_idx..args.len {
        if i > start_idx {
            out_line.push(' ');
        }
        let text = args[i];
        if interpret_escapes {
            var k = 0;
            while k < text.len {
                if text[k] == '\\' && k + 1 < text.len {
                    let esc = text[k + 1];
                    if esc == 'n' { out_line.push('\n'); k += 2; continue; }
                    if esc == 't' { out_line.push('\t'); k += 2; continue; }
                    if esc == 'r' { out_line.push('\r'); k += 2; continue; }
                    if esc == 'e' { out_line.push(27); k += 2; continue; } // ESC \033
                    if esc == '\\' { out_line.push('\\'); k += 2; continue; }
                }
                out_line.push(text[k]);
                k++;
            }
        } else {
            out_line.append(text);
        }
    }

    if !no_newline {
        out_line.push('\n');
    }

    write_stdout(out_line);
    flush_stdout();
    return 0;
}

// Builtin: cd [dir]
fn builtin_cd(state: ShellState&, args: const u8[..128][..16]&) -> i32 {
    var target: u8[..1024] = [];

    if args.len <= 1 {
        // cd with no args: go to HOME
        format(target, state.home);
    } else if args[1] == "-" {
        // cd -: go to OLDPWD
        var oldpwd_buf: u8[..1024] = [];
        var found = false;
        for v in state.vars {
            if v.name == "OLDPWD" {
                format(target, v.val);
                found = true;
                break;
            }
        }
        if !found {
            print("gosh: cd: OLDPWD not set");
            return 1;
        }
        print(target);
    } else {
        format(target, args[1]);
    }

    // Save current cwd as OLDPWD
    var oldpwd = ShellVar { exported: true };
    format(oldpwd.name, "OLDPWD");
    format(oldpwd.val, state.cwd);

    let res = gosh_chdir(target);
    if res != 0 {
        print("gosh: cd: ", target, ": No such file or directory");
        return 1;
    }

    // Update state.cwd
    var cwd_buf: u8[1024] = [0; 1024];
    let n = gosh_getcwd(cwd_buf);
    state.cwd.clear();
    if n > 0 {
        format(state.cwd, cwd_buf[..n]);
    }

    // Set OLDPWD and PWD in variables
    var found_old = false;
    var found_pwd = false;
    for &v in state.vars {
        if v.name == "OLDPWD" {
            v.val.clear();
            format(v.val, oldpwd.val);
            found_old = true;
        }
        if v.name == "PWD" {
            v.val.clear();
            format(v.val, state.cwd);
            found_pwd = true;
        }
    }
    if !found_old && state.vars.len < 256 {
        state.vars.push(oldpwd);
        state.var_count = state.vars.len as i32;
    }
    if !found_pwd && state.vars.len < 256 {
        var pwd_var = ShellVar { exported: true };
        format(pwd_var.name, "PWD");
        format(pwd_var.val, state.cwd);
        state.vars.push(pwd_var);
        state.var_count = state.vars.len as i32;
    }

    gosh_setenv("PWD", state.cwd);
    gosh_setenv("OLDPWD", oldpwd.val);

    return 0;
}

// Builtin: pwd
fn builtin_pwd(state: const ShellState&) -> i32 {
    print(state.cwd);
    return 0;
}

// Builtin: export [name[=val]...]
fn builtin_export(state: ShellState&, args: const u8[..128][..16]&) -> i32 {
    if args.len <= 1 {
        // List all exported variables
        for v in state.vars {
            if v.exported {
                print("export ", v.name, "=\"", v.val, "\"");
            }
        }
        return 0;
    }

    for i in 1..args.len {
        let arg = args[i];
        let eq = find(arg, "=");

        if eq >= 0 {
            let name = arg[..eq];
            let val = arg[eq + 1..];

            var found = false;
            for &v in state.vars {
                if v.name == name {
                    v.exported = true;
                    v.val.clear();
                    format(v.val, val);
                    gosh_setenv(name, v.val);
                    found = true;
                    break;
                }
            }

            if !found && state.vars.len < 256 {
                var v = ShellVar { exported: true };
                format(v.name, name);
                format(v.val, val);
                state.vars.push(v);
                state.var_count = state.vars.len as i32;
                gosh_setenv(name, v.val);
            }
        } else {
            let name = arg;
            var found = false;
            for &v in state.vars {
                if v.name == name {
                    v.exported = true;
                    gosh_setenv(name, v.val);
                    found = true;
                    break;
                }
            }
            if !found && state.vars.len < 256 {
                var v = ShellVar { exported: true };
                format(v.name, name);
                state.vars.push(v);
                state.var_count = state.vars.len as i32;
                gosh_setenv(name, v.val);
            }
        }
    }
    return 0;
}

// Builtin: unset [name...]
fn builtin_unset(state: ShellState&, args: const u8[..128][..16]&) -> i32 {
    for i in 1..args.len {
        let name = args[i];
        for k in state.vars.len {
            if state.vars[k].name == name {
                remove_at(state.vars, k);
                state.var_count = state.vars.len as i32;
                gosh_unsetenv(name);
                break;
            }
        }
    }
    return 0;
}

// Builtin: set
fn builtin_set(state: const ShellState&) -> i32 {
    for v in state.vars {
        print(v.name, "=", v.val);
    }
    return 0;
}

// Builtin: alias [name=val]
fn builtin_alias(state: ShellState&, args: const u8[..128][..16]&) -> i32 {
    if args.len <= 1 {
        for a in state.aliases {
            print("alias ", a.name, "='", a.val, "'");
        }
        return 0;
    }

    for i in 1..args.len {
        let arg = args[i];
        let eq = find(arg, "=");
        if eq > 0 {
            let name = arg[..eq];
            let val = arg[eq + 1..];

            var found = false;
            for &a in state.aliases {
                if a.name == name {
                    a.val.clear();
                    format(a.val, val);
                    found = true;
                    break;
                }
            }
            if !found && state.aliases.len < 64 {
                var a = ShellAlias {};
                format(a.name, name);
                format(a.val, val);
                state.aliases.push(a);
                state.alias_count = state.aliases.len as i32;
            }
        } else {
            // Print specific alias
            for a in state.aliases {
                if a.name == arg {
                    print("alias ", a.name, "='", a.val, "'");
                }
            }
        }
    }
    return 0;
}

// Builtin: unalias [name...]
fn builtin_unalias(state: ShellState&, args: const u8[..128][..16]&) -> i32 {
    for i in 1..args.len {
        let name = args[i];
        for k in state.aliases.len {
            if state.aliases[k].name == name {
                remove_at(state.aliases, k);
                state.alias_count = state.aliases.len as i32;
                break;
            }
        }
    }
    return 0;
}

// Builtin: history
fn builtin_history(state: const ShellState&) -> i32 {
    for i in state.hist_count {
        var num_buf: u8[>..] = [];
        format_uint(num_buf, (i + 1) as u64, 10, 5, ' ');
        print(num_buf, "  ", state.hist_lines[i]);
    }
    return 0;
}

// Builtin: type [name...]
fn builtin_type(state: const ShellState&, args: const u8[..128][..16]&) -> i32 {
    var ret: i32 = 0;
    for i in 1..args.len {
        let name = args[i];

        // Check alias
        var is_alias = false;
        for a in state.aliases {
            if a.name == name {
                print(name, " is an alias for ", a.val);
                is_alias = true;
                break;
            }
        }
        if is_alias { continue; }

        // Check builtin
        if is_builtin(name) {
            print(name, " is a shell builtin");
            continue;
        }

        // Check function
        var is_fn = false;
        for f in state.funcs {
            if f.name == name {
                print(name, " is a shell function");
                is_fn = true;
                break;
            }
        }
        if is_fn { continue; }

        // Check PATH
        var path_env: u8[>..] = [];
        var found = false;
        if env("PATH", path_env) {
            each_split(path_env, ':') {
                if it.len > 0 {
                    var full_path: u8[>..] = [];
                    format(full_path, it, "/", name);
                    if gosh_is_executable(full_path) != 0 {
                        print(name, " is ", full_path);
                        found = true;
                        return from each_split;
                    }
                }
            };
        }
        if !found {
            print("gosh: type: ", name, ": not found");
            ret = 1;
        }
    }
    return ret;
}

// Builtin: test / [ ... ]
fn builtin_test(args: const u8[..128][..16]&) -> i32 {
    var len = args.len;
    if len > 1 && args[0] == "[" && args[len - 1] == "]" {
        len--;
    }

    // test with no condition is false (exit 1)
    if len <= 1 { return 1; }

    // test "str" (true if non-empty)
    if len == 2 {
        return if args[1].len > 0 { 0 } else { 1 };
    }

    // test -z "str" (true if empty)
    if len == 3 && args[1] == "-z" {
        return if args[2].len == 0 { 0 } else { 1 };
    }

    // test -n "str" (true if not empty)
    if len == 3 && args[1] == "-n" {
        return if args[2].len > 0 { 0 } else { 1 };
    }

    // test -d "path" (true if directory)
    if len == 3 && args[1] == "-d" {
        return if gosh_is_dir(args[2]) != 0 { 0 } else { 1 };
    }

    // test -f "path" / -e "path" (true if file exists)
    if len == 3 && (args[1] == "-f" || args[1] == "-e") {
        return if gosh_file_exists(args[2]) != 0 { 0 } else { 1 };
    }

    // test -x "path" (true if executable)
    if len == 3 && args[1] == "-x" {
        return if gosh_is_executable(args[2]) != 0 { 0 } else { 1 };
    }

    // Binary string comparisons: s1 = s2, s1 == s2, s1 != s2
    if len == 4 {
        let left = args[1];
        let op = args[2];
        let right = args[3];

        if op == "=" || op == "==" {
            return if left == right { 0 } else { 1 };
        }
        if op == "!=" {
            return if left != right { 0 } else { 1 };
        }

        // Integer comparisons: -eq, -ne, -lt, -le, -gt, -ge
        let n1, ok1 = parse_int(left);
        let n2, ok2 = parse_int(right);
        if ok1 && ok2 {
            if op == "-eq" { return if n1 == n2 { 0 } else { 1 }; }
            if op == "-ne" { return if n1 != n2 { 0 } else { 1 }; }
            if op == "-lt" { return if n1 < n2 { 0 } else { 1 }; }
            if op == "-le" { return if n1 <= n2 { 0 } else { 1 }; }
            if op == "-gt" { return if n1 > n2 { 0 } else { 1 }; }
            if op == "-ge" { return if n1 >= n2 { 0 } else { 1 }; }
        }
    }

    return 1;
}

// Builtin: printf format [args...]
fn builtin_printf(args: const u8[..128][..16]&) -> i32 {
    if args.len <= 1 { return 0; }
    let fmt_str = args[1];
    var arg_idx = 2;
    var out_buf: u8[>..] = [];

    while true {
        let cycle_start = arg_idx;
        var i = 0;
        while i < fmt_str.len {
            let c = fmt_str[i];
            if c == '%' && i + 1 < fmt_str.len {
                let spec = fmt_str[i + 1];
                if spec == 's' {
                    if arg_idx < args.len {
                        out_buf.append(args[arg_idx]);
                        arg_idx++;
                    }
                    i += 2;
                    continue;
                }
                if spec == 'd' || spec == 'i' {
                    if arg_idx < args.len {
                        let num, ok = parse_int(args[arg_idx]);
                        format(out_buf, if ok { num } else { 0 });
                        arg_idx++;
                    } else {
                        out_buf.push('0');
                    }
                    i += 2;
                    continue;
                }
                if spec == '%' {
                    out_buf.push('%');
                    i += 2;
                    continue;
                }
            }
            if c == '\\' && i + 1 < fmt_str.len {
                let esc = fmt_str[i + 1];
                if esc == 'n' { out_buf.push('\n'); i += 2; continue; }
                if esc == 't' { out_buf.push('\t'); i += 2; continue; }
                if esc == 'r' { out_buf.push('\r'); i += 2; continue; }
                if esc == '\\' { out_buf.push('\\'); i += 2; continue; }
            }
            out_buf.push(c);
            i++;
        }

        // Repeat only when this pass consumed arguments and more remain.
        if arg_idx >= args.len || arg_idx == cycle_start { break; }
    }

    write_stdout(out_buf);
    flush_stdout();
    return 0;
}

// Poll active background jobs and report completed ones
fn poll_jobs(state: ShellState&) {
    var k: i64 = 0;
    while k < state.jobs.len {
        var status: i32 = 0;
        let res = gosh_poll_job(state.jobs[k].pid, status);
        if res == 1 {
            if state.interactive {
                print("[", state.jobs[k].id, "]+ Done                    ", state.jobs[k].cmd);
            }
            remove_at(state.jobs, k);
            state.job_count = state.jobs.len as i32;
        } else if res == -1 {
            remove_at(state.jobs, k);
            state.job_count = state.jobs.len as i32;
        } else {
            k++;
        }
    }
}

// Builtin: jobs
fn builtin_jobs(state: ShellState&) -> i32 {
    poll_jobs(state);
    for j in state.jobs {
        print("[", j.id, "]+ Running                 ", j.cmd, " &");
    }
    return 0;
}

// Builtin: fg [%n]
fn builtin_fg(state: ShellState&, args: const u8[..128][..16]&) -> i32 {
    poll_jobs(state);
    if state.jobs.len == 0 {
        print("gosh: fg: current: no such job");
        return 1;
    }

    var target_id = -1;
    if args.len > 1 {
        var s = args[1];
        if starts_with(s, "%") { s = s[1..]; }
        let id, ok = parse_int(s);
        if ok { target_id = id as i32; }
    }

    var job_idx = -1;
    if target_id >= 0 {
        for i in state.jobs.len {
            if state.jobs[i].id == target_id {
                job_idx = i as i32;
                break;
            }
        }
    } else {
        job_idx = (state.jobs.len - 1) as i32;
    }

    if job_idx < 0 {
        print("gosh: fg: no such job");
        return 1;
    }

    let job = state.jobs[job_idx];
    print(job.cmd);

    if gosh_term_isatty(0) != 0 {
        gosh_tcsetpgrp(0, job.pid);
    }

    gosh_kill(job.pid, 18); // SIGCONT
    let st = gosh_wait_pid(job.pid);

    if gosh_term_isatty(0) != 0 {
        gosh_tcsetpgrp(0, gosh_get_pid());
    }

    remove_at(state.jobs, job_idx);
    state.job_count = state.jobs.len as i32;
    return st;
}

// Builtin: bg [%n]
fn builtin_bg(state: ShellState&, args: const u8[..128][..16]&) -> i32 {
    poll_jobs(state);
    if state.jobs.len == 0 {
        print("gosh: bg: current: no such job");
        return 1;
    }

    var target_id = -1;
    if args.len > 1 {
        var s = args[1];
        if starts_with(s, "%") { s = s[1..]; }
        let id, ok = parse_int(s);
        if ok { target_id = id as i32; }
    }

    var job_idx = -1;
    if target_id >= 0 {
        for i in state.jobs.len {
            if state.jobs[i].id == target_id {
                job_idx = i as i32;
                break;
            }
        }
    } else {
        job_idx = (state.jobs.len - 1) as i32;
    }

    if job_idx < 0 {
        print("gosh: bg: no such job");
        return 1;
    }

    let job = state.jobs[job_idx];
    gosh_kill(job.pid, 18); // SIGCONT
    print("[", job.id, "]+ ", job.cmd, " &");
    return 0;
}

// Builtin: help
fn builtin_help() -> i32 {
    print("""
\033[1;36mGOSH — A High-Performance Native Unix Shell Written in Goose\033[0m

Available Builtins:
  cd [dir]                Change the current directory (- for OLDPWD)
  pwd                     Print current working directory
  exit [n]                Exit the shell with status code n
  export [VAR[=VAL]]      Export variables to environment
  unset [VAR...]          Unset shell variables
  echo [-n] [-e] [args]   Print arguments to stdout with escape support
  printf fmt [args]       Format and print data
  history                 Display command history
  alias [name=val]        Define or display aliases
  unalias name...         Remove defined alias
  type [name...]          Describe how a command would be interpreted
  command cmd [args]      Execute command bypassing functions/aliases
  jobs                    List active background jobs
  fg [%n]                 Bring job to foreground
  bg [%n]                 Resume job in background
  source file / . file    Execute commands from a file in current shell
  set                     Display all shell variables
  test / [ expr ]         Evaluate conditional expression (fast in-process)
  help                    Display this help message

Interactive Features:
  * Real-time syntax highlighting while typing (Green for valid executables)
  * Fish-style autosuggestions (press Right Arrow or Tab to accept)
  * Zsh-inspired Tab completion for commands, files, directories, variables
  * Fast history navigation (Up/Down arrows) and interactive search (Ctrl+R)
  * Git-aware prompt with instant branch detection
""");
    return 0;
}
